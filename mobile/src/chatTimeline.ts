import type { RemoteLine } from './types';
import { toolTarget, toolVerb } from './toolPresentation';
import { editPreviewFromInput, editPreviewFromResult, editPreviewsFromChanges, type EditPreview } from './editPreview';

export type TurnEnding = 'done' | 'stopped' | 'failed';

export type ChatItem = {
  id: string;
  kind: 'prose' | 'thinking' | 'turn' | 'tool' | 'user' | 'error';
  text: string;
  detail?: string;
  toolName?: string;
  target?: string;
  path?: string;
  pending?: boolean;
  failed?: boolean;
  /** A turn's length: measured from the log's times, else the agent's own count. */
  durationMs?: number;
  ending?: TurnEnding;
  /** What the agent says the turn did (Claude's turn summary). */
  summary?: string;
  /** Swift reference-date seconds, as the Mac logs them. */
  startedAt?: number;
  endedAt?: number;
  measuredMs?: number;
  reportedMs?: number;
  /** On the newest turn line of an idle chat: all its turns added up. */
  totalMs?: number;
  additions?: number;
  deletions?: number;
  edits?: EditPreview[];
};

function editCounts(value: any): { additions: number; deletions: number } | undefined {
  if (!value || typeof value !== 'object') return;
  if (Array.isArray(value.structuredPatch) && value.structuredPatch.length) {
    const lines = value.structuredPatch.flatMap((hunk: any) => Array.isArray(hunk?.lines) ? hunk.lines : []).filter((line: unknown): line is string => typeof line === 'string');
    return { additions: lines.filter((line: string) => line.startsWith('+')).length,
      deletions: lines.filter((line: string) => line.startsWith('-')).length };
  }
  if (value.type === 'create' && typeof value.content === 'string') {
    const lines = value.content.split('\n');
    if (lines.at(-1) === '') lines.pop();
    return { additions: lines.length, deletions: 0 };
  }
  const changeDiffs = (Array.isArray(value.changes) ? value.changes : []).map((change: any) => change.diff || change.unified_diff).filter((diff: unknown): diff is string => typeof diff === 'string');
  const diffs = changeDiffs.length ? changeDiffs : [value.diff || value.unified_diff].filter((diff: unknown): diff is string => typeof diff === 'string');
  if (!diffs.length) return;
  let additions = 0, deletions = 0;
  for (const diff of diffs) for (const line of diff.split('\n')) {
    if (line.startsWith('+++') || line.startsWith('---')) continue;
    if (line.startsWith('+')) additions++;
    if (line.startsWith('-')) deletions++;
  }
  return { additions, deletions };
}

type Block = { type: string; id?: string; name?: string; input: string; row?: ChatItem };
/**
 * The turn under way, as the Mac's Timeline follows it: from your message (or
 * the agent's first step in a turn it takes on its own) to the agent's turn
 * end, a stop or a failure, or your next message.
 */
type TurnState = {
  active: boolean;
  startedAt?: number;
  lastAt?: number;
  /** The agent did something in it, beyond your message arriving. */
  worked: boolean;
  /** Its line, once the agent reported an end or its usage. */
  row?: ChatItem;
  /** Claude noted the turn was stopped; its result follows. */
  interrupted: boolean;
};
type TimelineCache = {
  lines: RemoteLine[];
  turn: TurnState;
  rows: ChatItem[];
  tools: Map<string, ChatItem>;
  codexItems: Map<string, ChatItem>;
  blocks: Map<number, Block>;
};
const caches = new Map<string, TimelineCache>();

/** "2m 14s", as the Mac writes lengths. */
export function duration(ms: number) {
  const seconds = Math.max(0, Math.floor(ms / 1000));
  if (seconds < 60) return `${seconds}s`;
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return seconds % 60 ? `${minutes}m ${seconds % 60}s` : `${minutes}m`;
  return `${Math.floor(minutes / 60)}h ${minutes % 60}m`;
}

/** "2m 14s", "Did the thing · Done in 2m 14s", "Stopped after 1m 12s", "Failed after 40s"; "—" when the log doesn't say. */
export function turnLabel(row: ChatItem) {
  const length = row.durationMs == null ? undefined : duration(row.durationMs);
  const label = row.ending === 'stopped' ? (length ? `Stopped after ${length}` : 'Stopped')
    : row.ending === 'failed' ? (length ? `Failed after ${length}` : 'Failed')
    : row.summary ? [row.summary, length && `Done in ${length}`].filter(Boolean).join(' · ')
    : length ?? '—';
  return row.totalMs == null ? label : `${label} · ${duration(row.totalMs)} in total`;
}

