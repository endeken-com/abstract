// Codex as an Abstract agent plugin (ABS-185), moved from Abstract's
// CodexProvider.swift, CodexModels.swift, CodexCompactor.swift and
// CodexEditDiffs.swift. `codex exec --json` runs one turn and exits, one JSON
// object a line; a follow-up respawns with `exec resume`. Shapes checked
// against codex-cli 0.153.4 and 0.156.1 (the `codex-*.jsonl` fixtures).
"use strict";

const CONFIG_FILE = ".codex/config.toml";
const MODELS_CACHE = ".codex/models_cache.json";
const MAX_PREVIEW_LINES = 200;
const STARTED = 0, UPDATED = 1, COMPLETED = 2;

// MARK: JSON as Swift's JSONDecoder reads it

function isObject(value) { return value !== null && typeof value === "object" && !Array.isArray(value); }
function has(value, key) { return isObject(value) && Object.prototype.hasOwnProperty.call(value, key); }
/** `value?[key]`: a key present with `null` is a value, as in JSONValue. */
function get(value, key) { return has(value, key) ? value[key] : undefined; }
function str(value) { return typeof value === "string" ? value : undefined; }
function num(value) { return typeof value === "number" ? value : undefined; }
function arr(value) { return Array.isArray(value) ? value : undefined; }
function defined(value) { return value !== undefined; }
/** `JSONValue.int`: `Int(double)`. */
function int(value) { return typeof value === "number" ? Math.trunc(value) + 0 : undefined; }
/** Sets a key, `__proto__` included, as an own property. */
function put(object, key, value) {
  if (key === "__proto__") Object.defineProperty(object, key, { value, enumerable: true, writable: true, configurable: true });
  else object[key] = value;
  return object;
}
function merge(...objects) {
  const out = {};
  for (const object of objects) for (const key of Object.keys(object)) put(out, key, object[key]);
  return out;
}

