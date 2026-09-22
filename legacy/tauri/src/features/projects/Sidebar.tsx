import { useMemo, useState } from 'react';
import { AnimatePresence, motion } from 'motion/react';
import {
  Archive,
  ArchiveRestore,
  ChevronRight,
  Clock3,
  FolderGit2,
  GitBranch,
  MoreHorizontal,
  Pencil,
  Plus,
  Search,
  Settings,
  SquarePen,
  Trash2,
  Zap,
} from 'lucide-react';
import { useApp } from '../../store/app';
import type { Project, Session } from '../../lib/types';
import {
  IconButton,
  Kbd,
  Menu,
  MenuItem,
  MenuSeparator,
  StatusDot,
  STATUS_WORDS,
  Tooltip,
  cn,
  relativeTime,
} from '../../ui';
import { dragRegion, isMac } from '../../app/windowDrag';

export function Sidebar() {
  const projects = useApp((s) => s.projects);
  const sessions = useApp((s) => s.sessions);
  const automations = useApp((s) => s.automations);
  const view = useApp((s) => s.view);
  const setView = useApp((s) => s.setView);
  const showArchived = useApp((s) => s.showArchived);
  const setShowArchived = useApp((s) => s.setShowArchived);
  const openNewChat = useApp((s) => s.openNewChat);
  const setPaletteOpen = useApp((s) => s.setPaletteOpen);
  const setAddProjectOpen = useApp((s) => s.setAddProjectOpen);

  const byProject = useMemo(() => {
    const map = new Map<string, Session[]>();
    for (const s of sessions) {
      if (s.archived_at && !showArchived) continue;
      const key = s.project_id ?? '__scratch__';
      const list = map.get(key) ?? [];
      list.push(s);
      map.set(key, list);
    }
    return map;
  }, [sessions, showArchived]);

  const attention = useMemo(
    () => sessions.filter((s) => s.status === 'waiting_input' && !s.archived_at),
    [sessions],
  );
  const scratch = byProject.get('__scratch__') ?? [];
  const activeAutomations = automations.filter((a) => a.enabled).length;
  const archivedCount = sessions.filter((s) => s.archived_at).length;

  return (
    <aside
      className="flex h-full w-[272px] shrink-0 flex-col"
      style={{ background: 'var(--bt-surface)', boxShadow: 'inset -1px 0 0 var(--bt-border)' }}
    >
      {/* title bar row: traffic lights live on the left on macOS */}
      <div {...dragRegion} className={cn('flex h-12 shrink-0 items-center gap-1 pr-2', isMac ? 'pl-[84px]' : 'pl-3')}>
        <div className="flex-1" />
        <IconButton label="Search" shortcut="mod+k" onClick={() => setPaletteOpen(true)}>
          <Search size={15} />
        </IconButton>
        <IconButton label="New chat" shortcut="mod+n" onClick={() => openNewChat(null)}>
          <SquarePen size={15} />
        </IconButton>
      </div>

      <div className="px-2.5 pb-2">
        <button
          onClick={() => setPaletteOpen(true)}
          className="group flex h-8 w-full items-center gap-2 rounded-[8px] px-2.5 text-[12.5px] transition-colors"
          style={{ background: 'var(--bt-surface-2)', color: 'var(--bt-text-faint)', boxShadow: 'inset 0 0 0 1px var(--bt-border)' }}
        >
          <Search size={13} />
          <span className="flex-1 text-left group-hover:text-[var(--bt-text-dim)]">Jump to…</span>
          <Kbd shortcut="mod+k" />
        </button>
      </div>

      <nav className="min-h-0 flex-1 overflow-y-auto px-2 pb-3">
        <AnimatePresence initial={false}>
          {attention.length > 0 ? (
            <motion.div
              key="attention"
              initial={{ opacity: 0, height: 0 }}
              animate={{ opacity: 1, height: 'auto' }}
              exit={{ opacity: 0, height: 0 }}
              transition={{ duration: 0.22, ease: [0.22, 1, 0.36, 1] }}
              className="overflow-hidden"
            >
              <SectionLabel>
                Needs you
                <span
                  className="ml-1.5 inline-flex h-4 min-w-4 items-center justify-center rounded-full px-1 text-[10px] font-semibold"
                  style={{ background: 'var(--bt-accent-soft)', color: 'var(--bt-accent)' }}
                >
                  {attention.length}
                </span>
              </SectionLabel>
              {attention.map((s) => (
                <ChatRow key={`att-${s.id}`} session={s} projectName={projects.find((p) => p.id === s.project_id)?.name} layoutGroup="attention" />
              ))}
              <div className="h-2" />
            </motion.div>
          ) : null}
        </AnimatePresence>

        <SectionLabel
          action={
            <IconButton label="Add project" size="xs" onClick={() => setAddProjectOpen(true)}>
              <Plus size={13} />
            </IconButton>
          }
        >
          Projects
        </SectionLabel>

        {projects.length === 0 ? (
          <button
            onClick={() => setAddProjectOpen(true)}
            className="mt-1 flex w-full flex-col items-start gap-1 rounded-[10px] px-3 py-3 text-left transition-colors hover:bg-[var(--bt-hover)]"
            style={{ boxShadow: 'inset 0 0 0 1px var(--bt-border)', borderStyle: 'dashed' }}
          >
            <span className="flex items-center gap-2 text-[13px]" style={{ color: 'var(--bt-text)' }}>
              <FolderGit2 size={14} /> Add a repository
            </span>
            <span className="text-[11.5px] leading-snug" style={{ color: 'var(--bt-text-faint)' }}>
              Each chat runs in its own worktree of it.
            </span>
          </button>
        ) : null}

        {projects.map((p) => (
          <ProjectFolder key={p.id} project={p} sessions={byProject.get(p.id) ?? []} />
        ))}

        {scratch.length > 0 ? (
          <>
            <SectionLabel>Scratch</SectionLabel>
            {scratch.map((s) => (
              <ChatRow key={s.id} session={s} />
            ))}
          </>
        ) : null}

        {archivedCount > 0 ? (
          <button
            onClick={() => setShowArchived(!showArchived)}
            className="mt-3 flex w-full items-center gap-2 rounded-[7px] px-2 py-1 text-[11.5px] transition-colors hover:bg-[var(--bt-hover)]"
            style={{ color: 'var(--bt-text-faint)' }}
          >
            <Archive size={12} />
            {showArchived ? 'Hide archived' : `Show ${archivedCount} archived`}
          </button>
        ) : null}
      </nav>

      <div className="flex flex-col gap-0.5 px-2 py-2" style={{ boxShadow: 'inset 0 1px 0 var(--bt-border)' }}>
        <NavItem icon={<Zap size={14} />} label="Automations" active={view === 'automations'} onClick={() => setView('automations')} count={activeAutomations || undefined} />
        <NavItem icon={<GitBranch size={14} />} label="Worktrees" active={view === 'worktrees'} onClick={() => setView('worktrees')} />
        <NavItem icon={<Settings size={14} />} label="Settings" active={view === 'settings'} onClick={() => setView('settings')} shortcut="mod+," />
      </div>
    </aside>
  );
}

