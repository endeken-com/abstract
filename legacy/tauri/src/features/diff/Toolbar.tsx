import { Btn, Counts } from './ui';

export function Toolbar({
  fileCount,
  additions,
  deletions,
  sideBySide,
  onSideBySide,
  hideUnchanged,
  onHideUnchanged,
  busy,
  loading,
  onRefresh,
  confirmingAcceptAll,
  onAcceptAll,
  onCancelAcceptAll,
}: {
  fileCount: number;
  additions: number;
  deletions: number;
  sideBySide: boolean;
  onSideBySide: (value: boolean) => void;
  hideUnchanged: boolean;
  onHideUnchanged: (value: boolean) => void;
  busy: boolean;
  loading: boolean;
  onRefresh: () => void;
  confirmingAcceptAll: boolean;
  onAcceptAll: () => void;
  onCancelAcceptAll: () => void;
}): React.JSX.Element {
  return (
    <div
      className="shrink-0 flex items-center gap-4 flex-wrap px-4 py-2.5"
      style={{ background: 'var(--bt-surface)', borderBottom: '1px solid var(--bt-border)' }}
    >
      <div className="flex items-center gap-3">
        <span className="text-sm tabular-nums" style={{ color: 'var(--bt-text-dim)' }}>
          {fileCount} {fileCount === 1 ? 'file' : 'files'}
        </span>
        <Counts additions={additions} deletions={deletions} className="text-sm" />
      </div>

      <div className="flex items-center gap-px">
        <Btn active={sideBySide} onClick={() => onSideBySide(true)} title="Side-by-side diff">
          Side by side
        </Btn>
        <Btn active={!sideBySide} onClick={() => onSideBySide(false)} title="Inline diff">
          Inline
        </Btn>
      </div>

      <Btn
        active={hideUnchanged}
        onClick={() => onHideUnchanged(!hideUnchanged)}
        title="Collapse regions with no changes"
      >
        Hide unchanged
      </Btn>

      <div className="flex-1" />

      <Btn onClick={onRefresh} disabled={busy || loading}>
        {loading ? 'Refreshing…' : 'Refresh'}
      </Btn>

      {confirmingAcceptAll ? (
        <div className="flex items-center gap-3">
          <span className="text-sm" style={{ color: 'var(--bt-text-dim)' }}>
            Apply every file to the main working tree?
          </span>
          <Btn tone="accept" onClick={onAcceptAll} disabled={busy}>
            Confirm accept all
          </Btn>
          <Btn onClick={onCancelAcceptAll} disabled={busy}>
            Cancel
          </Btn>
        </div>
      ) : (
        <Btn tone="accept" onClick={onAcceptAll} disabled={busy || fileCount === 0}>
          Accept all
        </Btn>
      )}
    </div>
  );
}
