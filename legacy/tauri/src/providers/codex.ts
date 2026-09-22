/**
 * Codex CLI provider.
 *
 * Wire format: `codex exec --json`. Every stdout line is one JSON object.
 * Verified shapes come from `__fixtures__/codex-stream.jsonl` (codex-cli 0.153.4),
 * which only exercises `thread.started`, `turn.started`, `agent_message`,
 * `command_execution` and `turn.completed`. Every other branch is best-effort and
 * marked `// NOTE: unverified`.
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

const MAX_PREVIEW_LINES = 200;

/* ------------------------------------------------------------------ */
/* launch                                                              */
/* ------------------------------------------------------------------ */

function sandboxArgs(ctx: LaunchContext): string[] {
  switch (ctx.permissionPolicy) {
    case 'ask':
    case 'auto-edits':
      return ['-s', 'workspace-write'];
    case 'bypass':
      return ['-s', 'danger-full-access'];
  }
}

function buildLaunch(ctx: LaunchContext): LaunchSpec {
  return {
    command: ctx.binaryOverride ?? 'codex',
    args: [
      'exec',
      '--json',
      '-C',
      ctx.cwd,
      '--skip-git-repo-check',
      ...sandboxArgs(ctx),
      ...(ctx.extraArgs ?? []),
      ctx.prompt,
    ],
    cwd: ctx.cwd,
    keepStdinOpen: false,
  };
}

