import { useCallback, useEffect, useState } from 'react';
import { AnimatePresence, motion } from 'motion/react';
import { toast } from 'sonner';
import { revealItemInDir } from '@tauri-apps/plugin-opener';
import { ArrowUpRight, Eraser, FolderOpen, GitBranch, RefreshCw, Trash2, TriangleAlert } from 'lucide-react';
import * as ipc from '../../lib/ipc';
import { useApp } from '../../store/app';
import type { WorktreeInfo } from '../../lib/types';
import { Badge, Button, Dialog, EmptyState, IconButton, Segmented, Switch, cn } from '../../ui';
import { dragRegion } from '../../app/windowDrag';

/** Which worktrees exist, which chat owns each one, and what can be cleaned up. */
export function WorktreesView() {
  const projects = useApp((s) => s.projects);
  const selectSession = useApp((s) => s.selectSession);
  const [projectId, setProjectId] = useState<string | null>(projects[0]?.id ?? null);
  const [list, setList] = useState<WorktreeInfo[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [removing, setRemoving] = useState<WorktreeInfo | null>(null);

  const project = projects.find((p) => p.id === projectId);

  const load = useCallback(async (id: string | null) => {
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
  }, []);

  useEffect(() => {
    void load(projectId);
  }, [projectId, load]);

  if (projects.length === 0) {
    return <EmptyState icon={<GitBranch size={18} />} title="No projects yet" description="Add a project and its worktrees show up here." />;
  }

  const main = list.find((w) => w.path === project?.root_path);
  const owned = list.filter((w) => w !== main && !w.orphan);
  const orphans = list.filter((w) => w !== main && w.orphan);

  return (
    <div className="flex h-full flex-col">
      <header {...dragRegion} className="flex h-12 shrink-0 items-center gap-3 pl-5 pr-3" style={{ boxShadow: 'inset 0 -1px 0 var(--bt-border)' }}>
        <h1 className="text-[13.5px] font-medium">Worktrees</h1>
        <div className="flex-1" />
        {projects.length > 1 && projects.length <= 5 ? (
          <Segmented value={projectId ?? ''} onChange={(v) => setProjectId(v)} options={projects.map((p) => ({ value: p.id, label: p.name }))} />
        ) : (
          <select className="bt-select h-7 w-48 text-[12.5px]" value={projectId ?? ''} onChange={(e) => setProjectId(e.target.value || null)}>
            {projects.map((p) => (
              <option key={p.id} value={p.id}>
                {p.name}
              </option>
            ))}
          </select>
        )}
        <IconButton label="Refresh" onClick={() => void load(projectId)}>
          <RefreshCw size={14} className={cn(loading && 'animate-spin')} />
        </IconButton>
        <Button
          size="sm"
          variant="ghost"
          icon={<Eraser size={13} />}
          onClick={async () => {
            if (!projectId) return;
            try {
              await ipc.worktrees.prune(projectId);
              toast.success('Pruned stale worktree records');
              await load(projectId);
            } catch (e) {
              toast.error('Prune failed', { description: String(e) });
            }
          }}
        >
          Prune
        </Button>
      </header>

      <div className="min-h-0 flex-1 overflow-y-auto">
        <div className="mx-auto flex w-full max-w-[860px] flex-col gap-6 px-8 py-6">
          {error ? (
            <p className="rounded-[10px] px-3 py-2 text-[12.5px]" style={{ background: 'var(--bt-removed-soft)', color: 'var(--bt-removed)' }}>
              {error}
            </p>
          ) : null}

          {main ? (
            <Section title="Main working tree" hint="Accepted changes land here, unstaged.">
              <Row w={main} kind="main" />
            </Section>
          ) : null}

          <Section title={`Chat worktrees · ${owned.length}`} hint="One per chat, on its own branch.">
            {owned.length === 0 ? (
              <p className="px-4 py-5 text-[12.5px]" style={{ color: 'var(--bt-text-faint)' }}>
                No chats in this project yet.
              </p>
            ) : (
              owned.map((w) => <Row key={w.path} w={w} kind="owned" onOpen={() => w.session_id && void selectSession(w.session_id)} onRemove={() => setRemoving(w)} />)
            )}
          </Section>

          <AnimatePresence>
            {orphans.length ? (
              <motion.div initial={{ opacity: 0, y: 6 }} animate={{ opacity: 1, y: 0 }} exit={{ opacity: 0 }}>
                <Section
                  title={`Abandoned · ${orphans.length}`}
                  hint="Worktrees no chat owns any more. Safe to remove once you've kept what you need."
                  tone="warn"
                >
                  {orphans.map((w) => (
                    <Row key={w.path} w={w} kind="orphan" onRemove={() => setRemoving(w)} />
                  ))}
                </Section>
              </motion.div>
            ) : null}
          </AnimatePresence>

          {project && project.nested_repos.length > 0 ? (
            <p className="flex items-start gap-2 text-[12px] leading-relaxed" style={{ color: 'var(--bt-text-faint)' }}>
              <TriangleAlert size={13} className="mt-0.5 shrink-0" style={{ color: 'var(--bt-warn)' }} />
              Nested repositories are excluded from worktree diffs: <span className="font-mono">{project.nested_repos.join(', ')}</span>
            </p>
          ) : null}
        </div>
      </div>

      <RemoveDialog
        target={removing}
        onClose={() => setRemoving(null)}
        onConfirm={async (deleteBranch) => {
          if (!projectId || !removing) return;
          try {
            await ipc.worktrees.remove(projectId, removing.path, deleteBranch ? removing.branch ?? undefined : undefined);
            toast.success('Worktree removed', { description: deleteBranch ? `Branch ${removing.branch} deleted too` : undefined });
            setRemoving(null);
            await load(projectId);
          } catch (e) {
            toast.error('Could not remove the worktree', { description: String(e) });
          }
        }}
      />
    </div>
  );
}

function Section({ title, hint, tone, children }: { title: string; hint?: string; tone?: 'warn'; children: React.ReactNode }) {
  return (
    <section>
      <div className="mb-2 flex items-baseline gap-2 px-1">
        <h2 className="text-[12.5px] font-medium" style={{ color: tone === 'warn' ? 'var(--bt-warn)' : 'var(--bt-text-dim)' }}>
          {title}
        </h2>
        {hint ? (
          <span className="text-[12px]" style={{ color: 'var(--bt-text-faint)' }}>
            {hint}
          </span>
        ) : null}
      </div>
      <div className="overflow-hidden rounded-[12px]" style={{ background: 'var(--bt-surface)', boxShadow: 'inset 0 0 0 1px var(--bt-border), inset 0 1px 0 var(--bt-highlight)' }}>
        {children}
      </div>
    </section>
  );
}

function Row({ w, kind, onOpen, onRemove }: { w: WorktreeInfo; kind: 'main' | 'owned' | 'orphan'; onOpen?: () => void; onRemove?: () => void }) {
  return (
    <div className="group flex items-center gap-3 px-4 py-3 transition-colors hover:bg-[var(--bt-hover)] [&:not(:last-child)]:shadow-[inset_0_-1px_0_var(--bt-border)]">
      <span className="flex h-8 w-8 shrink-0 items-center justify-center rounded-[9px]" style={{ background: 'var(--bt-surface-3)', color: kind === 'orphan' ? 'var(--bt-warn)' : 'var(--bt-text-dim)' }}>
        <GitBranch size={14} />
      </span>
      <div className="min-w-0 flex-1">
        <p className="flex items-center gap-2 truncate text-[13px]" style={{ color: 'var(--bt-text)' }}>
          {kind === 'owned' ? w.session_name : (w.branch ?? (w.detached ? 'detached HEAD' : 'no branch'))}
          {w.locked ? <Badge>locked</Badge> : null}
        </p>
        <p className="mt-0.5 flex items-center gap-2 truncate text-[11.5px]" style={{ color: 'var(--bt-text-faint)' }}>
          {kind === 'owned' && w.branch ? <span className="font-mono">{w.branch}</span> : null}
          <span className="truncate font-mono">{w.path}</span>
        </p>
      </div>
      <div className="flex shrink-0 items-center gap-1 opacity-0 transition-opacity group-hover:opacity-100">
        <IconButton label="Reveal in file manager" onClick={() => void revealItemInDir(w.path).catch((e) => toast.error('Could not open the folder', { description: String(e) }))}>
          <FolderOpen size={14} />
        </IconButton>
        {onOpen ? (
          <Button size="sm" variant="ghost" iconRight={<ArrowUpRight size={13} />} onClick={onOpen}>
            Open chat
          </Button>
        ) : null}
        {onRemove ? (
          <IconButton label="Remove worktree" variant="danger" onClick={onRemove}>
            <Trash2 size={14} />
          </IconButton>
        ) : null}
      </div>
    </div>
  );
}

function RemoveDialog({ target, onClose, onConfirm }: { target: WorktreeInfo | null; onClose: () => void; onConfirm: (deleteBranch: boolean) => Promise<void> }) {
  const [deleteBranch, setDeleteBranch] = useState(false);
  const [busy, setBusy] = useState(false);
  useEffect(() => {
    setDeleteBranch(false);
    setBusy(false);
  }, [target?.path]);
  return (
    <Dialog
      open={!!target}
      onOpenChange={(v) => !v && onClose()}
      title="Remove worktree?"
      description="Its directory is deleted. Uncommitted work inside it is lost."
      width={480}
      footer={
        <>
          <Button variant="ghost" onClick={onClose}>
            Cancel
          </Button>
          <Button
            variant="primary"
            className="!bg-[var(--bt-removed)] !text-white"
            loading={busy}
            onClick={async () => {
              setBusy(true);
              await onConfirm(deleteBranch);
              setBusy(false);
            }}
          >
            Remove
          </Button>
        </>
      }
    >
      {target ? (
        <div className="flex flex-col gap-4">
          <p className="rounded-[9px] px-3 py-2 font-mono text-[12px]" style={{ background: 'var(--bt-surface-2)', color: 'var(--bt-text-dim)' }}>
            {target.path}
          </p>
          {target.branch ? (
            <label className="flex items-center justify-between gap-3 text-[13px]" style={{ color: 'var(--bt-text)' }}>
              <span>
                Also delete branch <span className="font-mono text-[12px]">{target.branch}</span>
                <span className="block text-[12px]" style={{ color: 'var(--bt-text-faint)' }}>
                  Kept by default, so nothing committed is lost.
                </span>
              </span>
              <Switch checked={deleteBranch} onCheckedChange={setDeleteBranch} label="Delete branch" />
            </label>
          ) : null}
        </div>
      ) : null}
    </Dialog>
  );
}