function SectionLabel({ children, action }: { children: React.ReactNode; action?: React.ReactNode }) {
  return (
    <div className="flex h-7 items-center px-2 pt-2">
      <span className="flex flex-1 items-center text-[11px] font-medium tracking-[0.02em]" style={{ color: 'var(--bt-text-faint)' }}>
        {children}
      </span>
      {action}
    </div>
  );
}

function ProjectAvatar({ name }: { name: string }) {
  return (
    <span
      className="inline-flex h-[18px] w-[18px] shrink-0 items-center justify-center rounded-[5px] text-[10px] font-semibold uppercase"
      style={{
        background: 'linear-gradient(180deg, var(--bt-surface-4), var(--bt-surface-3))',
        color: 'var(--bt-text-dim)',
        boxShadow: 'inset 0 0 0 1px var(--bt-border-strong), inset 0 1px 0 var(--bt-highlight)',
      }}
    >
      {name.slice(0, 1)}
    </span>
  );
}

function ProjectFolder({ project, sessions }: { project: Project; sessions: Session[] }) {
  const collapsed = useApp((s) => !!s.collapsedProjects[project.id]);
  const toggle = useApp((s) => s.toggleProject);
  const openNewChat = useApp((s) => s.openNewChat);
  const setView = useApp((s) => s.setView);
  const running = sessions.filter((s) => s.status === 'running').length;
  const needsYou = sessions.some((s) => s.status === 'waiting_input');

  return (
    <div className="mt-0.5">
      <div className="group relative flex h-8 items-center rounded-[8px] transition-colors hover:bg-[var(--bt-hover)]">
        <button onClick={() => toggle(project.id)} className="flex h-full min-w-0 flex-1 items-center gap-2 pl-1.5 pr-1 text-left">
          <motion.span
            animate={{ rotate: collapsed ? 0 : 90 }}
            transition={{ duration: 0.18, ease: [0.22, 1, 0.36, 1] }}
            className="flex shrink-0"
            style={{ color: 'var(--bt-text-ghost)' }}
          >
            <ChevronRight size={13} />
          </motion.span>
          <ProjectAvatar name={project.name} />
          <span className="truncate text-[13px] font-medium" style={{ color: 'var(--bt-text)' }}>
            {project.name}
          </span>
          {project.executor === 'ssh' ? (
            <span className="shrink-0 text-[10.5px]" style={{ color: 'var(--bt-text-faint)' }}>
              ssh
            </span>
          ) : null}
        </button>

        <div className="flex shrink-0 items-center gap-1 pr-1">
          {needsYou ? <StatusDot status="waiting_input" size={6} /> : null}
          {running > 0 ? (
            <span className="text-[11px] tabular-nums group-hover:hidden" style={{ color: 'var(--bt-text-faint)' }}>
              {running}
            </span>
          ) : null}
          <div className="hidden items-center group-hover:flex group-focus-within:flex">
            <Menu
              trigger={
                <button
                  aria-label={`${project.name} options`}
                  className="inline-flex h-6 w-6 items-center justify-center rounded-[6px] text-[var(--bt-text-faint)] hover:bg-[var(--bt-active)] hover:text-[var(--bt-text)]"
                >
                  <MoreHorizontal size={14} />
                </button>
              }
            >
              <MenuItem icon={<SquarePen size={14} />} onSelect={() => openNewChat(project.id)}>
                New chat
              </MenuItem>
              <MenuItem icon={<GitBranch size={14} />} onSelect={() => setView('worktrees')}>
                Worktrees
              </MenuItem>
            </Menu>
            <Tooltip label={`New chat in ${project.name}`}>
              <button
                aria-label={`New chat in ${project.name}`}
                onClick={() => openNewChat(project.id)}
                className="inline-flex h-6 w-6 items-center justify-center rounded-[6px] text-[var(--bt-text-faint)] hover:bg-[var(--bt-active)] hover:text-[var(--bt-text)]"
              >
                <Plus size={14} />
              </button>
            </Tooltip>
          </div>
        </div>
      </div>

      <AnimatePresence initial={false}>
        {!collapsed ? (
          <motion.div
            initial={{ height: 0, opacity: 0 }}
            animate={{ height: 'auto', opacity: 1 }}
            exit={{ height: 0, opacity: 0 }}
            transition={{ duration: 0.22, ease: [0.22, 1, 0.36, 1] }}
            className="overflow-hidden"
          >
            <div className="relative ml-[15px] flex flex-col gap-px border-l pl-1.5" style={{ borderColor: 'var(--bt-border)' }}>
              {sessions.length === 0 ? (
                <button
                  onClick={() => openNewChat(project.id)}
                  className="flex h-7 items-center gap-2 rounded-[7px] px-2 text-[12px] transition-colors hover:bg-[var(--bt-hover)]"
                  style={{ color: 'var(--bt-text-faint)' }}
                >
                  <Plus size={12} /> Start a chat
                </button>
              ) : (
                sessions.map((s) => <ChatRow key={s.id} session={s} />)
              )}
            </div>
          </motion.div>
        ) : null}
      </AnimatePresence>
    </div>
  );
}

