import type { FileDiff } from '../../lib/types';
import { Btn, Counts } from './ui';

/**
 * Hunk-level accept/reject. `[hunk.index]` is what the backend matches on, and
 * those indexes are only valid for the collect that produced them — every
 * action re-collects before anything else can be clicked.
 */
export function HunkList({
  file,
  busy,
  onAccept,
  onReject,
}: {
  file: FileDiff;
  busy: boolean;
  onAccept: (hunkIndex: number) => void;
  onReject: (hunkIndex: number) => void;
}): React.JSX.Element {
  if (file.binary) {
    return (
      <Shell>
        <p className="px-4 py-3 text-sm m-0" style={{ color: 'var(--bt-text-faint)' }}>
          Binary file — accept or reject it as a whole.
        </p>
      </Shell>
    );
  }
  if (file.hunks.length === 0) {
    return (
      <Shell>
        <p className="px-4 py-3 text-sm m-0" style={{ color: 'var(--bt-text-faint)' }}>
          No hunks reported for this file.
        </p>
      </Shell>
    );
  }

  return (
    <Shell>
      <div className="flex flex-col">
        {file.hunks.map((hunk) => (
          <div
            key={hunk.index}
            className="flex items-center gap-4 px-4 py-2.5"
            style={{ borderTop: '1px solid var(--bt-border)' }}
          >
            <span
              className="font-mono text-xs truncate flex-1"
              style={{ color: 'var(--bt-text-dim)' }}
              title={hunk.header}
            >
              {hunk.header}
            </span>
            <Counts additions={hunk.additions} deletions={hunk.deletions} className="text-xs" />
            <div className="flex gap-2 shrink-0">
              <Btn tone="accept" disabled={busy} onClick={() => onAccept(hunk.index)}>
                Accept
              </Btn>
              <Btn tone="reject" disabled={busy} onClick={() => onReject(hunk.index)}>
                Reject
              </Btn>
            </div>
          </div>
        ))}
      </div>
    </Shell>
  );
}

function Shell({ children }: { children: React.ReactNode }): React.JSX.Element {
  return (
    <div
      className="shrink-0 max-h-56 overflow-y-auto"
      style={{ background: 'var(--bt-surface)', borderTop: '1px solid var(--bt-border-strong)' }}
    >
      <div
        className="sticky top-0 px-4 py-2 text-xs uppercase tracking-wider"
        style={{ background: 'var(--bt-surface)', color: 'var(--bt-text-faint)' }}
      >
        Hunks
      </div>
      {children}
    </div>
  );
}
