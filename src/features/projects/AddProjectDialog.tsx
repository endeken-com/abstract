import { useState } from 'react';
import { open } from '@tauri-apps/plugin-dialog';
import * as ipc from '../../lib/ipc';
import { useApp } from '../../store/app';
import type { ProbeResult } from '../../lib/types';
import { Button } from '../../app/ui';
import { Modal } from '../../app/Modal';
import { PROVIDERS } from '../../providers/registry';

export function AddProjectDialog({ onClose }: { onClose: () => void }) {
  const refreshProjects = useApp((s) => s.refreshProjects);
  const [probe, setProbe] = useState<ProbeResult | null>(null);
  const [name, setName] = useState('');
  const [provider, setProvider] = useState(PROVIDERS[0]?.id ?? 'claude');
  const [baseRef, setBaseRef] = useState('HEAD');
  const [policy, setPolicy] = useState('ask');
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  async function pick() {
    setError(null);
    const selected = await open({ directory: true, multiple: false, title: 'Choose a git repository' });
    if (typeof selected !== 'string') return;
    try {
      const result = await ipc.projects.probe(selected);
      setProbe(result);
      setName(result.name);
      setBaseRef(result.default_branch);
    } catch (e) {
      setProbe(null);
      setError(String(e));
    }
  }

  async function save() {
    if (!probe) return;
    setBusy(true);
    setError(null);
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
      onClose();
    } catch (e) {
      setError(String(e));
    } finally {
      setBusy(false);
    }
  }

  return (
    <Modal title="Add project" onClose={onClose}>
      <div className="flex flex-col gap-4">
        <div className="flex items-center gap-3">
          <Button onClick={() => void pick()}>Choose repository…</Button>
          {probe ? (
            <span className="truncate font-mono text-xs" style={{ color: 'var(--bt-text-dim)' }}>
              {probe.root_path}
            </span>
          ) : (
            <span className="text-xs" style={{ color: 'var(--bt-text-faint)' }}>
              Pick any directory inside the repository.
            </span>
          )}
        </div>

        {probe && !probe.is_root ? (
          <p className="text-xs" style={{ color: 'var(--bt-warn)' }}>
            That directory sits inside a larger repository. Backtick will use the repository root
            above, so worktrees carry the whole project.
          </p>
        ) : null}

        {probe && probe.nested_repos.length > 0 ? (
          <div className="px-3 py-2 text-xs" style={{ background: 'var(--bt-surface-2)' }}>
            <p style={{ color: 'var(--bt-warn)' }}>
              {probe.nested_repos.length} nested repositor
              {probe.nested_repos.length === 1 ? 'y' : 'ies'} found.
            </p>
            <p className="mt-1" style={{ color: 'var(--bt-text-dim)' }}>
              A worktree cannot carry these, so changes an agent makes inside them stay out of the
              diff view. Submodules are initialised in each new worktree.
            </p>
            <ul className="mt-1 font-mono" style={{ color: 'var(--bt-text-faint)' }}>
              {probe.nested_repos.slice(0, 6).map((r) => (
                <li key={r}>{r}</li>
              ))}
            </ul>
          </div>
        ) : null}

        {probe ? (
          <div className="grid grid-cols-2 gap-3">
            <Field label="Name">
              <input value={name} onChange={(e) => setName(e.target.value)} className="w-full" />
            </Field>
            <Field label="Base ref for new worktrees">
              <input value={baseRef} onChange={(e) => setBaseRef(e.target.value)} className="w-full" />
            </Field>
            <Field label="Default agent">
              <select value={provider} onChange={(e) => setProvider(e.target.value)} className="w-full">
                {PROVIDERS.map((p) => (
                  <option key={p.id} value={p.id}>
                    {p.name}
                  </option>
                ))}
              </select>
            </Field>
            <Field label="Default permissions">
              <select value={policy} onChange={(e) => setPolicy(e.target.value)} className="w-full">
                <option value="ask">Ask each time</option>
                <option value="auto-edits">Accept edits automatically</option>
                <option value="bypass">Bypass all prompts</option>
              </select>
            </Field>
          </div>
        ) : null}

        {error ? (
          <p className="text-xs" style={{ color: 'var(--bt-removed)' }}>
            {error}
          </p>
        ) : null}

        <div className="flex justify-end gap-2">
          <Button onClick={onClose}>Cancel</Button>
          <Button variant="accent" disabled={!probe || busy} onClick={() => void save()}>
            {busy ? 'Adding…' : 'Add project'}
          </Button>
        </div>
      </div>
    </Modal>
  );
}

function Field({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <label className="flex flex-col gap-1">
      <span className="text-xs" style={{ color: 'var(--bt-text-dim)' }}>
        {label}
      </span>
      {children}
    </label>
  );
}
