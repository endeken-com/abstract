// Claude Code as an Abstract agent plugin (ABS-185), moved from Abstract's
// ClaudeProvider.swift and ClaudeModels.swift.
//
// Wire format: `claude -p --output-format stream-json --input-format stream-json
// --verbose --include-partial-messages`. Every stdout line is one JSON object.
// Shapes come from `Tests/AbstractCoreTests/Fixtures/claude-*.jsonl` (claude CLI
// 2.1.274 and later). The prompt is never an argv argument: it is written to
// stdin as a stream-json user turn, and so is every follow-up, permission
// answer, mode change, interrupt and task request.
"use strict";

const SETTINGS_FILE = ".claude/settings.json";
const PROVIDER_ID = "claude";
/** Max diff lines kept in an edit preview; the UI only renders a mini-diff. */
const MAX_PREVIEW_LINES = 200;

const BASE_ARGS = [
  "-p",
  "--output-format", "stream-json",
  "--input-format", "stream-json",
  "--verbose",
  "--include-partial-messages",
  // After a turn with an obvious next step, a `prompt_suggestion` line.
  "--prompt-suggestions", "true",
  // Headless runs omit thinking text unless asked; with summaries the
  // Thinking and Verbose transcripts have something to show, for past
  // turns too (verified against claude 2.1.274).
  "--thinking-display", "summarized",
];

/** `claude -p` with no tools, the small model and JSON output, reading the
 * prompt from stdin (`--tools` takes several values, so a prompt argument
 * after it would be read as one). */
const NAMING_ARGS = ["-p", "--tools", "", "--model", "haiku", "--output-format", "json", "--no-session-persistence"];

/** Offered under "Specific versions" alongside whatever the account's aliases resolve to today. */
const PINNED_VERSIONS = ["claude-fable-5-1", "claude-opus-5-5", "claude-opus-5-5[1m]", "claude-sonnet-5", "claude-haiku-4-5-20251001"];
/** The levels claude 2.1.274 reports for every model that takes an effort. */
const EFFORT_LEVELS = ["low", "medium", "high", "xhigh", "max"];
const DISCOVERY_TIMEOUT = 15;

const STYLE_TITLES = { proactive: "Proactive", concise: "Concise", explanatory: "Explanatory", learning: "Learning" };

// MARK: Swift's strings, as the Swift provider compared them

// Foundation's character sets: `.whitespaces` is Zs and tab; with newlines
// it adds U+000A–U+000D, U+0085, U+2028 and U+2029 (JS's trim differs).
const SPACES = "\\t \\u00A0\\u1680\\u2000-\\u200A\\u202F\\u205F\\u3000";
const NEWLINES = "\\n\\u000B\\f\\r\\u0085\\u2028\\u2029";
const TRIM_ALL = new RegExp("^[" + SPACES + NEWLINES + "]+|[" + SPACES + NEWLINES + "]+$", "g");
function trim(text) { return text.replace(TRIM_ALL, ""); }

const ASCII = /^[\x00-\x7f]*$/;
/** A string as Swift compares it: by canonical equivalence. */
function canon(text) { return ASCII.test(text) ? text : text.normalize("NFC"); }
/** Swift's `==` on strings. */
function same(a, b) { return a === b || canon(a) === canon(b); }
/** `==` on two `String?`: nil equals nil. */
function sameOptional(a, b) { return a === undefined || b === undefined ? a === b : same(a, b); }

const SEGMENTER = typeof Intl !== "undefined" && typeof Intl.Segmenter === "function"
  ? new Intl.Segmenter("en", { granularity: "grapheme" }) : null;
/** A string's Swift `Character`s: its extended grapheme clusters. */
function characters(text) {
  return SEGMENTER ? Array.from(SEGMENTER.segment(text), piece => piece.segment) : Array.from(text);
}
/** Swift's `hasPrefix`: whole characters, by canonical equivalence. */
function hasPrefix(text, prefix) {
  const count = characters(prefix).length;
  if (count === 0) return true;
  let head = "", taken = 0;
  for (const piece of SEGMENTER ? SEGMENTER.segment(text) : Array.from(text, segment => ({ segment }))) {
    head += piece.segment;
    if (++taken === count) break;
  }
  return taken === count && same(head, prefix);
}
/** Swift's `hasSuffix`. */
function hasSuffix(text, suffix) {
  const count = characters(suffix).length;
  if (count === 0) return true;
  const all = characters(text);
  return all.length >= count && same(all.slice(all.length - count).join(""), suffix);
}
/** `split(separator: "-")`, by characters, empty pieces dropped. */
function splitDashes(text) {
  const parts = [];
  let part = "";
  for (const character of characters(text)) {
    if (character === "-") {
      if (part !== "") parts.push(part);
      part = "";
    } else part += character;
  }
  if (part !== "") parts.push(part);
  return parts;
}

/** `Int(text)`: an optional sign and ASCII digits; nil past Int64. */
function swiftInt(text) {
  const match = /^([+-]?)([0-9]+)$/.exec(text);
  if (!match) return undefined;
  const digits = match[2].replace(/^0+(?=.)/, "");
  const limit = match[1] === "-" ? "9223372036854775808" : "9223372036854775807";
  if (digits.length > 19 || (digits.length === 19 && digits > limit)) return undefined;
  return Number(match[1] + digits);
}

/** An `Int` as Swift prints it: every digit, never an exponent. */
function intString(value) {
  return Number.isSafeInteger(value) ? String(value) : BigInt(value).toString();
}

// MARK: JSON as the Swift provider decoded it

const FAIL = {};

/** `JSONDecoder` into `JSONValue` (`serialization`: `JSONSerialization`
 * instead). Both differ from `JSON.parse`: a trailing comma is fine, the
 * first of two equal keys wins, a lone surrogate escape or a number out of
 * Double's range fails the whole text (JSONSerialization lets an underflow
 * and a negative overflow through), and nesting is capped. undefined when
 * it fails. */