const SPACE = /[ \t\n\r]*/y;
const NUMBER = /-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?/y;
const STRING = /"(?:[^"\\\u0000-\u001f]|\\(?:["\\/bfnrt]|u[0-9a-fA-F]{4}))*"/y;
const LONE_SURROGATE = /[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?:^|[^\uD800-\uDBFF])[\uDC00-\uDFFF]/;

/** JSON as Foundation's parser takes it (JSONDecoder and JSONSerialization
 * alike): one leading byte-order mark, trailing commas, the first of a
 * repeated key, at most 512 levels; no lone surrogate, and no number a
 * Double can't hold. undefined when it isn't JSON. */
function decode(text) {
  if (typeof text !== "string") return undefined;
  let at = text.charCodeAt(0) === 0xFEFF ? 1 : 0;
  const fail = () => { throw new SyntaxError("not JSON"); };
  function space() { SPACE.lastIndex = at; SPACE.exec(text); at = SPACE.lastIndex; }
  function string() {
    STRING.lastIndex = at;
    const match = STRING.exec(text);
    if (!match) fail();
    at = STRING.lastIndex;
    const token = match[0];
    if (token.indexOf("\\") < 0) return token.slice(1, -1);
    const value = JSON.parse(token);
    if (token.indexOf("\\u") >= 0 && LONE_SURROGATE.test(value)) fail();
    return value;
  }
  function value(depth) {
    space();
    const c = text[at];
    if (c === "{" || c === "[") {
      if (depth >= 512) fail();
      at++;
      const object = c === "{";
      const out = object ? {} : [];
      const close = object ? "}" : "]";
      space();
      if (text[at] === close) { at++; return out; }
      for (;;) {
        if (object) {
          space();
          if (text[at] !== "\"") fail();
          const key = string();
          space();
          if (text[at] !== ":") fail();
          at++;
          const v = value(depth + 1);
          if (!Object.prototype.hasOwnProperty.call(out, key)) put(out, key, v);
        } else {
          out.push(value(depth + 1));
        }
        space();
        if (text[at] === ",") {
          at++;
          space();
          if (text[at] === close) { at++; return out; }
          continue;
        }
        if (text[at] === close) { at++; return out; }
        fail();
      }
    }
    if (c === "\"") return string();
    if (text.startsWith("true", at)) { at += 4; return true; }
    if (text.startsWith("false", at)) { at += 5; return false; }
    if (text.startsWith("null", at)) { at += 4; return null; }
    NUMBER.lastIndex = at;
    const match = NUMBER.exec(text);
    if (!match) fail();
    at = NUMBER.lastIndex;
    const n = Number(match[0]);
    if (!isFinite(n) || (n === 0 && /[1-9]/.test(match[0].replace(/[eE].*$/, "")))) fail();
    return n;
  }
  try {
    const result = value(0);
    space();
    return at === text.length ? result : undefined;
  } catch (e) {
    return undefined;
  }
}

/** JSON as Swift's JSONEncoder writes it with sorted keys and slashes as
 * they are: the same escapes as JS's. */
function sortedJSON(value) {
  if (Array.isArray(value)) return "[" + value.map(sortedJSON).join(",") + "]";
  if (isObject(value)) {
    return "{" + Object.keys(value).sort(compareStrings).map(k => JSON.stringify(k) + ":" + sortedJSON(value[k])).join(",") + "}";
  }
  return JSON.stringify(value);
}

// MARK: Strings as Swift reads them

// Foundation's character sets: `.whitespaces` is Zs and tab; with newlines
// it adds U+000A–U+000D, U+0085, U+2028 and U+2029 (JS's trim differs).
const SPACES = "\\t \\u00A0\\u1680\\u2000-\\u200A\\u202F\\u205F\\u3000";
const NEWLINES = "\\n\\u000B\\f\\r\\u0085\\u2028\\u2029";
const TRIM_SPACES = new RegExp("^[" + SPACES + "]+|[" + SPACES + "]+$", "g");
const TRIM_ALL = new RegExp("^[" + SPACES + NEWLINES + "]+|[" + SPACES + NEWLINES + "]+$", "g");
function trimSpaces(text) { return text.replace(TRIM_SPACES, ""); }
function trim(text) { return text.replace(TRIM_ALL, ""); }
/** `Character.isWhitespace`: Unicode's White_Space. */
const WHITESPACE_RUN = /[\t-\r \u0085\u00A0\u1680\u2000-\u200A\u2028\u2029\u202F\u205F\u3000]+/;
/** Swift's `==` on strings: canonical equivalence. */
function same(a, b) { return a === b || a.normalize("NFC") === b.normalize("NFC"); }
/** Swift's `<` on strings: code points of the canonical form. */
function compareStrings(a, b) {
  if (a === b) return 0;
  const x = Array.from(a.normalize("NFC")), y = Array.from(b.normalize("NFC"));
  for (let i = 0; i < Math.min(x.length, y.length); i++) {
    const d = x[i].codePointAt(0) - y[i].codePointAt(0);
    if (d) return d;
  }
  return x.length - y.length;
}

/** Whether a character ends at `index`: what follows doesn't extend it. */
const EXTENDS = /^[\p{M}\u200C\u200D\u{1F3FB}-\u{1F3FF}\u{E0020}-\u{E007F}]/u;
function boundary(text, index) {
  if (index <= 0 || index >= text.length) return true;
  if (text[index - 1] === "\r" && text[index] === "\n") return false;
  return !EXTENDS.test(text.slice(index, index + 2));
}
/** `hasPrefix`, in characters. */
function hasPrefix(text, prefix) { return text.startsWith(prefix) && boundary(text, prefix.length); }

function graphemes(text) {
  if (typeof Intl !== "undefined" && typeof Intl.Segmenter === "function") {
    return Array.from(new Intl.Segmenter(undefined, { granularity: "grapheme" }).segment(text), piece => piece.segment);
  }
  return Array.from(text);
}

/** `split(separator: "\n")`: empty pieces dropped, and "\r\n" is one
 * character to Swift, so it never splits there. */
function lines(text) {
  const out = [];
  let start = 0;
  for (let i = 0; i < text.length; i++) {
    if (text[i] !== "\n" || (i > 0 && text[i - 1] === "\r")) continue;
    if (i > start) out.push(text.slice(start, i));
    start = i + 1;
  }
  if (text.length > start) out.push(text.slice(start));
  return out;
}

const INT_MIN = -(2n ** 63n), INT_MAX = 2n ** 63n - 1n;
/** `Int(text)`: an optional sign and ASCII digits; nil past Int64. */
function swiftInt(text) {
  if (!/^[+-]?[0-9]+$/.test(text)) return undefined;
  const value = BigInt(text);
  return value < INT_MIN || value > INT_MAX ? undefined : Number(value) + 0;
}

// MARK: Launching

/** A TOML basic string; its escapes match JSON's, all but `\/`, which TOML
 * doesn't have (so slashes stay as they are). */
function tomlString(text) { return JSON.stringify(text); }
function tomlArray(items) { return "[" + items.map(tomlString).join(", ") + "]"; }

/** `exec resume` has no `-s`, so a follow-up sets the sandbox as config. */
function sandboxArgs(policy, resuming) {
  const mode = policy === "bypass" ? "danger-full-access"
    : policy === "plan" || policy === "read-only" ? "read-only" : "workspace-write";
  return resuming ? ["-c", "sandbox_mode=\"" + mode + "\""] : ["-s", mode];
}

/** Library skills (ABS-122): Codex reads skills only from its home, so the
 * chat's agent gets a stand-in for `~/.codex` whose `skills` adds them to
 * the user's own, and whose every other entry is the real one. */
function skillEnv(skills) { return skills ? { CODEX_HOME: skills.folder } : {}; }

/** The profile's instructions (ABS-101), the output style, the plan mode
 * and, when the chat gets it, the code-history instruction, joined as
 * developer instructions. */
function developerInstructions(ctx) {
  const mode = ctx.permissionPolicy === "plan" ? ctx.text.plan : ctx.permissionPolicy === "read-only" ? ctx.text.readOnly : null;
  const parts = [ctx.instructions, ctx.outputStyle.instructions, mode, ctx.historyTool ? ctx.text.codeHistory : null, ctx.toolNotes]
    .filter(part => part !== null && part !== undefined);
  return parts.length ? ["-c", "developer_instructions=" + tomlString(parts.join("\n\n"))] : [];
}

/** A server Abstract runs (code history, plugin tools, branch naming) as
 * config overrides, on `exec` and `exec resume` alike. */
function serverCommandArgs(key, serverCommand) {
  return ["-c", key + ".command=" + tomlString(serverCommand.length ? serverCommand[0] : ""),
          "-c", key + ".args=" + tomlArray(serverCommand.slice(1))];
}

/** The code-history tool (ABS-61). It declares itself read-only, or `exec`
 * (approval policy "never") refuses the call. */
function historyArgs(tool) {
  if (!tool) return [];
  return serverCommandArgs("mcp_servers." + AbstractAgent.constants.codeHistory.server, tool.serverCommand);
}

/** The plugin-tools server (ABS-97). A call may wait for you to answer Ask
 * first, so Codex waits as long as Abstract does. */
function pluginArgs(tools) {
  if (!tools) return [];
  const limits = AbstractAgent.constants.pluginTools;
  const key = "mcp_servers." + limits.server;
  return serverCommandArgs(key, tools.serverCommand)
    .concat(["-c", key + ".tool_timeout_sec=" + Math.trunc(limits.askTimeout + limits.timeout + 30)]);
}

function branchArgs(branch) {
  if (!branch) return [];
  const key = "mcp_servers." + AbstractAgent.constants.branch.server;
  return serverCommandArgs(key, branch.serverCommand)
    .concat(["-c", key + ".tools={ \"name_branch\" = { approval_mode = \"approve\" } }"]);
}

/** The environment name that carries one of a server's secrets. */
function secretVariable(server, key) {
  const clean = text => graphemes(text.toUpperCase()).map(c => /^[\p{Alphabetic}\p{N}]/u.test(c) ? c : "_").join("");
  return "ABSTRACT_MCP_" + clean(server) + "_" + clean(key);
}

/** The project's MCP servers (ABS-123) as config overrides. Allowed tools
 * are approved outright (`exec` never asks); Off and Ask first ones are
 * disabled. Header and environment values travel in the environment,
 * named here, never in argv. */
function toolServerArgs(servers) {
  const args = [];
  const env = {};
  for (const server of servers) {
    const key = "mcp_servers." + server.name;
    const connection = server.connection;
    if (connection.type === "url") {
      args.push("-c", key + ".url=" + tomlString(connection.url));
      const headers = Object.keys(connection.headers || {}).sort(compareStrings);
      if (headers.length) {
        const names = headers.map(header => {
          put(env, secretVariable(server.name, header), get(connection.headers, header));
          return tomlString(header) + " = " + tomlString(secretVariable(server.name, header));
        });
        args.push("-c", key + ".env_http_headers={ " + names.join(", ") + " }");
      }
    } else {
      const argv = connection.argv;
      args.push("-c", key + ".command=" + tomlString(argv.length ? argv[0] : ""), "-c", key + ".args=" + tomlArray(argv.slice(1)));
      const vars = Object.keys(connection.env || {}).sort(compareStrings);
      if (vars.length) {
        for (const name of vars) put(env, name, get(connection.env, name));
        args.push("-c", key + ".env_vars=" + tomlArray(vars));
      }
    }
    if (server.allowed.length) {
      args.push("-c", key + ".tools={ " + server.allowed.map(tool => tomlString(tool) + " = { approval_mode = \"approve\" }").join(", ") + " }");
    }
    if (server.withheld.length) args.push("-c", key + ".disabled_tools=" + tomlArray(server.withheld));
  }
  return { args, env };
}

function launch(ctx, resumeId) {
  const resuming = resumeId !== null && resumeId !== undefined;
  const servers = toolServerArgs(ctx.toolServers);
  return {
    // `exec resume` has no `-C` either; the process cwd stands in for it.
    args: (resuming ? ["exec", "resume", resumeId] : ["exec"]).concat(["--json"], resuming ? [] : ["-C", ctx.cwd],
      ["--skip-git-repo-check"], sandboxArgs(ctx.permissionPolicy, resuming),
      ctx.model !== null ? ["-m", ctx.model] : [],
      // A config override; the value is TOML, so the level is quoted.
      ctx.effort !== null ? ["-c", "model_reasoning_effort=\"" + ctx.effort + "\""] : [],
      developerInstructions(ctx), historyArgs(ctx.historyTool), pluginArgs(ctx.pluginTools), branchArgs(ctx.branchTool),
      servers.args, ctx.extraArgs, ctx.images.flatMap(image => ["--image", image]),
      // A prompt like "- fix the parser" would otherwise parse as a flag,
      // and `--image` takes every value up to the next flag.
      hasPrefix(ctx.prompt, "-") || ctx.images.length ? ["--", ctx.prompt] : [ctx.prompt]),
    env: merge(servers.env, skillEnv(ctx.skills)),
    // `codex exec` waits on an open stdin forever.
    keepStdinOpen: false,
  };
}

// MARK: Reading its output

/** `JSONValue.double`, finite only. */
function finite(value) { return typeof value === "number" && isFinite(value) ? value : undefined; }
/** Never traps: out-of-range numbers yield nil. */
function wireInt(value) {
  const d = finite(value);
  if (d === undefined) return undefined;
  const n = Math.trunc(d) + 0;
  return n >= -9223372036854775808 && n < 9223372036854775808 ? n : undefined;
}

/** An `error` or `turn.failed` line's message, wherever it sits. */
function message(object) {
  const error = get(object, "error");
  const text = str(get(error, "message")) ?? str(get(object, "message")) ?? str(error);
  return text === undefined || text === "" ? undefined : text;
}

function warning(text) { return { type: "notice", notice: { kind: "warning", message: text } }; }

/** Display name for a generic (non-command) item type. */
function toolName(item, itemType) {
  switch (itemType) {
    case "command_execution": return "Bash";
    // A new file reads "Created", as Claude's Write does.
    case "file_change": case "patch_apply": return str(get(item, "kind")) === "add" ? "Write" : "ApplyPatch";
    case "todo_list": return "TodoList";
    case "web_search": return "WebSearch";
    case "mcp_tool_call": return str(get(item, "tool")) ?? str(get(item, "name")) ?? "McpToolCall";
    default: return itemType;
  }
}

/** Best-effort textual output for a completed generic item. */
function output(item) {
  return str(get(item, "aggregated_output")) ?? str(get(item, "output")) ?? str(get(item, "result")) ?? str(get(item, "text")) ?? "";
}

/** `Diff.parseHunkHeader`: "@@ -a,b +c,d @@" → [a, b, c, d]. */
function hunkHeader(line) {
  let body = line;
  while (hasPrefix(body, "@@")) body = body.slice(2);
  const pair = value => {
    const comma = value.indexOf(",");
    if (comma < 0) return [swiftInt(value) ?? 0, 1];
    return [swiftInt(value.slice(0, comma)) ?? 0, swiftInt(value.slice(comma + 1)) ?? 1];
  };
  let old = [0, 1], neu = [0, 1];
  for (const token of body.split(WHITESPACE_RUN)) {
    if (!token) continue;
    if (hasPrefix(token, "-")) old = pair(token.slice(1));
    else if (hasPrefix(token, "+")) neu = pair(token.slice(1));
    else if (token === "@@") break;
  }
  return [old[0], old[1], neu[0], neu[1]];
}

/** The EditPreview of a `file_change` / `patch_apply` item or one of its
 * changes. Codex sends no diff; the enricher below writes one in before the
 * line is logged. A few other plausible field names are accepted too. */
function editPreview(item) {
  const changes = arr(get(item, "changes"));
  const first = changes && changes.length && isObject(changes[0]) ? changes[0] : item;
  const filePath = str(get(first, "path")) ?? str(get(first, "file_path")) ?? str(get(item, "path")) ?? str(get(item, "file_path")) ?? "";
  const diff = str(get(first, "diff")) ?? str(get(first, "unified_diff")) ?? str(get(item, "diff")) ?? str(get(item, "unified_diff"));
  if (diff === undefined) return null;
  const lines = [];
  let additions = 0, deletions = 0;
  // Line numbers once a hunk header gives them; the first hunk needs no gap.
  let old, neu, gap = false;
  for (const raw of diff.split("\n")) {
    if (hasPrefix(raw, "@@")) {
      const header = hunkHeader(raw);
      old = header[0]; neu = header[2]; gap = lines.length > 0;
      continue;
    }
    // File headers and "\ No newline at end of file" are noise in a mini-diff.
    if (hasPrefix(raw, "+++") || hasPrefix(raw, "---") || hasPrefix(raw, "\\") || raw === "") continue;
    const head = String.fromCodePoint(raw.codePointAt(0));
    const rest = raw.slice(head.length);
    let line;
    switch (head) {
      case "+":
        additions++;
        line = { origin: "+", content: rest };
        if (neu !== undefined) line.newLine = neu++;
        break;
      case "-":
        deletions++;
        line = { origin: "-", content: rest };
        if (old !== undefined) line.oldLine = old++;
        break;
      case " ":
        line = { origin: " ", content: rest };
        if (old !== undefined) line.oldLine = old++;
        if (neu !== undefined) line.newLine = neu++;
        break;
      default:
        line = { origin: " ", content: raw };
    }
    // The counts cover the whole change; the preview stops at its cap.
    if (lines.length >= MAX_PREVIEW_LINES) continue;
    if (gap) { line.startsHunk = true; gap = false; }
    lines.push(line);
  }
  if (!lines.length) return null;
  return { filePath, additions, deletions, lines };
}

function withEdit(event, edit) {
  if (edit) event.edit = edit;
  return event;
}

/** Stateful `codex exec --json` parser, one per process. Unknown lines stay
 * raw in the log, so a newer CLI can still be read. */
function parser() {
  /** Item ids for which a `toolUse` has already been emitted. */
  const openTools = new Set();

  function genericTool(item, id, itemType, phase, edit) {
    const events = [];
    if (!openTools.has(id)) {
      openTools.add(id);
      events.push(withEdit({ type: "toolUse", id, name: toolName(item, itemType), input: item }, edit));
    }
    if (phase === COMPLETED) {
      openTools.delete(id);
      const status = str(get(item, "status"));
      events.push(withEdit({ type: "toolResult", toolUseId: id, output: output(item), isError: status === "failed" || status === "error" }, edit));
    }
    return events;
  }

  function commandExecution(item, id, phase) {
    const events = [];
    if (!openTools.has(id)) {
      openTools.add(id);
      events.push({ type: "toolUse", id, name: "Bash", input: { command: str(get(item, "command")) ?? "" } });
    }
    if (phase === COMPLETED) {
      openTools.delete(id);
      const exitCode = finite(get(item, "exit_code"));
      events.push({ type: "toolResult", toolUseId: id, output: str(get(item, "aggregated_output")) ?? "",
                    isError: exitCode === undefined ? false : exitCode !== 0 });
    }
    return events;
  }

  /** One call per file, the way Claude's edits read: codex-cli batches a
   * patch's files into one item, and each change becomes a call whose
   * `file_path` the chat reads. */
  function fileChange(item, id, itemType, phase) {
    const changes = (arr(get(item, "changes")) ?? []).filter(change => str(get(change, "path")) !== undefined);
    if (!changes.length) return genericTool(item, id, itemType, phase, editPreview(item));
    const uses = [], results = [];
    changes.forEach((change, i) => {
      const call = { type: itemType, file_path: get(change, "path") };
      if (has(change, "kind")) call.kind = get(change, "kind");
      if (has(item, "status")) call.status = get(item, "status");
      for (const event of genericTool(call, i === 0 ? id : id + "#" + i, itemType, phase, editPreview(change))) {
        (event.type === "toolUse" ? uses : results).push(event);
      }
    });
    return uses.concat(results);
  }

  /** An MCP call, named the way Claude's stream names it
   * (`mcp__<server>__<tool>`), with the call's own arguments as its input. */
  function mcpTool(item, id, phase) {
    const events = [];
    if (!openTools.has(id)) {
      openTools.add(id);
      const server = str(get(item, "server")) ?? "";
      const tool = str(get(item, "tool")) ?? "McpToolCall";
      events.push({ type: "toolUse", id, name: server === "" ? tool : "mcp__" + server + "__" + tool,
                    input: has(item, "arguments") ? get(item, "arguments") : {} });
    }
    if (phase === COMPLETED) {
      openTools.delete(id);
      const status = str(get(item, "status"));
      const error = str(get(get(item, "error"), "message")) ?? str(get(item, "error"));
      const content = (arr(get(get(item, "result"), "content")) ?? []).map(part => str(get(part, "text"))).filter(defined).join("\n");
      events.push({ type: "toolResult", toolUseId: id, output: error ?? (content === "" ? output(item) : content),
                    isError: error !== undefined || status === "failed" || status === "error" });
    }
    return events;
  }

  function onItem(object, phase) {
    const item = get(object, "item");
    if (!isObject(item)) return null;
    const itemType = str(get(item, "type"));
    if (itemType === undefined) return null;
    const id = str(get(item, "id")) ?? "";
    switch (itemType) {
      case "agent_message":
        return [{ type: "text", role: "assistant", text: str(get(item, "text")) ?? "", blockId: id, partial: phase !== COMPLETED }];
      case "reasoning":
        return [{ type: "thinking", text: str(get(item, "text")) ?? str(get(item, "summary")) ?? "", blockId: id, partial: phase !== COMPLETED }];
      case "command_execution":
        return commandExecution(item, id, phase);
      // Warnings: a deprecated setting, a model rerouted, anything Codex
      // carries on past. They come completed.
      case "error": {
        const text = str(get(item, "message"));
        return phase === COMPLETED && text !== undefined && text !== "" ? [warning(text)] : [];
      }
      case "file_change": case "patch_apply":
        return fileChange(item, id, itemType, phase);
      case "mcp_tool_call":
        return mcpTool(item, id, phase);
      case "todo_list": case "web_search":
        return genericTool(item, id, itemType, phase, null);
      default:
        return null;
    }
  }

  /** The line's events; null when it isn't understood (a raw line). */
  function dispatch(object) {
    switch (str(get(object, "type"))) {
      case "thread.started": {
        const id = str(get(object, "thread_id"));
        return id === undefined ? null : [{ type: "sessionId", id }];
      }
      case "turn.started":
        openTools.clear();
        return [{ type: "status", status: "running" }];
      case "turn.completed": {
        const usage = get(object, "usage");
        return [{ type: "usage", usage: { inputTokens: wireInt(get(usage, "input_tokens")) ?? 0,
                                          outputTokens: wireInt(get(usage, "output_tokens")) ?? 0,
                                          cacheRead: wireInt(get(usage, "cached_input_tokens")) ?? 0,
                                          cacheWrite: wireInt(get(usage, "cache_write_input_tokens")) ?? 0 } },
                { type: "status", status: "finished" }];
      }
      case "turn.failed":
        return [{ type: "error", message: message(object) ?? "Codex reported an error" }, { type: "status", status: "errored" }];
      // Codex carries on after an `error`: when the turn fails over it,
      // `turn.failed` follows with the same message.
      case "error": {
        const text = message(object);
        return text === undefined ? [] : [warning(text)];
      }
      case "item.started": return onItem(object, STARTED);
      case "item.updated": return onItem(object, UPDATED);
      case "item.completed": return onItem(object, COMPLETED);
      default: return null;
    }
  }

  function line(text, stream) {
    const trimmed = trim(text);
    if (!trimmed.length) return [];
    const raw = [{ type: "raw", line: text, stream }];
    if (stream !== "stdout") return raw;
    const object = decode(trimmed);
    if (!isObject(object)) return raw;
    return dispatch(object) ?? raw;
  }

  return {
    feed(lines) { return lines.map(l => line(l.line, l.stream)); },
    exit(code) {
      if (code === 0) return [{ type: "status", status: "finished" }];
      return [{ type: "error", message: "codex exited with code " + (code === null || code === undefined ? "null" : String(code)) },
              { type: "status", status: "errored" }];
    },
  };
}

// MARK: Edit diffs

/** Codex says which files a patch touched but not how. Once a patch is
 * applied this reads each file and writes a unified `diff` into its change
 * before the line is logged, against the file as the chat's previous edit
 * left it, or as committed at HEAD the first time, so an edit shows only its
 * own change. */
function enricher(worktree) {
  /** Each file as the chat's latest edit left it, by absolute path. */
  const snapshots = new Map();
  return {
    enrich(line, stream) {
      if (stream !== "stdout" || !(line.includes("file_change") || line.includes("patch_apply"))) return line;
      const top = decode(line);
      if (!isObject(top) || str(get(top, "type")) !== "item.completed") return line;
      const item = get(top, "item");
      const itemType = str(get(item, "type"));
      if (!isObject(item) || (itemType !== "file_change" && itemType !== "patch_apply")) return line;
      const changes = arr(get(item, "changes"));
      if (!changes) return line;
      let filled = false;
      const enriched = changes.map(change => {
        const path = str(get(change, "path"));
        if (!isObject(change) || has(change, "diff") || path === undefined) return change;
        const cwd = worktree.cwd;
        const full = hasPrefix(path, "/") ? path : (cwd.endsWith("/") ? cwd : cwd + "/") + path;
        const kind = str(get(change, "kind"));
        const after = kind === "delete" ? "" : (worktree.read(full) ?? "");
        const before = snapshots.has(full) ? snapshots.get(full) : (kind === "add" ? "" : worktree.committed(full));
        snapshots.set(full, after);
        filled = true;
        return put(merge(change), "diff", AbstractAgent.unifiedDiff(before, after));
      });
      if (!filled) return line;
      put(item, "changes", enriched);
      return AbstractAgent.compactJSON(top);
    },
  };
}

// MARK: Compaction, through `codex app-server`

/** One JSON-RPC line; no `id` makes it a notification. */
function rpc(id, method, params) {
  const body = { jsonrpc: "2.0", method };
  if (id !== undefined) body.id = id;
  if (params !== undefined) body.params = params;
  return sortedJSON(body) + "\n";
}

/** Compacting one thread over the app server's JSON-RPC: initialize, resume
 * the thread, start compacting, and wait for its `contextCompaction` item to
 * complete. Shapes checked against codex-cli 0.156.1; no summary text is
 * exposed. `receive` answers `{send}`, `{done}`, `{fail}` or null (wait). */
function compaction(threadId) {
  const INITIALIZE = 1, RESUME = 2, COMPACT = 3;
  let before, after, window, compacting = false;
  // Which request is pending, so a duplicate reply is ignored, not re-sent.
  let phase = INITIALIZE;
  const isCompaction = object => str(get(get(get(object, "params"), "item"), "type")) === "contextCompaction";
  const result = () => {
    const out = {};
    if (before !== undefined) out.tokensBefore = before;
    if (after !== undefined) out.tokensAfter = after;
    if (window !== undefined) out.contextWindow = window;
    return out;
  };
  // `params.turn.error.message`, then `params.error.message`, then a generic reason.
  const failure = object => {
    const params = get(object, "params");
    const text = str(get(get(get(params, "turn"), "error"), "message")) ?? str(get(get(params, "error"), "message"));
    return "Codex: " + (text ?? "compacting ended without finishing.");
  };
  return {
    opening: [rpc(INITIALIZE, "initialize", { clientInfo: { name: "abstract", version: "1" } })],
    receive(line) {
      const object = decode(line);
      if (!isObject(object)) return null;
      const error = get(object, "error");
      if (isObject(error)) return { fail: "Codex: " + (str(get(error, "message")) ?? "the request failed") };
      const id = int(get(object, "id"));
      const method = str(get(object, "method"));
      if (id === INITIALIZE && phase === INITIALIZE) {
        phase = RESUME;
        return { send: [rpc(undefined, "initialized"), rpc(RESUME, "thread/resume", { threadId, excludeTurns: true })] };
      }
      if (id === RESUME && phase === RESUME) {
        phase = COMPACT;
        return { send: [rpc(COMPACT, "thread/compact/start", { threadId })] };
      }
      if (method === "thread/tokenUsage/updated") {
        const usage = get(get(object, "params"), "tokenUsage");
        const tokens = int(get(get(usage, "last"), "totalTokens"));
        window = int(get(usage, "modelContextWindow")) ?? window;
        if (compacting) after = tokens; else before = tokens;
        return null;
      }
      if (method === "item/started" && isCompaction(object)) { compacting = true; return null; }
      if (method === "item/completed" && isCompaction(object)) return { done: result() };
      // The turn ended some other way before its compaction item completed.
      if (method === "turn/failed") return { fail: failure(object) };
      if (method === "turn/completed" && str(get(get(get(object, "params"), "turn"), "status")) !== "completed") {
        return { fail: failure(object) };
      }
      // Compacting finished but its item/completed didn't arrive: finish
      // with whatever tokens were seen rather than hang.
      if (method === "turn/completed" && compacting) return { done: result() };
      return null;
    },
  };
}

function* compact(request) {
  const conversation = compaction(request.sessionId);
  return yield { converse: { args: ["app-server"], cwd: request.cwd, keepStdinOpen: true, timeout: 300,
                             opening: conversation.opening, receive: line => conversation.receive(line) } };
}

// MARK: Models and settings

/** A top-level string key of ~/.codex/config.toml, i.e. one before the
 * first `[table]`. */
function configValue(text, key) {
  if (typeof text !== "string") return undefined;
  for (const raw of lines(text)) {
    const line = trimSpaces(raw);
    if (hasPrefix(line, "[")) break;
    const eq = line.indexOf("=");
    if (!hasPrefix(line, key) || eq < 0) continue;
    if (!same(trimSpaces(line.slice(0, eq)), key)) continue;
    return trimSpaces(line.slice(eq + 1)).replace(/^["']+|["']+$/g, "");
  }
  return undefined;
}

/** ISO8601DateFormatter's internet date-time, as milliseconds; undefined
 * when it isn't one (fractional seconds included). */
function parseDate(text) {
  const match = /^\s*([0-9]{4,})-([0-9]{1,2})-([0-9]{1,2})T([0-9]{2}):([0-9]{2}):([0-9]{2})\s*(Z|z|GMT|UTC|[+-][0-9]{2}(?::?[0-9]{2})?)/.exec(text);
  if (!match) return undefined;
  const [year, month, day, hour, minute, second] = match.slice(1, 7).map(Number);
  if (month < 1 || month > 12 || day < 1 || day > 31 || hour > 24 || minute > 59 || second > 59) return undefined;
  const zone = match[7];
  let offset = 0;
  if (zone[0] === "+" || zone[0] === "-") {
    const digits = zone.slice(1).replace(":", "");
    const hours = Number(digits.slice(0, 2)), minutes = digits.length > 2 ? Number(digits.slice(2)) : 0;
    if (hours > 23 || minutes > 59) return undefined;
    offset = (zone[0] === "-" ? -1 : 1) * (hours * 60 + minutes);
  }
  const date = new Date(0);
  date.setUTCFullYear(year, month - 1, day);
  date.setUTCHours(hour, minute, second, 0);
  return date.getTime() - offset * 60000;
}

const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

/** "MMM d" in `timeZone` (this Mac's when undefined). */
function monthDay(ms, timeZone) {
  const date = new Date(ms);
  if (typeof Intl !== "undefined" && typeof Intl.DateTimeFormat === "function") {
    const parts = new Intl.DateTimeFormat("en-US", { timeZone, month: "numeric", day: "numeric" }).formatToParts(date);
    const part = type => Number((parts.find(p => p.type === type) || {}).value);
    return MONTHS[part("month") - 1] + " " + part("day");
  }
  return timeZone === "UTC" ? MONTHS[date.getUTCMonth()] + " " + date.getUTCDate() : MONTHS[date.getMonth()] + " " + date.getDate();
}

/** "Retires Oct 14", "Retired Oct 14", or "Being retired" without a date. */
function retirementNote(upgrade, now, timeZone) {
  const text = str(get(upgrade, "retirement_at"));
  const date = text === undefined ? undefined : parseDate(text);
  if (date === undefined) return "Being retired";
  return (date > now ? "Retires " : "Retired ") + monthDay(date, timeZone);
}

/** The model catalogue (~/.codex/models_cache.json): listed models by ascending priority. null
 * when it isn't one or lists nothing. `visibility` "hide" marks internal
 * models; a non-null `upgrade` marks one being retired. */
function modelCatalog(text, now, timeZone) {
  const entries = arr(get(decode(text), "models"));
  if (!entries) return null;
  const priority = entry => num(get(entry, "priority")) ?? Infinity;
  const models = entries.map((entry, offset) => ({ entry, offset, priority: priority(entry) }))
    .filter(({ entry }) => same(str(get(entry, "visibility")) ?? "list", "list"))
    .sort((a, b) => a.priority < b.priority ? -1 : a.priority > b.priority ? 1 : a.offset - b.offset)
    .map(({ entry }) => {
      const slug = str(get(entry, "slug"));
      if (slug === undefined || slug === "") return null;
      const option = { id: slug, label: str(get(entry, "display_name")) ?? slug,
                       efforts: (arr(get(entry, "supported_reasoning_levels")) ?? []).map(level => str(get(level, "effort"))).filter(defined) };
      const detail = str(get(entry, "description"));
      if (detail !== undefined) option.detail = detail;
      const defaultEffort = str(get(entry, "default_reasoning_level"));
      if (defaultEffort !== undefined) option.defaultEffort = defaultEffort;
      const upgrade = get(entry, "upgrade");
      if (isObject(upgrade)) option.note = retirementNote(upgrade, now ?? Date.now(), timeZone);
      return option;
    })
    .filter(option => option !== null);
  return models.length ? { models, versions: [] } : null;
}

// MARK: Naming

/** Every agent message, in order: earlier ones may be commentary, and the
 * answer comes last. */
function namingAnswer(output) {
  const messages = [];
  for (const line of lines(output)) {
    const event = decode(line);
    const item = get(event, "item");
    if (!isObject(event) || str(get(event, "type")) !== "item.completed" || !isObject(item)
        || str(get(item, "type")) !== "agent_message") continue;
    const text = str(get(item, "text"));
    if (text !== undefined) messages.push(text);
  }
  return messages.length ? messages.join("\n") : null;
}

/** The last error event's message; the API's own, when it wraps one as JSON. */
function namingError(output) {
  let text;
  for (const line of lines(output)) {
    const event = decode(line);
    if (!isObject(event)) continue;
    switch (str(get(event, "type"))) {
      case "error": text = str(get(event, "message")) ?? text; break;
      case "turn.failed": text = str(get(get(event, "error"), "message")) ?? text; break;
    }
  }
  if (text === undefined) return null;
  const inner = get(decode(text), "error");
  return str(get(inner, "message")) ?? text;
}

AbstractAgent.register({
  id: "codex",
  launch,
  parser,
  enricher,
  defaultModel(config) { return configValue((config || {})[CONFIG_FILE], "model") ?? null; },
  defaultEffort(config) { return configValue((config || {})[CONFIG_FILE], "model_reasoning_effort") ?? null; },
  // The CLI keeps the account's models in ~/.codex/models_cache.json and
  // refreshes it itself; the host reads it (a `config` file) on the chat's Mac.
  *discoverModels({ config }) {
    const text = (config || {})[MODELS_CACHE];
    return typeof text === "string" ? modelCatalog(text, Date.now()) : null;
  },
  compact,
  naming: {
    // The chat's model at low effort, in a read-only sandbox.
    launch({ prompt, home, model }) {
      return { args: ["exec", "--json", "-C", home, "--skip-git-repo-check", "-s", "read-only", "-c", "model_reasoning_effort=\"low\""]
                 .concat(model !== null && model !== undefined ? ["-m", model] : [], ["--", prompt]),
               cwd: home };
    },
    answer: namingAnswer,
    error: namingError,
  },
});

// For tests of these helpers.
var CodexAgent = {
  decode, sortedJSON, tomlString, tomlArray, sandboxArgs, skillEnv, developerInstructions, historyArgs, pluginArgs, branchArgs,
  toolServerArgs, secretVariable, editPreview, hunkHeader, configValue, parseDate, modelCatalog, compaction, namingAnswer, namingError,
};