/** A Claude result for a turn you stopped: it reports itself as an error, but isn't one. */
const stopped = (value: any) => typeof value.terminal_reason === 'string' && value.terminal_reason.startsWith('aborted');

/**
 * Rebuild semantic transcript rows from provider wire events. `status` is the
 * chat's: once it's no longer working, a turn whose end never reached the log
 * still gets its line, and the newest line adds the chat's total.
 */
export function chatTimeline(lines: RemoteLine[], cacheKey = 'default', status?: string): ChatItem[] {
  const previous = caches.get(cacheKey);
  const continues = previous && lines.length >= previous.lines.length
    && (previous.lines.length === 0 || lines[previous.lines.length - 1] === previous.lines[previous.lines.length - 1]);
  const state: TimelineCache = continues ? previous : {
    lines: [], turn: { active: false, worked: false, interrupted: false }, rows: [], tools: new Map(), codexItems: new Map(), blocks: new Map(),
  };
  const { rows, tools, codexItems, blocks, turn } = state;
  const begin = (at?: number) => Object.assign(turn, { active: true, startedAt: at, lastAt: at, worked: false, row: undefined });
  const step = (at?: number) => {
    if (!turn.active) begin(at);
    turn.worked = true;
    if (at != null) turn.lastAt = at;
  };
  /** The agent reported the turn's end or usage. With nothing before it, its start isn't known. */
  const report = (id: string, at?: number) => {
    if (!turn.active) begin(undefined);
    if (at != null) turn.lastAt = at;
    return turn.row ??= { id: `turn-${id}`, kind: 'turn', text: '', ending: 'done' };
  };
  const finished = (row: ChatItem): ChatItem => {
    const measuredMs = turn.startedAt != null && turn.lastAt != null && turn.lastAt >= turn.startedAt
      ? Math.round((turn.lastAt - turn.startedAt) * 1000) : undefined;
    return { ...row, startedAt: turn.startedAt, endedAt: turn.lastAt, measuredMs, durationMs: measuredMs ?? row.reportedMs };
  };
  /** Ends the turn under way. One that ended without a word from the agent still gets a line when its length is known. */
  const close = (id: string, implicitly: boolean, ending?: TurnEnding) => {
    if (!turn.active) return;
    if (ending && ending !== 'done') report(id).ending = ending;
    if (turn.row) rows.push(finished(turn.row));
    else if (turn.worked) {
      const line = finished({ id: `turn-${id}`, kind: 'turn', text: '', ending: 'done' });
      if (!implicitly || line.measuredMs != null) rows.push(line);
    }
    Object.assign(turn, { active: false, worked: false, row: undefined });
  };
  const readTurnEnd = (value: any, id: string, at?: number) => {
    if (value.type === 'system' && value.subtype === 'post_turn_summary') {
      const row = report(id, at);
      if (value.status_detail) row.summary = value.status_detail;
    } else if (value.type === 'result') {
      const ending: TurnEnding = turn.interrupted || stopped(value) ? 'stopped' : value.is_error ? 'failed' : 'done';
      turn.interrupted = false;
      const row = report(id, at);
      if (typeof value.duration_ms === 'number') row.reportedMs = value.duration_ms;
      close(id, false, ending);
    } else if (value.type === 'turn.completed') {
      report(id, at);
      close(id, false);
    } else if (value.type === 'turn.failed' || (value.type === 'error' && value.sessionID)) {
      // Codex's own `error` is a warning it carries on past; OpenCode's ends the turn.
      if (turn.active && at != null) turn.lastAt = at;
      close(id, false, 'failed');
    } else if (value.type === 'step_finish') {
      // OpenCode reports each step; they add up into one line for the turn.
      report(id, at);
    }
  };
  const append = (kind: ChatItem['kind'], text: string, id: string) => {
    if (text.trim()) rows.push({ id, kind, text });
  };
  const addTool = (id: string, name: string, input: any, pending: boolean): ChatItem => {
    const target = toolTarget(name, input);
    const edits = editPreviewFromInput(name, input);
    const row: ChatItem = { id, kind: 'tool', text: toolVerb(name, pending), toolName: name, target: target.text, path: target.path, pending, edits };
    if (edits.length) {
      row.additions = edits.reduce((total, edit) => total + edit.additions, 0);
      row.deletions = edits.reduce((total, edit) => total + edit.deletions, 0);
    }
    rows.push(row);
    return row;
  };
  /** One parsed line's rows. */
  const read = (value: any, id: string) => {
    // Codex item IDs are scoped to a turn. Reusing a map across turns makes
    // later messages and commands overwrite rows from earlier turns.
    if (value.type === 'turn.started') codexItems.clear();
    if (value.type === 'stream_event') {
      const event = value.event || {};
      const index = Number(event.index ?? 0);
      if (event.type === 'message_start') blocks.clear();
      if (event.type === 'content_block_start') {
        const content = event.content_block || {};
        const block = { type: content.type || '', id: content.id, name: content.name, input: '', row: undefined as ChatItem | undefined };
        if (content.type === 'text' || content.type === 'thinking') {
          block.row = { id, kind: content.type === 'thinking' ? 'thinking' : 'prose', text: content.text || content.thinking || '', pending: true };
          rows.push(block.row);
        }
        blocks.set(index, block);
      } else if (event.type === 'content_block_delta') {
        const block = blocks.get(index);
        if (block?.row && (event.delta?.type === 'text_delta' || event.delta?.type === 'thinking_delta'))
          block.row.text += event.delta.text || event.delta.thinking || '';
        if (block && event.delta?.type === 'input_json_delta') block.input += event.delta.partial_json || '';
      } else if (event.type === 'content_block_stop') {
        const block = blocks.get(index);
        if (block?.type === 'tool_use') {
          let input: any = {};
          try { input = JSON.parse(block.input || '{}'); } catch { /* incomplete tool input */ }
          const row = addTool(id, block.name || 'Tool', input, true);
          if (block.id) tools.set(block.id, row);
        }
        if (block?.row) block.row.pending = false;
      }
      return;
    }
    if (value.type === 'assistant') {
      // Reconcile completed content by block index. A partial stream must not
      // hide a completed tool or text block.
      (value.message?.content || []).forEach((content: any, index: number) => {
        const block = blocks.get(index);
        if (content.type === 'text' || content.type === 'thinking') {
          const kind = content.type === 'thinking' ? 'thinking' : 'prose';
          if (block?.row?.kind === kind) { block.row.text = content.text || content.thinking || block.row.text; block.row.pending = false; }
          else append(kind, content.text || content.thinking || '', `${id}-${index}`);
        }
        if (content.type === 'tool_use' && !tools.has(content.id)) {
          const row = addTool(`${id}-${content.id || index}`, content.name || 'Tool', content.input || {}, true);
          if (content.id) tools.set(content.id, row);
        }
      });
      blocks.clear();
      return;
    }
    if (value.type === 'user' && value.message?.content?.some?.((x: any) => x.type === 'tool_result')) {
      for (const content of value.message.content) if (content.type === 'tool_result') {
        const row = tools.get(content.tool_use_id);
        if (row) {
          row.detail = typeof content.content === 'string' ? content.content : JSON.stringify(content.content);
          row.pending = false;
          row.failed = !!content.is_error;
          row.text = toolVerb(row.toolName || 'Tool');
          Object.assign(row, editCounts(value.tool_use_result));
          const edits = editPreviewFromResult(value.tool_use_result, row.path);
          if (edits.length) row.edits = edits;
        }
      }
      return;
    }
    if (value.type === 'user') {
      const content = value.message?.content;
      // The CLI's note that the turn was stopped, which its result shows.
      if (Array.isArray(content) && content.some((x: any) => typeof x.text === 'string' && x.text.startsWith('[Request interrupted by user'))) {
        state.turn.interrupted = true;
        return;
      }
      append('user', typeof content === 'string' ? content : Array.isArray(content) ? content.filter((x: any) => x.type === 'text').map((x: any) => x.text).join('\n') : '', id);
      return;
    }
    if (['item.started', 'item.updated', 'item.completed'].includes(value.type)) {
      const item = value.item || {};
      const itemId = String(item.id || id);
      if (item.type === 'agent_message' || item.type === 'reasoning') {
        const kind = item.type === 'reasoning' ? 'thinking' : 'prose';
        const text = item.text || item.summary || '';
        let row = codexItems.get(itemId);
        if (!row) { row = { id, kind, text, pending: value.type !== 'item.completed' }; rows.push(row); codexItems.set(itemId, row); }
        else { row.text = text || row.text; row.pending = value.type !== 'item.completed'; }
      } else if (['command_execution', 'file_change', 'patch_apply', 'mcp_tool_call', 'web_search', 'todo_list'].includes(item.type)) {
        const name = item.type === 'mcp_tool_call' ? item.tool || item.name || 'mcp__tool' : item.type;
        let row = codexItems.get(itemId);
        if (!row) { row = addTool(id, name, item, value.type !== 'item.completed'); codexItems.set(itemId, row); }
        if (value.type === 'item.completed') {
          row.pending = false;
          row.text = toolVerb(name);
          const detail = item.aggregated_output || item.result || item.error || item.changes?.map((change: any) => change.diff).filter(Boolean).join('\n') || '';
          row.detail = typeof detail === 'string' ? detail : JSON.stringify(detail, null, 2);
          row.failed = item.status === 'failed' || (typeof item.exit_code === 'number' && item.exit_code !== 0);
          Object.assign(row, editCounts(item));
          const edits = editPreviewsFromChanges(Array.isArray(item.changes) ? item.changes : []);
          if (edits.length) row.edits = edits;
        }
      }
      return;
    }
    if (value.type === 'reasoning') append('thinking', value.part?.text || value.text || '', id);
    if (value.type === 'text') append('prose', value.part?.text || value.text || '', id);
    if (value.type === 'agent_message') append('prose', value.text || '', id);
    if (value.type === 'result' && value.is_error && !turn.interrupted && !stopped(value)) append('error', value.result || value.subtype || 'Agent reported an error', id);
    if (value.type === 'error' || value.type === 'turn.failed') append('error', value.message || value.error?.message || value.error || 'Agent error', id);
  };
  for (let position = continues ? previous.lines.length : 0; position < lines.length; position++) {
    const record = lines[position];
    const at = record.line.at;
    const id = String(record.seq);
    if (record.line.stream === 'user') {
      // Your message starts a turn; one logged twice before the agent answers is still one.
      if (!turn.active || turn.worked || turn.row) { close(id, true); begin(at); }
      append('user', record.line.line, id);
      continue;
    }
    if (record.line.stream === 'handoff') { close(id, true); continue; }
    let value: any;
    try { value = JSON.parse(record.line.line); } catch { continue; }
    const before = rows.length;
    read(value, id);
    const added = rows.slice(before);
    if (added.some(row => row.kind === 'prose' || row.kind === 'thinking' || row.kind === 'tool')) step(at);
    else if (turn.active) { if (added.length) turn.worked = true; if (at != null) turn.lastAt = at; }
    readTurnEnd(value, id, at);
  }
  state.lines = lines.slice();
  caches.delete(cacheKey);
  caches.set(cacheKey, state);
  if (caches.size > 8) caches.delete(caches.keys().next().value!);
  // New row objects keep VirtualizedList's change tracking sound when a live
  // event completes a previously visible message or command.
  const out = rows.filter(row => row.kind === 'tool' || row.kind === 'turn' || row.text.trim()).map(row => ({ ...row }));
  const idle = !!status && !['created', 'provisioning', 'running', 'waiting_input'].includes(status);
  if (turn.active) {
    // A turn still under way that has a line already (OpenCode's steps), or
    // one that ended without its end reaching the log.
    const ending: TurnEnding | undefined = idle && status === 'errored' ? 'failed' : undefined;
    if (turn.row) out.push(finished({ ...turn.row, ending: ending ?? turn.row.ending }));
    else if (idle && turn.worked) {
      const line = finished({ id: `turn-${lines.at(-1)?.seq ?? 0}`, kind: 'turn', text: '', ending: ending ?? 'done' });
      if (line.measuredMs != null) out.push(line);
    }
  }
  const turnRows = out.filter(row => row.kind === 'turn');
  if (idle && turnRows.length > 1) turnRows[turnRows.length - 1].totalMs = turnRows.reduce((total, row) => total + (row.durationMs ?? 0), 0);
  return out;
}
