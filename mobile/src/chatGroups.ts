import type { PullRequest, Session, Snapshot } from './types';
import { itemKey, type MacState, type MacView } from './macs';

// The phone's chat list grouped by what each chat needs from you, as the Mac's
// sidebar groups it (Packages/AbstractCore/Sources/AbstractCore/Sessions/SidebarChats.swift).
// Keep the two in step. Dates are Swift reference dates, in seconds.

export type ChatGroup = 'pinned' | 'needsYou' | 'working' | 'readyToReview' | 'done' | 'archived';
export const groupOrder: ChatGroup[] = ['pinned', 'needsYou', 'working', 'readyToReview', 'done', 'archived'];
export const groupTitles: Record<ChatGroup, string> = {
  pinned: 'Pinned', needsYou: 'Needs you', working: 'Working', readyToReview: 'Ready to review', done: 'Done', archived: 'Archived',
};
export type Arrangement = 'status' | 'project';
export type Checks = 'passed' | 'failing' | 'running';

// What the list knows of one chat, on whichever paired Mac it runs.
export type ChatFacts = {
  session: Session;
  hostId: string;
  mac: string;
  macState: MacState;
  pullRequest?: PullRequest | null;
  // Uncommitted, unpushed or unmerged work; undefined until the Mac has read its branch.
  hasChanges?: boolean;
  backgroundTasks: boolean;
  projectName?: string | null;
};
export type ChatSection = { group: ChatGroup; chats: ChatFacts[]; older: ChatFacts[] };

// How long a chat stays in Done before it folds under "Show N older".
export const doneWindow = 7 * 86_400;
export const standalone = 'Standalone';

export const activeAt = (chat: ChatFacts) => chat.session.lastEventAt ?? chat.session.createdAt;
// Chats on different Macs never share a key, even when their ids match.
export const chatKey = (chat: ChatFacts) => itemKey(chat.hostId, chat.session.id);

export function chatsFromMacs(macs: MacView[]): ChatFacts[] {
  return macs.flatMap(mac => chatsFromSnapshot(mac.snapshot, mac));
}

export function chatsFromSnapshot(snapshot: Snapshot | null | undefined, mac: Pick<MacView, 'id' | 'name' | 'state'>): ChatFacts[] {
  if (!snapshot) return [];
  const projects = new Map(snapshot.projects.map(p => [p.id, p.name]));
  const busy = new Set(snapshot.backgroundTasks || []);
  return snapshot.sessions.map(session => ({
    session, hostId: mac.id, mac: mac.name, macState: mac.state,
    pullRequest: snapshot.pullRequests?.[session.id] ?? null,
    // A chat with no folder has nothing to review.
    hasChanges: session.worktreePath ? snapshot.unmergedWork?.[session.id] : false,
    backgroundTasks: busy.has(session.id),
    projectName: session.projectId ? projects.get(session.projectId) ?? null : null,
  }));
}

const prState = (pr: PullRequest) => pr.state.toUpperCase();

// One failing check is the news; then any still running; none, nothing.
export function checksOf(pr: PullRequest | null | undefined): Checks | null {
  const checks = pr?.checks || [];
  if (checks.some(c => c.outcome === 'failed')) return 'failing';
  if (checks.some(c => c.outcome === 'pending')) return 'running';
  return checks.some(c => c.outcome === 'passed') ? 'passed' : null;
}

// Where a chat belongs, pins and archive aside: what it needs from you.
export function statusOf(chat: ChatFacts): ChatGroup {
  switch (chat.session.status) {
    case 'waiting_input': case 'errored': return 'needsYou';
    case 'running': case 'provisioning': return 'working';
  }
  if (chat.backgroundTasks) return 'working';
  if (chat.pullRequest) return prState(chat.pullRequest) === 'OPEN' ? 'readyToReview' : 'done';
  // Not known yet counts as changes: nothing is filed as done before it's known to have none.
  return chat.hasChanges ?? true ? 'readyToReview' : 'done';
}

export function groupOf(chat: ChatFacts): ChatGroup {
  if (chat.session.archivedAt != null) return 'archived';
  if (chat.session.pinnedAt != null) return 'pinned';
  return statusOf(chat);
}

