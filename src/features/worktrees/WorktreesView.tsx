import { useEffect, useState } from 'react';
import * as ipc from '../../lib/ipc';
import { useApp } from '../../store/app';
import type { WorktreeInfo } from '../../lib/types';
import { Button, Empty } from '../../app/ui';

/**
 * Which worktrees exist, which chat owns each one, and which are abandoned
 * leftovers that can be cleaned up.
 */
export function WorktreesView() {
  const projects = useApp((s) => s.projects);
  const selectSession = useApp((s) => s.selectSession);
  const [projectId, setProjectId] = useState<string | null>(projects[0]?.id ?? null);
  const [list, setList] = useState<WorktreeInfo[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function load(id: string | null) {
    if (!id) return;
    setLoading(true);
    setError(null);
    try {
      setList(await ipc.worktrees.list(id));
    } catch (e) {
      setError(String(e));
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => {
    void load(projectId);
  }, [projectId]);

  const project = projects.find((p) => p.id === projectId);
  const orphans = list.filter((w) => w.orphan && w.path !== project?.root_path);

  if (projects.length === 0) return <Empty title="Add a project to inspect its worktrees." />;

  return (
    <div className="flex h-full flex-col">
      <header
        className="flex shrink-0 items-center gap-3 px-4 py-2"
        style={{ borderBottom: '1px solid var(--bt-border)' }}
      >
        <h1 className="text-sm">Worktrees</h1>
        <select value={projectId ?? ''} onChange={(e) => setProjectId(e.target.value || null)}>
          {projects.map((p) => (
            <option key={p.id} value={p.id}>
              {p.name}
            </option>
          ))}
        </select>
        <div className="flex-1" />
        <Button onClick={() => void load(projectId)}>Refresh</Button>
        <Button
          disabled={!projectId}
          title="Drop git's records of worktrees whose directories are gone"
          onClick={async () => {
            if (!projectId) return;
            await ipc.worktrees.prune(projectId);
            await load(projectId);
          }}
        >
          Prune
        </Button>
      </header>

      <div className="min-h-0 flex-1 overflow-y-auto p-4">
        {error ? (
          <p className="pb-3 text-xs" style={{ color: 'var(--bt-removed)' }}>
            {error}
          </p>
        ) : null}
        {loading ? (
          <p className="text-xs" style={{ color: 'var(--bt-text-faint)' }}>
            Loading…
          </p>
        ) : null}

        {orphans.length > 0 ? (
          <p className="pb-3 text-xs" style={{ color: 'var(--bt-warn)' }}>
            {orphans.length} worktree{orphans.length === 1 ? '' : 's'} no longer belong to a chat.
            Removing one deletes its directory; the branch is kept unless you say otherwise.
          </p>
        ) : null}

        <div className="flex flex-col">
          {list.map((w) => {
            const isRoot = w.path === project?.root_path;
            return (
              <div
                key={w.path}
                className="flex items-center gap-3 px-3 py-2"
                style={{ borderBottom: '1px solid var(--bt-border)' }}
              >
                <div className="min-w-0 flex-1">
                  <p className="truncate font-mono text-xs" style={{ color: 'var(--bt-text)' }}>
                    {w.path}
                  </p>
                  <p className="text-xs" style={{ color: 'var(--bt-text-faint)' }}>
                    {w.branch ?? (w.detached ? 'detached HEAD' : 'no branch')}
                    {isRoot
                      ? ' · main working tree'
                      : w.session_name
                        ? ` · ${w.session_name}`
                        : ' · abandoned'}
                    {w.locked ? ' · locked' : ''}
                  </p>
                </div>
                {w.session_id ? (
                  <Button onClick={() => void selectSession(w.session_id)}>Open chat</Button>
                ) : null}
                {!isRoot ? (
                  <Button
                    variant="danger"
                    onClick={async () => {
                      if (!projectId) return;
                      if (!confirm(`Remove worktree at ${w.path}?`)) return;
                      const alsoBranch =
                        w.branch && confirm(`Also delete the branch ${w.branch}?`)
                          ? w.branch
                          : undefined;
                      try {
                        await ipc.worktrees.remove(projectId, w.path, alsoBranch);
                        await load(projectId);
                      } catch (e) {
                        setError(String(e));
                      }
                    }}
                  >
                    Remove
                  </Button>
                ) : null}
              </div>
            );
          })}
        </div>

        {project && project.nested_repos.length > 0 ? (
          <p className="pt-4 text-xs" style={{ color: 'var(--bt-text-faint)' }}>
            Nested repositories in this project are excluded from worktree diffs:{' '}
            {project.nested_repos.join(', ')}
          </p>
        ) : null}
      </div>
    </div>
  );
}
