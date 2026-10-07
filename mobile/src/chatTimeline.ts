import type { RemoteLine } from './types';
import { toolTarget, toolVerb } from './toolPresentation';
import { editPreviewFromInput, editPreviewFromResult, editPreviewsFromChanges, type EditPreview } from './editPreview';

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
  durationMs?: number;
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
type TimelineCache = {
  lines: RemoteLine[];
  rows: ChatItem[];
  tools: Map<string, ChatItem>;
  codexItems: Map<string, ChatItem>;
  blocks: Map<number, Block>;
};
const caches = new Map<string, TimelineCache>();

/** Rebuild semantic transcript rows from provider wire events. */
export function chatTimeline(lines: RemoteLine[], cacheKey = 'default'): ChatItem[] {
  const previous = caches.get(cacheKey);
  const continues = previous && lines.length >= previous.lines.length
    && (previous.lines.length === 0 || lines[previous.lines.length - 1] === previous.lines[previous.lines.length - 1]);
  const state: TimelineCache = continues ? previous : {
    lines: [], rows: [], tools: new Map(), codexItems: new Map(), blocks: new Map(),
  };
  const { rows, tools, codexItems, blocks } = state;
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
  for (let position = continues ? previous.lines.length : 0; position < lines.length; position++) {
    const record = lines[position];
    if (record.line.stream === 'user') {
      append('user', record.line.line, String(record.seq));
      continue;
    }
    let value: any;
    try { value = JSON.parse(record.line.line); } catch { continue; }
    const id = String(record.seq);
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
      continue;
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
      continue;
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
      continue;
    }
    if (value.type === 'user') {
      const content = value.message?.content;
      append('user', typeof content === 'string' ? content : Array.isArray(content) ? content.filter((x: any) => x.type === 'text').map((x: any) => x.text).join('\n') : '', id);
      continue;
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
      continue;
    }
    if (value.type === 'reasoning') append('thinking', value.part?.text || value.text || '', id);
    if (value.type === 'text') append('prose', value.part?.text || value.text || '', id);
    if (value.type === 'agent_message') append('prose', value.text || '', id);
    if (value.type === 'result' && !value.is_error && typeof value.duration_ms === 'number')
      rows.push({ id, kind: 'turn', text: '', durationMs: value.duration_ms });
    if (value.type === 'error' || value.type === 'turn.failed') append('error', value.message || value.error?.message || value.error || 'Agent error', id);
  }
  state.lines = lines.slice();
  caches.delete(cacheKey);
  caches.set(cacheKey, state);
  if (caches.size > 8) caches.delete(caches.keys().next().value!);
  // New row objects keep VirtualizedList's change tracking sound when a live
  // event completes a previously visible message or command.
  return rows.filter(row => row.kind === 'tool' || row.kind === 'turn' || row.text.trim()).map(row => ({ ...row }));
}
