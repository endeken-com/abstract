import { useState } from 'react';
import { open } from '@tauri-apps/plugin-dialog';
import { toast } from 'sonner';
import { FolderGit2, FolderOpen, TriangleAlert } from 'lucide-react';
import * as ipc from '../../lib/ipc';
import { useApp } from '../../store/app';
import type { ProbeResult } from '../../lib/types';
import { Button, Dialog, Field, Input, Select } from '../../ui';
import { PROVIDERS } from '../../providers/registry';

export function AddProjectDialog() {
  const isOpen = useApp((s) => s.addProjectOpen);
  const setOpen = useApp((s) => s.setAddProjectOpen);
  return (
    <Dialog open={isOpen} onOpenChange={setOpen} title="Add project" description="Point Abstract at a git repository on this machine." width={560}>
      {isOpen ? <AddProjectForm onDone={() => setOpen(false)} /> : null}
    </Dialog>
  );
}

function AddProjectForm({ onDone }: { onDone: () => void }) {
  const refreshProjects = useApp((s) => s.refreshProjects);
  const [probe, setProbe] = useState<ProbeResult | null>(null);
  const [name, setName] = useState('');
  const [provider, setProvider] = useState(PROVIDERS[0]?.id ?? 'claude');
  const [baseRef, setBaseRef] = useState('HEAD');
  const [policy, setPolicy] = useState('ask');
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [picking, setPicking] = useState(false);

  async function pick() {
    setError(null);
    setPicking(true);
    try {
      const selected = await open({ directory: true, multiple: false, title: 'Choose a git repository' });
      if (typeof selected !== 'string') return;
      const result = await ipc.projects.probe(selected);
      setProbe(result);
      setName(result.name);
      setBaseRef(result.default_branch);
    } catch (e) {
      setProbe(null);
      setError(String(e));
    } finally {
      setPicking(false);
    }
  }

  async function save() {
    if (!probe) return;
    setBusy(true);
    try {
      await ipc.projects.add({
        name: name.trim() || probe.name,
        root_path: probe.root_path,
        default_base_ref: baseRef,
        default_provider_id: provider,
        default_permission_policy: policy,
        nested_repos: probe.nested_repos,
      });
      await refreshProjects();
      toast.success(`${name.trim() || probe.name} added`);
      onDone();
    } catch (e) {
      setError(String(e));
      setBusy(false);
    }
  }

  return (
    <div className="flex flex-col gap-4">
      <button
        onClick={() => void pick()}
        className="group flex items-center gap-3 rounded-[12px] px-4 py-3.5 text-left transition-colors hover:bg-[var(--bt-hover)]"
        style={{ background: 'var(--bt-surface-2)', boxShadow: `inset 0 0 0 1px ${probe ? 'var(--bt-border-strong)' : 'var(--bt-border)'}` }}
      >
        <span className="flex h-9 w-9 shrink-0 items-center justify-center rounded-[10px]" style={{ background: 'var(--bt-surface-4)', color: 'var(--bt-text-dim)' }}>
          {probe ? <FolderGit2 size={17} /> : <FolderOpen size={17} />}
        </span>
        <span className="min-w-0 flex-1">
          <span className="block text-[13px] font-medium" style={{ color: 'var(--bt-text)' }}>
            {probe ? probe.name : picking ? 'Choosing…' : 'Choose a repository'}
          </span>
          <span className="block truncate font-mono text-[11.5px]" style={{ color: 'var(--bt-text-faint)' }}>
            {probe ? probe.root_path : 'Any folder inside the repository works.'}
          </span>
        </span>
        <span className="text-[12px]" style={{ color: 'var(--bt-text-faint)' }}>
          {probe ? 'Change' : 'Browse'}
        </span>
      </button>

      {probe && !probe.is_root ? (
        <Notice>That folder sits inside a larger repository, so Abstract uses its root. Worktrees then carry the whole project.</Notice>
      ) : null}
      {probe && probe.nested_repos.length > 0 ? (
        <Notice>
          Found {probe.nested_repos.length} nested repositor{probe.nested_repos.length === 1 ? 'y' : 'ies'} (
          <span className="font-mono">{probe.nested_repos.slice(0, 3).join(', ')}</span>
          {probe.nested_repos.length > 3 ? '…' : ''}). A worktree can't carry them, so changes inside them stay out of the review.
        </Notice>
      ) : null}

      {probe ? (
        <div className="grid grid-cols-2 gap-3">
          <Field label="Name">
            <Input value={name} onChange={(e) => setName(e.target.value)} />
          </Field>
          <Field label="Branch new worktrees from">
            <Input mono value={baseRef} onChange={(e) => setBaseRef(e.target.value)} />
          </Field>
          <Field label="Default agent">
            <Select value={provider} onChange={(e) => setProvider(e.target.value)}>
              {PROVIDERS.map((p) => (
                <option key={p.id} value={p.id}>
                  {p.name}
                </option>
              ))}
            </Select>
          </Field>
          <Field label="Default permissions">
            <Select value={policy} onChange={(e) => setPolicy(e.target.value)}>
              <option value="ask">Ask before acting</option>
              <option value="auto-edits">Accept edits</option>
              <option value="bypass">Full autonomy</option>
            </Select>
          </Field>
        </div>
      ) : null}

      {error ? (
        <p className="text-[12.5px]" style={{ color: 'var(--bt-removed)' }}>
          {error}
        </p>
      ) : null}

      <div className="flex justify-end gap-2 pt-1">
        <Button variant="ghost" onClick={onDone}>
          Cancel
        </Button>
        <Button variant="primary" disabled={!probe} loading={busy} onClick={() => void save()}>
          Add project
        </Button>
      </div>
    </div>
  );
}

function Notice({ children }: { children: React.ReactNode }) {
  return (
    <p
      className="flex items-start gap-2 rounded-[10px] px-3 py-2.5 text-[12.5px] leading-relaxed"
      style={{ background: 'color-mix(in srgb, var(--bt-warn) 9%, transparent)', color: 'var(--bt-text-dim)', boxShadow: 'inset 0 0 0 1px color-mix(in srgb, var(--bt-warn) 22%, transparent)' }}
    >
      <TriangleAlert size={14} className="mt-0.5 shrink-0" style={{ color: 'var(--bt-warn)' }} />
      <span>{children}</span>
    </p>
  );
}