// The chats in their groups, in the order the list shows them; empty groups are left out.
export function sections(chats: ChatFacts[], now: number): ChatSection[] {
  return groupOrder.flatMap((group): ChatSection[] => {
    const members = chats.filter(c => groupOf(c) === group);
    if (!members.length) return [];
    members.sort(group === 'pinned' ? (a, b) => (a.session.pinnedAt ?? 0) - (b.session.pinnedAt ?? 0) : (a, b) => activeAt(b) - activeAt(a));
    if (group !== 'done') return [{ group, chats: members, older: [] }];
    const cutoff = now - doneWindow;
    return [{ group, chats: members.filter(c => activeAt(c) >= cutoff), older: members.filter(c => activeAt(c) < cutoff) }];
  });
}

// The quiet second line under a chat's title. Empty parts are left out.
export type ChatLine = { project?: string; pullRequest?: PullRequest; checks?: Checks; changesRequested: boolean; mac?: string };

// Checks and requested changes only matter while the pull request is open. The
// Mac is named only when more than one is paired.
export function lineOf(chat: ChatFacts, showProject: boolean, showMac = false): ChatLine {
  const pr = chat.pullRequest || undefined;
  const open = !!pr && prState(pr) === 'OPEN';
  return {
    project: showProject ? chat.projectName || undefined : undefined,
    pullRequest: pr,
    checks: open ? checksOf(pr) || undefined : undefined,
    changesRequested: open && pr!.reviewDecision === 'CHANGES_REQUESTED',
    mac: showMac ? chat.mac : undefined,
  };
}

export const lineIsEmpty = (line: ChatLine) => !line.project && !line.pullRequest && !line.mac;

// "abstract · #3981 · passed · changes requested · Studio", as VoiceOver and the tests read it.
export function lineText(line: ChatLine): string {
  return [line.project, line.pullRequest && `#${line.pullRequest.number}`, line.checks, line.changesRequested && 'changes requested', line.mac]
    .filter(Boolean).join(' · ');
}

// How long ago, in the fewest characters: "now", "12m", "3h", "2d", "5w".
export function age(date: number, now: number): string {
  const s = now - date, a = Math.abs(s);
  if (a < 45) return 'now';
  const text = a < 3600 ? `${Math.floor(a / 60)}m` : a < 86_400 ? `${Math.floor(a / 3600)}h` : a < 604_800 ? `${Math.floor(a / 86_400)}d` : `${Math.floor(a / 604_800)}w`;
  return s < 0 ? `in ${text}` : text;
}

// What the search field and the filter menu narrow the list to. Empty lists let everything through.
export type ChatFilter = { projects: string[]; agents: string[]; macs: string[] };
export const noFilter: ChatFilter = { projects: [], agents: [], macs: [] };
export const filterIsEmpty = (f: ChatFilter) => !f.projects.length && !f.agents.length && !f.macs.length;

// Projects by name, so the same repository on two Macs is one choice; a chat
// with no project is "Standalone". Macs by name.
export function filterMatches(f: ChatFilter, chat: ChatFacts): boolean {
  return (!f.projects.length || f.projects.includes(chat.projectName || standalone))
    && (!f.agents.length || f.agents.includes(chat.session.providerId))
    && (!f.macs.length || f.macs.includes(chat.mac));
}

// The search box: the chat's title or branch, or its pull request's number.
export function queryMatches(chat: ChatFacts, query: string): boolean {
  const q = query.trim();
  if (!q) return true;
  const n = /^#?\d+$/.test(q) ? Number(q.replace('#', '')) : null;
  if (n != null && chat.pullRequest?.number === n) return true;
  const lower = q.toLowerCase();
  return chat.session.name.toLowerCase().includes(lower) || !!chat.session.branch?.toLowerCase().includes(lower);
}

// The choices that persist: how to group, which chats, and archived ones.
export type ChatListPrefs = { arrangement: Arrangement; filter: ChatFilter; showArchived: boolean };
export const defaultPrefs: ChatListPrefs = { arrangement: 'status', filter: noFilter, showArchived: false };

const list = (value: unknown): string[] => Array.isArray(value) ? value.filter(x => typeof x === 'string') : [];

export function parsePrefs(raw: string | null | undefined): ChatListPrefs {
  try {
    const p = JSON.parse(raw || '{}');
    return {
      arrangement: p.arrangement === 'project' ? 'project' : 'status',
      filter: { projects: list(p.filter?.projects), agents: list(p.filter?.agents), macs: list(p.filter?.macs) },
      showArchived: p.showArchived === true,
    };
  } catch { return defaultPrefs; }
}

// The chats the search, the filters and the archive choice let through.
export function narrow(chats: ChatFacts[], prefs: ChatListPrefs, query: string): ChatFacts[] {
  return chats.filter(c => (prefs.showArchived || c.session.archivedAt == null) && filterMatches(prefs.filter, c) && queryMatches(c, query));
}
