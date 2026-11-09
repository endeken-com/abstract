// Muse Code as an Abstract agent plugin (ABS-185), moved from Abstract's
// MuseProvider.swift. Driven over `muse serve`: the MSP session host is the
// only surface that carries each tool call's real arguments, status and
// output as it happens (docs/spikes/ABS-88.md). One host process stays alive
// for the chat; a relaunch resumes its retained session by id. The naming
// one-off still uses `exec`, which is all that call needs.
"use strict";

const SETTINGS_FILE = ".config/muse/settings.json";
const SIGN_IN = "Muse Code needs sign-in. Run muse login on this Mac, then try again.";
const EFFORTS = ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"];
const FINISHED_TOOL = ["completed", "failed", "cancelled", "rejected", "timedOut"];
const BOOKKEEPING = ["session/statusChanged", "session/contextUsage",
  "session/approvalModeChanged", "session/modelChanged", "session/reasoningEffortChanged",
  "session/listChanged", "session/closed", "turn/foregroundCompleted",
  "approval/request", "approval/resolved", "approval/updated", "approval/reviewing"];
const INITIALIZE = '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"abstract","version":"0.0.0"}}}\n';

// MARK: JSON as Swift's JSONValue reads it

function parse(text) {
  try { return JSON.parse(text); } catch (e) { return undefined; }
}
function isObject(value) { return value !== null && typeof value === "object" && !Array.isArray(value); }
/** `value?[key]`: a key present with `null` is a value, as in JSONValue. */
function get(value, key) {
  return isObject(value) && Object.prototype.hasOwnProperty.call(value, key) ? value[key] : undefined;
}
function str(value) { return typeof value === "string" ? value : undefined; }
function int(value) { return typeof value === "number" ? Math.trunc(value) : undefined; }
function arr(value) { return Array.isArray(value) ? value : undefined; }
function defined(value) { return value !== undefined; }

// Foundation's character sets: `.whitespaces` is Zs and tab; with newlines
// it adds U+000A–U+000D, U+0085, U+2028 and U+2029 (JS's trim differs).
const SPACES = "\\t \\u00A0\\u1680\\u2000-\\u200A\\u202F\\u205F\\u3000";
const NEWLINES = "\\n\\u000B\\f\\r\\u0085\\u2028\\u2029";
const TRIM_SPACES = new RegExp("^[" + SPACES + "]+|[" + SPACES + "]+$", "g");
const TRIM_ALL = new RegExp("^[" + SPACES + NEWLINES + "]+|[" + SPACES + NEWLINES + "]+$", "g");
function trimSpaces(text) { return text.replace(TRIM_SPACES, ""); }
function trim(text) { return text.replace(TRIM_ALL, ""); }
/** `localizedCaseInsensitiveContains`. */
function mentions(text, part) { return text.toLowerCase().includes(part.toLowerCase()); }
/** Swift's `==` on strings: canonical equivalence. */
function same(a, b) { return a === b || a.normalize("NFC") === b.normalize("NFC"); }

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

/** `String(text.prefix(n))`, in characters. */
function prefix(text, n) {
  if (typeof Intl !== "undefined" && typeof Intl.Segmenter === "function") {
    let out = "", count = 0;
    for (const piece of new Intl.Segmenter(undefined, { granularity: "grapheme" }).segment(text)) {
      if (count++ >= n) break;
      out += piece.segment;
    }
    return out;
  }
  return Array.from(text).slice(0, n).join("");
}

/** `Int(text)`: an optional sign and decimal digits; nil past Int64. */
function swiftInt(text) {
  const match = /^([+-]?)([0-9]+)$/.exec(text);
  if (!match) return undefined;
  const digits = match[2].replace(/^0+(?=.)/, "");
  if (match[1] === "-") return digits === "0" ? 0 : -1;
  if (digits.length > 19 || (digits.length === 19 && digits > "9223372036854775807")) return undefined;
  return Number(digits);
}

// MARK: The MSP wire