function parseJSON(text, serialization) {
  const n = text.length;
  const maxDepth = serialization ? 513 : 512;
  let i = text.charCodeAt(0) === 0xfeff ? 1 : 0;

  function fail() { throw FAIL; }
  function ws() {
    while (i < n) {
      const c = text.charCodeAt(i);
      if (c === 0x20 || c === 0x09 || c === 0x0a || c === 0x0d) i++;
      else break;
    }
  }
  function hex4() {
    if (i + 4 > n) fail();
    const digits = text.slice(i, i + 4);
    if (!/^[0-9a-fA-F]{4}$/.test(digits)) fail();
    i += 4;
    return parseInt(digits, 16);
  }
  function string() {
    i++;
    let out = "", start = i;
    for (;;) {
      if (i >= n) fail();
      const c = text.charCodeAt(i);
      if (c === 0x22) { out += text.slice(start, i); i++; return out; }
      if (c < 0x20) fail();
      if (c !== 0x5c) { i++; continue; }
      out += text.slice(start, i);
      i++;
      if (i >= n) fail();
      const e = text[i++];
      switch (e) {
        case "\"": out += "\""; break;
        case "\\": out += "\\"; break;
        case "/": out += "/"; break;
        case "b": out += "\b"; break;
        case "f": out += "\f"; break;
        case "n": out += "\n"; break;
        case "r": out += "\r"; break;
        case "t": out += "\t"; break;
        case "u": {
          const unit = hex4();
          if (unit >= 0xdc00 && unit <= 0xdfff) fail();
          if (unit >= 0xd800 && unit <= 0xdbff) {
            if (text[i] !== "\\" || text[i + 1] !== "u") fail();
            i += 2;
            const low = hex4();
            if (low < 0xdc00 || low > 0xdfff) fail();
            out += String.fromCharCode(unit, low);
          } else out += String.fromCharCode(unit);
          break;
        }
        default: fail();
      }
      start = i;
    }
  }
  const NUMBER = /-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?/y;
  function number() {
    NUMBER.lastIndex = i;
    const match = NUMBER.exec(text);
    if (!match || match[0] === "") fail();
    const token = match[0];
    i += token.length;
    const value = Number(token);
    if (serialization) {
      if (value === Infinity) fail();
    } else if (!isFinite(value) || (value === 0 && /[1-9]/.test(token.split(/[eE]/)[0]))) {
      fail();
    }
    return value;
  }
  function literal(word, value) {
    if (!text.startsWith(word, i)) fail();
    i += word.length;
    return value;
  }
  function put(object, key, value) {
    if (key === "__proto__") Object.defineProperty(object, key, { value, enumerable: true, writable: true, configurable: true });
    else object[key] = value;
  }
  function object(depth) {
    if (depth > maxDepth) fail();
    i++;
    const out = {};
    const seen = new Set();
    ws();
    if (text.charCodeAt(i) === 0x7d) { i++; return out; }
    for (;;) {
      ws();
      if (text.charCodeAt(i) !== 0x22) fail();
      const key = string();
      ws();
      if (text.charCodeAt(i) !== 0x3a) fail();
      i++;
      const item = value(depth);
      const id = serialization ? key : canon(key);
      if (!seen.has(id)) { seen.add(id); put(out, key, item); }
      ws();
      const c = text.charCodeAt(i);
      if (c === 0x2c) {
        i++;
        ws();
        if (text.charCodeAt(i) === 0x7d) { i++; return out; }
        continue;
      }
      if (c === 0x7d) { i++; return out; }
      fail();
    }
  }
  function array(depth) {
    if (depth > maxDepth) fail();
    i++;
    const out = [];
    ws();
    if (text.charCodeAt(i) === 0x5d) { i++; return out; }
    for (;;) {
      out.push(value(depth));
      ws();
      const c = text.charCodeAt(i);
      if (c === 0x2c) {
        i++;
        ws();
        if (text.charCodeAt(i) === 0x5d) { i++; return out; }
        continue;
      }
      if (c === 0x5d) { i++; return out; }
      fail();
    }
  }
  function value(depth) {
    ws();
    if (i >= n) fail();
    switch (text.charCodeAt(i)) {
      case 0x7b: return object(depth + 1);
      case 0x5b: return array(depth + 1);
      case 0x22: return string();
      case 0x74: return literal("true", true);
      case 0x66: return literal("false", false);
      case 0x6e: return literal("null", null);
      default: return number();
    }
  }
  try {
    const result = value(0);
    ws();
    if (i !== n) return undefined;
    return result;
  } catch (e) {
    if (e === FAIL) return undefined;
    throw e;
  }
}

function isObject(value) { return value !== null && typeof value === "object" && !Array.isArray(value); }
/** `value?[key]`: a key present with `null` is a value, as in JSONValue. */
function get(value, key) {
  return isObject(value) && Object.prototype.hasOwnProperty.call(value, key) ? value[key] : undefined;
}
function str(value) { return typeof value === "string" ? value : undefined; }
function bool(value) { return typeof value === "boolean" ? value : undefined; }
function arr(value) { return Array.isArray(value) ? value : undefined; }
function strings(value) { return (arr(value) ?? []).map(str).filter(x => x !== undefined); }
/** `ClaudeWire.double`: finite numbers only. */
function double(value) { return typeof value === "number" && isFinite(value) ? value : undefined; }
/** `ClaudeWire.int`: toward zero, nil out of Int64's range. */
function int(value) {
  const d = double(value);
  if (d === undefined) return undefined;
  const t = Math.trunc(d);
  return t >= -9223372036854775808 && t < 9223372036854775808 ? t : undefined;
}
function nonEmpty(value) {
  const s = str(value);
  return s === undefined || s === "" ? undefined : s;
}
/** An object without its undefined members: Swift's nil is a missing key. */
function compact(object) {
  const out = {};
  for (const key of Object.keys(object)) if (object[key] !== undefined) out[key] = object[key];
  return out;
}
/** A JSON string literal, escaped as the Swift provider did (as `JSON.stringify`). */
function quoted(text) { return JSON.stringify(text); }

// MARK: Base64, as Foundation reads it

const BASE64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

function utf8Length(text) {
  let length = 0;
  for (let i = 0; i < text.length; i++) {
    const c = text.charCodeAt(i);
    if (c < 0x80) length += 1;
    else if (c < 0x800) length += 2;
    else if (c >= 0xd800 && c <= 0xdbff) { length += 4; i++; }
    else length += 3;
  }
  return length;
}

/** `Data(base64Encoded:options: .ignoreUnknownCharacters)`: the bytes, or null. */
function base64Decode(text) {
  if (text === "") return [];
  const bytes = [];
  const quantum = [];
  let padOnly = false, sawSymbol = false;
  for (const ch of text) {
    if (ch !== "=" && BASE64.indexOf(ch) < 0) continue;
    sawSymbol = true;
    if (padOnly && ch !== "=") return null;
    quantum.push(ch);
    if (quantum.length < 4) continue;
    const pad = quantum.indexOf("=");
    const v = quantum.map(c => BASE64.indexOf(c));
    if (pad < 0) {
      bytes.push(((v[0] << 2) | (v[1] >> 4)) & 255, ((v[1] << 4) | (v[2] >> 2)) & 255, ((v[2] << 6) | v[3]) & 255);
      quantum.length = 0;
      continue;
    }
    if (quantum.slice(pad).some(c => c !== "=")) return null;
    if (pad === 0) { padOnly = true; quantum.length = 0; continue; }
    if (pad < 2) return null;
    bytes.push(((v[0] << 2) | (v[1] >> 4)) & 255);
    if (pad === 3) bytes.push(((v[1] << 4) | (v[2] >> 2)) & 255);
    return bytes;
  }
  if (quantum.some(c => c !== "=")) return null;
  if (bytes.length === 0) return !sawSymbol && utf8Length(text) % 4 === 0 ? [] : null;
  return bytes;
}

