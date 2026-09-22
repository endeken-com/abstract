import { useEffect, useState, type JSX } from 'react';
import { automations as automationsIpc } from '../../lib/ipc';
import type { Automation, AutomationRun } from '../../lib/types';
import { useApp } from '../../store/app';
import { Dot, StatusWord } from './ui';
import { runTone, runWord } from './RunHistory';
import { formatRelative } from './format';

/**
 * The most recent run per automation, so the list can say how the last fire
 * went without opening anything. One small call per automation, refreshed when
 * the set of automations changes.
 */
function useLastRuns(automations: Automation[]): Record<string, AutomationRun | undefined> {
  const [lastRuns, setLastRuns] = useState<Record<string, AutomationRun | undefined>>({});
  const key = automations.map((a) => `${a.id}:${a.updated_at}`).join('|');

  useEffect(() => {
    let cancelled = false;
    // `key` is the dependency; the ids come from the current list.
    const ids = automations.map((a) => a.id);
    if (ids.length === 0) {
      setLastRuns({});
      return;
    }
    Promise.all(
      ids.map((id) =>
        automationsIpc
          .runs(id, 1)
          .then((rows) => [id, rows[0]] as const)
          .catch(() => [id, undefined] as const),
      ),
    ).then((pairs) => {
      if (cancelled) return;
      const next: Record<string, AutomationRun | undefined> = {};
      for (const [id, run] of pairs) next[id] = run;
      setLastRuns(next);
    });
    return () => {
      cancelled = true;
    };
  }, [key]);

  return lastRuns;
}

export function AutomationList({
  creating,
  onNew,
  onSelect,
}: {
  creating: boolean;
  onNew: () => void;
  onSelect: (id: string) => void;
}): JSX.Element {
  const automations = useApp((s) => s.automations);
  const projects = useApp((s) => s.projects);
  const selectedId = useApp((s) => s.selectedAutomationId);
  const lastRuns = useLastRuns(automations);

  return (
    <div
      className="w-80 shrink-0 flex flex-col h-full min-h-0"
      style={{ borderRight: '1px solid var(--bt-border)', background: 'var(--bt-surface)' }}
    >
      <div
        className="p-3 flex items-center justify-between gap-3"
        style={{ borderBottom: '1px solid var(--bt-border)' }}
      >
        <span style={{ color: 'var(--bt-text-faint)' }}>
          Automations{automations.length > 0 ? ` · ${automations.length}` : ''}
        </span>
        <button
          type="button"
          onClick={onNew}
          className="px-2.5 py-1"
          style={{
            background: creating ? 'var(--bt-surface-3)' : 'var(--bt-surface-2)',
            border: `1px solid ${creating ? 'var(--bt-accent)' : 'var(--bt-border-strong)'}`,
            color: creating ? 'var(--bt-accent)' : 'var(--bt-text)',
          }}
        >
          New automation
        </button>
      </div>

      <div className="flex-1 min-h-0 overflow-y-auto">
        {automations.length === 0 ? (
          <p className="p-4 m-0" style={{ color: 'var(--bt-text-faint)' }}>
            Nothing scheduled yet.
          </p>
        ) : (
          <ul className="list-none m-0 p-0">
            {automations.map((automation) => {
              const active = automation.id === selectedId && !creating;
              const projectName =
                projects.find((p) => p.id === automation.project_id)?.name ?? 'No project';
              const lastRun = lastRuns[automation.id];
              return (
                <li key={automation.id}>
                  <button
                    type="button"
                    onClick={() => onSelect(automation.id)}
                    aria-current={active ? 'true' : undefined}
                    className="w-full text-left px-4 flex flex-col gap-1"
                    style={{
                      paddingTop: 'calc(var(--bt-row-py) * 2)',
                      paddingBottom: 'calc(var(--bt-row-py) * 2)',
                      background: active ? 'var(--bt-surface-3)' : 'transparent',
                      borderLeft: `2px solid ${active ? 'var(--bt-accent)' : 'transparent'}`,
                      borderBottom: '1px solid var(--bt-border)',
                    }}
                  >
                    <span className="flex items-center gap-2 min-w-0">
                      <Dot tone={automation.enabled ? 'accent' : 'off'} />
                      <span className="truncate" style={{ color: 'var(--bt-text)' }}>
                        {automation.name}
                      </span>
                    </span>
                    <span className="truncate" style={{ color: 'var(--bt-text-dim)' }}>
                      {projectName}
                    </span>
                    <span className="flex flex-wrap items-center gap-x-2 gap-y-0.5">
                      <span style={{ color: 'var(--bt-text-faint)' }}>
                        {automation.enabled
                          ? `Next ${formatRelative(automation.next_run_at)}`
                          : 'Paused'}
                      </span>
                      {lastRun ? (
                        <>
                          <span style={{ color: 'var(--bt-text-faint)' }}>·</span>
                          <StatusWord tone={runTone(lastRun.status)}>
                            last run {runWord(lastRun.status)}
                          </StatusWord>
                        </>
                      ) : (
                        <>
                          <span style={{ color: 'var(--bt-text-faint)' }}>·</span>
                          <span style={{ color: 'var(--bt-text-faint)' }}>never run</span>
                        </>
                      )}
                    </span>
                  </button>
                </li>
              );
            })}
          </ul>
        )}
      </div>
    </div>
  );
}