const Wire = {
  /** A UUIDv7, as the host requires of its command and session ids. */
  newId() {
    let ms = Date.now();
    const bytes = Array.from(AbstractAgent.randomBytes(16));
    for (let i = 5; i >= 0; i--) { bytes[i] = ms % 256; ms = Math.floor(ms / 256); }
    bytes[6] = (bytes[6] & 0x0f) | 0x70;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    const hex = bytes.map(b => b.toString(16).padStart(2, "0")).join("");
    return [hex.slice(0, 8), hex.slice(8, 12), hex.slice(12, 16), hex.slice(16, 20), hex.slice(20)].join("-");
  },
  request(id, method, params) {
    return AbstractAgent.compactJSON({ jsonrpc: "2.0", id, method, params }) + "\n";
  },
  notification(method) {
    return AbstractAgent.compactJSON({ jsonrpc: "2.0", method }) + "\n";
  },
  /** An image file on this Mac as a wire part; null when it isn't one. Reading
   * it is the host's, `AbstractAgent.readImage(path)` → { mediaType, base64Data },
   * and only for the pictures the launch or message being built sends. */
  image(path) {
    const image = typeof AbstractAgent.readImage === "function" ? AbstractAgent.readImage(path) : null;
    if (!isObject(image) || typeof image.mediaType !== "string" || typeof image.base64Data !== "string") return null;
    return { type: "image", mediaType: image.mediaType, base64Data: image.base64Data };
  },
  turnStart(sessionId, turn) {
    const parts = (turn.imageParts || (turn.images || []).map(Wire.image)).filter(part => part !== null);
    parts.push({ type: "text", text: turn.prompt });
    const params = { commandId: Wire.newId(), sessionId, input: parts };
    if (turn.effort != null && EFFORTS.includes(turn.effort)) params.reasoningEffort = turn.effort;
    return Wire.request(3, "turn/start", params);
  },
  setModel(sessionId, model) {
    return Wire.request(4, "session/setModel", { commandId: Wire.newId(), sessionId, model: { modelId: model } });
  },
};

/** First turns waiting for their session: the launch can't carry the turn
 * (the host answers requests concurrently, and a turn for a session that is
 * not loaded yet is refused), so the parser sends it when the host confirms
 * the session. Keyed by the client-minted session id; an entry is only
 * removed once a live parser's queued turn is actually drained, so replaying
 * the log in the same process cannot spend it. One script serves every
 * Muse chat, so this is shared between them. */
const pendingTurns = new Map();

// MARK: Launching

function launch(ctx, resumeId) {
  const policy = ctx.permissionPolicy;
  const mode = policy === "plan" ? ctx.text.plan : policy === "read-only" ? ctx.text.readOnly : null;
  // No system-prompt channel of its own here, so a profile's instructions
  // (ABS-101) lead the first message, like the style.
  const prompt = [ctx.instructions, ctx.outputStyle.instructions, mode].filter(x => x != null)
    .map(x => x + "\n\n").join("") + ctx.prompt;
  // The host's sandbox posture is fixed by launch flags; what may run without
  // asking is chosen on the wire. Abstract still cannot answer an approval, so
  // nothing is left waiting for one: unmatched work is denied, never held.
  const flags = policy === "auto-edits" ? [] : policy === "bypass" ? ["--disable-sandbox"] : ["--disable-write", "--disable-shell"];
  const approvalMode = policy === "bypass" ? "allowAll" : "denyUnmatched";
  // The client mints the session id, so the first turn can be sent by the
  // parser the moment the host confirms the session is loaded.
  const sessionId = resumeId ?? Wire.newId();
  // The first turn's pictures are read now, while the host lets the launch
  // read them; the parser sends the turn once the session is loaded.
  pendingTurns.set(sessionId, { prompt, model: ctx.model, effort: ctx.effort, images: ctx.images,
                                imageParts: ctx.images.map(Wire.image) });
  let session;
  if (resumeId != null) {
    // Abstract's own log is the transcript; history would repeat it.
    session = Wire.request(2, "session/resume", { commandId: Wire.newId(), sessionId, excludeItems: true });
  } else {
    const params = { commandId: Wire.newId(), sessionId, workspaceRoot: ctx.cwd, approvalMode };
    if (ctx.model != null) params.modelId = ctx.model;
    session = Wire.request(2, "session/start", params);
  }
  return {
    args: ["serve", "--trust-workspace"].concat(flags, ctx.extraArgs),
    // Muse reads the skills in `$CODEX_HOME/skills` as the user's own.
    env: ctx.skills ? { CODEX_HOME: ctx.skills.folder } : {},
    stdin: Wire.request(1, "initialize", { clientInfo: { name: "abstract", version: "0.0.0" } })
      + Wire.notification("initialized") + session,
    keepStdinOpen: true,
  };
}