/** `base64EncodedString()`. */
function base64Encode(bytes) {
  let out = "";
  for (let i = 0; i < bytes.length; i += 3) {
    const a = bytes[i], b = bytes[i + 1], c = bytes[i + 2];
    out += BASE64[a >> 2] + BASE64[((a & 3) << 4) | ((b ?? 0) >> 4)];
    out += b === undefined ? "=" : BASE64[((b & 15) << 2) | ((c ?? 0) >> 6)];
    out += c === undefined ? "=" : BASE64[c & 63];
  }
  return out;
}

// MARK: Launching

/** `--permission-prompt-tool stdio` routes every approval to Abstract as a
 * `can_use_tool` control request. Without it, a headless run quietly denies
 * anything that needs approval (verified against claude 2.1.274). Every mode
 * keeps it, and `--allow-dangerously-skip-permissions` makes full autonomy
 * reachable, so the mode can change live in either direction without a restart. */
function policyArgs(policy) {
  let mode;
  switch (policy) {
    case "auto-edits": mode = ["--permission-mode", "acceptEdits"]; break;
    case "bypass": mode = ["--permission-mode", "bypassPermissions"]; break;
    // Its plan mode is the read-only one: it explores, then asks to start
    // through `ExitPlanMode`, whatever the message was.
    case "plan": case "read-only": mode = ["--permission-mode", "plan"]; break;
    default: mode = [];
  }
  return mode.concat(["--permission-prompt-tool", "stdio", "--allow-dangerously-skip-permissions"]);
}

/** Library skills (ABS-122): Claude loads `.claude/skills` from every folder
 * added with `--add-dir`, links included, as it does from the worktree's.
 * Passed on every resume too. */
function skillArgs(skills) {
  return skills ? ["--add-dir", skills.folder] : [];
}

/** How Claude names an MCP tool in rules and in its stream: any character but
 * ASCII letters, digits, `_` and `-` becomes `_`, as Claude does it. A
 * server's odd tool name (`x,Bash`) so stays one rule for that tool and can't
 * widen `--allowedTools` to another. */
function toolName(server, tool) {
  const clean = s => characters(s).map(c => /^[A-Za-z0-9_-]$/.test(c) ? c : "_").join("");
  return "mcp__" + clean(server) + "__" + clean(tool);
}

/** Every MCP server the chat gets, in one config: the code-history tool, the
 * plugin-tools server, the branch tool and the project's servers. It sits
 * beside the user's own servers (never `--strict-mcp-config`) and is passed on
 * every resume too. With a chat folder it's a file only the user can read,
 * since headers and environment can hold keys; argv can be read by anyone.
 *
 * Allowed tools run without asking (`--allowedTools`), Off tools are taken
 * away (`--disallowedTools`), and Ask first tools get an `ask` rule in
 * `settingsArgs`, which asks even under full autonomy. */
function mcpArgs(ctx) {
  const servers = ctx.mcpServers || [];
  if (!servers.length) return [];
  const config = {};
  for (const server of servers) {
    const connection = server.connection;
    let entry;
    if (connection.type === "url") {
      entry = { type: "http", url: connection.url };
      if (Object.keys(connection.headers || {}).length) entry.headers = connection.headers;
    } else {
      const argv = connection.argv || [];
      entry = { command: argv.length ? argv[0] : "", args: argv.slice(1) };
      if (Object.keys(connection.env || {}).length) entry.env = connection.env;
    }
    Object.defineProperty(config, server.name, { value: entry, enumerable: true, writable: true, configurable: true });
  }
  const json = AbstractAgent.compactJSON({ mcpServers: config });
  const file = ctx.configDirectory != null ? AbstractAgent.writeConfigFile("claude-mcp.json", json) : null;
  const args = ["--mcp-config", file ?? json];
  // The code-history tools by name; the plugin-tools server's by its name:
  // Abstract asks itself for a plugin tool set to Ask first, so Claude
  // mustn't ask again, and the list can change mid-chat.
  const history = AbstractAgent.constants.codeHistory;
  const allowed = servers.flatMap(server => {
    if (same(server.name, history.server) && server.allowsEverything) {
      return [history.historyTool, history.excerptTool].map(tool => "mcp__" + history.server + "__" + tool);
    }
    return server.allowsEverything ? ["mcp__" + server.name] : server.allowed.map(tool => toolName(server.name, tool));
  });
  if (allowed.length) args.push("--allowedTools", allowed.join(","));
  const off = servers.flatMap(server => server.off.map(tool => toolName(server.name, tool)));
  if (off.length) args.push("--disallowedTools", off.join(","));
  return args;
}

/** Everything appended to Claude's system prompt, as one argument: the
 * profile's instructions (ABS-101) first, then how to use the code-history
 * tool when the chat gets it, then the project's notes on its MCP servers. */
function instructionArgs(ctx) {
  const parts = [ctx.instructions, ctx.historyTool == null ? null : AbstractAgent.constants.codeHistory.instruction,
                 ctx.toolNotes].filter(part => part != null);
  return parts.length ? ["--append-system-prompt", parts.join("\n\n")] : [];
}

/** Claude's built-in styles go by their display name in its settings. */
function styleArgs(style) {
  const title = STYLE_TITLES[style];
  return style === "default" || typeof title !== "string" ? [] : ["--settings", '{"outputStyle":"' + title + '"}'];
}

/** Extra settings for this run: the output style, and an `ask` rule for
 * every MCP tool set to Ask first. */
function settingsArgs(ctx) {
  const style = ctx.outputStyle.id;
  const ask = (ctx.toolServers || []).flatMap(server => server.askFirst.map(tool => toolName(server.name, tool)));
  if (!ask.length) return styleArgs(style);
  const settings = { permissions: { ask } };
  if (style !== "default" && typeof STYLE_TITLES[style] === "string") settings.outputStyle = STYLE_TITLES[style];
  return ["--settings", AbstractAgent.compactJSON(settings)];
}

/** A picture as a content block; null when it can't be read or isn't a
 * type Claude takes (its path is in the text). Reading it is the host's,
 * and only for the pictures the launch or message being built sends. */
function imageBlock(path) {
  const image = typeof AbstractAgent.readImage === "function" ? AbstractAgent.readImage(path) : null;
  if (!isObject(image) || typeof image.mediaType !== "string" || typeof image.base64Data !== "string") return null;
  return '{"type":"image","source":{"type":"base64","media_type":' + quoted(image.mediaType)
    + ',"data":"' + image.base64Data + '"}}';
}

/** One stream-json user turn. Keys are written in a fixed order so the line is
 * byte-identical to what the CLI's own SDK sends. Images first, then the text,
 * as Anthropic suggests. */
function userMessageLine(text, images) {
  const blocks = (images || []).map(imageBlock).filter(block => block !== null)
    .concat(['{"type":"text","text":' + quoted(text) + "}"]);
  return '{"type":"user","message":{"role":"user","content":[' + blocks.join(",") + "]}}\n";
}

