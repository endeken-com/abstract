import { useState, type JSX } from 'react';
import { automations as automationsIpc } from '../../lib/ipc';
import type { Automation } from '../../lib/types';
import { useApp } from '../../store/app';
import { AutomationForm } from './AutomationForm';
import { RunHistory } from './RunHistory';
import { Button, Card, Muted, StatusWord, Toggle } from './ui';
import { formatRelative } from './format';

type Tab = 'runs' | 'settings';

export function AutomationDetail({ automation }: { automation: Automation }): JSX.Element {
  const projects = useApp((s) => s.projects);
  const refreshAutomations = useApp((s) => s.refreshAutomations);
  const selectAutomation = useApp((s) => s.selectAutomation);

  const [tab, setTab] = useState<Tab>('runs');
  const [reloadKey, setReloadKey] = useState(0);
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [confirmingDelete, setConfirmingDelete] = useState(false);

  const projectName =
    projects.find((p) => p.id === automation.project_id)?.name ?? 'No project';

  const setEnabled = (enabled: boolean) => {
    setBusy('enabled');
    setError(null);
    automationsIpc
      .setEnabled(automation.id, enabled)
      .then(() => refreshAutomations())
      .catch((e: unknown) => setError(String(e)))
      .finally(() => setBusy(null));
  };

  const runNow = () => {
    setBusy('run');
    setError(null);
    automationsIpc
      .runNow(automation.id)
      .then(async () => {
        await refreshAutomations();
        setReloadKey((k) => k + 1);
        setTab('runs');
      })
      .catch((e: unknown) => setError(String(e)))
      .finally(() => setBusy(null));
  };

  const remove = () => {
    setBusy('delete');
    setError(null);
    automationsIpc
      .remove(automation.id)
      .then(async () => {
        await refreshAutomations();
        selectAutomation(null);
      })
      .catch((e: unknown) => setError(String(e)))
      .finally(() => setBusy(null));
  };

  return (
    <div className="flex flex-col gap-6">
      <header className="flex flex-col gap-3">
        <div className="flex flex-wrap items-start justify-between gap-4">
          <div className="flex flex-col gap-1">
            <h1 className="m-0 text-[1.3em] font-semibold" style={{ color: 'var(--bt-text)' }}>
              {automation.name}
            </h1>
            <div className="flex flex-wrap items-center gap-x-3 gap-y-1">
              <span style={{ color: 'var(--bt-text-dim)' }}>{projectName}</span>
              <span style={{ color: 'var(--bt-text-faint)' }}>·</span>
              <StatusWord tone={automation.enabled ? 'accent' : 'off'}>
                {automation.enabled ? 'active' : 'paused'}
              </StatusWord>
              <span style={{ color: 'var(--bt-text-faint)' }}>·</span>
              <span style={{ color: 'var(--bt-text-dim)' }}>
                {automation.enabled
                  ? `next fire ${formatRelative(automation.next_run_at)}`
                  : 'not scheduled while paused'}
              </span>
            </div>
          </div>
          <Button onClick={runNow} disabled={busy !== null}>
            {busy === 'run' ? 'Starting…' : 'Run now'}
          </Button>
        </div>

        <nav aria-label="Automation tabs" className="flex gap-1">
          {(
            [
              { value: 'runs' as const, label: 'Run History' },
              { value: 'settings' as const, label: 'Settings' },
            ] satisfies { value: Tab; label: string }[]
          ).map((item) => {
            const active = item.value === tab;
            return (
              <button
                key={item.value}
                type="button"
                aria-current={active ? 'page' : undefined}
                onClick={() => setTab(item.value)}
                className="px-3 py-2"
                style={{
                  background: active ? 'var(--bt-surface-2)' : 'transparent',
                  borderBottom: `2px solid ${active ? 'var(--bt-accent)' : 'transparent'}`,
                  color: active ? 'var(--bt-text)' : 'var(--bt-text-dim)',
                }}
              >
                {item.label}
              </button>
            );
          })}
        </nav>
      </header>

      {error ? (
        <p className="m-0" style={{ color: 'var(--bt-removed)' }}>
          {error}
        </p>
      ) : null}

      {tab === 'runs' ? (
        <RunHistory automationId={automation.id} reloadKey={reloadKey} />
      ) : (
        <div className="flex flex-col gap-8">
          <Card>
            <Toggle
              label="Active"
              hint="While this is off nothing fires, manually triggered runs aside."
              checked={automation.enabled}
              onChange={setEnabled}
            />
          </Card>

          <AutomationForm
            key={automation.id}
            automation={automation}
            onSaved={() => setReloadKey((k) => k + 1)}
          />

          <Card>
            <div className="flex flex-col gap-3">
              <span className="font-medium" style={{ color: 'var(--bt-text)' }}>
                Delete this automation
              </span>
              <Muted>
                Deleting removes the automation and its run history. The sessions and worktrees it
                created stay exactly where they are.
              </Muted>
              {confirmingDelete ? (
                <div className="flex flex-wrap items-center gap-3">
                  <span style={{ color: 'var(--bt-text)' }}>
                    Delete “{automation.name}” and its run history?
                  </span>
                  <Button variant="danger" onClick={remove} disabled={busy !== null}>
                    {busy === 'delete' ? 'Deleting…' : 'Yes, delete'}
                  </Button>
                  <Button onClick={() => setConfirmingDelete(false)}>Keep it</Button>
                </div>
              ) : (
                <div>
                  <Button variant="danger" onClick={() => setConfirmingDelete(true)}>
                    Delete
                  </Button>
                </div>
              )}
            </div>
          </Card>
        </div>
      )}
    </div>
  );
}
