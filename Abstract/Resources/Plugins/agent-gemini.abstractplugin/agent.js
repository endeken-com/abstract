// Google's Antigravity CLI 1.5.3, verified with a signed-in Gemini 3.8 Flash
// turn and a second process resumed by conversation id (ABS-195).
"use strict";

const DEFAULT_MODEL = "gemini-3.8-flash-medium";
const FALLBACK_MODELS = [
  { id: "gemini-3.8-flash-high", label: "Gemini 3.8 Flash (High)", efforts: [] },
  { id: DEFAULT_MODEL, label: "Gemini 3.8 Flash (Medium)", efforts: [] },
  { id: "gemini-3.8-flash-low", label: "Gemini 3.8 Flash (Low)", efforts: [] },
];

function object(value) { return value !== null && typeof value === "object" && !Array.isArray(value); }
function string(value) { return typeof value === "string" ? value : null; }
function number(value) { return typeof value === "number" && Number.isFinite(value) ? value : null; }
function parse(line) { try { return JSON.parse(line); } catch (_) { return null; } }

function catalog(output) {
  const models = [];
  for (const line of output.split("\n")) {
    const match = /^(gemini-[a-zA-Z0-9.-]+)\s+(.+)$/.exec(line.trim());
    if (match) models.push({ id: match[1], label: match[2].trim(), efforts: [] });
  }
  return models.length ? { accountDefault: models.find(model => model.id === DEFAULT_MODEL) || models[0], models, versions: [] } : null;
}

function namingResult(output) {
  const result = parse(output);
  return object(result) ? result : null;
}

function launch(ctx, resumeId) {
  const parts = [ctx.branchTool ? null : ctx.instructions, ctx.outputStyle && ctx.outputStyle.instructions,
    ctx.permissionPolicy === "plan" ? ctx.text.plan : ctx.permissionPolicy === "read-only" ? ctx.text.readOnly : null]
    .filter(part => typeof part === "string" && part.length);
  const prompt = parts.length ? parts.join("\n\n") + "\n\n" + ctx.prompt : ctx.prompt;
  const policy = ctx.permissionPolicy;
  const flags = policy === "bypass" ? ["--dangerously-skip-permissions"]
    : policy === "auto-edits" ? ["--mode", "accept-edits"]
    : policy === "plan" || policy === "read-only" ? ["--mode", "plan"] : [];
  return { args: ["--print", prompt, "--output-format", "stream-json", "--model", ctx.model || DEFAULT_MODEL]
    .concat(resumeId ? ["--conversation", resumeId] : [], flags, ctx.extraArgs || []),
    env: {}, keepStdinOpen: false };
}

function tokens(value) {
  const usage = object(value) ? value : {};
  return { inputTokens: number(usage.input_tokens) || 0, outputTokens: number(usage.output_tokens) || 0,
    cacheRead: number(usage.cache_read_tokens) || 0, cacheWrite: 0 };
}

