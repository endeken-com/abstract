import { useMemo, useRef } from 'react';
import { useVirtualizer } from '@tanstack/react-virtual';
import type { FileDiff } from '../../lib/types';
import { Counts } from './ui';
import { STATUS_GLYPH, STATUS_LABEL, baseOf, buildRows, statusColor } from './lib';

const DIR_ROW = 30;
const FILE_ROW = 46;

export function FileList({
  files,
  selectedPath,
  onSelect,
}: {
  files: FileDiff[];
  selectedPath: string | null;
  onSelect: (path: string) => void;
}): React.JSX.Element {
  const rows = useMemo(() => buildRows(files), [files]);
  const scrollRef = useRef<HTMLDivElement | null>(null);

  const virtualizer = useVirtualizer({
    count: rows.length,
    getScrollElement: () => scrollRef.current,
    estimateSize: (i) => (rows[i]?.kind === 'dir' ? DIR_ROW : FILE_ROW),
    overscan: 12,
    getItemKey: (i) => rows[i]?.key ?? i,
  });

  return (
    <div ref={scrollRef} className="flex-1 overflow-y-auto overflow-x-hidden">
      <div className="relative w-full" style={{ height: virtualizer.getTotalSize() }}>
        {virtualizer.getVirtualItems().map((item) => {
          const row = rows[item.index];
          if (!row) return null;
          return (
            <div
              key={item.key}
              className="absolute left-0 top-0 w-full"
              style={{ height: item.size, transform: `translateY(${item.start}px)` }}
            >
              {row.kind === 'dir' ? (
                <DirHeader dir={row.dir} count={row.count} />
              ) : (
                <FileRow
                  file={row.file}
                  selected={row.file.path === selectedPath}
                  onSelect={onSelect}
                />
              )}
            </div>
          );
        })}
      </div>
    </div>
  );
}

function DirHeader({ dir, count }: { dir: string; count: number }): React.JSX.Element {
  return (
    <div
      className="h-full flex items-center gap-2 px-3 font-mono text-xs truncate"
      style={{
        color: 'var(--bt-text-faint)',
        background: 'var(--bt-surface)',
        borderBottom: '1px solid var(--bt-border)',
      }}
      title={dir || 'repository root'}
    >
      <span className="truncate">{dir || './'}</span>
      <span className="tabular-nums">({count})</span>
    </div>
  );
}

function FileRow({
  file,
  selected,
  onSelect,
}: {
  file: FileDiff;
  selected: boolean;
  onSelect: (path: string) => void;
}): React.JSX.Element {
  return (
    <button
      type="button"
      onClick={() => onSelect(file.path)}
      aria-current={selected}
      className="h-full w-full flex items-center gap-3 pl-3 pr-3 text-left"
      style={{
        background: selected ? 'var(--bt-surface-3)' : 'transparent',
        borderLeft: `2px solid ${selected ? 'var(--bt-accent)' : 'transparent'}`,
      }}
      title={`${STATUS_LABEL[file.status]} — ${file.path}`}
    >
      <span
        className="font-mono text-xs w-3 shrink-0"
        style={{ color: statusColor(file.status) }}
        aria-label={STATUS_LABEL[file.status]}
      >
        {STATUS_GLYPH[file.status]}
      </span>
      <span className="flex-1 min-w-0 flex flex-col">
        <span
          className="font-mono text-sm truncate"
          style={{ color: selected ? 'var(--bt-accent)' : 'var(--bt-text)' }}
        >
          {baseOf(file.path)}
        </span>
        {file.status === 'renamed' && file.old_path ? (
          <span className="font-mono text-xs truncate" style={{ color: 'var(--bt-text-faint)' }}>
            was {file.old_path}
          </span>
        ) : file.binary ? (
          <span className="text-xs" style={{ color: 'var(--bt-text-faint)' }}>
            binary
          </span>
        ) : null}
      </span>
      <Counts additions={file.additions} deletions={file.deletions} className="text-xs" />
    </button>
  );
}
