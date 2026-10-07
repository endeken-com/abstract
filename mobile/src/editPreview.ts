export type EditLine = {
  kind: ' ' | '+' | '-';
  text: string;
  old?: number;
  next?: number;
  startsHunk?: boolean;
};
export type EditPreview = { path: string; lines: EditLine[]; additions: number; deletions: number };

const maxLines = 200;
function splitLines(text: string): string[] {
  const lines = text.split('\n');
  if (lines.length > 1 && lines.at(-1) === '') lines.pop();
  return lines;
}
function preview(path: string, lines: EditLine[]): EditPreview {
  return {
    path,
    additions: lines.filter(line => line.kind === '+').length,
    deletions: lines.filter(line => line.kind === '-').length,
    lines: lines.slice(0, maxLines).map(line => ({ ...line, text: line.text.slice(0, 2_001) })),
  };
}
function lineDiff(before: string, after: string): EditLine[] {
  const old = splitLines(before), next = splitLines(after);
  let head = 0;
  while (head < old.length && head < next.length && old[head] === next[head]) head++;
  let tail = 0;
  while (tail < old.length - head && tail < next.length - head && old[old.length - 1 - tail] === next[next.length - 1 - tail]) tail++;
  const a = old.slice(head, old.length - tail), b = next.slice(head, next.length - tail);
  const lines: EditLine[] = old.slice(0, head).map(text => ({ kind: ' ', text: ` ${text}` }));
  if (a.length * b.length > 250_000) {
    lines.push(...a.map(text => ({ kind: '-' as const, text: `-${text}` })), ...b.map(text => ({ kind: '+' as const, text: `+${text}` })));
  } else {
    const lcs = Array.from({ length: a.length + 1 }, () => Array<number>(b.length + 1).fill(0));
    for (let i = a.length - 1; i >= 0; i--) for (let j = b.length - 1; j >= 0; j--)
      lcs[i][j] = a[i] === b[j] ? lcs[i + 1][j + 1] + 1 : Math.max(lcs[i + 1][j], lcs[i][j + 1]);
    let i = 0, j = 0;
    while (i < a.length || j < b.length) {
      if (i < a.length && j < b.length && a[i] === b[j]) lines.push({ kind: ' ', text: ` ${a[i++]}` }), j++;
      else if (j === b.length || (i < a.length && lcs[i + 1][j] >= lcs[i][j + 1])) lines.push({ kind: '-', text: `-${a[i++]}` });
      else lines.push({ kind: '+', text: `+${b[j++]}` });
    }
  }
  lines.push(...old.slice(old.length - tail).map(text => ({ kind: ' ' as const, text: ` ${text}` })));
  return lines;
}

export function editPreviewFromInput(name: string, input: any): EditPreview[] {
  if (!input || typeof input !== 'object') return [];
  const path = String(input.file_path || input.path || '');
  const key = name.toLowerCase();
  if (key === 'edit' && typeof input.old_string === 'string' && typeof input.new_string === 'string')
    return [preview(path, lineDiff(input.old_string, input.new_string))];
  if (key === 'multiedit' && Array.isArray(input.edits)) {
    const lines: EditLine[] = [];
    input.edits.forEach((edit: any) => {
      if (typeof edit.old_string !== 'string' || typeof edit.new_string !== 'string') return;
      const part = lineDiff(edit.old_string, edit.new_string);
      if (part.length && lines.length) part[0].startsHunk = true;
      lines.push(...part);
    });
    return lines.length ? [preview(path, lines)] : [];
  }
  if (key === 'write' && typeof input.content === 'string')
    return [preview(path, splitLines(input.content).map((text, index) => ({ kind: '+', text: `+${text}`, next: index + 1 })))];
  return [];
}

export function editPreviewFromResult(result: any, fallbackPath = ''): EditPreview[] {
  if (!result || typeof result !== 'object') return [];
  const path = String(result.filePath || result.file_path || fallbackPath);
  if (Array.isArray(result.structuredPatch)) {
    const lines: EditLine[] = [];
    for (const hunk of result.structuredPatch) {
      let old = typeof hunk?.oldStart === 'number' ? hunk.oldStart : undefined;
      let next = typeof hunk?.newStart === 'number' ? hunk.newStart : undefined;
      let first = lines.length > 0;
      for (const text of hunk?.lines || []) {
        if (typeof text !== 'string' || ![' ', '+', '-'].includes(text[0])) continue;
        const kind = text[0] as EditLine['kind'];
        lines.push({ kind, text, old: kind === '+' ? undefined : old, next: kind === '-' ? undefined : next, startsHunk: first });
        first = false;
        if (kind !== '+') old = old === undefined ? undefined : old + 1;
        if (kind !== '-') next = next === undefined ? undefined : next + 1;
      }
    }
    return lines.length ? [preview(path, lines)] : [];
  }
  if (result.type === 'create' && typeof result.content === 'string')
    return [preview(path, splitLines(result.content).map((text, index) => ({ kind: '+', text: `+${text}`, next: index + 1 })))];
  return [];
}

export function editPreviewsFromChanges(changes: any[]): EditPreview[] {
  return changes.flatMap(change => {
    const patch = change?.diff || change?.unified_diff;
    if (typeof patch !== 'string') return [];
    const lines: EditLine[] = [];
    let old: number | undefined, next: number | undefined;
    let first = false;
    for (const text of patch.split('\n')) {
      const hunk = text.match(/^@@ -(\d+)(?:,\d+)? \+(\d+)/);
      if (hunk) { old = Number(hunk[1]); next = Number(hunk[2]); first = lines.length > 0; continue; }
      if (text.startsWith('+++') || text.startsWith('---') || ![' ', '+', '-'].includes(text[0])) continue;
      const kind = text[0] as EditLine['kind'];
      lines.push({ kind, text, old: kind === '+' ? undefined : old, next: kind === '-' ? undefined : next, startsHunk: first });
      first = false;
      if (kind !== '+') old = old === undefined ? undefined : old + 1;
      if (kind !== '-') next = next === undefined ? undefined : next + 1;
    }
    return lines.length ? [preview(String(change?.path || ''), lines)] : [];
  });
}