function ChatRow({ session, projectName, layoutGroup = 'tree' }: { session: Session; projectName?: string; layoutGroup?: string }) {
  const selected = useApp((s) => s.selectedSessionId === session.id && s.view === 'chat');
  const selectSession = useApp((s) => s.selectSession);
  const renameSession = useApp((s) => s.renameSession);
  const archiveSession = useApp((s) => s.archiveSession);
  const deleteSession = useApp((s) => s.deleteSession);
  const [renaming, setRenaming] = useState(false);
  const [draft, setDraft] = useState(session.name);

  const meta = [
    STATUS_WORDS[session.status] ?? session.status,
    projectName,
    relativeTime(session.last_event_at ?? session.created_at),
  ].filter(Boolean);

  async function commitRename() {
    setRenaming(false);
    const name = draft.trim();
    if (name && name !== session.name) await renameSession(session.id, name);
  }

  return (
    <div className="group relative">
      {selected ? (
        <motion.div
          layoutId={`chat-selection-${layoutGroup}`}
          className="absolute inset-0 rounded-[8px]"
          style={{ background: 'var(--bt-active)', boxShadow: 'inset 0 1px 0 var(--bt-highlight)' }}
          transition={{ type: 'spring', stiffness: 520, damping: 42 }}
        />
      ) : null}
      <button
        onClick={() => void selectSession(session.id)}
        onDoubleClick={() => {
          setDraft(session.name);
          setRenaming(true);
        }}
        className={cn(
          'relative flex w-full items-start gap-2.5 rounded-[8px] px-2 py-[var(--bt-row-py)] text-left transition-colors',
          !selected && 'hover:bg-[var(--bt-hover)]',
          session.archived_at && 'opacity-55',
        )}
      >
        <span className="mt-[6px] flex">
          <StatusDot status={session.status} />
        </span>
        <span className="min-w-0 flex-1">
          {renaming ? (
            <input
              autoFocus
              value={draft}
              onChange={(e) => setDraft(e.target.value)}
              onBlur={() => void commitRename()}
              onClick={(e) => e.stopPropagation()}
              onKeyDown={(e) => {
                if (e.key === 'Enter') void commitRename();
                if (e.key === 'Escape') setRenaming(false);
              }}
              className="bt-input h-6 w-full px-1.5 text-[13px]"
            />
          ) : (
            <span
              className="block truncate text-[13px] leading-[1.35]"
              style={{ color: selected ? 'var(--bt-text)' : 'color-mix(in srgb, var(--bt-text) 88%, transparent)' }}
            >
              {session.name}
            </span>
          )}
          <span className="mt-0.5 flex items-center gap-1 truncate text-[11.5px]" style={{ color: 'var(--bt-text-faint)' }}>
            {session.automation_id ? <Clock3 size={10.5} className="shrink-0" /> : null}
            <span className="truncate">{meta.join(' · ')}</span>
          </span>
        </span>
      </button>

      <div className="absolute right-1 top-1.5 hidden group-hover:block has-[[data-state=open]]:block">
        <Menu
          trigger={
            <button
              aria-label="Chat options"
              className="inline-flex h-6 w-6 items-center justify-center rounded-[6px] text-[var(--bt-text-faint)] hover:bg-[var(--bt-active)] hover:text-[var(--bt-text)]"
              style={{ background: 'var(--bt-surface-3)' }}
            >
              <MoreHorizontal size={14} />
            </button>
          }
        >
          <MenuItem
            icon={<Pencil size={14} />}
            onSelect={() => {
              setDraft(session.name);
              setRenaming(true);
            }}
          >
            Rename
          </MenuItem>
          <MenuItem
            icon={session.archived_at ? <ArchiveRestore size={14} /> : <Archive size={14} />}
            onSelect={() => void archiveSession(session.id, !session.archived_at)}
          >
            {session.archived_at ? 'Unarchive' : 'Archive'}
          </MenuItem>
          <MenuSeparator />
          <MenuItem
            danger
            icon={<Trash2 size={14} />}
            onSelect={() => {
              if (confirm(`Delete “${session.name}” and remove its worktree?`)) void deleteSession(session.id, true, false);
            }}
          >
            Delete chat and worktree
          </MenuItem>
        </Menu>
      </div>
    </div>
  );
}

function NavItem({
  icon,
  label,
  active,
  onClick,
  count,
  shortcut,
}: {
  icon: React.ReactNode;
  label: string;
  active: boolean;
  onClick: () => void;
  count?: number;
  shortcut?: string;
}) {
  return (
    <button
      onClick={onClick}
      className={cn(
        'group flex h-8 w-full items-center gap-2.5 rounded-[8px] px-2 text-[13px] transition-colors',
        active ? 'bg-[var(--bt-active)] text-[var(--bt-text)]' : 'text-[var(--bt-text-dim)] hover:bg-[var(--bt-hover)] hover:text-[var(--bt-text)]',
      )}
    >
      <span className={cn('flex', active ? 'text-[var(--bt-text)]' : 'text-[var(--bt-text-faint)] group-hover:text-[var(--bt-text-dim)]')}>{icon}</span>
      <span className="flex-1 text-left">{label}</span>
      {count ? (
        <span className="text-[11px] tabular-nums" style={{ color: 'var(--bt-text-faint)' }}>
          {count}
        </span>
      ) : null}
      {shortcut ? <Kbd shortcut={shortcut} className="opacity-0 transition-opacity group-hover:opacity-100" /> : null}
    </button>
  );
}
