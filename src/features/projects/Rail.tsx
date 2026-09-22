import { useMemo, useState } from 'react';
import { useApp } from '../../store/app';
import type { Project, Session } from '../../lib/types';
import { Button, StatusTag, relativeTime } from '../../app/ui';
import { AddProjectDialog } from './AddProjectDialog';

/**
 * The rail is the app's spine: every chat lives inside the folder of the
 * project it belongs to. "Attention" floats chats that need the developer
 * across every project.
 */
export function Rail({ onNewChat }: { onNewChat: (projectId: string | null) => void }) {
  const projects = useApp((s) => s.projects);
  const sessions = useApp((s) => s.sessions);
  const automations = useApp((s) => s.automations);
  const selectedSessionId = useApp((s) => s.selectedSessionId);
  const selectSession = useApp((s) => s.selectSession);
  const setView = useApp((s) => s.setView);
  const view = useApp((s) => s.view);
  const collapsed = useApp((s) => s.collapsedProjects);
  const toggleProject = useApp((s) => s.toggleProject);
  const showArchived = useApp((s) => s.showArchived);
  const setShowArchived = useApp((s) => s.setShowArchived);
  const [adding, setAdding] = useState(false);

  const byProject = useMemo(() => {
    const map = new Map<string, Session[]>();
    for (const s of sessions) {
      if (s.archived_at && !showArchived) continue;
      const key = s.project_id ?? '__none__';
      const list = map.get(key) ?? [];
      list.push(s);
      map.set(key, list);
    }
    return map;
  }, [sessions, showArchived]);

  const attention = sessions.filter((s) => s.status === 'waiting_input' && !s.archived_at);
  const scratch = byProject.get('__none__') ?? [];

  return (
    <div
      className="flex h-full w-72 shrink-0 flex-col"
      style={{ background: 'var(--bt-surface)', borderRight: '1px solid var(--bt-border)' }}
    >
      <div className="bt-drag h-9 shrink-0" />

      <div className="min-h-0 flex-1 overflow-y-auto">
        {attention.length > 0 ? (
          <Section label="Attention">
            {attention.map((s) => (
              <SessionRow
                key={s.id}
                session={s}
                selected={s.id === selectedSessionId}
                onSelect={() => void selectSession(s.id)}
                showProject={projects.find((p) => p.id === s.project_id)?.name}
              />
            ))}
          </Section>
        ) : null}

        {projects.map((p) => (
          <ProjectFolder
            key={p.id}
            project={p}
            sessions={byProject.get(p.id) ?? []}
            collapsed={!!collapsed[p.id]}
            onToggle={() => toggleProject(p.id)}
            selectedSessionId={selectedSessionId}
            onSelect={(id) => void selectSession(id)}
            onNewChat={() => onNewChat(p.id)}
          />
        ))}

        {scratch.length > 0 ? (
          <Section label="Scratch">
            {scratch.map((s) => (
              <SessionRow
                key={s.id}
                session={s}
                selected={s.id === selectedSessionId}
                onSelect={() => void selectSession(s.id)}
              />
            ))}
          </Section>
        ) : null}

        {projects.length === 0 ? (
          <p className="px-3 py-4 text-xs" style={{ color: 'var(--bt-text-faint)' }}>
            No projects yet. Add a git repository to start running agents in worktrees.
          </p>
        ) : null}
      </div>

      <div className="shrink-0 border-t" style={{ borderColor: 'var(--bt-border)' }}>
        <RailButton
          label={`Automations${automations.length ? ` (${automations.length})` : ''}`}
          active={view === 'automations'}
          onClick={() => setView('automations')}
        />
        <RailButton
          label="Worktrees"
          active={view === 'worktrees'}
          onClick={() => setView('worktrees')}
        />
        <RailButton label="Settings" active={view === 'settings'} onClick={() => setView('settings')} />
        <div className="flex items-center justify-between px-3 py-2">
          <Button onClick={() => setAdding(true)}>Add project</Button>
          <button
            className="text-xs"
            style={{ color: 'var(--bt-text-faint)' }}
            onClick={() => setShowArchived(!showArchived)}
          >
            {showArchived ? 'Hide archived' : 'Show archived'}
          </button>
        </div>
      </div>

      {adding ? <AddProjectDialog onClose={() => setAdding(false)} /> : null}
    </div>
  );
}

