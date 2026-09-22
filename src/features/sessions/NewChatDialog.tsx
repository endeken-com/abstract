import { useState } from 'react';
import { useApp } from '../../store/app';
import { Button } from '../../app/ui';
import { Modal } from '../../app/Modal';
import { PROVIDERS } from '../../providers/registry';
import type { PermissionPolicy } from '../../providers/types';

export function NewChatDialog({
  projectId,
  onClose,
}: {
  projectId: string | null;
  onClose: () => void;
}) {
  const projects = useApp((s) => s.projects);
  const providerStatus = useApp((s) => s.providerStatus);
  const startChat = useApp((s) => s.startChat);

  const project = projects.find((p) => p.id === projectId) ?? projects[0] ?? null;
  const [selectedProject, setSelectedProject] = useState<string | null>(project?.id ?? null);
  const current = projects.find((p) => p.id === selectedProject) ?? null;

  const [provider, setProvider] = useState(current?.default_provider_id ?? PROVIDERS[0]?.id ?? 'claude');
  const [prompt, setPrompt] = useState('');
  const [baseRef, setBaseRef] = useState(current?.default_base_ref ?? 'HEAD');
  const [policy, setPolicy] = useState<PermissionPolicy>(
    (current?.default_permission_policy as PermissionPolicy) ?? 'ask',
  );
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const status = providerStatus[provider];

  async function submit() {
    if (!prompt.trim()) return;
    setBusy(true);
    setError(null);
    try {
      await startChat({
        projectId: selectedProject,
        providerId: provider,
        prompt: prompt.trim(),
        baseRef,
        permissionPolicy: policy,
      });
      onClose();
    } catch (e) {
      setError(String(e));
    } finally {
      setBusy(false);
    }
  }

  return (
    <Modal title="New chat" onClose={onClose}>
      <div className="flex flex-col gap-4">
        <label className="flex flex-col gap-1">
          <span className="text-xs" style={{ color: 'var(--bt-text-dim)' }}>
            Project
          </span>
          <select
            className="w-full"
            value={selectedProject ?? ''}
            onChange={(e) => {
              const id = e.target.value || null;
              setSelectedProject(id);
              const p = projects.find((x) => x.id === id);
              if (p) {
                setProvider(p.default_provider_id);
                setBaseRef(p.default_base_ref);
                setPolicy(p.default_permission_policy as PermissionPolicy);
              }
            }}
          >
            {projects.map((p) => (
              <option key={p.id} value={p.id}>
                {p.name}
              </option>
            ))}
          </select>
        </label>

        <label className="flex flex-col gap-1">
          <span className="text-xs" style={{ color: 'var(--bt-text-dim)' }}>
            Prompt
          </span>
          <textarea
            autoFocus
            rows={6}
            className="w-full font-mono"
            style={{ fontSize: 'var(--bt-code-size)' }}
            value={prompt}
            onChange={(e) => setPrompt(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) void submit();
            }}
            placeholder="What should the agent do in its own worktree?"
          />
        </label>

        <div className="grid grid-cols-3 gap-3">
          <label className="flex flex-col gap-1">
            <span className="text-xs" style={{ color: 'var(--bt-text-dim)' }}>
              Agent
            </span>
            <select value={provider} onChange={(e) => setProvider(e.target.value)}>
              {PROVIDERS.map((p) => (
                <option key={p.id} value={p.id}>
                  {p.name}
                </option>
              ))}
            </select>
          </label>
          <label className="flex flex-col gap-1">
            <span className="text-xs" style={{ color: 'var(--bt-text-dim)' }}>
              Base ref
            </span>
            <input value={baseRef} onChange={(e) => setBaseRef(e.target.value)} />
          </label>
          <label className="flex flex-col gap-1">
            <span className="text-xs" style={{ color: 'var(--bt-text-dim)' }}>
              Permissions
            </span>
            <select value={policy} onChange={(e) => setPolicy(e.target.value as PermissionPolicy)}>
              <option value="ask">Ask each time</option>
              <option value="auto-edits">Accept edits</option>
              <option value="bypass">Bypass prompts</option>
            </select>
          </label>
        </div>

        {status && !status.available ? (
          <p className="text-xs" style={{ color: 'var(--bt-warn)' }}>
            {provider} was not found on this machine's PATH. Set its path in Settings › Agents.
          </p>
        ) : null}

        {error ? (
          <p className="text-xs" style={{ color: 'var(--bt-removed)' }}>
            {error}
          </p>
        ) : null}

        <div className="flex items-center justify-between">
          <span className="text-xs" style={{ color: 'var(--bt-text-faint)' }}>
            A fresh worktree and branch are created for this chat.
          </span>
          <div className="flex gap-2">
            <Button onClick={onClose}>Cancel</Button>
            <Button variant="accent" disabled={busy || !prompt.trim()} onClick={() => void submit()}>
              {busy ? 'Starting…' : 'Start'}
            </Button>
          </div>
        </div>
      </div>
    </Modal>
  );
}