// MARK: Reading its output

function rawEvent(line, stream) { return { type: "raw", line, stream }; }
function status(value, detail) { return detail === undefined ? { type: "status", status: value } : { type: "status", status: value, detail }; }

function exitMessage(lastError, code) {
  if (lastError !== null && (mentions(lastError, "credential") || mentions(lastError, "login"))) return SIGN_IN;
  if (lastError !== null && mentions(lastError, "model")) {
    return "Muse Code could not use this model: " + lastError + " Choose another model in the chat.";
  }
  if (lastError !== null) return "Muse Code failed: " + lastError;
  return "Muse Code exited with code " + (code == null ? "unknown" : String(code)) + ". Check the CLI on this Mac.";
}

function friendly(message) {
  if (mentions(message, "does not exist or you lack access")) {
    return "Muse Code cannot use this model. Choose another model in the chat. " + message;
  }
  if (mentions(message, "credential") || mentions(message, "login") || mentions(message, "not signed in")) return SIGN_IN;
  return message;
}

/** What one `session/tokenUsage` step used. Muse counts cached input inside
 * `inputTokens` and reasoning inside `outputTokens`; the chat counts input
 * not served from the cache, as for the other agents. */
function usageTotals(usage) {
  const read = int(get(usage, "cacheReadTokens")) ?? 0;
  const write = int(get(usage, "cacheWriteTokens")) ?? 0;
  return { inputTokens: Math.max(0, (int(get(usage, "inputTokens")) ?? 0) - read - write),
           outputTokens: int(get(usage, "outputTokens")) ?? 0, cacheRead: read, cacheWrite: write };
}

/** The `muse serve` view stream folded into agent events. Items arrive by
 * revision (replace if higher), a completed item may never have been
 * started, and output streams as deltas before the item settles. */