function launch(ctx, resumeId) {
  return {
    args: BASE_ARGS.concat(policyArgs(ctx.permissionPolicy),
      ctx.readableDirs.flatMap(dir => ["--add-dir", dir]),
      skillArgs(ctx.skills),
      ctx.model != null ? ["--model", ctx.model] : [],
      ctx.effort != null ? ["--effort", ctx.effort] : [],
      settingsArgs(ctx), mcpArgs(ctx), instructionArgs(ctx),
      resumeId != null ? ["--resume", resumeId] : [],
      ctx.extraArgs),
    env: { CLAUDE_CODE_BASH_EDIT_DIFF: "1" },
    stdin: userMessageLine(ctx.prompt, ctx.images),
    keepStdinOpen: true,
  };
}

// MARK: Answers on stdin

function message({ text, images }) { return userMessageLine(text, images || []); }

/** Verified against a live `can_use_tool` prompt: allow runs the tool with
 * `updatedInput`; deny returns `message` to the agent as the tool's error and
 * the agent carries on. */
function permission({ requestId, allow, input }) {
  let response;
  if (allow) {
    const json = input == null ? null : AbstractAgent.compactJSON(input);
    response = '{"behavior":"allow","updatedInput":' + (json == null || json === "" ? "{}" : json) + "}";
  } else {
    response = '{"behavior":"deny","message":"Denied by user"}';
  }
  return '{"type":"control_response","response":{"subtype":"success","request_id":' + quoted(requestId)
    + ',"response":' + response + "}}\n";
}

/** `set_permission_mode` with "default", "acceptEdits", "bypassPermissions"
 * or "plan" answers success (verified against claude's control channel). */
function permissionMode({ policy, requestId }) {
  let mode;
  switch (policy) {
    case "ask": mode = "default"; break;
    case "auto-edits": mode = "acceptEdits"; break;
    case "bypass": mode = "bypassPermissions"; break;
    case "plan": case "read-only": mode = "plan"; break;
    default: return null;
  }
  return '{"type":"control_request","request_id":' + quoted(requestId)
    + ',"request":{"subtype":"set_permission_mode","mode":' + quoted(mode) + "}}\n";
}

/** The task ends as `stopped`, reported by `task_notification` (claude 2.1.280). */
function stopTask({ taskId, requestId }) {
  return '{"type":"control_request","request_id":' + quoted(requestId)
    + ',"request":{"subtype":"stop_task","task_id":' + quoted(taskId) + "}}\n";
}

/** The turn ends with a `result` whose `terminal_reason` is `aborted_streaming`
 * (or `aborted_tools` mid-tool), and the process, its session and its
 * background tasks stay for the next message (claude 2.1.283). */
function interrupt({ requestId }) {
  return '{"type":"control_request","request_id":' + quoted(requestId) + ',"request":{"subtype":"interrupt"}}\n';
}

/** `background_tasks`, the control-request form of Ctrl+B: the blocking call
 * returns at once and the work carries on as a background task. */
function background({ toolUseId, requestId }) {
  const target = toolUseId != null ? ',"tool_use_id":' + quoted(toolUseId) : "";
  return '{"type":"control_request","request_id":' + quoted(requestId)
    + ',"request":{"subtype":"background_tasks"' + target + "}}\n";
}

// MARK: Reading its output

function rawEvent(line, stream) { return { type: "raw", line, stream }; }
function status(value, detail) { return compact({ type: "status", status: value, detail }); }
function errorEvent(message) { return { type: "error", message }; }

/** The summary Claude Code resumes from, minus its fixed opening. */
function compactSummary(text) {
  let body = text;
  if (hasPrefix(body, "This session is being continued")) {
    const at = body.indexOf("Summary:\n");
    if (at >= 0) body = body.slice(at + "Summary:\n".length);
  }
  const trimmed = trim(body);
  return trimmed === "" ? undefined : trimmed;
}

/** A tool_result `content` field: a string, or an array of content blocks. */
function flatten(content) {
  const s = str(content);
  if (s !== undefined) return s;
  return (arr(content) ?? []).map(block => str(get(block, "text"))).filter(x => x !== undefined).join("");
}

/** The `image` blocks of a tool_result `content` array, as Claude sends them. */
function images(content) {
  const out = [];
  for (const block of arr(content) ?? []) {
    if (str(get(block, "type")) !== "image") continue;
    const source = get(block, "source");
    if (source === undefined || str(get(source, "type")) !== "base64") continue;
    const encoded = str(get(source, "data"));
    if (encoded === undefined) continue;
    const bytes = base64Decode(encoded);
    if (bytes === null) continue;
    out.push({ mediaType: str(get(source, "media_type")) ?? "image/png", data: base64Encode(bytes) });
  }
  return out;
}

const TASK_STATUS = { pending: "running", running: "running", completed: "completed", failed: "failed",
                      killed: "stopped", stopped: "stopped" };
/** The CLI's own task states; "killed" is a stopped task. */
function taskStatus(raw) {
  return raw !== undefined && Object.prototype.hasOwnProperty.call(TASK_STATUS, raw) ? TASK_STATUS[raw] : undefined;
}

function taskUsage(usage) {
  if (!isObject(usage)) return undefined;
  return compact({ tokens: int(get(usage, "total_tokens")), toolUses: int(get(usage, "tool_uses")),
                   durationMs: int(get(usage, "duration_ms")) });
}

/** `task_started`, `task_progress`, `task_updated` or `task_notification`, as
 * claude 2.1.280 sends them (see `Fixtures/claude-background.jsonl`). */
function task(obj) {
  const id = str(get(obj, "task_id"));
  if (id === undefined || id === "") return undefined;
  switch (str(get(obj, "subtype"))) {
    case "task_started": {
      const type = str(get(obj, "task_type"));
      const kind = type === "local_agent" || type === "remote_agent" ? "agent" : type === "local_bash" ? "shell" : "other";
      return { kind: "started", task: compact({
        id, kind, description: str(get(obj, "description")) ?? "", toolUseId: str(get(obj, "tool_use_id")),
        subagentType: str(get(obj, "subagent_type")), prompt: str(get(obj, "prompt")),
        isBackgrounded: get(obj, "is_backgrounded") === true, ownedBySubagent: get(obj, "owned_by_subagent") === true,
        status: "running" }) };
    }
    case "task_progress":
      return compact({ kind: "progress", taskId: id,
                       activity: nonEmpty(get(obj, "summary")) ?? nonEmpty(get(obj, "description")),
                       lastToolName: nonEmpty(get(obj, "last_tool_name")), usage: taskUsage(get(obj, "usage")) });
    case "task_updated": {
      const patch = get(obj, "patch");
      return compact({ kind: "updated", taskId: id, status: taskStatus(str(get(patch, "status"))),
                       isBackgrounded: bool(get(patch, "is_backgrounded")), error: nonEmpty(get(patch, "error")) });
    }
    case "task_notification":
      return compact({ kind: "finished", taskId: id, status: taskStatus(str(get(obj, "status"))) ?? "completed",
                       summary: nonEmpty(get(obj, "summary")), outputFile: nonEmpty(get(obj, "output_file")),
                       usage: taskUsage(get(obj, "usage")) });
    default:
      return undefined;
  }
}

