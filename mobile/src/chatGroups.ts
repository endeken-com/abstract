import { swiftDate, type PullRequest, type Session, type Snapshot, type Stall, type ProviderPresentation } from './types';
import { providerLabel } from './providerPresentation';
import { stallRowText } from './stalls';
import { itemKey, type MacState, type MacView } from './macs';
import { iconFor, type ChatIcon } from './projectIcons';

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
  providerPresentation?: ProviderPresentation;
  hostId: string;
  mac: string;
  macState: MacState;
  lastSeenAt?: number | null;
  pullRequest?: PullRequest | null;
  // Uncommitted, unpushed or unmerged work; undefined until the Mac has read its branch.
  hasChanges?: boolean;
  backgroundTasks: boolean;
  projectName?: string | null;
  // Working but silent past its Mac's quiet/stalled threshold; null otherwise.
  stall?: Stall | null;
  subtaskProgress?: { done: number; total: number };
  // What leads its row: its project's icon, or its agent's logo.
  icon: ChatIcon;
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

export function chatsFromSnapshot(snapshot: Snapshot | null | undefined, mac: Pick<MacView, 'id' | 'name' | 'state' | 'lastSeenAt'>): ChatFacts[] {
  if (!snapshot) return [];
  const projects = new Map(snapshot.projects.map(p => [p.id, p]));
  const busy = new Set(snapshot.backgroundTasks || []);
  const children = new Map<string, Session[]>();
  for (const session of snapshot.sessions) {
    if (session.parentSessionId) children.set(session.parentSessionId, [...(children.get(session.parentSessionId) || []), session]);
  }
  return snapshot.sessions.map(session => {
    const project = session.projectId ? projects.get(session.projectId) : undefined;
    const subtasks = children.get(session.id);
    return {
      session, hostId: mac.id, mac: mac.name, macState: mac.state, lastSeenAt: mac.lastSeenAt,
      providerPresentation: snapshot.providerPresentations?.find(provider => provider.id === session.providerId),
      pullRequest: snapshot.pullRequests?.[session.id] ?? null,
      // A chat with no folder has nothing to review.
      hasChanges: session.worktreePath ? snapshot.unmergedWork?.[session.id] : false,
      backgroundTasks: busy.has(session.id),
      projectName: project?.name ?? null,
      stall: snapshot.stalls?.[session.id] ?? null,
      subtaskProgress: subtasks?.length ? { done: subtasks.filter(child => child.status === 'idle' || child.status === 'finished').length, total: subtasks.length } : undefined,
      icon: iconFor(project, session.projectId ? snapshot.projectIcons?.[session.projectId] : undefined),
    };
  });
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
  // A stalled chat waits on your call: keep waiting, stop, or stop and retry.
  if (chat.stall?.state === 'stalled') return 'needsYou';
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

// Parents precede their delegated chats. Broken and cyclic links still appear once;
// a matching id on another Mac cannot become the parent.
export function chains(chats: ChatFacts[]): ChatFacts[][] {
  const byKey = new Map(chats.map(chat => [chatKey(chat), chat]));
  const children = new Map<string, ChatFacts[]>();
  for (const chat of chats) {
    const parent = chat.session.parentSessionId && itemKey(chat.hostId, chat.session.parentSessionId);
    if (parent && byKey.has(parent)) children.set(parent, [...(children.get(parent) || []), chat]);
  }
  for (const siblings of children.values()) siblings.sort((a, b) => activeAt(b) - activeAt(a) || chatKey(a).localeCompare(chatKey(b)));

  const seen = new Set<string>();
  const result: ChatFacts[][] = [];
  const addChain = (root: ChatFacts) => {
    const members: ChatFacts[] = [];
    const visit = (chat: ChatFacts) => {
      const key = chatKey(chat);
      if (seen.has(key)) return;
      seen.add(key);
      members.push(chat);
      for (const child of children.get(key) || []) visit(child);
    };
    visit(root);
    if (members.length) result.push(members);
  };
  for (const chat of chats) {
    const parent = chat.session.parentSessionId && itemKey(chat.hostId, chat.session.parentSessionId);
    if (!parent || !byKey.has(parent)) addChain(chat);
  }
  for (const chat of chats) if (!seen.has(chatKey(chat))) addChain(chat);
  return result;
}

// A delegated family stays in its most urgent member's group and folds as one.
export function sections(chats: ChatFacts[], now: number): ChatSection[] {
  const families = chains(chats).map(members => ({
    members,
    group: members.map(groupOf).reduce((best, next) => groupOrder.indexOf(next) < groupOrder.indexOf(best) ? next : best),
    activeAt: Math.max(...members.map(activeAt)),
    pinnedAt: Math.min(...members.map(c => c.session.pinnedAt ?? Infinity)),
  }));
  return groupOrder.flatMap((group): ChatSection[] => {
    const members = families.filter(family => family.group === group);
    if (!members.length) return [];
    members.sort(group === 'pinned' ? (a, b) => a.pinnedAt - b.pinnedAt : (a, b) => b.activeAt - a.activeAt);
    if (group !== 'done') return [{ group, chats: members.flatMap(family => family.members), older: [] }];
    const cutoff = now - doneWindow;
    return [{ group, chats: members.filter(family => family.activeAt >= cutoff).flatMap(family => family.members),
      older: members.filter(family => family.activeAt < cutoff).flatMap(family => family.members) }];
  });
}

// Keep families under their root's project, with pinned families first.
export function groupedByProject(chats: ChatFacts[]): Map<string | null, ChatFacts[]> {
  const groups = new Map<string | null, ChatFacts[][]>();
  for (const family of chains(chats)) {
    const project = family[0].session.projectId;
    groups.set(project, [...(groups.get(project) || []), family]);
  }
  return new Map([...groups].map(([project, families]) => {
    const pinned = families.filter(family => family.some(chat => chat.session.pinnedAt != null))
      .sort((a, b) => Math.min(...a.map(chat => chat.session.pinnedAt ?? Infinity)) - Math.min(...b.map(chat => chat.session.pinnedAt ?? Infinity)));
    const rest = families.filter(family => family.every(chat => chat.session.pinnedAt == null));
    return [project, [...pinned, ...rest].flat()];
  }));
}

// The quiet second line under a chat's title. Empty parts are left out.
export type ChatLine = { attention?: string; stall?: string; stalled: boolean; project?: string; pullRequest?: PullRequest; checks?: Checks; changesRequested: boolean; mac?: string };

// Why a chat needs you, in the Mac's words, so the row never says it by colour
// alone. Under the "Needs you" heading, a chat waiting on you needs no word of its own.
export function attentionOf(session: Session, group?: ChatGroup): string | undefined {
  if (session.status === 'errored') return 'Failed';
  return session.status === 'waiting_input' && group !== 'needsYou' ? 'Needs you' : undefined;
}

// Checks and requested changes only matter while the pull request is open. The
// Mac is named only when more than one is paired. `group` is the heading the row sits under.
export function lineOf(chat: ChatFacts, showProject: boolean, showMac = false, now = swiftDate(), group?: ChatGroup): ChatLine {
  const pr = chat.pullRequest || undefined;
  const open = !!pr && prState(pr) === 'OPEN';
  return {
    attention: attentionOf(chat.session, group),
    stall: chat.stall ? stallRowText(chat.stall, now) : undefined,
    stalled: chat.stall?.state === 'stalled',
    project: showProject ? chat.projectName || undefined : undefined,
    pullRequest: pr,
    checks: open ? checksOf(pr) || undefined : undefined,
    changesRequested: open && pr!.reviewDecision === 'CHANGES_REQUESTED',
    mac: showMac ? chat.mac : undefined,
  };
}

export const lineIsEmpty = (line: ChatLine) => !line.attention && !line.stall && !line.project && !line.pullRequest && !line.mac;

// "abstract · #3981 · passed · changes requested · Studio", as the tests read it.
export function lineText(line: ChatLine): string {
  return [line.attention, line.stall, line.project, line.pullRequest && `#${line.pullRequest.number}`, line.checks, line.changesRequested && 'changes requested', line.mac]
    .filter(Boolean).join(' · ');
}

// The state its leading badge shows, in the Mac's words; null at rest.
export function badgeOf(chat: ChatFacts): 'unreachable' | 'stalled' | 'needsYou' | 'failed' | 'working' | null {
  if (chat.macState === 'unreachable') return 'unreachable';
  if (chat.stall?.state === 'stalled') return 'stalled';
  switch (chat.session.status) {
    case 'waiting_input': return 'needsYou';
    case 'errored': return 'failed';
    case 'running': case 'provisioning': return 'working';
  }
  return chat.backgroundTasks ? 'working' : null;
}

const badgeWords = { unreachable: "Mac isn't reachable", stalled: 'Stalled', needsYou: 'Needs you', failed: 'Failed', working: 'Working' };

// The whole row as VoiceOver and TalkBack read it: the same facts the row shows,
// in the order it shows them, with the project and agent its icon stands for.
export function rowLabel(chat: ChatFacts, line: ChatLine, now: number): string {
  const badge = badgeOf(chat);
  const pr = line.pullRequest;
  const prWords = pr && `pull request ${pr.number}${pr.isDraft ? ', draft' : prState(pr) === 'OPEN' ? '' : `, ${pr.state.toLowerCase()}`}`;
  return [
    chat.session.name,
    chat.session.parentSessionId && 'sub-task',
    badge && badge !== 'unreachable' && (line.attention || line.stall || badgeWords[badge]),
    chat.projectName || standalone,
    chat.providerPresentation?.label || providerLabel(undefined, chat.session.providerId),
    badge === 'unreachable' ? `${chat.mac} isn't reachable` : line.mac && `on ${line.mac}`,
    prWords,
    line.checks && `checks ${line.checks}`,
    line.changesRequested && 'changes requested',
    chat.session.archivedAt != null && 'archived',
    chat.subtaskProgress && `${chat.subtaskProgress.done} of ${chat.subtaskProgress.total} sub-tasks done`,
    spokenAge(activeAt(chat), now),
  ].filter(Boolean).join(', ');
}

// How long ago, in the fewest characters: "now", "12m", "3h", "2d", "5w".
export function age(date: number, now: number): string {
  const s = now - date, a = Math.abs(s);
  if (a < 45) return 'now';
  const text = a < 3600 ? `${Math.floor(a / 60)}m` : a < 86_400 ? `${Math.floor(a / 3600)}h` : a < 604_800 ? `${Math.floor(a / 86_400)}d` : `${Math.floor(a / 604_800)}w`;
  return s < 0 ? `in ${text}` : text;
}

// The same age in words: "active 12 minutes ago".
export function spokenAge(date: number, now: number): string {
  const a = Math.abs(now - date);
  if (a < 45) return 'active now';
  const [n, unit] = a < 3600 ? [Math.floor(a / 60), 'minute'] : a < 86_400 ? [Math.floor(a / 3600), 'hour'] : a < 604_800 ? [Math.floor(a / 86_400), 'day'] : [Math.floor(a / 604_800), 'week'];
  const words = `${n} ${unit}${n === 1 ? '' : 's'}`;
  return now < date ? `in ${words}` : `active ${words} ago`;
}

// What the search field and the filter menu narrow the list to. Empty lists let everything through.
export type ActivityFilter = 'today' | 'last3Days' | 'last7Days' | 'last30Days' | 'olderThan30Days';
export type ChatFilter = { projects: string[]; agents: string[]; macs: string[]; activity: ActivityFilter | null };
export const noFilter: ChatFilter = { projects: [], agents: [], macs: [], activity: null };
export const filterIsEmpty = (f: ChatFilter) => !f.projects.length && !f.agents.length && !f.macs.length && !f.activity;

// Projects by name, so the same repository on two Macs is one choice; a chat
// with no project is "Standalone". Macs by name.
export function filterMatches(f: ChatFilter, chat: ChatFacts, now = swiftDate()): boolean {
  return (!f.projects.length || f.projects.includes(chat.projectName || standalone))
    && (!f.agents.length || f.agents.includes(chat.session.providerId))
    && (!f.macs.length || f.macs.includes(chat.mac))
    && activityMatches(f.activity, activeAt(chat), now);
}

function activityMatches(activity: ActivityFilter | null, date: number, now: number): boolean {
  if (!activity) return true;
  if (activity === 'today') {
    const day = new Date((date + 978_307_200) * 1000);
    return day.toDateString() === new Date((now + 978_307_200) * 1000).toDateString();
  }
  const age = now - date;
  if (activity === 'olderThan30Days') return age > 30 * 86_400;
  const days = activity === 'last3Days' ? 3 : activity === 'last7Days' ? 7 : 30;
  return age >= 0 && age <= days * 86_400;
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
const activities: ActivityFilter[] = ['today', 'last3Days', 'last7Days', 'last30Days', 'olderThan30Days'];

export function parsePrefs(raw: string | null | undefined): ChatListPrefs {
  try {
    const p = JSON.parse(raw || '{}');
    return {
      arrangement: p.arrangement === 'project' ? 'project' : 'status',
      filter: { projects: list(p.filter?.projects), agents: list(p.filter?.agents), macs: list(p.filter?.macs),
        activity: activities.includes(p.filter?.activity) ? p.filter.activity : null },
      showArchived: p.showArchived === true,
    };
  } catch { return defaultPrefs; }
}

// The chats the search, the filters and the archive choice let through.
export function narrow(chats: ChatFacts[], prefs: ChatListPrefs, query: string, now = swiftDate()): ChatFacts[] {
  const matches = chats.filter(c => (prefs.showArchived || c.session.archivedAt == null) && filterMatches(prefs.filter, c, now) && queryMatches(c, query));
  const byKey = new Map(chats.map(chat => [chatKey(chat), chat]));
  const included = new Set(matches.map(chatKey));
  for (const chat of matches) {
    let parent = chat.session.parentSessionId;
    while (parent) {
      const key = itemKey(chat.hostId, parent);
      const ancestor = byKey.get(key);
      if (!ancestor || included.has(key)) break;
      included.add(key);
      parent = ancestor.session.parentSessionId;
    }
  }
  return chats.filter(chat => included.has(chatKey(chat)));
}
