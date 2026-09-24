import { motion } from 'motion/react';
import { ArrowRight, FolderPlus, SquarePen } from 'lucide-react';
import { useApp } from '../store/app';
import { Button, Kbd, StatusDot, STATUS_WORDS, relativeTime } from '../ui';
import { dragRegion } from './windowDrag';

export function Home() {
  const projects = useApp((s) => s.projects);
  const sessions = useApp((s) => s.sessions);
  const openNewChat = useApp((s) => s.openNewChat);
  const setAddProjectOpen = useApp((s) => s.setAddProjectOpen);
  const selectSession = useApp((s) => s.selectSession);
  const recent = sessions.filter((s) => !s.archived_at).slice(0, 6);
  const hasProjects = projects.length > 0;

  return (
    <div className="flex h-full flex-col">
      <div {...dragRegion} className="h-12 shrink-0" />
      <div className="flex min-h-0 flex-1 flex-col items-center overflow-y-auto px-8 pb-12">
        <motion.div
          initial={{ opacity: 0, y: 10 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.4, ease: [0.22, 1, 0.36, 1] }}
          className="mt-[12vh] flex w-full max-w-[640px] flex-col items-center"
        >
          <div
            className="mb-6 flex h-14 w-14 items-center justify-center rounded-[16px]"
            style={{
              background: 'linear-gradient(160deg, var(--bt-surface-4), var(--bt-surface-2))',
              color: 'var(--bt-accent)',
              boxShadow: 'inset 0 0 0 1px var(--bt-border-strong), inset 0 1px 0 var(--bt-highlight), 0 20px 50px -20px color-mix(in srgb, var(--bt-accent) 45%, transparent)',
            }}
          >
            <AbstractMark />
          </div>
          <h1 className="text-center text-[24px] font-semibold tracking-[-0.02em]" style={{ color: 'var(--bt-text)' }}>
            {hasProjects ? 'What should we build?' : 'Welcome to Abstract'}
          </h1>
          <p className="mt-2 max-w-[46ch] text-center text-[13.5px] leading-relaxed" style={{ color: 'var(--bt-text-faint)' }}>
            {hasProjects
              ? 'Every chat runs its own agent in an isolated worktree, so several can work at once without stepping on each other.'
              : 'Add a git repository to start. Agents work in their own worktrees and you review every change before it lands.'}
          </p>

          {hasProjects ? (
            <button
              onClick={() => openNewChat(null)}
              className="group mt-8 flex w-full items-center gap-3 rounded-[14px] px-4 py-4 text-left transition-[box-shadow,background] duration-200"
              style={{ background: 'var(--bt-elevated)', boxShadow: '0 0 0 1px var(--bt-border-strong), 0 20px 50px -24px rgb(0 0 0 / 0.9)' }}
            >
              <SquarePen size={16} style={{ color: 'var(--bt-text-faint)' }} />
              <span className="flex-1 text-[14px]" style={{ color: 'var(--bt-text-faint)' }}>
                Describe a task…
              </span>
              <Kbd shortcut="mod+n" />
            </button>
          ) : (
            <Button variant="primary" size="lg" className="mt-8" icon={<FolderPlus size={15} />} onClick={() => setAddProjectOpen(true)}>
              Add a project
            </Button>
          )}

          {recent.length ? (
            <div className="mt-10 w-full">
              <p className="mb-2 px-1 text-[11.5px] font-medium" style={{ color: 'var(--bt-text-faint)' }}>
                Recent
              </p>
              <div className="grid grid-cols-2 gap-2">
                {recent.map((s, i) => (
                  <motion.button
                    key={s.id}
                    initial={{ opacity: 0, y: 6 }}
                    animate={{ opacity: 1, y: 0 }}
                    transition={{ delay: 0.05 + i * 0.03, duration: 0.3, ease: [0.22, 1, 0.36, 1] }}
                    onClick={() => void selectSession(s.id)}
                    className="group flex flex-col gap-1.5 rounded-[12px] px-3.5 py-3 text-left transition-colors hover:bg-[var(--bt-surface-2)]"
                    style={{ background: 'var(--bt-surface)', boxShadow: 'inset 0 0 0 1px var(--bt-border)' }}
                  >
                    <span className="flex items-center gap-2">
                      <StatusDot status={s.status} />
                      <span className="truncate text-[13px]" style={{ color: 'var(--bt-text)' }}>
                        {s.name}
                      </span>
                    </span>
                    <span className="flex items-center gap-1 text-[11.5px]" style={{ color: 'var(--bt-text-faint)' }}>
                      {projects.find((p) => p.id === s.project_id)?.name} · {STATUS_WORDS[s.status] ?? s.status} · {relativeTime(s.last_event_at ?? s.created_at)}
                      <ArrowRight size={11} className="ml-auto opacity-0 transition-opacity group-hover:opacity-100" />
                    </span>
                  </motion.button>
                ))}
              </div>
            </div>
          ) : null}

          <div className="mt-10 flex flex-wrap items-center justify-center gap-x-5 gap-y-2 text-[12px]" style={{ color: 'var(--bt-text-ghost)' }}>
            <span className="flex items-center gap-1.5"><Kbd shortcut="mod+k" /> jump anywhere</span>
            <span className="flex items-center gap-1.5"><Kbd shortcut="mod+n" /> new chat</span>
            <span className="flex items-center gap-1.5"><Kbd shortcut="mod+d" /> review changes</span>
            <span className="flex items-center gap-1.5"><Kbd shortcut="mod+1" /> switch chats</span>
          </div>
        </motion.div>
      </div>
    </div>
  );
}

/** The abstract glyph, drawn rather than typeset so it reads at any size. */
function AbstractMark() {
  return (
    <svg width="22" height="22" viewBox="0 0 24 24" fill="none" aria-hidden>
      <path d="M9 5.5 L14.5 13" stroke="currentColor" strokeWidth="3.2" strokeLinecap="round" />
    </svg>
  );
}
