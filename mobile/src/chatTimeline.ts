import type { RemoteLine } from './types';
import { toolTarget, toolVerb } from './toolPresentation';
import { editPreviewFromInput, type EditPreview } from './editPreview';

export type ChatItem = {
  id: string;
  kind: 'prose' | 'thinking' | 'turn' | 'tool' | 'user' | 'error';
  text: string;
  detail?: string;
  toolName?: string;
  toolInput?: any;
  target?: string;
  path?: string;
  pending?: boolean;
  failed?: boolean;
  durationMs?: number;
  additions?: number;
  deletions?: number;
  edits?: EditPreview[];
};

type TimelineCache = {
  lines: RemoteLine[];
  rows: ChatItem[];
  tools: Map<string, ChatItem>;
  textBlocks: Map<string, ChatItem>;
  thinkingBlocks: Map<string, ChatItem>;
};
const caches = new Map<string, TimelineCache>();

// EditPreview is Codable on the Mac; the phone's view uses shorter field names.
function hostEdit(value: any): EditPreview | null {
  if (!value || typeof value !== 'object' || typeof value.filePath !== 'string') return null;
  return {
    path: value.filePath,
    additions: Number(value.additions) || 0,
    deletions: Number(value.deletions) || 0,
    lines: (Array.isArray(value.lines) ? value.lines : []).map((line: any) => ({
      kind: line.origin === '+' || line.origin === '-' ? line.origin : ' ',
      text: String(line.origin || ' ') + String(line.content || ''),
      old: typeof line.oldLine === 'number' ? line.oldLine : undefined,
      next: typeof line.newLine === 'number' ? line.newLine : undefined,
      startsHunk: line.startsHunk === true,
    })),
  };
}

function setEdits(row: ChatItem, edits: EditPreview[]) {
  if (!edits.length) return;
  row.edits = edits;
  row.additions = edits.reduce((total, edit) => total + edit.additions, 0);
  row.deletions = edits.reduce((total, edit) => total + edit.deletions, 0);
}

/** Render the host's normalized agent events, regardless of the agent plugin. */
export function chatTimeline(lines: RemoteLine[], cacheKey = 'default'): ChatItem[] {
  const previous = caches.get(cacheKey);
  const continues = previous && lines.length >= previous.lines.length
    && (previous.lines.length === 0 || lines[previous.lines.length - 1] === previous.lines[previous.lines.length - 1]);
  const state: TimelineCache = continues ? previous : {
    lines: [], rows: [], tools: new Map(), textBlocks: new Map(), thinkingBlocks: new Map(),
  };
  const { rows, tools, textBlocks, thinkingBlocks } = state;
  for (let position = continues ? previous.lines.length : 0; position < lines.length; position++) {
    const record = lines[position];
    for (const [index, event] of (record.events || []).entries()) {
      const id = String(record.seq) + ':' + index;
      if (event.type === 'text' || event.type === 'thinking') {
        const role = event.role === 'user' ? 'user' : event.type === 'thinking' ? 'thinking' : 'prose';
        const blocks = event.type === 'thinking' ? thinkingBlocks : textBlocks;
        const blockId = typeof event.blockId === 'string' ? event.blockId : null;
        const old = blockId ? blocks.get(blockId) : undefined;
        if (old) {
          old.text = event.partial ? old.text + String(event.text || '') : String(event.text || '');
          old.pending = event.partial === true;
        } else {
          const row: ChatItem = { id, kind: role, text: String(event.text || ''), pending: event.partial === true };
          rows.push(row);
          if (blockId) blocks.set(blockId, row);
        }
        continue;
      }
      if (event.type === 'toolUse') {
        const name = String(event.name || 'Tool');
        const input = event.input || {};
        let row = tools.get(String(event.id));
        if (!row) {
          row = { id, kind: 'tool', text: toolVerb(name, true), toolName: name, pending: true };
          rows.push(row);
          tools.set(String(event.id), row);
        }
        row.toolName = name;
        row.toolInput = input;
        const target = toolTarget(name, input);
        row.target = target.text;
        row.path = target.path;
        const edit = hostEdit(event.edit);
        setEdits(row, edit ? [edit] : editPreviewFromInput(name, input));
        continue;
      }
      if (event.type === 'toolResult') {
        const row = tools.get(String(event.toolUseId));
        if (!row) continue;
        row.pending = false;
        row.failed = event.isError === true;
        row.text = toolVerb(row.toolName || 'Tool');
        row.detail = String(event.output || '');
        const edit = hostEdit(event.edit);
        if (edit) setEdits(row, [edit]);
        continue;
      }
      if (event.type === 'toolFileChanges') {
        const row = tools.get(String(event.toolUseId));
        if (row) setEdits(row, (event.changes?.previews || []).map(hostEdit).filter((edit: EditPreview | null): edit is EditPreview => !!edit));
        continue;
      }
      if (event.type === 'turnEnd' && typeof event.durationMs === 'number') {
        rows.push({ id, kind: 'turn', text: '', durationMs: event.durationMs });
        continue;
      }
      if (event.type === 'error' && typeof event.message === 'string') {
        rows.push({ id, kind: 'error', text: event.message });
      }
    }
  }
  state.lines = lines.slice();
  caches.delete(cacheKey);
  caches.set(cacheKey, state);
  if (caches.size > 8) caches.delete(caches.keys().next().value!);
  // New objects let VirtualizedList redraw rows completed by a later event.
  return rows.filter(row => row.kind === 'tool' || row.kind === 'turn' || row.text.trim()).map(row => ({ ...row }));
}
