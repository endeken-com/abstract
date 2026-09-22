/**
 * Claude Code provider.
 *
 * Wire format: `claude -p --output-format stream-json --input-format stream-json
 * --verbose --include-partial-messages`. Every stdout line is one JSON object.
 * Shapes here are taken from `__fixtures__/claude-stream.jsonl` (claude CLI 2.1.274).
 */

import type {
  AgentEvent,
  EditPreview,
  LaunchContext,
  LaunchSpec,
  OutputParser,
  ProviderDefinition,
  UsageTotals,
} from './types';

/* ------------------------------------------------------------------ */
/* narrowing helpers                                                    */
/* ------------------------------------------------------------------ */

type JsonObject = Record<string, unknown>;

function isObject(value: unknown): value is JsonObject {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function asObject(value: unknown): JsonObject | undefined {
  return isObject(value) ? value : undefined;
}

function asString(value: unknown): string | undefined {
  return typeof value === 'string' ? value : undefined;
}

function asNumber(value: unknown): number | undefined {
  return typeof value === 'number' && Number.isFinite(value) ? value : undefined;
}

function numberOr(value: unknown, fallback: number): number {
  return asNumber(value) ?? fallback;
}

function asArray(value: unknown): unknown[] {
  return Array.isArray(value) ? value : [];
}

/** Max diff lines kept in an EditPreview; the UI only renders a mini-diff. */
const MAX_PREVIEW_LINES = 200;

/* ------------------------------------------------------------------ */
/* launch                                                              */
/* ------------------------------------------------------------------ */

const BASE_ARGS = [
  '-p',
  '--output-format',
  'stream-json',
  '--input-format',
  'stream-json',
  '--verbose',
  '--include-partial-messages',
];

function policyArgs(ctx: LaunchContext): string[] {
  switch (ctx.permissionPolicy) {
    case 'ask':
      return ['--permission-prompts', 'host'];
    case 'auto-edits':
      return ['--permission-mode', 'acceptEdits'];
    case 'bypass':
      return ['--permission-mode', 'bypassPermissions'];
  }
}

/**
 * A stream-json user turn. Verified working against the live CLI: the prompt is
 * never an argv argument, it is written to stdin as one of these lines.
 */
function userMessageLine(text: string): string {
  return (
    JSON.stringify({
      type: 'user',
      message: { role: 'user', content: [{ type: 'text', text }] },
    }) + '\n'
  );
}

// NOTE: unverified against a live permission prompt — the control_response shape
// below is implemented from the documented protocol, not from a recorded fixture.
function permissionResponseLine(
  requestId: string,
  allow: boolean,
  updatedInput?: unknown,
): string {
  const response = allow
    ? { behavior: 'allow', updatedInput: updatedInput ?? {} }
    : { behavior: 'deny', message: 'Denied by user' };
  return (
    JSON.stringify({
      type: 'control_response',
      response: { subtype: 'success', request_id: requestId, response },
    }) + '\n'
  );
}

function buildLaunch(ctx: LaunchContext): LaunchSpec {
  return {
    command: ctx.binaryOverride ?? 'claude',
    args: [...BASE_ARGS, ...policyArgs(ctx), ...(ctx.extraArgs ?? [])],
    cwd: ctx.cwd,
    stdinInitial: userMessageLine(ctx.prompt),
    keepStdinOpen: true,
  };
}

function buildResume(ctx: LaunchContext & { resumeId: string }): LaunchSpec {
  return {
    command: ctx.binaryOverride ?? 'claude',
    args: [
      ...BASE_ARGS,
      ...policyArgs(ctx),
      '--resume',
      ctx.resumeId,
      ...(ctx.extraArgs ?? []),
    ],
    cwd: ctx.cwd,
    stdinInitial: userMessageLine(ctx.prompt),
    keepStdinOpen: true,
  };
}

/* ------------------------------------------------------------------ */
/* edit previews                                                       */
/* ------------------------------------------------------------------ */

function pushDiffLine(
  out: EditPreview['lines'],
  counts: { additions: number; deletions: number },
  raw: string,
): void {
  const head = raw.charAt(0);
  if (head === '+') {
    counts.additions += 1;
    out.push({ origin: '+', content: raw.slice(1) });
  } else if (head === '-') {
    counts.deletions += 1;
    out.push({ origin: '-', content: raw.slice(1) });
  } else if (head === ' ') {
    out.push({ origin: ' ', content: raw.slice(1) });
  } else {
    out.push({ origin: ' ', content: raw });
  }
}

/** Build an EditPreview from a `tool_use_result.structuredPatch` array. */
function previewFromStructuredPatch(
  filePath: string,
  patch: unknown[],
): EditPreview | undefined {
  const lines: EditPreview['lines'] = [];
  const counts = { additions: 0, deletions: 0 };
  for (const hunk of patch) {
    const hunkObj = asObject(hunk);
    if (!hunkObj) continue;
    for (const entry of asArray(hunkObj.lines)) {
      const raw = asString(entry);
      if (raw === undefined) continue;
      if (lines.length >= MAX_PREVIEW_LINES) break;
      pushDiffLine(lines, counts, raw);
    }
  }
  if (lines.length === 0) return undefined;
  return { filePath, additions: counts.additions, deletions: counts.deletions, lines };
}

/** Build an EditPreview for a freshly created file: every line is an addition. */
function previewFromCreate(filePath: string, content: string): EditPreview {
  const all = content.split('\n');
  if (all.length > 0 && all[all.length - 1] === '') all.pop();
  const lines = all
    .slice(0, MAX_PREVIEW_LINES)
    .map((content_) => ({ origin: '+' as const, content: content_ }));
  return { filePath, additions: all.length, deletions: 0, lines };
}

function editFromToolUseResult(result: unknown): EditPreview | undefined {
  const obj = asObject(result);
  if (!obj) return undefined;
  const filePath = asString(obj.filePath) ?? asString(obj.file_path) ?? '';
  const patch = asArray(obj.structuredPatch);
  if (patch.length > 0) return previewFromStructuredPatch(filePath, patch);
  if (obj.type === 'create') {
    const content = asString(obj.content);
    if (content !== undefined) return previewFromCreate(filePath, content);
  }
  return undefined;
}

/* ------------------------------------------------------------------ */
/* parser                                                              */
/* ------------------------------------------------------------------ */

interface BlockState {
  kind: 'text' | 'tool_use' | 'thinking' | 'other';
  toolId?: string;
  toolName?: string;
  jsonBuffer: string;
}

/** Flatten a tool_result `content` field (string, or array of content blocks). */
function flattenContent(content: unknown): string {
  const direct = asString(content);
  if (direct !== undefined) return direct;
  const parts: string[] = [];
  for (const entry of asArray(content)) {
    const obj = asObject(entry);
    if (!obj) continue;
    const text = asString(obj.text);
    if (text !== undefined) parts.push(text);
  }
  return parts.join('');
}

function usageFrom(usage: unknown): UsageTotals {
  const obj = asObject(usage) ?? {};
  return {
    inputTokens: numberOr(obj.input_tokens, 0),
    outputTokens: numberOr(obj.output_tokens, 0),
    cacheRead: numberOr(obj.cache_read_input_tokens, 0),
    cacheWrite: numberOr(obj.cache_creation_input_tokens, 0),
  };
}

class ClaudeParser implements OutputParser {
  private messageId = '';
  private readonly blocks = new Map<number, BlockState>();

  feed(line: string, stream: 'stdout' | 'stderr'): AgentEvent[] {
    if (stream === 'stderr') {
      if (line.trim() === '') return [];
      return [{ type: 'raw', line, stream: 'stderr' }];
    }
    const trimmed = line.trim();
    if (trimmed === '') return [];

    let parsed: unknown;
    try {
      parsed = JSON.parse(trimmed);
    } catch {
      return [{ type: 'raw', line, stream }];
    }
    const obj = asObject(parsed);
    if (!obj) return [{ type: 'raw', line, stream }];

    try {
      return this.dispatch(obj, line, stream);
    } catch {
      // A parser must never throw; anything unexpected degrades to a raw line.
      return [{ type: 'raw', line, stream }];
    }
  }

  onExit(code: number | null): AgentEvent[] {
    if (code === 0) return [{ type: 'status', status: 'finished' }];
    return [
      { type: 'error', message: `claude exited with code ${code ?? 'null'}` },
      { type: 'status', status: 'errored' },
    ];
  }

  private dispatch(obj: JsonObject, line: string, stream: 'stdout' | 'stderr'): AgentEvent[] {
    switch (obj.type) {
      case 'system':
        return this.onSystem(obj, line, stream);
      case 'stream_event':
        return this.onStreamEvent(obj, line, stream);
      case 'assistant':
        return this.onAssistant(obj);
      case 'user':
        return this.onUser(obj);
      case 'result':
        return this.onResult(obj);
      case 'control_request':
        return this.onControlRequest(obj, line, stream);
      // Housekeeping frames the UI has no use for.
      case 'rate_limit_event':
        return [];
      default:
        return [{ type: 'raw', line, stream }];
    }
  }

  private onSystem(obj: JsonObject, line: string, stream: 'stdout' | 'stderr'): AgentEvent[] {
    switch (obj.subtype) {
      case 'init': {
        const events: AgentEvent[] = [];
        const sessionId = asString(obj.session_id);
        if (sessionId !== undefined) events.push({ type: 'session_id', id: sessionId });
        events.push({
          type: 'system',
          model: asString(obj.model),
          cwd: asString(obj.cwd),
          permissionMode: asString(obj.permissionMode),
          sessionId,
        });
        return events;
      }
      case 'post_turn_summary': {
        const events: AgentEvent[] = [
          { type: 'turn_end', summary: asString(obj.status_detail) },
        ];
        const needsAction = asString(obj.needs_action);
        if (needsAction !== undefined && needsAction !== '') {
          events.push({ type: 'status', status: 'waiting_input', detail: needsAction });
        }
        return events;
      }
      // Transient chrome: not surfaced.
      case 'status':
      case 'hook_started':
      case 'hook_response':
      case 'commands_changed':
      case 'task_summary':
        return [];
      default:
        return [{ type: 'raw', line, stream }];
    }
  }

  private blockId(index: number): string {
    return `${this.messageId}:${index}`;
  }

  private onStreamEvent(
    obj: JsonObject,
    line: string,
    stream: 'stdout' | 'stderr',
  ): AgentEvent[] {
    const event = asObject(obj.event);
    if (!event) return [{ type: 'raw', line, stream }];

    switch (event.type) {
      case 'message_start': {
        const message = asObject(event.message);
        this.messageId = asString(message?.id) ?? '';
        this.blocks.clear();
        return [{ type: 'status', status: 'running' }];
      }
      case 'content_block_start': {
        const index = numberOr(event.index, 0);
        const block = asObject(event.content_block);
        const kind = block?.type;
        this.blocks.set(index, {
          kind:
            kind === 'text' || kind === 'tool_use' || kind === 'thinking' ? kind : 'other',
          toolId: asString(block?.id),
          toolName: asString(block?.name),
          jsonBuffer: '',
        });
        // The complete block arrives on the `assistant` frame; emitting here too
        // would duplicate it in the transcript.
        return [];
      }
      case 'content_block_delta': {
        const index = numberOr(event.index, 0);
        const delta = asObject(event.delta);
        if (!delta) return [];
        switch (delta.type) {
          case 'text_delta': {
            const text = asString(delta.text) ?? '';
            return [
              {
                type: 'text',
                role: 'assistant',
                text,
                blockId: this.blockId(index),
                partial: true,
              },
            ];
          }
          case 'thinking_delta': {
            const text = asString(delta.thinking) ?? '';
            return [
              { type: 'thinking', text, blockId: this.blockId(index), partial: true },
            ];
          }
          case 'input_json_delta': {
            const state = this.blocks.get(index);
            if (state) state.jsonBuffer += asString(delta.partial_json) ?? '';
            return [];
          }
          default:
            return [];
        }
      }
      case 'content_block_stop': {
        this.blocks.delete(numberOr(event.index, 0));
        return [];
      }
      case 'message_delta':
        return [];
      case 'message_stop': {
        this.blocks.clear();
        return [];
      }
      default:
        return [{ type: 'raw', line, stream }];
    }
  }

  private onAssistant(obj: JsonObject): AgentEvent[] {
    const message = asObject(obj.message);
    if (!message) return [];
    const messageId = asString(message.id) ?? this.messageId;
    const events: AgentEvent[] = [];
    asArray(message.content).forEach((entry, index) => {
      const block = asObject(entry);
      if (!block) return;
      if (block.type === 'text') {
        events.push({
          type: 'text',
          role: 'assistant',
          text: asString(block.text) ?? '',
          blockId: `${messageId}:${index}`,
          partial: false,
        });
      } else if (block.type === 'tool_use') {
        events.push({
          type: 'tool_use',
          id: asString(block.id) ?? '',
          name: asString(block.name) ?? '',
          input: block.input,
        });
      }
    });
    return events;
  }

  private onUser(obj: JsonObject): AgentEvent[] {
    const message = asObject(obj.message);
    if (!message) return [];
    const edit = editFromToolUseResult(obj.tool_use_result);
    const events: AgentEvent[] = [];
    for (const entry of asArray(message.content)) {
      const block = asObject(entry);
      if (!block) continue;
      if (block.type === 'tool_result') {
        events.push({
          type: 'tool_result',
          toolUseId: asString(block.tool_use_id) ?? '',
          output: flattenContent(block.content),
          isError: block.is_error === true,
          edit,
        });
      } else if (block.type === 'text') {
        events.push({ type: 'text', role: 'user', text: asString(block.text) ?? '' });
      }
    }
    return events;
  }

  private onResult(obj: JsonObject): AgentEvent[] {
    const events: AgentEvent[] = [
      {
        type: 'usage',
        usage: usageFrom(obj.usage),
        costUsd: asNumber(obj.total_cost_usd),
        durationMs: asNumber(obj.duration_ms),
        turns: asNumber(obj.num_turns),
      },
    ];
    if (obj.is_error === true) {
      events.push({
        type: 'error',
        message: asString(obj.result) ?? asString(obj.subtype) ?? 'Agent reported an error',
      });
      events.push({ type: 'status', status: 'errored' });
    } else {
      // The process stays alive after a result, awaiting the next stdin turn.
      events.push({ type: 'status', status: 'waiting_input' });
    }
    return events;
  }

  // NOTE: unverified against a live permission prompt — no control_request frame
  // appears in the recorded fixture.
  private onControlRequest(
    obj: JsonObject,
    line: string,
    stream: 'stdout' | 'stderr',
  ): AgentEvent[] {
    const request = asObject(obj.request);
    const requestId = asString(obj.request_id);
    if (!request || requestId === undefined || request.subtype !== 'can_use_tool') {
      return [{ type: 'raw', line, stream }];
    }
    return [
      {
        type: 'permission_request',
        requestId,
        toolName: asString(request.tool_name) ?? '',
        input: request.input,
      },
    ];
  }
}

/* ------------------------------------------------------------------ */

export const claudeProvider: ProviderDefinition = {
  id: 'claude',
  name: 'Claude Code',
  binary: 'claude',
  detectArgs: ['--version'],
  followUpMode: 'stdin',
  buildLaunch,
  buildResume,
  createParser: () => new ClaudeParser(),
  buildUserMessage: userMessageLine,
  buildPermissionResponse: permissionResponseLine,
};
