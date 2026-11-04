// OpenCode as an Abstract agent plugin (ABS-185), moved from Abstract's
// OpenCodeProvider.swift. `opencode run --format json` prints complete parts,
// one JSON object a line; each run is one turn and `--session` resumes the
// conversation on the next. Shapes checked against OpenCode 1.18.18.
"use strict";

const PROFILE_AGENT = "abstract-profile";
const NAMING_AGENT = "abstract-naming";
const NAMING_CONFIG = '{"agent":{"abstract-naming":{"mode":"primary","tools":{"*":false},"permission":{"*":"deny"}}}}';
const NAMING_ENV = { OPENCODE_CONFIG_CONTENT: NAMING_CONFIG, OPENCODE_PERMISSION: '{"*":"deny"}' };
const CONFIG_FILE = ".config/opencode/opencode.json";

function parse(text) {
  try { return JSON.parse(text); } catch (e) { return undefined; }
}
function isObject(value) { return value !== null && typeof value === "object" && !Array.isArray(value); }
function str(value) { return typeof value === "string" ? value : undefined; }
function int(value) { return typeof value === "number" ? Math.trunc(value) : undefined; }
function blank(text) { return text.trim().length === 0; }

// MARK: Launching

/** One server in OpenCode's `mcp` block. */
function mcpEntry(connection) {
  if (connection.type === "url") {
    const entry = { type: "remote", url: connection.url, enabled: true };
    if (Object.keys(connection.headers || {}).length) entry.headers = connection.headers;
    return entry;
  }
  const entry = { type: "local", command: connection.argv, enabled: true };
  if (Object.keys(connection.env || {}).length) entry.environment = connection.env;
  return entry;
}

/** How OpenCode names an MCP tool: server and tool, each with anything but
 * letters, digits, `_` and `-` made `_` (checked in OpenCode 1.18.18). */
function toolKey(server, tool) {
  const clean = s => Array.from(s).map(c => /^[A-Za-z0-9_-]$/.test(c) ? c : "_").join("");
  return clean(server) + "_" + clean(tool);
}

/** The code-history tool, a profile's agent, library skills, plugin tools
 * and the project's servers, in `OPENCODE_CONFIG_CONTENT`, which OpenCode
 * merges with the user's own config: theirs stays, ours is added. */
function configEnv(ctx) {
  const config = {};
  const instructions = [];
  const names = ctx.serverNames;
  const local = command => ({ type: "local", command, enabled: true });
  if (ctx.historyTool) {
    config.mcp = { [names.history]: local(ctx.historyTool.serverCommand) };
    if (ctx.historyTool.instructionFile) instructions.push(ctx.historyTool.instructionFile);
  }
  if (ctx.skills) config.skills = { paths: [ctx.skills.folder] };
  if (ctx.pluginTools) config.mcp = Object.assign(config.mcp || {}, { [names.plugins]: local(ctx.pluginTools.serverCommand) });
  if (ctx.branchTool) config.mcp = Object.assign(config.mcp || {}, { [names.branch]: local(ctx.branchTool.serverCommand) });
  // `run` can't ask, so an Ask first tool is turned off like an Off one.
  if (ctx.toolServers.length) {
    const servers = config.mcp || {};
    const tools = {};
    for (const server of ctx.toolServers) {
      servers[server.name] = mcpEntry(server.connection);
      for (const tool of server.withheld) tools[toolKey(server.name, tool)] = false;
    }
    config.mcp = servers;
    if (Object.keys(tools).length) config.tools = tools;
    if (ctx.toolNotes && ctx.configDirectory) {
      const file = AbstractAgent.writeConfigFile("opencode-tool-notes.md", ctx.toolNotes + "\n");
      if (file) instructions.push(file);
    }
  }
  if (instructions.length) config.instructions = instructions;
  if (ctx.instructions) config.agent = { [PROFILE_AGENT]: { mode: "primary", prompt: ctx.instructions } };
  return Object.keys(config).length ? { OPENCODE_CONFIG_CONTENT: AbstractAgent.compactJSON(config) } : {};
}