function buildResume(ctx: LaunchContext & { resumeId: string }): LaunchSpec {
  return {
    command: ctx.binaryOverride ?? 'codex',
    args: [
      'exec',
      'resume',
      ctx.resumeId,
      '--json',
      '-C',
      ctx.cwd,
      '--skip-git-repo-check',
      ...sandboxArgs(ctx),
      ...(ctx.extraArgs ?? []),
      ctx.prompt,
    ],
    cwd: ctx.cwd,
    keepStdinOpen: false,
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

function previewFromUnifiedDiff(filePath: string, diff: string): EditPreview | undefined {
  const lines: EditPreview['lines'] = [];
  const counts = { additions: 0, deletions: 0 };
  for (const raw of diff.split('\n')) {
    // Skip unified-diff headers; they are noise in a mini-diff.
    if (raw.startsWith('+++') || raw.startsWith('---') || raw.startsWith('@@')) continue;
    if (raw === '') continue;
    if (lines.length >= MAX_PREVIEW_LINES) break;
    pushDiffLine(lines, counts, raw);
  }
  if (lines.length === 0) return undefined;
  return { filePath, additions: counts.additions, deletions: counts.deletions, lines };
}

/**
 * Best-effort EditPreview for a `file_change` / `patch_apply` item.
 *
 * NOTE: unverified — no file-change item appears in the recorded fixture. We
 * accept a handful of plausible field names and return undefined otherwise.
 */
function editFromItem(item: JsonObject): EditPreview | undefined {
  const changes = asArray(item.changes);
  const first = asObject(changes[0]) ?? item;
  const filePath =
    asString(first.path) ??
    asString(first.file_path) ??
    asString(item.path) ??
    asString(item.file_path) ??
    '';
  const diff =
    asString(first.diff) ??
    asString(first.unified_diff) ??
    asString(item.diff) ??
    asString(item.unified_diff);
  if (diff === undefined) return undefined;
  return previewFromUnifiedDiff(filePath, diff);
}

/* ------------------------------------------------------------------ */
/* parser                                                              */
/* ------------------------------------------------------------------ */

type Phase = 'started' | 'updated' | 'completed';

function usageFrom(usage: unknown): UsageTotals {
  const obj = asObject(usage) ?? {};
  return {
    inputTokens: numberOr(obj.input_tokens, 0),
    outputTokens: numberOr(obj.output_tokens, 0),
    cacheRead: numberOr(obj.cached_input_tokens, 0),
    cacheWrite: numberOr(obj.cache_write_input_tokens, 0),
  };
}

/** Display name for a generic (non-command) item type. */
function toolNameFor(item: JsonObject, itemType: string): string {
  switch (itemType) {
    case 'command_execution':
      return 'Bash';
    case 'file_change':
    case 'patch_apply':
      return 'ApplyPatch';
    case 'todo_list':
      return 'TodoList';
    case 'web_search':
      return 'WebSearch';
    case 'mcp_tool_call':
      return asString(item.tool) ?? asString(item.name) ?? 'McpToolCall';
    default:
      return itemType;
  }
}

/** Best-effort textual output for a completed generic item. */
function outputFor(item: JsonObject): string {
  return (
    asString(item.aggregated_output) ??
    asString(item.output) ??
    asString(item.result) ??
    asString(item.text) ??
    ''
  );
}

class CodexParser implements OutputParser {
  /** Item ids for which a `tool_use` has already been emitted. */
  private readonly openTools = new Set<string>();

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
      { type: 'error', message: `codex exited with code ${code ?? 'null'}` },
      { type: 'status', status: 'errored' },
    ];
  }

  private dispatch(obj: JsonObject, line: string, stream: 'stdout' | 'stderr'): AgentEvent[] {
    switch (obj.type) {
      case 'thread.started': {
        const id = asString(obj.thread_id);
        return id === undefined ? [{ type: 'raw', line, stream }] : [{ type: 'session_id', id }];
      }
      case 'turn.started':
        return [{ type: 'status', status: 'running' }];
      case 'turn.completed':
        return [
          { type: 'usage', usage: usageFrom(obj.usage) },
          { type: 'status', status: 'finished' },
        ];
      // NOTE: unverified — no failing turn appears in the recorded fixture.
      case 'turn.failed':
      case 'error': {
        const errorObj = asObject(obj.error);
        const message =
          asString(errorObj?.message) ??
          asString(obj.message) ??
          asString(obj.error) ??
          'Codex reported an error';
        return [
          { type: 'error', message },
          { type: 'status', status: 'errored' },
        ];
      }
      case 'item.started':
        return this.onItem(obj, 'started', line, stream);
      case 'item.updated':
        return this.onItem(obj, 'updated', line, stream);
      case 'item.completed':
        return this.onItem(obj, 'completed', line, stream);
      default:
        return [{ type: 'raw', line, stream }];
    }
  }

  private onItem(
    obj: JsonObject,
    phase: Phase,
    line: string,
    stream: 'stdout' | 'stderr',
  ): AgentEvent[] {
    const item = asObject(obj.item);
    const itemType = asString(item?.type);
    if (!item || itemType === undefined) return [{ type: 'raw', line, stream }];
    const id = asString(item.id) ?? '';

    switch (itemType) {
      case 'agent_message':
        return [
          {
            type: 'text',
            role: 'assistant',
            text: asString(item.text) ?? '',
            blockId: id,
            partial: phase !== 'completed',
          },
        ];

      // NOTE: unverified — no reasoning item appears in the recorded fixture.
      case 'reasoning':
        return [
          {
            type: 'thinking',
            text: asString(item.text) ?? asString(item.summary) ?? '',
            blockId: id,
            partial: phase !== 'completed',
          },
        ];

      case 'command_execution':
        return this.onCommandExecution(item, id, phase);

      // NOTE: unverified — no file-change item appears in the recorded fixture.
      case 'file_change':
      case 'patch_apply':
        return this.onGenericTool(item, id, itemType, phase, editFromItem(item));

      // NOTE: unverified — these item types do not appear in the recorded fixture.
      case 'todo_list':
      case 'web_search':
      case 'mcp_tool_call':
        return this.onGenericTool(item, id, itemType, phase, undefined);

      default:
        return [{ type: 'raw', line, stream }];
    }
  }

  private onCommandExecution(item: JsonObject, id: string, phase: Phase): AgentEvent[] {
    const events: AgentEvent[] = [];
    if (!this.openTools.has(id)) {
      this.openTools.add(id);
      events.push({
        type: 'tool_use',
        id,
        name: 'Bash',
        input: { command: asString(item.command) ?? '' },
      });
    }
    if (phase === 'completed') {
      this.openTools.delete(id);
      const exitCode = asNumber(item.exit_code);
      events.push({
        type: 'tool_result',
        toolUseId: id,
        output: asString(item.aggregated_output) ?? '',
        isError: exitCode !== undefined && exitCode !== 0,
      });
    }
    return events;
  }

  private onGenericTool(
    item: JsonObject,
    id: string,
    itemType: string,
    phase: Phase,
    edit: EditPreview | undefined,
  ): AgentEvent[] {
    const events: AgentEvent[] = [];
    if (!this.openTools.has(id)) {
      this.openTools.add(id);
      events.push({
        type: 'tool_use',
        id,
        name: toolNameFor(item, itemType),
        input: item,
        edit,
      });
    }
    if (phase === 'completed') {
      this.openTools.delete(id);
      events.push({
        type: 'tool_result',
        toolUseId: id,
        output: outputFor(item),
        isError: item.status === 'failed' || item.status === 'error',
        edit,
      });
    }
    return events;
  }
}

/* ------------------------------------------------------------------ */

export const codexProvider: ProviderDefinition = {
  id: 'codex',
  name: 'Codex',
  binary: 'codex',
  detectArgs: ['--version'],
  followUpMode: 'respawn',
  buildLaunch,
  buildResume,
  createParser: () => new CodexParser(),
};
