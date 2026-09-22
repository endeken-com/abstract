import { toast } from 'sonner';
import { revealItemInDir } from '@tauri-apps/plugin-opener';
import {
  Archive,
  Copy,
  FolderOpen,
  GitCompareArrows,
  MessagesSquare,
  MoreHorizontal,
  RotateCcw,
  Square,
  Trash2,
} from 'lucide-react';
import { useApp } from '../../store/app';
import { Timeline } from '../output/Timeline';
import { DiffView } from '../diff/DiffView';
import { Composer } from './Composer';
import { Button, EmptyState, IconButton, Menu, MenuItem, MenuSeparator, Segmented, StatusPill } from '../../ui';
import { dragRegion } from '../../app/windowDrag';
import { getProvider } from '../../providers/registry';

export function ChatView({ sessionId }: { sessionId: string }) {
  const session = useApp((s) => s.sessions.find((x) => x.id === sessionId));
  const project = useApp((s) => s.projects.find((p) => p.id === session?.project_id));
  const tab = useApp((s) => s.chatTab);
  const setChatTab = useApp((s) => s.setChatTab);
  const sendFollowUp = useApp((s) => s.sendFollowUp);
  const stopSession = useApp((s) => s.stopSession);
  const restartSession = useApp((s) => s.restartSession);
  const deleteSession = useApp((s) => s.deleteSession);
  const archiveSession = useApp((s) => s.archiveSession);

  if (!session) return <EmptyState title="This chat no longer exists." />;

  const providerName = safeProviderName(session.provider_id);
  const working = session.status === 'running' || session.status === 'provisioning';

  async function run(label: string, fn: () => Promise<void>) {
    try {
      await fn();
    } catch (e) {
      toast.error(label, { description: String(e) });
    }
  }

  return (
    <div className="flex h-full min-w-0 flex-col">
      <header {...dragRegion} className="flex h-12 shrink-0 items-center gap-3 pl-5 pr-3" style={{ boxShadow: 'inset 0 -1px 0 var(--bt-border)' }}>
        <div className="flex min-w-0 flex-1 items-center gap-2 text-[13px]">
          {project ? (
            <>
              <span className="shrink-0" style={{ color: 'var(--bt-text-faint)' }}>
                {project.name}
              </span>
              <span style={{ color: 'var(--bt-text-ghost)' }}>/</span>
            </>
          ) : null}
          <span className="truncate font-medium" style={{ color: 'var(--bt-text)' }}>
            {session.name}
          </span>
          <StatusPill status={session.status} className="ml-1 shrink-0" />
        </div>

        <Segmented
          value={tab}
          onChange={setChatTab}
          options={[
            { value: 'chat', label: 'Chat', icon: <MessagesSquare size={12.5} /> },
            { value: 'diff', label: 'Changes', icon: <GitCompareArrows size={12.5} /> },
          ]}
        />

        <div className="flex items-center gap-1">
          {session.alive ? (
            <Button size="sm" variant="ghost" icon={<Square size={11} fill="currentColor" />} onClick={() => void run('Could not stop the agent', () => stopSession(session.id))}>
              Stop
            </Button>
          ) : (
            <Button size="sm" variant="ghost" icon={<RotateCcw size={13} />} onClick={() => void run('Could not restart the agent', () => restartSession(session.id))}>
              {session.provider_session_id ? 'Resume' : 'Restart'}
            </Button>
          )}
          <Menu
            trigger={
              <IconButton label="More">
                <MoreHorizontal size={15} />
              </IconButton>
            }
          >
            {session.worktree_path ? (
              <>
                <MenuItem icon={<FolderOpen size={14} />} onSelect={() => void revealItemInDir(session.worktree_path ?? '').catch((e) => toast.error('Could not open the folder', { description: String(e) }))}>
                  Reveal worktree
                </MenuItem>
                <MenuItem
                  icon={<Copy size={14} />}
                  onSelect={() => {
                    void navigator.clipboard.writeText(session.worktree_path ?? '');
                    toast.success('Worktree path copied');
                  }}
                >
                  Copy worktree path
                </MenuItem>
              </>
            ) : null}
            {session.branch ? (
              <MenuItem
                icon={<Copy size={14} />}
                onSelect={() => {
                  void navigator.clipboard.writeText(session.branch ?? '');
                  toast.success('Branch name copied');
                }}
              >
                Copy branch name
              </MenuItem>
            ) : null}
            <MenuSeparator />
            <MenuItem icon={<Archive size={14} />} onSelect={() => void archiveSession(session.id, !session.archived_at)}>
              {session.archived_at ? 'Unarchive' : 'Archive'}
            </MenuItem>
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
      </header>

      {tab === 'chat' ? (
        <>
          <Timeline sessionId={session.id} status={session.status} providerName={providerName} />
          <Composer
            providerName={providerName}
            branch={session.branch}
            working={working}
            onSend={(text) => run('Could not send the message', () => sendFollowUp(session.id, text))}
            onStop={() => run('Could not stop the agent', () => stopSession(session.id))}
          />
        </>
      ) : (
        <DiffView sessionId={session.id} />
      )}
    </div>
  );
}

function safeProviderName(id: string): string {
  try {
    return getProvider(id).name;
  } catch {
    return id;
  }
}
