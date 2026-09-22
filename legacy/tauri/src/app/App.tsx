import { useEffect } from 'react';
import { AnimatePresence, motion } from 'motion/react';
import { Toaster } from 'sonner';
import { isTauri } from '@tauri-apps/api/core';
import { useApp } from '../store/app';
import { Sidebar } from '../features/projects/Sidebar';
import { AddProjectDialog } from '../features/projects/AddProjectDialog';
import { ChatView } from '../features/sessions/ChatView';
import { NewChatDialog } from '../features/sessions/NewChatDialog';
import { WorktreesView } from '../features/worktrees/WorktreesView';
import { AutomationsView } from '../features/automations/AutomationsView';
import { SettingsView } from '../features/settings/SettingsView';
import { TooltipProvider } from '../ui';
import { CommandPalette } from './CommandPalette';
import { ErrorBoundary } from './ErrorBoundary';
import { Home } from './Home';
import { dragRegion } from './windowDrag';

export function App() {
  const init = useApp((s) => s.init);
  const ready = useApp((s) => s.ready);
  const error = useApp((s) => s.error);
  const view = useApp((s) => s.view);
  const selectedSessionId = useApp((s) => s.selectedSessionId);

  useEffect(() => {
    void init().then(async () => {
      if (!isTauri()) (await import('../lib/mock')).applyUrlState();
    });
  }, [init]);

  useGlobalShortcuts();

  if (!ready) {
    return <div {...dragRegion} className="h-full" style={{ background: 'var(--bt-bg)' }} />;
  }

  const key = view === 'chat' ? `chat-${selectedSessionId ?? 'home'}` : view;

  return (
    <TooltipProvider>
      <div className="flex h-full w-full" style={{ background: 'var(--bt-bg)' }}>
        <Sidebar />
        <main className="relative flex min-w-0 flex-1 flex-col">
          {error ? (
            <div className="shrink-0 px-5 py-2 text-[12.5px]" style={{ background: 'var(--bt-removed-soft)', color: 'var(--bt-removed)' }}>
              {error}
            </div>
          ) : null}
          <AnimatePresence mode="wait" initial={false}>
            <motion.div
              key={key}
              className="min-h-0 flex-1"
              initial={{ opacity: 0 }}
              animate={{ opacity: 1 }}
              exit={{ opacity: 0 }}
              transition={{ duration: 0.12 }}
            >
              <ErrorBoundary resetKey={key} label={labelFor(view)}>
                <MainView />
              </ErrorBoundary>
            </motion.div>
          </AnimatePresence>
        </main>
      </div>
      <CommandPalette />
      <NewChatDialog />
      <AddProjectDialog />
      <Toaster position="bottom-right" theme="dark" gap={8} offset={20} />
    </TooltipProvider>
  );
}

function MainView() {
  const view = useApp((s) => s.view);
  const selectedSessionId = useApp((s) => s.selectedSessionId);
  if (view === 'settings') return <WithTitleBar><SettingsView /></WithTitleBar>;
  if (view === 'automations') return <WithTitleBar><AutomationsView /></WithTitleBar>;
  if (view === 'worktrees') return <WorktreesView />;
  if (selectedSessionId) return <ChatView sessionId={selectedSessionId} />;
  return <Home />;
}

/** Views that do not draw their own header still need a draggable strip. */
function WithTitleBar({ children }: { children: React.ReactNode }) {
  return (
    <div className="flex h-full flex-col">
      <div {...dragRegion} className="h-3 shrink-0" />
      <div className="min-h-0 flex-1">{children}</div>
    </div>
  );
}

function labelFor(view: string): string {
  return view === 'chat' ? 'This chat' : `${view.charAt(0).toUpperCase()}${view.slice(1)}`;
}

function useGlobalShortcuts() {
  useEffect(() => {
    function onKey(e: KeyboardEvent) {
      const s = useApp.getState();
      const mod = e.metaKey || e.ctrlKey;
      if (!mod) return;
      const key = e.key.toLowerCase();
      if (key === 'k') {
        e.preventDefault();
        s.setPaletteOpen(!s.paletteOpen);
      } else if (key === 'n') {
        e.preventDefault();
        s.openNewChat(s.sessions.find((x) => x.id === s.selectedSessionId)?.project_id ?? null);
      } else if (key === ',') {
        e.preventDefault();
        s.setView('settings');
      } else if (key === 'd' && s.selectedSessionId) {
        e.preventDefault();
        s.setChatTab(s.chatTab === 'diff' && s.view === 'chat' ? 'chat' : 'diff');
      } else if (/^[1-9]$/.test(key)) {
        const target = s.sessions.filter((x) => !x.archived_at)[Number(key) - 1];
        if (target) {
          e.preventDefault();
          void s.selectSession(target.id);
        }
      }
    }
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, []);
}
