import { useState } from 'react';
import { useApp } from '../../store/app';
import { Timeline } from '../output/Timeline';
import { DiffView } from '../diff/DiffView';
import { Button, StatusTag, Empty } from '../../app/ui';

export function ChatView({ sessionId }: { sessionId: string }) {
  const session = useApp((s) => s.sessions.find((x) => x.id === sessionId));
  const projects = useApp((s) => s.projects);
  const sendFollowUp = useApp((s) => s.sendFollowUp);
  const stopSession = useApp((s) => s.stopSession);
  const restartSession = useApp((s) => s.restartSession);
  const deleteSession = useApp((s) => s.deleteSession);
  const [tab, setTab] = useState<'chat' | 'diff'>('chat');
  const [draft, setDraft] = useState('');
  const [error, setError] = useState<string | null>(null);

  if (!session) return <Empty title="Chat not found" />;
  const project = projects.find((p) => p.id === session.project_id);

  async function send() {
    const text = draft.trim();
    if (!text || !session) return;
    setDraft('');
    setError(null);
    try {
      await sendFollowUp(session.id, text);
    } catch (e) {
      setError(String(e));
    }
  }

  return (
    <div className="flex h-full min-w-0 flex-col">
      <header
        className="flex shrink-0 items-center gap-3 px-4 py-2"
        style={{ borderBottom: '1px solid var(--bt-border)' }}
      >
        <div className="min-w-0 flex-1">
          <div className="flex items-center gap-2">
            <h1 className="truncate text-sm">{session.name}</h1>
            <StatusTag status={session.status} alive={session.alive} />
          </div>
          <p className="truncate text-xs" style={{ color: 'var(--bt-text-faint)' }}>
            {project ? `${project.name} · ` : ''}
            {session.branch ? `${session.branch} · ` : ''}
            <span className="font-mono">{session.worktree_path}</span>
          </p>
        </div>

        <nav className="flex" style={{ border: '1px solid var(--bt-border)' }}>
          {(['chat', 'diff'] as const).map((t) => (
            <button
              key={t}
              onClick={() => setTab(t)}
              className="px-3 py-1 text-xs"
              style={{
                background: tab === t ? 'var(--bt-surface-3)' : 'transparent',
                color: tab === t ? 'var(--bt-accent)' : 'var(--bt-text-dim)',
              }}
            >
              {t === 'chat' ? 'Chat' : 'Diff'}
            </button>
          ))}
        </nav>

        {session.alive ? (
          <Button onClick={() => void stopSession(session.id)}>Stop</Button>
        ) : (
          <Button onClick={() => void restartSession(session.id)}>Restart</Button>
        )}
        <Button
          variant="danger"
          title="Delete this chat and remove its worktree"
          onClick={() => {
            if (confirm(`Delete "${session.name}" and remove its worktree?`)) {
              void deleteSession(session.id, true, false);
            }
          }}
        >
          Delete
        </Button>
      </header>

      {tab === 'chat' ? (
        <>
          <Timeline sessionId={sessionId} />
          <div className="shrink-0 px-4 pt-2 pb-3" style={{ borderTop: '1px solid var(--bt-border)' }}>
            {error ? (
              <p className="pb-1 text-xs" style={{ color: 'var(--bt-removed)' }}>
                {error}
              </p>
            ) : null}
            <textarea
              rows={2}
              value={draft}
              onChange={(e) => setDraft(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) void send();
              }}
              placeholder="Reply to the agent…  ⌘↵ to send"
              className="w-full resize-none"
              style={{ fontSize: 'var(--bt-ui-size)' }}
            />
          </div>
        </>
      ) : (
        <DiffView sessionId={sessionId} />
      )}
    </div>
  );
}