/** A structured patch's hunks as a preview; undefined when no line remains. */
function patchPreview(patch, filePath) {
  const lines = [];
  let additions = 0, deletions = 0;
  patch.forEach((hunk, index) => {
    // Unknown starts leave the lines unnumbered rather than counting from 0.
    let oldLine = int(get(hunk, "oldStart")), newLine = int(get(hunk, "newStart"));
    let first = index > 0;
    for (const entry of arr(get(hunk, "lines")) ?? []) {
      if (typeof entry !== "string") continue;
      // Counted past the cap so the +/− totals stay true.
      const rest = entry.slice(1);
      let line;
      switch (entry[0]) {
        case "+":
          additions++;
          line = compact({ origin: "+", content: rest, newLine });
          if (newLine !== undefined) newLine += 1;
          break;
        case "-":
          deletions++;
          line = compact({ origin: "-", content: rest, oldLine });
          if (oldLine !== undefined) oldLine += 1;
          break;
        case " ":
          line = compact({ origin: " ", content: rest, oldLine, newLine });
          if (oldLine !== undefined) oldLine += 1;
          if (newLine !== undefined) newLine += 1;
          break;
        default:
          line = { origin: " ", content: entry };
      }
      if (lines.length < MAX_PREVIEW_LINES) {
        if (first) { line.startsHunk = true; first = false; }
        lines.push(line);
      }
    }
  });
  if (!lines.length) return undefined;
  return { filePath, additions, deletions, lines };
}

/** A freshly created file: every line is an addition. */
function createdPreview(filePath, content) {
  const all = content.split("\n");
  if (all[all.length - 1] === "") all.pop();
  return { filePath, additions: all.length, deletions: 0,
           lines: all.slice(0, MAX_PREVIEW_LINES).map((text, index) => ({ origin: "+", content: text, newLine: index + 1 })) };
}

function editPreview(result) {
  if (!isObject(result)) return undefined;
  const filePath = str(get(result, "filePath")) ?? str(get(result, "file_path")) ?? "";
  const patch = arr(get(result, "structuredPatch")) ?? [];
  if (patch.length) return patchPreview(patch, filePath);
  const content = str(get(result, "content"));
  if (str(get(result, "type")) === "create" && content !== undefined) return createdPreview(filePath, content);
  return undefined;
}

function bashEditDiff(result) {
  const diff = get(result, "bashEditDiff");
  if (!isObject(diff) || get(diff, "skipped") === true) return undefined;
  const previews = [];
  for (const file of arr(get(diff, "files")) ?? []) {
    const path = str(get(file, "filePath"));
    if (path === undefined || path === "") continue;
    const preview = patchPreview(arr(get(file, "hunks")) ?? [], path);
    if (preview !== undefined) previews.push(preview);
  }
  const previewPaths = new Set(previews.map(preview => canon(preview.filePath)));
  const remainingPaths = strings(get(diff, "changedFiles")).filter(path => !previewPaths.has(canon(path)));
  const moreFiles = Math.max(0, int(get(diff, "moreFiles")) ?? 0);
  const incomplete = get(diff, "unavailable") === true || get(diff, "shared") === true;
  if (!previews.length && !remainingPaths.length && moreFiles <= 0 && !incomplete) return undefined;
  return { previews, remainingPaths, moreFiles, incomplete };
}

function gitOperations(result) {
  const report = get(result, "gitOperation");
  return report === undefined ? [] : AbstractAgent.gitOperationsFromReport(report);
}

/** Stateful stream-json parser, one per process. Block ids are
 * `messageId:index`, where index is the content block's index in the streamed
 * message, so the final text from an `assistant` frame replaces the partial
 * deltas that preceded it. */