function launch(ctx, resumeId) {
  // `run` has no approval channel: only Full autonomy approves what OpenCode's
  // own rules would ask about. Its plan agent can't edit, so Plan and Ask use
  // it, and a profile's instructions ride on the prompt there (ABS-101).
  const auto = ctx.permissionPolicy === "bypass" ? ["--auto"] : [];
  const agent = ctx.readOnly ? ["--agent", "plan"] : (ctx.instructions ? ["--agent", PROFILE_AGENT] : []);
  const historyInPrompt = ctx.historyTool && !ctx.historyTool.instructionFile;
  const notesInPrompt = ctx.configDirectory ? null : ctx.toolNotes;
  const prompt = (ctx.readOnly && ctx.instructions ? ctx.instructions + "\n\n" : "")
    + (ctx.outputStyle.instructions ? ctx.outputStyle.instructions + "\n\n" : "")
    + (ctx.permissionPolicy === "read-only" ? ctx.text.readOnly + "\n\n" : "")
    + (historyInPrompt ? ctx.text.codeHistory + "\n\n" : "")
    + (notesInPrompt ? notesInPrompt + "\n\n" : "") + ctx.prompt;
  return {
    // OpenCode finds its project from the inherited PWD, so the worktree is named outright.
    args: ["run", "--format", "json", "--thinking", "--dir", ctx.cwd].concat(auto, agent,
      resumeId ? ["--session", resumeId] : [],
      ctx.model ? ["--model", ctx.model] : [],
      ctx.effort ? ["--variant", ctx.effort] : [],
      ctx.images.flatMap(image => ["--file", image]),
      ctx.extraArgs,
      prompt.startsWith("-") ? ["--", prompt] : [prompt]),
    env: configEnv(ctx),
    keepStdinOpen: false,
  };
}

// MARK: Reading its output

/** Unknown lines stay raw in the log, so a newer CLI can still be read. */
function parser() {
  let sessionId = null;
  const seenTools = new Set();
  const finishedTools = new Set();

  function line(text, stream) {
    const raw = { type: "raw", line: text, stream };
    if (stream !== "stdout") return [raw];
    const object = parse(text);
    if (!isObject(object) || typeof object.type !== "string") return [raw];
    const events = [];
    const id = str(object.sessionID);
    if (id !== undefined && id !== sessionId) {
      sessionId = id;
      events.push({ type: "sessionId", id });
    }
    const part = isObject(object.part) ? object.part : {};
    switch (object.type) {
      case "step_start":
        events.push({ type: "status", status: "running" });
        break;
      case "text": {
        const t = str(part.text);
        if (t !== undefined && !blank(t)) events.push({ type: "text", role: "assistant", text: t, blockId: str(part.id), partial: false });
        break;
      }
      case "reasoning": {
        const t = str(part.text);
        if (t !== undefined && !blank(t)) events.push({ type: "thinking", text: t, blockId: str(part.id), partial: false });
        break;
      }
      case "tool_use": {
        const tool = str(part.tool), callId = str(part.callID);
        if (tool === undefined || callId === undefined) return events.concat([raw]);
        const state = isObject(part.state) ? part.state : {};
        const input = "input" in state ? state.input : {};
        const status = str(state.status);
        // Its edit and write name their fields in camelCase; the host's preview reads both.
        const edit = AbstractAgent.editPreview(tool, input);
        if (!seenTools.has(callId)) {
          seenTools.add(callId);
          events.push({ type: "toolUse", id: callId, name: tool, input, edit });
        }
        // The full input may only come with the result, so a completed edit carries its diff there too.
        if ((status === "completed" || status === "error") && !finishedTools.has(callId)) {
          finishedTools.add(callId);
          const output = str(state.output) ?? str(state.error) ?? "";
          events.push({ type: "toolResult", toolUseId: callId, output, isError: status === "error",
                        edit: status === "completed" ? edit : null });
        }
        break;
      }
      case "step_finish": {
        const tokens = isObject(part.tokens) ? part.tokens : {};
        const cache = isObject(tokens.cache) ? tokens.cache : {};
        events.push({ type: "usage", usage: { inputTokens: int(tokens.input) || 0, outputTokens: int(tokens.output) || 0,
                                              cacheRead: int(cache.read) || 0, cacheWrite: int(cache.write) || 0 },
                      costUsd: typeof part.cost === "number" ? part.cost : undefined });
        break;
      }
      case "error": {
        const error = isObject(object.error) ? object.error : {};
        events.push({ type: "error", message: str(error.message) ?? str(object.message) ?? "OpenCode reported an error" });
        events.push({ type: "status", status: "errored" });
        break;
      }
      default:
        events.push(raw);
    }
    return events;
  }

  return {
    feed(lines) { return lines.map(l => line(l.line, l.stream)); },
    exit(code) {
      if (code === 0) return [{ type: "status", status: "finished" }];
      return [{ type: "error", message: "opencode exited with code " + (code === null ? "null" : String(code)) },
              { type: "status", status: "errored" }];
    },
  };
}

// MARK: Models and settings

function readConfig(config) {
  const object = parse((config || {})[CONFIG_FILE] || "");
  return isObject(object) ? object : {};
}

function effortOrder(value) {
  const index = ["none", "minimal", "low", "medium", "high", "xhigh", "max"].indexOf(value);
  return index < 0 ? 100 : index;
}

/** `opencode models --verbose`: an id line, then a pretty JSON object per
 * model. Variants become the effort choices. */