function serveParser() {
  let sawServe = false;
  let sessionId = null;
  let turnActive = false;
  let turnFinished = false;
  let lastError = null;
  let pendingInput = [];
  /** The session whose registered first turn is sitting in `pendingInput`. */
  let pendingSession = null;
  let queuedFirstTurn = false;
  const shownQuestions = new Set();
  const calls = new Map();
  /** Streamed tool output by item id, until the item's final form lands. */
  const outputText = new Map();
  /** Streamed reply text by item id, so a completion with no text of its own still carries what streamed. */
  const replyText = new Map();
  /** Streamed reasoning summary parts by item id, in part order. */
  const summaryParts = new Map();

  function reply(id, msg) {
    const error = get(msg, "error");
    if (error !== undefined) {
      const message = str(get(error, "message")) ?? "Muse Code refused a request.";
      switch (id) {
        case 1: return [{ type: "error", message: "Muse Code could not start: " + message }, status("errored")];
        case 2: case 3: return [{ type: "error", message: friendly(message) }, status("errored")];
        default: return [];
      }
    }
    const session = get(get(msg, "result"), "session");
    const id2 = str(get(session, "sessionId"));
    if (id !== 2 || session === undefined || id2 === undefined) return [];
    const out = [];
    if (sessionId !== id2) {
      sessionId = id2;
      out.push({ type: "sessionId", id: id2 });
    }
    const pending = pendingTurns.get(id2);
    const sessionModel = str(get(session, "modelId"));
    out.push({ type: "system", model: (pending ? pending.model : null) ?? sessionModel,
               cwd: str(get(session, "workspaceRoot")), sessionId: id2 });
    // The session is loaded: the first turn may go now, and only now.
    if (pending && !queuedFirstTurn) {
      queuedFirstTurn = true;
      pendingSession = id2;
      if (pending.model != null && pending.model !== sessionModel) pendingInput.push(Wire.setModel(id2, pending.model));
      pendingInput.push(Wire.turnStart(id2, pending));
    }
    return out;
  }

  function notification(method, params, line) {
    switch (method) {
      case "session/started": {
        const id = str(get(get(params, "session"), "sessionId"));
        if (id === undefined || id === sessionId) return [];
        sessionId = id;
        return [{ type: "sessionId", id }];
      }
      case "turn/started":
        turnActive = true;
        return [status("running")];
      case "turn/completed": {
        turnActive = false;
        turnFinished = true;
        if (str(get(params, "terminal")) === "failed") {
          const reason = str(get(params, "reason")) ?? "Muse Code could not finish this turn.";
          return [{ type: "error", message: friendly(reason) }, status("errored")];
        }
        return [{ type: "turnEnd", durationMs: int(get(params, "durationMs")) }, status("idle")];
      }
      case "item/started": case "item/updated": case "item/completed": {
        const item = get(params, "item");
        if (item === undefined) return [rawEvent(line, "stdout")];
        return fold(item, method === "item/completed", line);
      }
      case "item/delta": {
        const itemId = str(get(params, "itemId")), delta = str(get(params, "delta"));
        if (itemId === undefined || delta === undefined) return [];
        const field = str(get(params, "field"));
        if (field === "text") {
          replyText.set(itemId, (replyText.get(itemId) ?? "") + delta);
          return delta === "" ? [] : [{ type: "text", role: "assistant", text: delta, blockId: itemId, partial: true }];
        }
        if (field === "output") {
          outputText.set(itemId, (outputText.get(itemId) ?? "") + delta);
          return [];
        }
        if (field !== undefined && field.startsWith("summary.")) {
          // Reasoning summary part n streams on `summary.n`; a new index starts a new paragraph.
          const index = swiftInt(field.slice("summary.".length));
          if (index === undefined || index < 0 || delta === "") return [];
          const parts = (summaryParts.get(itemId) ?? []).slice();
          const opensPart = index >= parts.length && parts.some(p => p !== "");
          while (parts.length <= index) parts.push("");
          parts[index] += delta;
          summaryParts.set(itemId, parts);
          return [{ type: "thinking", text: opensPart ? "\n\n" + delta : delta, blockId: itemId, partial: true }];
        }
        return [];
      }
      case "session/tokenUsage": {
        // One model step. Its own figures, never `cumulative`, so the steps
        // of a turn add up without counting any twice.
        const usage = get(params, "usage");
        if (usage === undefined) return [];
        return [{ type: "usage", usage: usageTotals(usage) }];
      }
      case "userInput/request": case "userInput/requested": {
        const id = str(get(params, "userInputId"));
        if (id === undefined || shownQuestions.has(id)) return [];
        shownQuestions.add(id);
        return [{ type: "permissionRequest", requestId: id, toolName: "request_user_input", input: params },
                status("waiting_input", "Question for you")];
      }
      default:
        // Bookkeeping the chat does not read. Approvals: the modes Abstract
        // sets never hold a call for one.
        if (BOOKKEEPING.includes(method)) return [];
        return [rawEvent(line, "stdout")];
    }
  }

  function fold(item, completed, line) {
    switch (str(get(item, "kind"))) {
      case "toolCall": case "webSearch":
        return foldTool(item);
      case "agentMessage": {
        const itemId = str(get(item, "itemId"));
        if (!completed || itemId === undefined) return [];
        const text = str(get(item, "text")) ?? replyText.get(itemId) ?? "";
        replyText.delete(itemId);
        return text === "" ? [] : [{ type: "text", role: "assistant", text, blockId: itemId, partial: false }];
      }
      case "reasoning": {
        // Muse shows the provider's reasoning summary; raw reasoning only
        // where the provider exposes it. Encrypted reasoning never reaches
        // the view, and nothing is made up from token counts.
        const itemId = str(get(item, "itemId"));
        if (!completed || itemId === undefined) return [];
        const joined = parts => parts.filter(p => p !== "").join("\n\n");
        const settled = joined((arr(get(item, "summary")) ?? []).map(str).filter(defined));
        const summary = settled === "" ? joined(summaryParts.get(itemId) ?? []) : settled;
        summaryParts.delete(itemId);
        const text = summary === "" ? str(get(item, "text")) ?? "" : summary;
        return text === "" ? [] : [{ type: "thinking", text, blockId: itemId, partial: false }];
      }
      case "userMessage": case "hookRun": case "reminderChild":
        // Yours is logged by Abstract itself; the rest is the host's own work.
        return [];
      default:
        return completed ? [rawEvent(line, "stdout")] : [];
    }
  }

  /** Tool arguments ride as a verbatim string: the model's own JSON when it
   * parses, an empty object when it does not. A target is never guessed out
   * of result prose. */
  function parseArgs(args) {
    if (args === undefined) return {};
    const value = parse(args);
    return value === undefined ? {} : value;
  }

  function foldTool(item) {
    const itemId = str(get(item, "itemId"));
    if (itemId === undefined) return [];
    const callId = str(get(item, "callId")) ?? itemId;
    const revision = int(get(item, "revision")) ?? 0;
    const call = Object.assign({ revision: 0, emittedUse: false, emittedResult: false }, calls.get(callId));
    if (call.emittedUse && revision < call.revision) return [];
    call.revision = Math.max(call.revision, revision);
    const out = [];
    if (!call.emittedUse) {
      call.emittedUse = true;
      const isSearch = str(get(item, "kind")) === "webSearch";
      const name = str(get(item, "tool")) ?? (isSearch ? "web_search" : "tool");
      let input = parseArgs(str(get(item, "args")));
      const query = str(get(item, "query"));
      if (isSearch && (!isObject(input) || Object.keys(input).length === 0) && query !== undefined) input = { query };
      out.push({ type: "toolUse", id: callId, name, input });
    }
    const state = str(get(item, "status"));
    if (FINISHED_TOOL.includes(state) && !call.emittedResult) {
      call.emittedResult = true;
      const output = str(get(item, "visibleOutput")) ?? outputText.get(itemId) ?? str(get(item, "failureReason")) ?? "";
      outputText.delete(itemId);
      out.push({ type: "toolResult", toolUseId: callId, output, isError: state !== "completed" });
    }
    calls.set(callId, call);
    return out;
  }

  return {
    get sawServe() { return sawServe; },
    noteStderr(line) {
      const trimmed = trim(line);
      if (trimmed !== "") lastError = trimmed;
    },
    takePendingInput() {
      if (pendingSession !== null) { pendingTurns.delete(pendingSession); pendingSession = null; }
      const out = pendingInput;
      pendingInput = [];
      return out;
    },
    feed(line, stream) {
      sawServe = true;
      const msg = parse(line);
      if (msg === undefined) return [rawEvent(line, stream)];
      const method = str(get(msg, "method"));
      if (method !== undefined) {
        const id = get(msg, "id");
        if (method === "userInput/request" && id !== undefined) {
          // The JSON-RPC reply confirms this client is showing the dialog.
          // The user's choice is a separate userInput/answer command.
          pendingInput.push(AbstractAgent.compactJSON({ jsonrpc: "2.0", id, result: {} }) + "\n");
        }
        return notification(method, get(msg, "params"), line);
      }
      const id = int(get(msg, "id"));
      if (id !== undefined) return reply(id, msg);
      return [rawEvent(line, stream)];
    },
    exit(code) {
      if (turnFinished && !turnActive) return [status("finished")];
      if (code === 0 && sessionId !== null) return [status("finished")];
      return [{ type: "error", message: exitMessage(lastError, code) }, status("errored")];
    },
  };
}

