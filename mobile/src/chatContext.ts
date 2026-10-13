import type { Session } from './types';

export type ChatContextIcon = 'branch' | 'worktree' | 'project' | 'standalone';
export type ChatContext = { caption: 'BRANCH' | 'WORKTREE' | 'PROJECT' | 'STANDALONE'; label: string; icon: ChatContextIcon; accessibilityLabel: string };

// One symbol per idea, as on the Mac (Abstract/Resources/ICONS.md): a branch draws the git-branch Octicon (BranchIcon), the rest are system symbols.
export const contextSymbols: Record<Exclude<ChatContextIcon, 'branch'>, { ios: string; android: string; web: string }> = {
  worktree: { ios: 'arrow.triangle.branch', android: 'account_tree', web: 'account_tree' },
  project: { ios: 'folder', android: 'folder', web: 'folder' },
  standalone: { ios: 'bubble.left', android: 'chat_bubble', web: 'chat_bubble' },
};

// What the pill above the reply box shows: the branch when the chat has one, otherwise where the chat runs.
export function chatContext(chat: Pick<Session, 'branch' | 'worktreePath' | 'projectId'>, projectName?: string | null): ChatContext {
  const folder = chat.worktreePath?.split('/').filter(Boolean).at(-1);
  if (chat.branch) return { caption: 'BRANCH', label: chat.branch, icon: 'branch', accessibilityLabel: `Branch ${chat.branch}` };
  if (folder) return { caption: 'WORKTREE', label: folder, icon: 'worktree', accessibilityLabel: `Worktree ${folder}` };
  if (chat.projectId) {
    const label = projectName || 'Project';
    return { caption: 'PROJECT', label, icon: 'project', accessibilityLabel: `Project ${label}` };
  }
  return { caption: 'STANDALONE', label: 'No project', icon: 'standalone', accessibilityLabel: 'Standalone chat' };
}
