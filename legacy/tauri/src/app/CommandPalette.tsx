import { Command } from 'cmdk';
import { AnimatePresence, motion } from 'motion/react';
import * as D from '@radix-ui/react-dialog';
import {
  Archive,
  FolderPlus,
  GitBranch,
  GitCompareArrows,
  MessagesSquare,
  Palette,
  RotateCcw,
  Search,
  Settings,
  Square,
  SquarePen,
  Zap,
} from 'lucide-react';
import type { ReactNode } from 'react';
import { useApp } from '../store/app';
import { Kbd, StatusDot, STATUS_WORDS, relativeTime } from '../ui';

/** ⌘K: jump anywhere, start anything, act on the current chat. */
export function CommandPalette() {
  const open = useApp((s) => s.paletteOpen);
  const setOpen = useApp((s) => s.setPaletteOpen);
  const sessions = useApp((s) => s.sessions);
  const projects = useApp((s) => s.projects);
  const selectedId = useApp((s) => s.selectedSessionId);
  const selectSession = useApp((s) => s.selectSession);
  const openNewChat = useApp((s) => s.openNewChat);
  const setView = useApp((s) => s.setView);
  const setChatTab = useApp((s) => s.setChatTab);
  const setAddProjectOpen = useApp((s) => s.setAddProjectOpen);
  const stopSession = useApp((s) => s.stopSession);
  const restartSession = useApp((s) => s.restartSession);
  const archiveSession = useApp((s) => s.archiveSession);
  const setSetting = useApp((s) => s.setSetting);

  const current = sessions.find((s) => s.id === selectedId);
  const visible = sessions.filter((s) => !s.archived_at);

  const go = (fn: () => void) => () => {
    setOpen(false);
    fn();
  };

  return (
    <D.Root open={open} onOpenChange={setOpen}>
      <AnimatePresence>
        {open ? (
          <D.Portal forceMount>
            <D.Overlay asChild forceMount>
              <motion.div
                className="fixed inset-0 z-50"
                style={{ background: 'rgb(0 0 0 / 0.45)', backdropFilter: 'blur(2px)' }}
                initial={{ opacity: 0 }}
                animate={{ opacity: 1 }}
                exit={{ opacity: 0 }}
                transition={{ duration: 0.12 }}
              />
            </D.Overlay>
            <D.Content asChild forceMount>
              <motion.div
                className="fixed left-1/2 top-[16vh] z-50 w-[640px] max-w-[calc(100vw-32px)] -translate-x-1/2 overflow-hidden rounded-[16px] outline-none"
                style={{ background: 'var(--bt-elevated)', boxShadow: 'var(--bt-shadow-lg)' }}
                initial={{ opacity: 0, scale: 0.97, y: -6 }}
                animate={{ opacity: 1, scale: 1, y: 0 }}
                exit={{ opacity: 0, scale: 0.98 }}
                transition={{ type: 'spring', stiffness: 600, damping: 40 }}
              >
                <D.Title className="sr-only">Command palette</D.Title>
                <D.Description className="sr-only">Search chats, projects and actions</D.Description>
                <Command loop className="bt-cmdk" label="Command palette">
                  <div className="flex items-center gap-2.5 px-4" style={{ boxShadow: 'inset 0 -1px 0 var(--bt-border)' }}>
                    <Search size={16} style={{ color: 'var(--bt-text-faint)' }} />
                    <Command.Input
                      autoFocus
                      placeholder="Search chats, projects, actions…"
                      className="h-12 flex-1 bg-transparent text-[14.5px] outline-none placeholder:text-[var(--bt-text-faint)]"
                      style={{ color: 'var(--bt-text)' }}
                    />
                    <Kbd shortcut="esc" />
                  </div>
                  <Command.List className="max-h-[420px] overflow-y-auto p-2">
                    <Command.Empty className="px-3 py-8 text-center text-[13px]" style={{ color: 'var(--bt-text-faint)' }}>
                      No matches.
                    </Command.Empty>

                    {current ? (
                      <Group heading={current.name}>
                        <Item icon={<GitCompareArrows size={15} />} onSelect={go(() => setChatTab('diff'))} shortcut="mod+d">
                          Review changes
                        </Item>
                        <Item icon={<MessagesSquare size={15} />} onSelect={go(() => setChatTab('chat'))}>
                          Show chat
                        </Item>
                        {current.alive ? (
                          <Item icon={<Square size={14} />} onSelect={go(() => void stopSession(current.id))}>
                            Stop agent
                          </Item>
                        ) : (
                          <Item icon={<RotateCcw size={15} />} onSelect={go(() => void restartSession(current.id))}>
                            {current.provider_session_id ? 'Resume agent' : 'Restart agent'}
                          </Item>
                        )}
                        <Item icon={<Archive size={15} />} onSelect={go(() => void archiveSession(current.id, !current.archived_at))}>
                          {current.archived_at ? 'Unarchive chat' : 'Archive chat'}
                        </Item>
                      </Group>
                    ) : null}

                    <Group heading="Start">
                      <Item icon={<SquarePen size={15} />} onSelect={go(() => openNewChat(null))} shortcut="mod+n">
                        New chat
                      </Item>
                      {projects.map((p) => (
                        <Item key={`new-${p.id}`} icon={<SquarePen size={15} />} value={`new chat in ${p.name}`} onSelect={go(() => openNewChat(p.id))}>
                          New chat in <span style={{ color: 'var(--bt-text)' }}>{p.name}</span>
                        </Item>
                      ))}
                      <Item icon={<FolderPlus size={15} />} onSelect={go(() => setAddProjectOpen(true))}>
                        Add project
                      </Item>
                    </Group>

                    {visible.length ? (
                      <Group heading="Chats">
                        {visible.map((s) => (
                          <Item
                            key={s.id}
                            value={`${s.name} ${projects.find((p) => p.id === s.project_id)?.name ?? ''} ${s.id}`}
                            icon={
                              <span className="flex w-[15px] justify-center">
                                <StatusDot status={s.status} />
                              </span>
                            }
                            onSelect={go(() => void selectSession(s.id))}
                            meta={`${STATUS_WORDS[s.status] ?? s.status} · ${relativeTime(s.last_event_at ?? s.created_at)}`}
                          >
                            <span className="truncate">{s.name}</span>
                            <span className="ml-2 shrink-0 text-[12px]" style={{ color: 'var(--bt-text-faint)' }}>
                              {projects.find((p) => p.id === s.project_id)?.name}
                            </span>
                          </Item>
                        ))}
                      </Group>
                    ) : null}

                    <Group heading="Go to">
                      <Item icon={<Zap size={15} />} onSelect={go(() => setView('automations'))}>
                        Automations
                      </Item>
                      <Item icon={<GitBranch size={15} />} onSelect={go(() => setView('worktrees'))}>
                        Worktrees
                      </Item>
                      <Item icon={<Settings size={15} />} onSelect={go(() => setView('settings'))} shortcut="mod+,">
                        Settings
                      </Item>
                    </Group>

                    <Group heading="Appearance">
                      {(['near-black', 'black', 'gray'] as const).map((t) => (
                        <Item key={t} icon={<Palette size={15} />} value={`theme ${t}`} onSelect={go(() => void setSetting('theme', t))}>
                          Theme: {t === 'near-black' ? 'Near black' : t === 'black' ? 'True black' : 'Graphite'}
                        </Item>
                      ))}
                    </Group>
                  </Command.List>
                  <div className="flex items-center gap-4 px-4 py-2 text-[11.5px]" style={{ color: 'var(--bt-text-faint)', boxShadow: 'inset 0 1px 0 var(--bt-border)', background: 'var(--bt-surface)' }}>
                    <span className="flex items-center gap-1.5">
                      <Kbd shortcut="up" />
                      <Kbd shortcut="down" /> navigate
                    </span>
                    <span className="flex items-center gap-1.5">
                      <Kbd shortcut="enter" /> open
                    </span>
                  </div>
                </Command>
              </motion.div>
            </D.Content>
          </D.Portal>
        ) : null}
      </AnimatePresence>
    </D.Root>
  );
}