/** `muse exec --json` writes journal envelopes, not MSP frames. Unfamiliar
 * records stay raw so a later CLI version remains inspectable. */
function execParser() {
  let sessionId = null;
  let finished = false;
  let lastError = null;
  const toolNames = new Map();

  return {
    feed(line, stream) {
      const trimmed = trim(line);
      if (trimmed === "") return [];
      const event = stream === "stdout" ? parse(trimmed) : undefined;
      const type = str(get(event, "payload_type"));
      if (stream !== "stdout" || event === undefined || type === undefined) {
        if (stream === "stderr") lastError = trimmed;
        return [rawEvent(line, stream)];
      }
      const out = [];
      const streamInfo = get(event, "stream");
      const id = str(get(streamInfo, "id"));
      if (id !== undefined && str(get(streamInfo, "kind")) === "session" && id !== sessionId) {
        sessionId = id;
        out.push({ type: "sessionId", id });
      }
      const payload = get(event, "payload");
      switch (type) {
        case "run.model.configured":
          out.push({ type: "system", model: str(get(payload, "model_id")), sessionId: sessionId ?? undefined });
          break;
        case "run.lifecycle.started":
          out.push(status("running"));
          break;
        case "task.lifecycle.proposed": {
          const taskId = str(get(payload, "task_id"));
          const kind = str(get(get(payload, "event"), "task_kind"));
          if (taskId !== undefined && kind !== undefined && kind.startsWith("tool.")) toolNames.set(taskId, kind.slice("tool.".length));
          out.push(rawEvent(line, stream));
          break;
        }
        case "task.lifecycle.scheduled": {
          const taskId = str(get(payload, "task_id"));
          const name = taskId === undefined ? undefined : toolNames.get(taskId);
          const key = str(get(get(payload, "event"), "idempotency_key"));
          if (name !== undefined && key !== undefined && key.startsWith("tool:")) {
            out.push({ type: "toolUse", id: key.slice("tool:".length), name, input: {} });
          } else out.push(rawEvent(line, stream));
          break;
        }
        case "tool.result": {
          const callId = str(get(payload, "call_id"));
          if (callId !== undefined) {
            const outcome = str(get(get(payload, "correlation_facts"), "outcome"));
            out.push({ type: "toolResult", toolUseId: callId, output: str(get(payload, "text")) ?? "",
                       isError: outcome === "failure" || outcome === "error" });
          } else out.push(rawEvent(line, stream));
          break;
        }
        case "run.output.delta": {
          const text = str(get(payload, "text"));
          if (text !== undefined && text !== "") {
            out.push({ type: "text", role: "assistant", text, blockId: str(get(get(payload, "run_stream"), "id")), partial: true });
          }
          break;
        }
        case "run.terminal.completed": {
          finished = true;
          const text = str(get(payload, "text"));
          if (text !== undefined && text !== "") {
            out.push({ type: "text", role: "assistant", text, blockId: str(get(get(payload, "run_stream"), "id")), partial: false });
          }
          out.push({ type: "turnEnd" });
          out.push(status("finished"));
          break;
        }
        case "run.terminal.failed": case "run.terminal.cancelled": {
          finished = true;
          const reason = str(get(payload, "reason")) ?? str(get(payload, "text")) ?? "Muse Code could not finish this turn.";
          out.push({ type: "error", message: mentions(reason, "does not exist or you lack access")
            ? "Muse Code cannot use this model. Choose another model in the chat. " + reason : reason });
          out.push(status("errored"));
          break;
        }
        default:
          out.push(rawEvent(line, stream));
      }
      return out;
    },
    exit(code) {
      if (finished) return [];
      if (code === 0) return [status("finished")];
      return [{ type: "error", message: exitMessage(lastError, code) }, status("errored")];
    },
  };
}

