import { useCallback, useEffect, useMemo, useState } from 'react';
import { diff } from '../../lib/ipc';
import type { FileDiff } from '../../lib/types';
import { FileList } from './FileList';
import { HunkList } from './HunkList';
import { MonacoDiff } from './MonacoDiff';
import { Toolbar } from './Toolbar';
import { useSessionDiff } from './useSessionDiff';
import { STATUS_LABEL, errText, totals } from './lib';
import { Btn, Centered, Counts, Notice } from './ui';

/**
 * Review what an agent changed in its worktree: pick a file on the left, read
 * the diff on the right, and accept (apply onto the project's main working
 * tree) or reject (undo inside the worktree) whole files or single hunks.
 */
export function DiffView({ sessionId }: { sessionId: string }): React.JSX.Element {
  const { data, loading, error, revision, reload } = useSessionDiff(sessionId);
  const [selectedPath, setSelectedPath] = useState<string | null>(null);
  const [sideBySide, setSideBySide] = useState(true);
  const [hideUnchanged, setHideUnchanged] = useState(false);
  const [busy, setBusy] = useState(false);
  const [actionError, setActionError] = useState<string | null>(null);
  const [confirmingAcceptAll, setConfirmingAcceptAll] = useState(false);

  const files = useMemo<FileDiff[]>(() => data?.files ?? [], [data]);
  const selected = useMemo(
    () => files.find((f) => f.path === selectedPath) ?? files[0] ?? null,
    [files, selectedPath],
  );
  const stats = useMemo(() => totals(files), [files]);

  // Keep the selection pointing at a file that still exists after a re-collect.
  useEffect(() => {
    if (selected && selected.path !== selectedPath) setSelectedPath(selected.path);
    if (!selected && selectedPath !== null) setSelectedPath(null);
  }, [selected, selectedPath]);

  useEffect(() => {
    setSelectedPath(null);
    setActionError(null);
    setConfirmingAcceptAll(false);
  }, [sessionId]);

  /** Every mutation reports its own failure and then re-collects regardless. */
  const run = useCallback(
    async (action: () => Promise<void>) => {
      setBusy(true);
      setActionError(null);
      let failure: string | null = null;
      try {
        await action();
      } catch (e) {
        failure = errText(e);
      }
      try {
        await reload();
      } finally {
        setActionError(failure);
        setBusy(false);
      }
    },
    [reload],
  );

  const acceptAll = useCallback(() => {
    if (!confirmingAcceptAll) {
      setConfirmingAcceptAll(true);
      return;
    }
    setConfirmingAcceptAll(false);
    void run(() => diff.accept(sessionId));
  }, [confirmingAcceptAll, run, sessionId]);

  const excluded = data?.excluded ?? [];

  return (
    <div
      className="h-full min-h-0 flex flex-col"
      style={{ background: 'var(--bt-bg)', color: 'var(--bt-text)' }}
    >
      <Toolbar
        fileCount={files.length}
        additions={stats.additions}
        deletions={stats.deletions}
        sideBySide={sideBySide}
        onSideBySide={setSideBySide}
        hideUnchanged={hideUnchanged}
        onHideUnchanged={setHideUnchanged}
        busy={busy}
        loading={loading}
        onRefresh={() => void reload()}
        confirmingAcceptAll={confirmingAcceptAll}
        onAcceptAll={acceptAll}
        onCancelAcceptAll={() => setConfirmingAcceptAll(false)}
      />

      {excluded.length > 0 ? (
        <div
          className="shrink-0 px-4 py-2 text-xs font-mono truncate"
          style={{ color: 'var(--bt-text-faint)', borderBottom: '1px solid var(--bt-border)' }}
          title={excluded.join(', ')}
        >
          nested repositories not shown: {excluded.join(', ')}
        </div>
      ) : null}

      {actionError ? <Notice text={actionError} onDismiss={() => setActionError(null)} /> : null}

      {error && !data ? (
        <Centered>
          <p className="m-0 text-sm" style={{ color: 'var(--bt-removed)' }}>
            Could not collect the diff.
          </p>
          <pre
            className="m-0 font-mono text-xs whitespace-pre-wrap break-words"
            style={{ color: 'var(--bt-text-dim)' }}
          >
            {error}
          </pre>
          <div className="flex justify-center">
            <Btn onClick={() => void reload()} disabled={loading}>
              Try again
            </Btn>
          </div>
        </Centered>
      ) : !data && loading ? (
        <Centered>
          <p className="m-0 text-sm" style={{ color: 'var(--bt-text-faint)' }}>
            Collecting changes…
          </p>
        </Centered>
      ) : files.length === 0 ? (
        <Centered>
          <p className="m-0 text-sm" style={{ color: 'var(--bt-text-dim)' }}>
            No changes in this worktree.
          </p>
          <p className="m-0 text-xs" style={{ color: 'var(--bt-text-faint)' }}>
            Anything the agent writes will show up here.
          </p>
        </Centered>
      ) : (
        <div className="flex-1 min-h-0 flex">
          <div
            className="w-80 shrink-0 flex flex-col min-h-0"
            style={{ background: 'var(--bt-surface)', borderRight: '1px solid var(--bt-border)' }}
          >
            <FileList files={files} selectedPath={selected?.path ?? null} onSelect={setSelectedPath} />
          </div>

          <div className="flex-1 min-w-0 flex flex-col min-h-0">
            {selected ? (
              <>
                <FileHeader
                  file={selected}
                  busy={busy}
                  onAccept={() => void run(() => diff.accept(sessionId, selected.path))}
                  onReject={() => void run(() => diff.reject(sessionId, selected.path))}
                />
                <MonacoDiff
                  sessionId={sessionId}
                  file={selected}
                  sideBySide={sideBySide}
                  hideUnchanged={hideUnchanged}
                  revision={revision}
                />
                <HunkList
                  file={selected}
                  busy={busy}
                  onAccept={(i) => void run(() => diff.accept(sessionId, selected.path, [i]))}
                  onReject={(i) => void run(() => diff.reject(sessionId, selected.path, [i]))}
                />
              </>
            ) : null}
          </div>
        </div>
      )}
    </div>
  );
}

function FileHeader({
  file,
  busy,
  onAccept,
  onReject,
}: {
  file: FileDiff;
  busy: boolean;
  onAccept: () => void;
  onReject: () => void;
}): React.JSX.Element {
  return (
    <div
      className="shrink-0 flex items-center gap-4 px-4 py-3"
      style={{ background: 'var(--bt-surface)', borderBottom: '1px solid var(--bt-border)' }}
    >
      <div className="flex-1 min-w-0 flex flex-col">
        <span className="font-mono text-sm truncate" style={{ color: 'var(--bt-text)' }}>
          {file.path}
        </span>
        <span className="text-xs" style={{ color: 'var(--bt-text-faint)' }}>
          {STATUS_LABEL[file.status]}
          {file.old_path ? ` from ${file.old_path}` : ''}
          {file.binary ? ' · binary' : ''}
        </span>
      </div>
      <Counts additions={file.additions} deletions={file.deletions} className="text-sm" />
      <div className="flex gap-2 shrink-0">
        <Btn tone="accept" disabled={busy} onClick={onAccept} title="Apply this file to the main working tree">
          Accept file
        </Btn>
        <Btn tone="reject" disabled={busy} onClick={onReject} title="Undo this file inside the worktree">
          Reject file
        </Btn>
      </div>
    </div>
  );
}
