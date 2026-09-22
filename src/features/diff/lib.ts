import type { FileDiff } from '../../lib/types';

/** Tauri rejects with the serialized Rust error, which is a plain string. */
export function errText(e: unknown): string {
  if (typeof e === 'string') return e;
  if (e instanceof Error) return e.message;
  if (e && typeof e === 'object') {
    const msg = (e as { message?: unknown }).message;
    if (typeof msg === 'string') return msg;
    try {
      return JSON.stringify(e);
    } catch {
      return String(e);
    }
  }
  return String(e);
}

export function dirOf(path: string): string {
  const i = path.lastIndexOf('/');
  return i < 0 ? '' : path.slice(0, i);
}

export function baseOf(path: string): string {
  const i = path.lastIndexOf('/');
  return i < 0 ? path : path.slice(i + 1);
}

export type FileRow =
  | { kind: 'dir'; key: string; dir: string; count: number }
  | { kind: 'file'; key: string; file: FileDiff };

/**
 * Flattened, directory-grouped rows: one header per directory followed by its
 * files. Flat so the virtualizer only has to think about a single list.
 */
export function buildRows(files: FileDiff[]): FileRow[] {
  const groups = new Map<string, FileDiff[]>();
  for (const f of files) {
    const dir = dirOf(f.path);
    const bucket = groups.get(dir);
    if (bucket) bucket.push(f);
    else groups.set(dir, [f]);
  }
  const dirs = [...groups.keys()].sort((a, b) => a.localeCompare(b));
  const rows: FileRow[] = [];
  for (const dir of dirs) {
    const bucket = [...(groups.get(dir) ?? [])].sort((a, b) => a.path.localeCompare(b.path));
    rows.push({ kind: 'dir', key: `dir:${dir}`, dir, count: bucket.length });
    for (const file of bucket) rows.push({ kind: 'file', key: `file:${file.path}`, file });
  }
  return rows;
}

export function totals(files: FileDiff[]): { additions: number; deletions: number } {
  return files.reduce(
    (acc, f) => ({ additions: acc.additions + f.additions, deletions: acc.deletions + f.deletions }),
    { additions: 0, deletions: 0 },
  );
}

export const STATUS_LABEL: Record<FileDiff['status'], string> = {
  added: 'added',
  modified: 'modified',
  deleted: 'deleted',
  renamed: 'renamed',
};

export const STATUS_GLYPH: Record<FileDiff['status'], string> = {
  added: 'A',
  modified: 'M',
  deleted: 'D',
  renamed: 'R',
};

export function statusColor(status: FileDiff['status']): string {
  if (status === 'added') return 'var(--bt-added)';
  if (status === 'deleted') return 'var(--bt-removed)';
  return 'var(--bt-text-dim)';
}

/** The code font size the rest of the app uses, for Monaco. */
export function codeFontSize(): number {
  const raw = getComputedStyle(document.documentElement).getPropertyValue('--bt-code-size');
  const n = Number.parseFloat(raw);
  return Number.isFinite(n) && n > 0 ? n : 13;
}

export const MONO_FONT = '"JetBrains Mono Variable", ui-monospace, monospace';