/** Both Muse streams: `muse serve` view items for chats, and the older
 * `muse exec --json` journal still sitting in existing chats' logs. Dispatch
 * is per line, so a log that crosses the change folds whole. */
function parser() {
  const exec = execParser();
  const serve = serveParser();
  function line(text, stream) {
    if (stream === "stdout") {
      const value = parse(text);
      if (value !== undefined && str(get(value, "payload_type")) === undefined
          && (str(get(value, "method")) !== undefined || str(get(value, "jsonrpc")) !== undefined)) {
        return serve.feed(text, stream);
      }
    }
    if (stream === "stderr") serve.noteStderr(text);
    return exec.feed(text, stream);
  }
  return {
    feed(batch) { return batch.map(l => line(l.line, l.stream)); },
    exit(code) { return serve.sawServe ? serve.exit(code) : exec.exit(code); },
    input() { return serve.takePendingInput(); },
  };
}

// MARK: Answers on stdin

function message({ text, images, sessionId }) {
  // Without the session's own id there is nowhere to send the turn; the
  // caller relaunches instead, which resumes it.
  if (sessionId == null || sessionId === "") return null;
  return Wire.turnStart(sessionId, { prompt: text, images: images || [], model: null, effort: null });
}

function permission({ requestId, allow, input }) {
  const sessionId = str(get(input, "sessionId"));
  if (sessionId === undefined || str(get(input, "userInputId")) !== requestId) return null;
  const base = { commandId: Wire.newId(), sessionId, userInputId: requestId };
  const cancel = () => Wire.request(5, "userInput/cancel", base);
  if (!allow) return cancel();
  const given = isObject(get(input, "answers")) ? get(input, "answers") : {};
  const questions = arr(get(input, "questions")) ?? [];
  const answers = [];
  for (const question of questions) {
    const id = str(get(question, "id")), text = str(get(question, "question"));
    const value = text === undefined ? undefined : str(get(given, text));
    if (id === undefined || value === undefined || value === "") return cancel();
    const labels = (arr(get(question, "options")) ?? []).map(option => str(get(option, "label"))).filter(defined);
    let selected;
    if (str(get(get(question, "selection"), "mode")) === "multiple") {
      const parts = value.split(",").filter(part => part !== "").map(trimSpaces);
      const picked = labels.filter(label => parts.some(part => same(part, label)));
      selected = parts.length === picked.length ? { selectedLabels: picked } : { freeText: prefix(value, 500) };
    } else if (labels.some(label => same(label, value))) {
      selected = { selectedLabel: value };
    } else {
      selected = { freeText: value };
    }
    answers.push(Object.assign({ questionId: id }, selected));
  }
  return Wire.request(5, "userInput/answer", Object.assign({}, base, { answers }));
}