function modelCatalog(output) {
  const models = [];
  let id = null;
  let json = [];
  for (const line of output.split("\n")) {
    if (id === null) {
      const candidate = line.trim();
      if (candidate.includes("/") && !candidate.includes(" ") && !candidate.startsWith("{")) id = candidate;
      continue;
    }
    json.push(line);
    const object = parse(json.join("\n"));
    if (!isObject(object)) continue;
    const variants = isObject(object.variants) ? object.variants : {};
    const efforts = Object.keys(variants).filter(key => isObject(variants[key]) && typeof variants[key].reasoningEffort === "string")
      .sort((a, b) => effortOrder(a) - effortOrder(b) || (a < b ? -1 : a > b ? 1 : 0));
    models.push({ id, label: str(object.name) ?? id, efforts });
    id = null;
    json = [];
  }
  return models.length ? { models, versions: [] } : null;
}

// MARK: Compaction, through `opencode serve`

const Server = {
  /** "opencode server listening on http://127.0.0.1:4096" → 4096. */
  port(line) {
    const at = line.indexOf("listening on http://");
    if (at < 0) return null;
    const address = line.slice(at + "listening on http://".length);
    const colon = address.lastIndexOf(":");
    if (colon < 0) return null;
    const digits = address.slice(colon + 1).match(/^[0-9]*/)[0];
    return digits ? parseInt(digits, 10) : null;
  },
  /** "openrouter/anthropic/x" → { provider: "openrouter", model: "anthropic/x" }. */
  model(id) {
    const slash = id.indexOf("/");
    if (slash <= 0 || slash === id.length - 1) return null;
    return { provider: id.slice(0, slash), model: id.slice(slash + 1) };
  },
  replies(messages) {
    return (Array.isArray(messages) ? messages : []).filter(m => isObject(m) && isObject(m.info) && m.info.role === "assistant");
  },
  /** The context's size: the last reply's tokens, not counting a compaction's. */
  contextTokens(messages) {
    const replies = Server.replies(messages).filter(m => m.info.mode !== "compaction");
    const last = replies[replies.length - 1];
    return last && isObject(last.info.tokens) && typeof last.info.tokens.total === "number" ? Math.trunc(last.info.tokens.total) : null;
  },
  /** What the compaction wrote: its reply's text, without the reasoning. */
  summary(messages) {
    const replies = Server.replies(messages).filter(m => m.info.mode === "compaction");
    const reply = replies[replies.length - 1];
    if (!reply) return null;
    const text = (Array.isArray(reply.parts) ? reply.parts : []).filter(p => isObject(p) && p.type === "text" && typeof p.text === "string")
      .map(p => p.text).join("\n\n").trim();
    return text.length ? text : null;
  },
  /** `{"name":…,"data":{"message":…}}` → its message. */
  errorMessage(body) {
    const object = parse(body);
    return isObject(object) && isObject(object.data) && typeof object.data.message === "string" ? object.data.message : null;
  },
  /** `base + path`, with `directory` as its query value, percent-encoded by
   * hand: OpenCode reads a literal `+` as a space, and space, `&` and `#`
   * must stay encoded too. */
  url(base, path, directory) {
    const allowed = /^[A-Za-z0-9\-._~!$'()*,;:@\/?]$/;
    let encoded = "";
    for (const c of Array.from(directory)) {
      if (allowed.test(c)) { encoded += c; continue; }
      for (const byte of unescape(encodeURIComponent(c))) encoded += "%" + byte.charCodeAt(0).toString(16).toUpperCase().padStart(2, "0");
    }
    return base + path + "?directory=" + encoded;
  },
  /** curl's `--max-time`: whole seconds left until `deadline`, at least 1;
   * null at or past it. One deadline bounds every call together. */
  maxTime(deadline, now) {
    const remaining = (deadline - now) / 1000;
    return remaining > 0 ? Math.max(1, Math.trunc(remaining)) : null;
  },
};

/** Starts `opencode serve` on the chat's host with a one-time password, asks
 * it to compact the session, reads the summary back, and stops it. */
function* compact(request) {
  const id = request.model || request.defaultModel;
  const model = id ? Server.model(id) : null;
  if (!model) throw new Error("OpenCode needs a model to compact with; choose one for this chat.");
  const deadline = Date.now() + 300 * 1000;
  const password = AbstractAgent.uuid();
  const server = yield { start: { args: ["serve", "--hostname", "127.0.0.1", "--port", "0"], cwd: request.cwd,
                                  env: { OPENCODE_SERVER_PASSWORD: password }, until: "listening on http://.*:[0-9]", timeout: 30 } };
  const port = Server.port(server.line);
  if (port === null) throw new Error("OpenCode's server didn't say where it listens.");
  const base = "http://127.0.0.1:" + port;
  function* call(path, extra) {
    const maxTime = Server.maxTime(deadline, Date.now());
    if (maxTime === null) throw new Error("opencode didn't answer in time.");
    const answer = yield { http: Object.assign({ url: Server.url(base, path, request.cwd), user: "opencode:" + password,
                                                 maxTime, cwd: request.cwd }, extra) };
    if (answer.status === undefined) {
      if (answer.timedOut) throw new Error("opencode didn't answer in time.");
      throw new Error("Couldn't reach OpenCode's server: " + (answer.error || ""));
    }
    if (!answer.ok) throw new Error("OpenCode: " + (Server.errorMessage(answer.body) || "HTTP " + answer.status));
    return answer.body;
  }
  const messages = "/session/" + request.sessionId + "/message";
  const before = Server.contextTokens(parse(yield* call(messages, {})));
  const body = AbstractAgent.compactJSON({ providerID: model.provider, modelID: model.model });
  const answer = yield* call("/session/" + request.sessionId + "/summarize",
                             { method: "POST", headers: { "content-type": "application/json" }, body });
  if (answer.trim() !== "true") throw new Error("OpenCode didn't compact: " + answer.slice(0, 200));
  const summary = Server.summary(parse(yield* call(messages, {})));
  yield { stop: server.handle };
  return { tokensBefore: before, summary };
}

// MARK: Naming

function namingCheckPasses(output) {
  const object = AbstractAgent.firstObject(output);
  const agent = object === null ? undefined : parse(object);
  if (!isObject(agent) || agent.name !== NAMING_AGENT) return false;
  const tools = isObject(agent.tools) ? agent.tools : null;
  if (!tools || !Object.keys(tools).length || !Object.values(tools).every(v => v === false)) return false;
  const rules = Array.isArray(agent.permission) ? agent.permission : null;
  if (!rules) return false;
  let deny = -1;
  rules.forEach((rule, i) => {
    if (isObject(rule) && rule.permission === "*" && rule.pattern === "*" && rule.action === "deny") deny = i;
  });
  if (deny < 0) return false;
  return rules.slice(deny + 1).every(rule => isObject(rule) && rule.permission === "external_directory");
}

AbstractAgent.register({
  id: "opencode",
  launch,
  parser,
  permissionDetail(policy) {
    switch (policy) {
      case "bypass": return "OpenCode approves anything its own rules don't deny. Only for trusted tasks.";
      case "plan": return "OpenCode's plan agent explores and writes a plan. Nothing changes until you approve it.";
      case "read-only": return "OpenCode's plan agent answers without changing anything.";
      default: return "OpenCode's own permission rules apply; anything they would ask about is declined.";
    }
  },
  defaultModel(config) { return str(readConfig(config).model) ?? null; },
  catalog() { return { models: [], versions: [] }; },
  *discoverModels(input) {
    const result = yield { run: { args: ["models", "--verbose"], timeout: 30 } };
    return result.ok ? modelCatalog(result.stdout) : null;
  },
  compact,
  naming: {
    // Its small model when one is set, else the chat's, as an agent with no
    // tools and every permission denied, given through the environment.
    launch({ prompt, home, model, config }) {
      const chosen = str(readConfig(config).small_model) ?? model;
      return { args: ["run", "--format", "json", "--agent", NAMING_AGENT, "--dir", home]
                 .concat(chosen ? ["--model", chosen] : [], prompt.startsWith("-") ? ["--", prompt] : [prompt]),
               cwd: home, env: NAMING_ENV };
    },
    // `run` falls back to its default agent, every tool on, when it doesn't
    // find the one asked for, so how it resolves the naming agent is read first.
    check({ home }) { return { args: ["debug", "agent", NAMING_AGENT], cwd: home, env: NAMING_ENV }; },
    checkPasses: namingCheckPasses,
    answer(output) {
      const texts = [];
      for (const line of output.split("\n")) {
        if (!line) continue;
        const event = parse(line);
        if (!isObject(event)) continue;
        if (event.type === "text" && isObject(event.part) && typeof event.part.text === "string") texts.push(event.part.text);
        else if (event.type === "error") return null;
      }
      return texts.length ? texts.join("\n") : null;
    },
    error(output) {
      let last = null;
      for (const line of output.split("\n")) {
        if (!line) continue;
        const event = parse(line);
        if (!isObject(event) || event.type !== "error") continue;
        const error = isObject(event.error) ? event.error : {};
        const message = (isObject(error.data) ? str(error.data.message) : undefined) ?? str(error.message) ?? str(event.message);
        if (message !== undefined) last = message;
      }
      return last;
    },
  },
});

// For tests of these helpers.
var OpenCodeAgent = { Server, modelCatalog, toolKey, configEnv, PROFILE_AGENT };