function Group({ heading, children }: { heading: string; children: ReactNode }) {
  return (
    <Command.Group
      heading={heading}
      className="mb-1 [&_[cmdk-group-heading]]:truncate [&_[cmdk-group-heading]]:px-2.5 [&_[cmdk-group-heading]]:pb-1 [&_[cmdk-group-heading]]:pt-2 [&_[cmdk-group-heading]]:text-[11px] [&_[cmdk-group-heading]]:font-medium [&_[cmdk-group-heading]]:text-[var(--bt-text-faint)]"
    >
      {children}
    </Command.Group>
  );
}

function Item({
  icon,
  children,
  onSelect,
  shortcut,
  meta,
  value,
}: {
  icon: ReactNode;
  children: ReactNode;
  onSelect: () => void;
  shortcut?: string;
  meta?: string;
  value?: string;
}) {
  return (
    <Command.Item
      value={value}
      onSelect={onSelect}
      className="flex h-10 cursor-default select-none items-center gap-3 rounded-[9px] px-2.5 text-[13px] outline-none transition-colors data-[selected=true]:bg-[var(--bt-active)]"
      style={{ color: 'var(--bt-text-dim)' }}
    >
      <span className="flex shrink-0" style={{ color: 'var(--bt-text-faint)' }}>
        {icon}
      </span>
      <span className="flex min-w-0 flex-1 items-center" style={{ color: 'var(--bt-text)' }}>
        {children}
      </span>
      {meta ? (
        <span className="shrink-0 text-[11.5px]" style={{ color: 'var(--bt-text-faint)' }}>
          {meta}
        </span>
      ) : null}
      {shortcut ? <Kbd shortcut={shortcut} /> : null}
    </Command.Item>
  );
}
