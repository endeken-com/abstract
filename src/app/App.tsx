import { useEffect, useState } from 'react';
import { useApp } from '../store/app';
import { Rail } from '../features/projects/Rail';
import { ChatView } from '../features/sessions/ChatView';
import { NewChatDialog } from '../features/sessions/NewChatDialog';
import { WorktreesView } from '../features/worktrees/WorktreesView';
import { AutomationsView } from '../features/automations/AutomationsView';
import { SettingsView } from '../features/settings/SettingsView';
import { Empty } from './ui';

export function App() {
  const init = useApp((s) => s.init);
  const ready = useApp((s) => s.ready);
  const error = useApp((s) => s.error);
  const view = useApp((s) => s.view);
  const selectedSessionId = useApp((s) => s.selectedSessionId);
  const sessions = useApp((s) => s.sessions);
  const projects = useApp((s) => s.projects);
  const selectSession = useApp((s) => s.selectSession);
  const [newChatFor, setNewChatFor] = useState<string | null | undefined>(undefined);

  useEffect(() => {
    void init();
  }, [init]);

  // ⌘N for a new chat, ⌘1..9 to jump between chats.
  useEffect(() => {
    function onKey(e: KeyboardEvent) {
      if (!(e.metaKey || e.ctrlKey)) return;
      if (e.key === 'n') {
        e.preventDefault();
        setNewChatFor(null);
        return;
      }
      const n = Number(e.key);
      if (n >= 1 && n <= 9) {
        const target = sessions.filter((s) => !s.archived_at)[n - 1];
        if (target) {
          e.preventDefault();
          void selectSession(target.id);
        }
      }
    }
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [sessions, selectSession]);

  if (!ready) {
    return (
      <div className="flex h-full items-center justify-center" style={{ color: 'var(--bt-text-faint)' }}>
        Starting Backtick…
      </div>
    );
  }

  return (
    <div className="flex h-full w-full">
      <Rail onNewChat={(projectId) => setNewChatFor(projectId)} />

      <main className="flex min-w-0 flex-1 flex-col" style={{ background: 'var(--bt-bg)' }}>
        <div className="bt-drag h-9 shrink-0" />
        {error ? (
          <p className="px-4 py-2 text-xs" style={{ color: 'var(--bt-removed)' }}>
            {error}
          </p>
        ) : null}

        <div className="min-h-0 flex-1">
          {view === 'settings' ? (
            <SettingsView />
          ) : view === 'automations' ? (
            <AutomationsView />
          ) : view === 'worktrees' ? (
            <WorktreesView />
          ) : selectedSessionId ? (
            <ChatView sessionId={selectedSessionId} key={selectedSessionId} />
          ) : (
            <Empty
              title={projects.length ? 'Pick a chat, or start a new one.' : 'Add a project to begin.'}
              hint={projects.length ? 'New chat: ⌘N' : 'Backtick runs each agent in its own git worktree.'}
            />
          )}
        </div>
      </main>

      {newChatFor !== undefined ? (
        <NewChatDialog projectId={newChatFor} onClose={() => setNewChatFor(undefined)} />
      ) : null}
    </div>
  );
}
