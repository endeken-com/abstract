import { useEffect, useState, type JSX } from 'react';
import { automations as automationsIpc } from '../../lib/ipc';
import type { AutomationRun } from '../../lib/types';
import { useApp } from '../../store/app';
import { Card, Muted, StatusWord, type Tone } from './ui';
import { formatClock, formatRelative } from './format';

export function runTone(status: AutomationRun['status']): Tone {
  if (status === 'created') return 'ok';
  if (status === 'failed') return 'bad';
  return 'warn';
}

export function runWord(status: AutomationRun['status']): string {
  if (status === 'created') return 'created';
  if (status === 'failed') return 'failed';
  return 'creating';
}

export function RunHistory({
  automationId,
  reloadKey = 0,
}: {
  automationId: string;
  reloadKey?: number;
}): JSX.Element {
  const selectSession = useApp((s) => s.selectSession);
  const setView = useApp((s) => s.setView);
  const [runs, setRuns] = useState<AutomationRun[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    automationsIpc
      .runs(automationId)
      .then((rows) => {
        if (cancelled) return;
        setRuns(rows);
        setError(null);
      })
      .catch((e: unknown) => {
        if (!cancelled) setError(String(e));
      })
      .finally(() => {
        if (!cancelled) setLoading(false);
      });
    return () => {
      cancelled = true;
    };
  }, [automationId, reloadKey]);

  const openSession = (sessionId: string) => {
    void selectSession(sessionId).then(() => setView('chat'));
  };

  return (
    <div className="flex flex-col gap-5">
      <Card className="p-0">
        {error ? (
          <p className="p-5 m-0" style={{ color: 'var(--bt-removed)' }}>
            Could not read run history — {error}
          </p>
        ) : loading ? (
          <p className="p-5 m-0" style={{ color: 'var(--bt-text-faint)' }}>
            Reading run history…
          </p>
        ) : runs.length === 0 ? (
          <p className="p-5 m-0" style={{ color: 'var(--bt-text-faint)' }}>
            No runs yet. The first one appears here as soon as this automation fires.
          </p>
        ) : (
          <ul className="list-none m-0 p-0">
            {runs.map((run, index) => {
              const sessionId = run.session_id;
              return (
              <li
                key={run.id}
                className="px-5 py-4 flex flex-col gap-2"
                style={{
                  borderTop: index === 0 ? undefined : '1px solid var(--bt-border)',
                }}
              >
                <div className="flex flex-wrap items-center justify-between gap-x-4 gap-y-1">
                  <span className="flex flex-wrap items-center gap-2">
                    <span style={{ color: 'var(--bt-text)' }}>Ran {formatClock(run.fired_at)}</span>
                    <span style={{ color: 'var(--bt-text-faint)' }}>·</span>
                    <StatusWord tone={runTone(run.status)}>{runWord(run.status)}</StatusWord>
                    <span style={{ color: 'var(--bt-text-faint)' }}>·</span>
                    <span style={{ color: 'var(--bt-text-dim)' }}>
                      {run.trigger === 'manual' ? 'manual' : 'on schedule'}
                    </span>
                  </span>
                  <span style={{ color: 'var(--bt-text-faint)' }}>
                    {formatRelative(run.fired_at)}
                  </span>
                </div>

                {sessionId ? (
                  <button
                    type="button"
                    className="self-start underline underline-offset-2"
                    style={{ color: 'var(--bt-accent)' }}
                    onClick={() => openSession(sessionId)}
                  >
                    Open the session this run created
                  </button>
                ) : null}

                {run.error ? (
                  <p
                    className="m-0 px-3 py-2 font-mono break-words"
                    style={{
                      background: 'var(--bt-surface-2)',
                      border: '1px solid var(--bt-border)',
                      color: 'var(--bt-removed)',
                      fontSize: 'var(--bt-code-size)',
                    }}
                  >
                    {run.error}
                  </p>
                ) : null}
              </li>
              );
            })}
          </ul>
        )}
      </Card>

      <Muted>
        A run counts as created once its workspace exists and the agent was launched. Whether the
        agent's work actually succeeded is shown on the session itself, not here.
      </Muted>
    </div>
  );
}