// MARK: Models and settings

function option(id, label, detail, efforts, defaultEffort) {
  const model = { id, label, efforts: efforts || [] };
  if (detail !== undefined) model.detail = detail;
  if (defaultEffort !== undefined) model.defaultEffort = defaultEffort;
  return model;
}

const MODEL_LABELS = new Map([
  ["muse-wonder-1.0", "Muse Wonder"],
  ["muse-wonder-full-1.0", "Muse Wonder Full"],
  ["muse-spark-1.3", "Muse Spark 1.3"],
  ["muse-spark-1.2", "Muse Spark 1.2"],
  ["muse-ember-1.0", "Muse Ember"],
]);

/** `model/list` is the account's available models, including gated models. */
function modelCatalog(line) {
  const reply = parse(line);
  if (reply === undefined || int(get(reply, "id")) !== 2) return null;
  const rows = arr(get(get(reply, "result"), "models"));
  if (rows === undefined) return null;
  const models = [];
  for (const row of rows) {
    const id = str(get(row, "modelId"));
    if (id === undefined || id === "") continue;
    const efforts = (arr(get(row, "variants")) ?? []).map(str).filter(effort => effort !== undefined && EFFORTS.includes(effort));
    const label = MODEL_LABELS.get(id) ?? str(get(row, "displayLabel")) ?? id;
    models.push(option(id, label, str(get(row, "description")), efforts, str(get(row, "defaultReasoningEffort"))));
  }
  if (!models.length) return null;
  const catalog = { models, versions: [] };
  const accountDefault = models.find(model => rows.some(row => str(get(row, "modelId")) === model.id && get(row, "isDefault") === true));
  if (accountDefault !== undefined) catalog.accountDefault = accountDefault;
  return catalog;
}