function Section({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className="pb-1">
      <div
        className="px-3 pt-3 pb-1 text-[11px] tracking-wide uppercase"
        style={{ color: 'var(--bt-text-faint)' }}
      >
        {label}
      </div>
      {children}
    </div>
  );
}

function ProjectFolder({
  project,
  sessions,
  collapsed,
  onToggle,
  selectedSessionId,
  onSelect,
  onNewChat,
}: {
  project: Project;
  sessions: Session[];
  collapsed: boolean;
  onToggle: () => void;
  selectedSessionId: string | null;
  onSelect: (id: string) => void;
  onNewChat: () => void;
}) {
  const running = sessions.filter((s) => s.status === 'running').length;
  const needsYou = sessions.some((s) => s.status === 'waiting_input');

  return (
    <div>
      <div
        className="group flex items-center gap-2 px-3 py-2"
        style={{ color: 'var(--bt-text)' }}
      >
        <button onClick={onToggle} className="flex min-w-0 flex-1 items-center gap-2 text-left">
          <span className="text-xs" style={{ color: 'var(--bt-text-faint)' }}>
            {collapsed ? '▸' : '▾'}
          </span>
          <span className="truncate text-sm">{project.name}</span>
          {needsYou ? (
            <span
              aria-label="needs attention"
              style={{ width: 6, height: 6, background: 'var(--bt-accent)' }}
            />
          ) : null}
          {running > 0 ? (
            <span className="text-xs" style={{ color: 'var(--bt-text-faint)' }}>
              {running}
            </span>
          ) : null}
        </button>
        <span
          className="shrink-0 px-1 text-[10px]"
          style={{ color: 'var(--bt-text-faint)', border: '1px solid var(--bt-border)' }}
        >
          {project.executor === 'ssh' ? `ssh: ${project.ssh_host}` : 'local'}
        </span>
        <button
          onClick={onNewChat}
          title="New chat in this project"
          className="opacity-0 group-hover:opacity-100"
          style={{ color: 'var(--bt-text-dim)' }}
        >
          +
        </button>
      </div>

      {!collapsed ? (
        <div>
          {sessions.length === 0 ? (
            <p className="px-3 pb-2 pl-7 text-xs" style={{ color: 'var(--bt-text-faint)' }}>
              No chats yet.
            </p>
          ) : (
            sessions.map((s) => (
              <SessionRow
                key={s.id}
                session={s}
                selected={s.id === selectedSessionId}
                onSelect={() => onSelect(s.id)}
              />
            ))
          )}
        </div>
      ) : null}
    </div>
  );
}

function SessionRow({
  session,
  selected,
  onSelect,
  showProject,
}: {
  session: Session;
  selected: boolean;
  onSelect: () => void;
  showProject?: string;
}) {
  return (
    <button
      onClick={onSelect}
      className="flex w-full flex-col gap-0.5 py-[var(--bt-row-py)] pr-3 pl-7 text-left"
      style={{
        background: selected ? 'var(--bt-surface-3)' : 'transparent',
        borderLeft: selected ? '2px solid var(--bt-accent)' : '2px solid transparent',
      }}
    >
      <span className="flex items-center gap-2">
        {session.automation_id ? (
          <span title="Created by an automation" style={{ color: 'var(--bt-text-faint)' }}>
            ◷
          </span>
        ) : null}
        <span className="truncate text-sm" style={{ color: 'var(--bt-text)' }}>
          {session.name}
        </span>
      </span>
      <span className="flex items-center gap-2">
        <StatusTag status={session.status} alive={session.alive} />
        <span className="text-[11px]" style={{ color: 'var(--bt-text-faint)' }}>
          {session.provider_id}
          {showProject ? ` · ${showProject}` : ''} · {relativeTime(session.last_event_at ?? session.created_at)}
        </span>
      </span>
    </button>
  );
}

function RailButton({
  label,
  active,
  onClick,
}: {
  label: string;
  active: boolean;
  onClick: () => void;
}) {
  return (
    <button
      onClick={onClick}
      className="w-full px-3 py-1.5 text-left text-sm"
      style={{
        color: active ? 'var(--bt-accent)' : 'var(--bt-text-dim)',
        background: active ? 'var(--bt-surface-2)' : 'transparent',
      }}
    >
      {label}
    </button>
  );
}
