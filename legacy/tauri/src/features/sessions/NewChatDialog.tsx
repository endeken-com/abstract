import { useEffect, useMemo, useState } from 'react';
import { toast } from 'sonner';
import { GitBranch, ShieldCheck, Sparkles, TriangleAlert } from 'lucide-react';
import { useApp } from '../../store/app';
import { Button, Dialog, Select, Textarea, cn } from '../../ui';
import { PROVIDERS } from '../../providers/registry';
import type { PermissionPolicy } from '../../providers/types';

const POLICIES: { value: PermissionPolicy; label: string; hint: string }[] = [
  { value: 'ask', label: 'Ask before acting', hint: 'You approve each tool call in the chat.' },
  { value: 'auto-edits', label: 'Accept edits', hint: 'File edits go through; commands still ask.' },
  { value: 'bypass', label: 'Full autonomy', hint: 'Nothing asks. Only for trusted tasks.' },
];

function slugify(input: string): string {
  const s = input
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 40)
    .replace(/-+$/, '');
  return s || 'session';
}

export function NewChatDialog() {
  const newChatFor = useApp((s) => s.newChatFor);
  const close = useApp((s) => s.closeNewChat);
  const open = newChatFor !== undefined;
  return (
    <Dialog open={open} onOpenChange={(v) => !v && close()} title="New chat" description="The agent gets its own worktree and branch." width={620}>
      {open ? <NewChatForm initialProjectId={newChatFor} onDone={close} /> : null}
    </Dialog>
  );
}