function claudeParser() {
  let messageId = "";
  /** Blocks of the message currently streaming, by stream index. Kept until
   * the next `message_start` (not dropped at `content_block_stop`) because
   * the CLI may send the complete `assistant` frame after the stop. */
  let blocks = new Map();
  /** From `init`: which commands are skills, and which only work in a terminal. */
  let skills = new Set();
  let terminalOnly = new Set();
  /** The last `rate_limit_event`'s status, window and reset time. */
  let lastRateLimit = null;
  /** The CLI said the turn under way was interrupted; its `result` follows. */
  let interrupted = false;
  /** A `compact_boundary` whose summary turn hasn't arrived yet. */
  let boundary = null;

  function finishCompaction(summary) {
    if (boundary === null) return [];
    const pending = boundary;
    boundary = null;
    return [{ type: "compaction", compaction: compact({
      kind: "finished", result: compact(Object.assign({}, pending.result, { summary })),
      trigger: pending.trigger, durationMs: pending.durationMs }) }];
  }

  function under(parent, events) {
    return parent === undefined ? events : events.map(event => ({ type: "subagent", parentToolUseId: parent, event }));
  }

  /** The commands as a chat lists them: each name once, skills marked,
   * terminal-only ones left out. null when none are left. */
  function commandList(commands) {
    const seen = new Set();
    const list = [];
    for (const command of commands) {
      const key = canon(command.name);
      if (terminalOnly.has(key) || seen.has(key)) continue;
      seen.add(key);
      list.push(compact({ name: command.name, kind: skills.has(key) ? "skill" : "command",
                          detail: command.detail, argumentHint: command.argumentHint }));
    }
    return list.length ? { type: "commands", providerId: PROVIDER_ID, commands: list } : null;
  }

  function onSystem(obj) {
    switch (str(get(obj, "subtype"))) {
      case "init": {
        const sessionId = str(get(obj, "session_id"));
        const events = [];
        if (sessionId !== undefined) events.push({ type: "sessionId", id: sessionId });
        events.push(compact({ type: "system", model: str(get(obj, "model")), cwd: str(get(obj, "cwd")),
                              permissionMode: str(get(obj, "permissionMode")), sessionId }));
        const skillNames = strings(get(obj, "skills"));
        skills = new Set(skillNames.map(canon));
        terminalOnly = new Set(strings(get(obj, "terminal_slash_commands")).map(canon));
        const names = strings(get(obj, "slash_commands"));
        const list = commandList(names.concat(skillNames).map(name => ({ name })));
        if (list) events.push(list);
        return events;
      }
      case "commands_changed": {
        const commands = [];
        for (const c of arr(get(obj, "commands")) ?? []) {
          const name = str(get(c, "name"));
          if (name === undefined) continue;
          commands.push({ name, detail: nonEmpty(get(c, "description")), argumentHint: nonEmpty(get(c, "argumentHint")) });
        }
        const list = commandList(commands);
        return list ? [list] : [];
      }
      case "post_turn_summary": {
        const events = [compact({ type: "turnEnd", summary: str(get(obj, "status_detail")) })];
        const needsAction = str(get(obj, "needs_action"));
        if (needsAction !== undefined && needsAction !== "") events.push(status("waiting_input", needsAction));
        return events;
      }
      case "task_started": case "task_progress": case "task_updated": case "task_notification": {
        const event = task(obj);
        return event === undefined ? [] : [{ type: "task", task: event }];
      }
      // Claude Code 2.1.282: `status` says `compacting` as it starts; the
      // boundary follows with what it did, then the summary as a synthetic turn.
      case "status":
        return str(get(obj, "status")) === "compacting" ? [{ type: "compaction", compaction: { kind: "started" } }] : [];
      case "compact_boundary": {
        const meta = get(obj, "compact_metadata");
        const trigger = str(get(meta, "trigger"));
        boundary = {
          trigger: trigger === "manual" || trigger === "auto" ? trigger : undefined,
          result: compact({ tokensBefore: int(get(meta, "pre_tokens")), tokensAfter: int(get(meta, "post_tokens")) }),
          durationMs: int(get(meta, "duration_ms")),
        };
        return [];
      }
      // A failed request it is sending again; `error_status` is null when
      // no answer came back at all.
      case "api_retry": {
        const attempt = int(get(obj, "attempt"));
        if (attempt === undefined) return [];
        return [{ type: "notice", notice: compact({ kind: "retrying", attempt, maxAttempts: int(get(obj, "max_retries")),
                                                    httpStatus: int(get(obj, "error_status")) }) }];
      }
      // Every other system frame is the CLI's own bookkeeping.
      default:
        return [];
    }
  }

  /** `rate_limit_info.status` is "allowed", "allowed_warning" or "rejected",
   * sent before every turn. A notice only when it turns to a warning or a
   * refusal, so a chat near its limit doesn't repeat it each turn. */
  function onRateLimit(obj) {
    const info = get(obj, "rate_limit_info");
    const state = str(get(info, "status"));
    if (info === undefined || state === undefined) return [];
    const resetsAt = double(get(info, "resetsAt"));
    // The reset time as a `Date` keeps it: seconds since 2001, and back.
    const kept = resetsAt === undefined ? "" : String((resetsAt - 978307200) + 978307200);
    const key = canon([state, str(get(info, "rateLimitType")) ?? "", kept].join("|"));
    const repeated = key === lastRateLimit;
    lastRateLimit = key;
    if (repeated) return [];
    const notice = compact({ resetsAt });
    switch (state) {
      case "allowed_warning": return [{ type: "notice", notice: Object.assign({ kind: "nearLimit" }, notice) }];
      case "rejected": return [{ type: "notice", notice: Object.assign({ kind: "limitReached" }, notice) }];
      default: return [];
    }
  }

  function blockId(index) { return messageId + ":" + intString(index); }

  function onStreamEvent(obj) {
    const event = get(obj, "event");
    if (!isObject(event)) return null;
    const index = int(get(event, "index")) ?? 0;
    switch (str(get(event, "type"))) {
      case "message_start":
        messageId = str(get(get(event, "message"), "id")) ?? "";
        blocks = new Map();
        return [status("running")];
      case "content_block_start": {
        const block = get(event, "content_block");
        const type = str(get(block, "type"));
        const kind = type === "text" ? "text" : type === "tool_use" ? "toolUse" : type === "thinking" ? "thinking" : "other";
        blocks.set(index, { kind, toolId: str(get(block, "id")), jsonBuffer: "", delivered: false });
        // The complete block arrives on the `assistant` frame; emitting here
        // too would duplicate it in the transcript.
        return [];
      }
      case "content_block_delta": {
        const delta = get(event, "delta");
        if (!isObject(delta)) return [];
        switch (str(get(delta, "type"))) {
          case "text_delta":
            return [{ type: "text", role: "assistant", text: str(get(delta, "text")) ?? "", blockId: blockId(index), partial: true }];
          case "thinking_delta":
            return [{ type: "thinking", text: str(get(delta, "thinking")) ?? "", blockId: blockId(index), partial: true }];
          case "input_json_delta": {
            const block = blocks.get(index);
            if (block) block.jsonBuffer += str(get(delta, "partial_json")) ?? "";
            return [];
          }
          default:
            return [];
        }
      }
      case "content_block_stop": case "message_delta": case "message_stop":
        return [];
      default:
        return null;
    }
  }

  /** Lowest-index streamed text block not yet delivered by an `assistant` frame. */
  function claimStreamedText() {
    let lowest;
    for (const [index, block] of blocks) {
      if (block.kind === "text" && !block.delivered && (lowest === undefined || index < lowest)) lowest = index;
    }
    if (lowest !== undefined) blocks.get(lowest).delivered = true;
    return lowest;
  }

  /** The tool input assembled from `input_json_delta` chunks, used when the
   * `assistant` frame carries none. */
  function streamedInput(toolId) {
    let found, foundIndex;
    for (const [index, block] of blocks) {
      if (block.kind === "toolUse" && block.toolId !== undefined && same(block.toolId, toolId)
          && (foundIndex === undefined || index < foundIndex)) {
        found = block;
        foundIndex = index;
      }
    }
    if (found === undefined || found.jsonBuffer === "") return undefined;
    return parseJSON(found.jsonBuffer, false);
  }

  /** `mainAgent`: false for a subagent's message, which never streams. */
  function onAssistant(obj, mainAgent) {
    const message = get(obj, "message");
    if (!isObject(message)) return [];
    const id = str(get(message, "id")) ?? messageId;
    // `blocks` describes this message only if it is the one that streamed.
    const streamed = mainAgent && same(id, messageId);
    const events = [];
    (arr(get(message, "content")) ?? []).forEach((block, position) => {
      switch (str(get(block, "type"))) {
        case "text": {
          // The CLI may split one message into several frames (one block
          // each), so the array position is not the stream index.
          const index = (streamed ? claimStreamedText() : undefined) ?? position;
          events.push({ type: "text", role: "assistant", text: str(get(block, "text")) ?? "",
                        blockId: id + ":" + intString(index), partial: false });
          break;
        }
        case "tool_use": {
          const toolId = str(get(block, "id")) ?? "";
          let input = get(block, "input");
          if ((input === undefined || input === null) && streamed) input = streamedInput(toolId);
          events.push({ type: "toolUse", id: toolId, name: str(get(block, "name")) ?? "", input: input === undefined ? {} : input });
          break;
        }
        default:
          break;
      }
    });
    return events;
  }

  function onUser(obj) {
    const message = get(obj, "message");
    if (!isObject(message)) return [];
    const synthetic = get(obj, "isSynthetic") === true;
    if (boundary !== null && synthetic) return finishCompaction(compactSummary(flatten(get(message, "content"))));
    const result = get(obj, "tool_use_result");
    const edit = editPreview(result);
    const fileChanges = bashEditDiff(result);
    const operations = gitOperations(result);
    const events = [];
    for (const block of arr(get(message, "content")) ?? []) {
      switch (str(get(block, "type"))) {
        case "tool_result": {
          const id = str(get(block, "tool_use_id")) ?? "";
          const isError = get(block, "is_error") === true;
          events.push(compact({ type: "toolResult", toolUseId: id, output: flatten(get(block, "content")), isError, edit }));
          if (fileChanges !== undefined) events.push({ type: "toolFileChanges", toolUseId: id, changes: fileChanges });
          const pictures = images(get(block, "content"));
          if (pictures.length) events.push({ type: "toolImages", toolUseId: id, images: pictures });
          if (!isError) for (const operation of operations) events.push({ type: "gitOperation", operation });
          break;
        }
        case "text": {
          // Claude Code's own additions (a skill's instructions, reminders)
          // come as user messages marked synthetic; they aren't yours.
          if (synthetic || get(obj, "isMeta") === true) continue;
          // "[Request interrupted by user]", or "… for tool use": the CLI's
          // note that the turn was stopped, which its result shows.
          const text = str(get(block, "text"));
          if (text !== undefined && hasPrefix(text, "[Request interrupted by user")) {
            interrupted = true;
            continue;
          }
          events.push({ type: "text", role: "user", text: text ?? "", partial: false });
          break;
        }
        default:
          break;
      }
    }
    return events;
  }

  function onResult(obj) {
    const usage = get(obj, "usage");
    // A stopped turn reports itself as an error; it isn't one. Its rule
    // comes first so the usage after it folds in.
    const reason = str(get(obj, "terminal_reason"));
    const stopped = interrupted || (reason !== undefined && hasPrefix(reason, "aborted"));
    interrupted = false;
    const events = finishCompaction().concat(stopped ? [{ type: "turnEnd", summary: "Stopped" }] : []);
    events.push(compact({
      type: "usage",
      usage: { inputTokens: int(get(usage, "input_tokens")) ?? 0, outputTokens: int(get(usage, "output_tokens")) ?? 0,
               cacheRead: int(get(usage, "cache_read_input_tokens")) ?? 0,
               cacheWrite: int(get(usage, "cache_creation_input_tokens")) ?? 0 },
      costUsd: double(get(obj, "total_cost_usd")),
      durationMs: int(get(obj, "duration_ms")),
      turns: int(get(obj, "num_turns")),
    }));
    if (get(obj, "is_error") === true && !stopped) {
      events.push(errorEvent(str(get(obj, "result")) ?? str(get(obj, "subtype")) ?? "Agent reported an error"));
      events.push(status("errored"));
    } else {
      // The process stays alive after a result, awaiting the next stdin turn.
      events.push(status("idle"));
    }
    return events;
  }

  /** Answers to Abstract's own requests. Only failures matter to the reader. */
  function onControlResponse(obj) {
    const response = get(obj, "response");
    if (str(get(response, "subtype")) !== "error") return [];
    return [errorEvent(str(get(response, "error")) ?? "The agent refused the request.")];
  }

  /** `can_use_tool`, as sent with `--permission-prompt-tool stdio`. */
  function onControlRequest(obj) {
    const request = get(obj, "request");
    const requestId = str(get(obj, "request_id"));
    if (!isObject(request) || requestId === undefined || str(get(request, "subtype")) !== "can_use_tool") return null;
    const tool = str(get(request, "tool_name")) ?? "";
    // AskUserQuestion asks the same way; its answers go back as the allowed input.
    const detail = AbstractAgent.isQuestion(tool) ? "Question for you"
      : tool === "" ? "Permission needed" : "Permission needed: " + tool;
    const input = get(request, "input");
    return [{ type: "permissionRequest", requestId, toolName: tool, input: input === undefined ? {} : input },
            status("waiting_input", detail)];
  }

  /** null: not understood, surfaced as a raw line. */
  function dispatch(obj) {
    // A subagent's messages name the tool call that started it. They come
    // whole, never streamed, but may land mid-way through the main agent's.
    const parentId = str(get(obj, "parent_tool_use_id"));
    const parent = parentId === "" ? undefined : parentId;
    switch (str(get(obj, "type"))) {
      case "system": return onSystem(obj);
      case "stream_event": return parent === undefined ? onStreamEvent(obj) : [];
      case "assistant": return under(parent, onAssistant(obj, parent === undefined));
      case "user": return under(parent, onUser(obj));
      case "result": return onResult(obj);
      case "control_request": return onControlRequest(obj);
      case "rate_limit_event": return onRateLimit(obj);
      // A long command's heartbeat; the UI has no use for it.
      case "tool_progress": return [];
      case "control_response": return onControlResponse(obj);
      case "prompt_suggestion": {
        const suggestion = str(get(obj, "suggestion"));
        return suggestion === undefined || suggestion === "" ? [] : [{ type: "promptSuggestion", text: suggestion }];
      }
      default: return null;
    }
  }

  function feed(line, stream) {
    const trimmed = trim(line);
    if (trimmed === "") return [];
    if (stream !== "stdout") return [rawEvent(line, stream)];
    const obj = parseJSON(trimmed, false);
    if (!isObject(obj)) return [rawEvent(line, stream)];
    return dispatch(obj) ?? [rawEvent(line, stream)];
  }

  return {
    feed(lines) { return lines.map(l => feed(l.line, l.stream)); },
    exit(code) {
      const pending = finishCompaction();
      if (code === 0) return pending.concat([status("finished")]);
      return pending.concat([errorEvent("claude exited with code " + (code == null ? "null" : String(code))), status("errored")]);
    },
  };
}