function parser() {
  let conversationId = null, lastTextId = null, failed = false;
  let stepUsage = { inputTokens: 0, outputTokens: 0, cacheRead: 0, cacheWrite: 0 };
  let hasStepUsage = false;
  const started = new Set(), finished = new Set();

  function line(text, stream) {
    const raw = { type: "raw", line: text, stream };
    if (stream !== "stdout") return [raw];
    const event = parse(text);
    if (!object(event) || typeof event.event !== "string") return [raw];
    const out = [];
    const id = string(event.conversation_id) || string(event.result && event.result.conversation_id);
    if (id && id !== conversationId) { conversationId = id; out.push({ type: "sessionId", id }); }

    switch (event.event) {
      case "init": {
        const init = object(event.init) ? event.init : {};
        out.push({ type: "system", model: string(init.model), cwd: string(init.cwd),
          permissionMode: string(init.permission_mode), sessionId: conversationId });
        out.push({ type: "status", status: "running" });
        return out;
      }
      case "step_update": {
        const step = event.step_update;
        if (!object(step)) return out.concat(raw);
        if (step.state === "DONE" && object(step.usage)) {
          const part = tokens(step.usage);
          for (const key of Object.keys(stepUsage)) stepUsage[key] += part[key];
          hasStepUsage = true;
        }
        if (step.step_type === "agent_response") {
          const delta = string(step.text_delta);
          if (delta) {
            lastTextId = "agy-text-" + String(step.step_index);
            out.push({ type: "text", role: "assistant", text: delta, blockId: lastTextId, partial: true });
          }
          return out;
        }
        if (step.step_type === "tool") {
          const tool = object(step.tool_info) ? step.tool_info : {};
          const name = string(step.tool_name) || string(tool.name);
          if (!name || number(step.step_index) === null) return out.concat(raw);
          const toolId = (conversationId || "agy") + ":" + String(step.step_index);
          const input = object(tool.parameters) ? Object.assign({}, tool.parameters) : {};
          // Antigravity's parameter casing differs from the chat's shared tool presentation.
          if (typeof input.Path === "string") input.file_path = input.Path;
          if (typeof input.CommandLine === "string") input.command = input.CommandLine;
          if (!started.has(toolId)) {
            started.add(toolId);
            out.push({ type: "toolUse", id: toolId, name, input, edit: AbstractAgent.editPreview(name, input) });
          }
          if (step.state === "DONE" && !finished.has(toolId)) {
            finished.add(toolId);
            const error = object(tool.error) ? tool.error : null;
            const output = string(tool.output) || (tool.output == null ? "" : AbstractAgent.compactJSON(tool.output));
            out.push({ type: "toolResult", toolUseId: toolId,
              output: error ? (string(error.message) || output) : output, isError: error !== null });
          }
          return out;
        }
        return ["user_input", "checkpoint"].includes(step.step_type) ? out : out.concat(raw);
      }
      case "result": {
        const result = object(event.result) ? event.result : {};
        const response = string(result.response);
        if (response && response.trim()) {
          out.push({ type: "text", role: "assistant", text: response,
            blockId: lastTextId || "agy-final", partial: false });
        }
        const usage = hasStepUsage ? stepUsage : tokens(result.usage);
        out.push({ type: "usage", usage });
        const duration = number(result.duration_seconds);
        out.push({ type: "turnEnd", durationMs: duration === null ? undefined : Math.round(duration * 1000), usage });
        if (result.status !== "SUCCESS") {
          failed = true;
          out.push({ type: "error", message: string(result.error) || "Antigravity reported " + (string(result.status) || "an error") });
          out.push({ type: "status", status: "errored" });
        }
        return out;
      }
      default: return out.concat(raw);
    }
  }

  return { feed(lines) { return lines.map(item => line(item.line, item.stream)); },
    exit(code) {
      if (failed) return [];
      if (code === 0) return [{ type: "status", status: "finished" }];
      return [{ type: "error", message: "Antigravity exited with code " + String(code) },
        { type: "status", status: "errored" }];
    } };
}

AbstractAgent.register({
  id: "gemini", launch, parser,
  catalog() { return { accountDefault: FALLBACK_MODELS[1], models: FALLBACK_MODELS, versions: [] }; },
  *discoverModels() { const result = yield { run: { args: ["models"], timeout: 20 } }; return result.ok ? catalog(result.stdout) : null; },
  permissionDetail(policy) {
    if (policy === "bypass") return "Antigravity approves all tool actions. Only for trusted tasks.";
    if (policy === "plan" || policy === "read-only") return "Antigravity uses plan mode; tools cannot change files.";
    if (policy === "auto-edits") return "Antigravity accepts file edits; other approvals are declined in headless mode.";
    return "Antigravity declines tool actions that need approval in headless mode.";
  },
  naming: {
    launch({ prompt, home, model }) {
      // Strict requests approval even for reads; headless mode denies it. Slash
      // expansion is disabled so task text cannot invoke a skill or command.
      return { args: ["--print", prompt, "--output-format", "json", "--model", model || DEFAULT_MODEL,
        "--disable-slash-commands", "--settings", '{"toolPermission":"strict"}'], cwd: home };
    },
    answer(output) {
      const result = namingResult(output);
      return result && result.status === "SUCCESS" ? string(result.response) : null;
    },
    error(output) {
      const result = namingResult(output);
      return result && result.status !== "SUCCESS" ? string(result.error) : null;
    },
  },
});

var GeminiAgent = { catalog, launch };