function NewChatForm({ initialProjectId, onDone }: { initialProjectId: string | null; onDone: () => void }) {
  const projects = useApp((s) => s.projects);
  const providerStatus = useApp((s) => s.providerStatus);
  const settings = useApp((s) => s.settings);
  const startChat = useApp((s) => s.startChat);
  const setAddProjectOpen = useApp((s) => s.setAddProjectOpen);

  const [projectId, setProjectId] = useState<string | null>(initialProjectId ?? projects[0]?.id ?? null);
  const project = projects.find((p) => p.id === projectId) ?? null;
  const [provider, setProvider] = useState(project?.default_provider_id ?? PROVIDERS[0]?.id ?? 'claude');
  const [baseRef, setBaseRef] = useState(project?.default_base_ref ?? 'HEAD');
  const [policy, setPolicy] = useState<PermissionPolicy>((project?.default_permission_policy as PermissionPolicy) ?? 'ask');
  const [prompt, setPrompt] = useState('');
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    if (!project) return;
    setProvider(project.default_provider_id);
    setBaseRef(project.default_base_ref);
    setPolicy(project.default_permission_policy as PermissionPolicy);
  }, [project?.id]); // eslint-disable-line react-hooks/exhaustive-deps

  const prefix = project?.branch_prefix || (settings.branch_prefix as string | undefined) || 'abstract/';
  const branchPreview = useMemo(() => `${prefix}${slugify(prompt.split('\n')[0] ?? '')}`, [prefix, prompt]);
  const status = providerStatus[provider];

  async function submit() {
    if (!prompt.trim() || !projectId || busy) return;
    setBusy(true);
    try {
      await startChat({ projectId, providerId: provider, prompt: prompt.trim(), baseRef, permissionPolicy: policy });
      onDone();
    } catch (e) {
      toast.error('Could not start the chat', { description: String(e) });
      setBusy(false);
    }
  }

  if (projects.length === 0) {
    return (
      <div className="flex flex-col items-start gap-3 py-2">
        <p className="text-[13px]" style={{ color: 'var(--bt-text-dim)' }}>
          Chats live inside a project. Add a git repository first.
        </p>
        <Button
          variant="primary"
          onClick={() => {
            onDone();
            setAddProjectOpen(true);
          }}
        >
          Add project
        </Button>
      </div>
    );
  }

  return (
    <div className="flex flex-col gap-4">
      <div
        className="rounded-[12px] transition-shadow focus-within:shadow-[0_0_0_1px_var(--bt-accent-line),0_0_0_4px_var(--bt-accent-soft)]"
        style={{ background: 'var(--bt-surface-2)', boxShadow: 'inset 0 0 0 1px var(--bt-border)' }}
      >
        <Textarea
          autoFocus
          autoGrow
          rows={4}
          maxRows={16}
          value={prompt}
          onChange={(e) => setPrompt(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) {
              e.preventDefault();
              void submit();
            }
          }}
          placeholder="Describe the task. Be as specific as you would with a colleague."
          className="!border-0 !bg-transparent !shadow-none px-4 pt-3.5 text-[14px] leading-[1.6]"
        />
        <div className="flex flex-wrap items-center gap-2 px-3 pb-3">
          <ChipSelect value={projectId ?? ''} onChange={(v) => setProjectId(v || null)} label="Project">
            {projects.map((p) => (
              <option key={p.id} value={p.id}>
                {p.name}
              </option>
            ))}
          </ChipSelect>
          <ChipSelect value={provider} onChange={setProvider} label="Agent" icon={<Sparkles size={12} />}>
            {PROVIDERS.map((p) => (
              <option key={p.id} value={p.id}>
                {p.name}
              </option>
            ))}
          </ChipSelect>
          <label
            className="inline-flex h-7 items-center gap-1.5 rounded-[7px] pl-2 pr-1 text-[12px]"
            style={{ background: 'var(--bt-surface-3)', color: 'var(--bt-text-dim)', boxShadow: 'inset 0 0 0 1px var(--bt-border)' }}
          >
            <GitBranch size={12} />
            from
            <input
              value={baseRef}
              onChange={(e) => setBaseRef(e.target.value)}
              aria-label="Base ref"
              className="bt-input h-5 w-24 !rounded-[5px] !border-0 !bg-transparent px-1 font-mono text-[11.5px] !shadow-none"
            />
          </label>
        </div>
      </div>

      <div className="grid grid-cols-3 gap-2">
        {POLICIES.map((p) => {
          const active = p.value === policy;
          return (
            <button
              key={p.value}
              onClick={() => setPolicy(p.value)}
              className={cn('flex flex-col items-start gap-1 rounded-[10px] px-3 py-2.5 text-left transition-[background,box-shadow] duration-150', !active && 'hover:bg-[var(--bt-hover)]')}
              style={{
                background: active ? 'var(--bt-accent-soft)' : 'transparent',
                boxShadow: active ? 'inset 0 0 0 1px var(--bt-accent-line)' : 'inset 0 0 0 1px var(--bt-border)',
              }}
            >
              <span className="flex items-center gap-1.5 text-[12.5px] font-medium" style={{ color: active ? 'var(--bt-text)' : 'var(--bt-text-dim)' }}>
                <ShieldCheck size={13} style={{ color: active ? 'var(--bt-accent)' : 'var(--bt-text-faint)' }} />
                {p.label}
              </span>
              <span className="text-[11.5px] leading-snug" style={{ color: 'var(--bt-text-faint)' }}>
                {p.hint}
              </span>
            </button>
          );
        })}
      </div>

      {status && !status.available ? (
        <p className="flex items-center gap-2 text-[12px]" style={{ color: 'var(--bt-warn)' }}>
          <TriangleAlert size={13} /> {provider} was not found on this machine. Set its path in Settings › Agents.
        </p>
      ) : null}

      <div className="flex items-center gap-3 pt-1">
        <span className="min-w-0 flex-1 truncate font-mono text-[11.5px]" style={{ color: 'var(--bt-text-faint)' }}>
          {branchPreview}
        </span>
        <Button variant="ghost" onClick={onDone}>
          Cancel
        </Button>
        <Button variant="primary" loading={busy} disabled={!prompt.trim()} onClick={() => void submit()} shortcut="mod+enter">
          Start
        </Button>
      </div>
    </div>
  );
}

function ChipSelect({
  value,
  onChange,
  label,
  icon,
  children,
}: {
  value: string;
  onChange: (v: string) => void;
  label: string;
  icon?: React.ReactNode;
  children: React.ReactNode;
}) {
  return (
    <span className="relative inline-flex">
      {icon ? (
        <span className="pointer-events-none absolute left-2 top-1/2 -translate-y-1/2" style={{ color: 'var(--bt-text-faint)' }}>
          {icon}
        </span>
      ) : null}
      <Select
        aria-label={label}
        value={value}
        onChange={(e) => onChange(e.target.value)}
        className={cn('!h-7 !w-auto !rounded-[7px] !bg-[var(--bt-surface-3)] !py-0 text-[12px] font-medium', icon ? '!pl-6' : '!pl-2.5')}
      >
        {children}
      </Select>
    </span>
  );
}