// MARK: Models and settings

/** "claude-haiku-4-5-20251001" → "haiku", "opus[1m]" → "opus". */
function withoutLongContext(id) {
  return hasSuffix(id, "[1m]") ? characters(id).slice(0, -4).join("") : id;
}

function family(id) {
  return splitDashes(withoutLongContext(id)).find(word => !same(word, "claude") && swiftInt(word) === undefined);
}

/** "claude-opus-5-5[1m]" → "Opus 5.5 · 1M context", "claude-haiku-4-5-20251001"
 * → "Haiku 4.5", "sonnet" → "Sonnet". Anything else is returned as is. */
function displayName(id) {
  const longContext = hasSuffix(id, "[1m]");
  const parts = splitDashes(withoutLongContext(id));
  const claude = parts.length > 0 && same(parts[0], "claude");
  if (!claude && parts.length !== 1) return id;
  const words = claude ? parts.slice(1) : parts;
  const name = words.find(word => swiftInt(word) === undefined);
  if (name === undefined) return id;
  // Short numbers are the version; the 8-digit one is a snapshot date.
  const version = words.filter(word => swiftInt(word) !== undefined && characters(word).length <= 2).join(".");
  const letters = characters(name);
  const title = letters[0].toUpperCase() + letters.slice(1).join("") + (version === "" ? "" : " " + version);
  return longContext ? title + " · 1M context" : title;
}