/** Asks `muse serve` for the account's catalog: initialize, then `model/list`. */
function* discoverModels() {
  return yield { converse: {
    args: ["serve"], keepStdinOpen: true, timeout: 12, opening: [INITIALIZE],
    receive(line) {
      const reply = parse(line);
      const id = int(get(reply, "id"));
      if (id === 1) {
        if (get(reply, "result") === undefined) return { done: null };
        return { send: ['{"jsonrpc":"2.0","method":"initialized"}\n', '{"jsonrpc":"2.0","id":2,"method":"model/list","params":{}}\n'] };
      }
      if (id === 2) return { done: modelCatalog(line) };
      return null;
    },
  } };
}

// MARK: Naming

const naming = {
  launch({ prompt, home, model }) {
    return { args: ["exec", "--json", "--preset", "empty", "--no-session-log", "--disable-shell",
                    "--disable-write", "--disable-web-tools", "--no-foreign-personal-context",
                    "--disable-reminders", "--max-model-steps", "1", "--workspace", home]
               .concat(model != null ? ["--model", model] : [], prompt.startsWith("-") ? ["--", prompt] : [prompt]),
             cwd: home };
  },
  answer(output) { return terminal(output, "run.terminal.completed", "text"); },
  error(output) { return terminal(output, "run.terminal.failed", "reason"); },
  check({ home }) { return { args: ["exec", "--help"], cwd: home }; },
  checkPasses(output) {
    return ["--preset", "--no-session-log", "--disable-shell", "--disable-write", "--disable-web-tools"]
      .every(flag => output.includes(flag));
  },
};

/** The last `payload_type` record's `payload[field]` in an exec journal. */
function terminal(output, type, field) {
  let last = null;
  for (const line of lines(output)) {
    const event = parse(line);
    if (str(get(event, "payload_type")) !== type) continue;
    const value = str(get(get(event, "payload"), field));
    if (value !== undefined) last = value;
  }
  return last;
}

AbstractAgent.register({
  id: "muse",
  launch,
  parser,
  message,
  permission,
  permissionDetail(policy) {
    switch (policy) {
      case "ask": return "Muse Code is read-only here because its file edits do not ask for approval. Abstract cannot answer an approval request; use the Muse Code terminal for that.";
      case "auto-edits": return "Muse Code may edit the worktree. Abstract cannot answer a command approval here; stop the turn and use the Muse Code terminal.";
      case "bypass": return "Muse Code runs without approval or a sandbox. Only for trusted tasks.";
      case "plan": return "Muse Code is read-only and writes a plan. Nothing changes until you approve it.";
      case "read-only": return "Muse Code is read-only: it can look and answer, but can't change anything.";
      default: return null;
    }
  },
  // Without a successful account-specific model/list, let Muse choose its own default.
  catalog() { return { models: [], versions: [] }; },
  defaultModel(config) {
    const text = (config || {})[SETTINGS_FILE];
    return typeof text === "string" ? str(get(parse(text), "model")) ?? null : null;
  },
  discoverModels,
  naming,
});

// For tests of these helpers.
var MuseAgent = {
  pendingTurns: {
    peek(sessionId) { return pendingTurns.get(sessionId) ?? null; },
    remove(sessionId) { pendingTurns.delete(sessionId); },
    register(sessionId, turn) { pendingTurns.set(sessionId, turn); },
  },
  modelCatalog,
  usageTotals,
  friendly,
  newId: Wire.newId,
  turnStart: Wire.turnStart,
  setModel: Wire.setModel,
};