function modelOption(id, label, detail, efforts, resolvedId) {
  return compact({ id, label, detail, efforts, resolvedId });
}

function fallbackModels() {
  const efforts = id => family(id) === "haiku" ? [] : EFFORT_LEVELS.slice();
  return {
    models: ["fable", "opus", "sonnet", "haiku"].map(id => modelOption(id, displayName(id), undefined, efforts(id))),
    versions: PINNED_VERSIONS.map(id => modelOption(id, displayName(id), id, efforts(id))),
  };
}

function entryOption(entry) {
  const value = str(get(entry, "value"));
  if (value === undefined || value === "") return undefined;
  const resolved = str(get(entry, "resolvedModel"));
  const efforts = get(entry, "supportsEffort") === true ? strings(get(entry, "supportedEffortLevels")) : [];
  // "Default (recommended)" says nothing once it sits under our own
  // "Default" row; name the model it runs instead.
  const label = value === "default" ? displayName(resolved ?? value) : str(get(entry, "displayName")) ?? displayName(value);
  return modelOption(value, label, str(get(entry, "description")), efforts, resolved);
}

/** A pinned version takes the efforts of the entry that runs it, then of the
 * same model without 1M context, then of its family. */
function effortsFor(id, entries) {
  const base = withoutLongContext(id);
  const own = family(id);
  const entry = entries.find(e => (e.resolvedId !== undefined && same(e.resolvedId, id)) || same(e.id, id))
    ?? entries.find(e => same(withoutLongContext(e.resolvedId ?? e.id), base))
    ?? entries.find(e => sameOptional(family(e.resolvedId ?? e.id), own));
  return entry === undefined ? [] : entry.efforts;
}

function catalogFromEntries(entries) {
  const parsed = entries.map(entryOption).filter(option => option !== undefined);
  if (!parsed.length) return null;
  const models = parsed.filter(option => option.id !== "default");
  // Specific versions: the pinned list plus what the aliases resolve to
  // today, minus models an entry already pins (Fable's entry is a full id).
  const pinnedByEntries = new Set(models.filter(option => hasPrefix(option.id, "claude-"))
    .flatMap(option => [option.id, option.resolvedId].filter(x => x !== undefined)).map(canon));
  const versionIds = [];
  const listed = new Set();
  for (const id of PINNED_VERSIONS.concat(parsed.map(option => option.resolvedId).filter(x => x !== undefined))) {
    if (listed.has(canon(id))) continue;
    listed.add(canon(id));
    if (!pinnedByEntries.has(canon(id))) versionIds.push(id);
  }
  const catalog = {
    models,
    versions: versionIds.map(id => modelOption(id, displayName(id), id, effortsFor(id, parsed))),
  };
  const accountDefault = parsed.find(option => option.id === "default");
  if (accountDefault !== undefined) catalog.accountDefault = accountDefault;
  return catalog;
}

/** The initialize `control_response` line → catalogue. null for any other
 * line, another request's response, an error response or no models. */
function modelCatalog(line, requestId) {
  const obj = parseJSON(line, false);
  if (str(get(obj, "type")) !== "control_response") return null;
  const response = get(obj, "response");
  if (response === undefined) return null;
  if (requestId != null) {
    const id = str(get(response, "request_id"));
    if (id === undefined || !same(id, requestId)) return null;
  }
  const entries = arr(get(get(response, "response"), "models"));
  return entries === undefined ? null : catalogFromEntries(entries);
}

/** `id` is Abstract's own and never needs escaping. */
function initializeRequest(id) {
  return '{"type":"control_request","request_id":"' + id + '","request":{"subtype":"initialize"}}\n';
}

/** The CLI has no `models` command. Its stream-json `initialize` control
 * request answers with the account's models, and running no turn costs no
 * usage (verified against claude 2.1.274). */
function* discoverModels() {
  const requestId = "abstract-models-" + AbstractAgent.uuid().toUpperCase();
  return yield { converse: {
    args: ["-p", "--output-format", "stream-json", "--input-format", "stream-json", "--verbose"],
    keepStdinOpen: true, timeout: DISCOVERY_TIMEOUT, opening: [initializeRequest(requestId)],
    receive(line) {
      if (line.includes(requestId) && line.includes('"control_response"')) return { done: modelCatalog(line, requestId) };
      return null;
    },
  } };
}

/** `model` in ~/.claude/settings.json, e.g. "opus[1m]". */
function defaultModel(config) {
  const text = (config || {})[SETTINGS_FILE];
  if (typeof text !== "string") return null;
  return str(get(parseJSON(text, false), "model")) ?? null;
}

// MARK: Naming

/** The `--output-format json` envelope, as JSONSerialization reads it. */
function namingEnvelope(output) {
  const text = AbstractAgent.firstObject(output);
  if (typeof text !== "string") return undefined;
  const envelope = parseJSON(text, true);
  return isObject(envelope) ? envelope : undefined;
}
/** `as? Bool == true`: a bridged NSNumber 1 counts. */
function isTrue(value) { return value === true || value === 1; }

const naming = {
  launch({ prompt, home }) { return { args: NAMING_ARGS, cwd: home, stdin: prompt }; },
  /** The `result` text of `--output-format json`. */
  answer(output) {
    const envelope = namingEnvelope(output);
    if (envelope === undefined || isTrue(get(envelope, "is_error"))) return null;
    return str(get(envelope, "result")) ?? null;
  },
  error(output) {
    const envelope = namingEnvelope(output);
    if (envelope === undefined || !isTrue(get(envelope, "is_error"))) return null;
    return str(get(envelope, "result")) ?? null;
  },
};

AbstractAgent.register({
  id: PROVIDER_ID,
  launch,
  parser: claudeParser,
  message,
  permission,
  permissionMode,
  stopTask,
  interrupt,
  background,
  catalog: fallbackModels,
  defaultModel,
  discoverModels,
  naming,
});

// For tests of these helpers.
var ClaudeAgent = {
  baseArgs: BASE_ARGS,
  namingArgs: NAMING_ARGS,
  pinnedVersions: PINNED_VERSIONS,
  effortLevels: EFFORT_LEVELS,
  policyArgs,
  skillArgs,
  toolName,
  mcpArgs,
  instructionArgs,
  styleArgs,
  settingsArgs,
  userMessageLine,
  imageBlock,
  compactSummary(text) { return compactSummary(text) ?? null; },
  displayName,
  fallbackModels,
  modelCatalog,
  modelCatalogFromEntries: catalogFromEntries,
  initializeRequest,
  parseJSON(text, serialization) { const value = parseJSON(text, !!serialization); return value === undefined ? { failed: true } : { value }; },
  base64Decode,
  base64Encode,
};
