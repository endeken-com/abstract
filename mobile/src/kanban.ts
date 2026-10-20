import type { PullRequest } from './types';
import type { MacView } from './macs';
import { activeAt, age, checksOf, queryMatches, statusOf, type ChatFacts } from './chatGroups';

// The phone's Kanban board: chats by progress, with the same columns and
// grouping rules as the Mac plugin's board.js
// (Abstract/Resources/Plugins/kanban.abstractplugin/board.js), fed by the
// remote snapshot instead of the plugin snapshot. Progress comes from
// chatGroups.statusOf, which mirrors SidebarChats.status — the same source
// PluginSnapshot derives its progress from. Keep the three in step.

export type BoardProgress = 'needsYou' | 'working' | 'readyToReview' | 'done';
export const boardColumns: { key: BoardProgress; title: string; empty: string }[] = [
  { key: 'needsYou', title: 'Needs you', empty: 'Nothing needs you.' },
  { key: 'working', title: 'Working', empty: 'Nothing is working right now.' },
  { key: 'readyToReview', title: 'Ready to review', empty: 'Nothing is waiting for review.' },
  { key: 'done', title: 'Done', empty: 'Nothing is done yet.' },
];

export const standaloneKey = '__standalone__';
export const standaloneName = 'Standalone';

const agentNames: Record<string, string> = {
  claude: 'Claude Code', codex: 'Codex', opencode: 'OpenCode', muse: 'Muse Code',
  ollama: 'Codex · Ollama', lmstudio: 'Codex · LM Studio',
};
export const agentName = (agentId: string) => agentNames[agentId] || agentId || '';

// Same shape as PluginSnapshot.projectKey: tells same-named projects on two
// Macs apart.
export const projectKeyOf = (chat: ChatFacts) =>
  chat.session.projectId == null ? standaloneKey : `${chat.hostId}:${chat.session.projectId}`;

export type ProjectOption = {
  key: string; name: string; macId: string; macName: string;
  standalone: boolean; labelIncludesMac: boolean; label: string;
};

// The project choices the filter offers. Same-named projects on different
// Macs stay apart: their labels name the Mac. Standalone appears when a
// chat has no project.
export function projectOptions(macs: MacView[], chats: ChatFacts[]): ProjectOption[] {
  const options: ProjectOption[] = [];
  const seen = new Set<string>();
  const add = (key: string, name: string, macId: string, macName: string) => {
    if (seen.has(key)) return;
    seen.add(key);
    options.push({ key, name, macId, macName, standalone: key === standaloneKey, labelIncludesMac: false, label: name });
  };
  const projects = macs.flatMap(mac => (mac.snapshot?.projects || []).map(p => ({ key: `${mac.id}:${p.id}`, name: p.name, macId: mac.id, macName: mac.name })))
    .sort((a, b) => a.name.localeCompare(b.name));
  for (const p of projects) add(p.key, p.name, p.macId, p.macName);
  for (const chat of chats) {
    if (chat.session.projectId == null) add(standaloneKey, standaloneName, chat.hostId, chat.mac);
    else if (!seen.has(projectKeyOf(chat))) add(projectKeyOf(chat), 'Project', chat.hostId, chat.mac);
  }
  const nameCounts = new Map<string, number>();
  for (const o of options) nameCounts.set(o.name, (nameCounts.get(o.name) || 0) + 1);
  for (const o of options) {
    o.labelIncludesMac = !o.standalone && (nameCounts.get(o.name) || 0) > 1 && !!o.macName;
    o.label = o.labelIncludesMac ? `${o.name} · ${o.macName}` : o.name;
  }
  return options;
}

export function agentOptions(chats: ChatFacts[]): { key: string; label: string }[] {
  const seen = new Set<string>();
  const options: { key: string; label: string }[] = [];
  for (const chat of chats) {
    if (!seen.has(chat.session.providerId)) {
      seen.add(chat.session.providerId);
      options.push({ key: chat.session.providerId, label: agentName(chat.session.providerId) });
    }
  }
  return options.sort((a, b) => a.label.localeCompare(b.label));
}

export const macOptions = (macs: MacView[]) =>
  macs.map(mac => ({ key: mac.id, label: mac.name, reachable: mac.state !== 'unreachable' }));

export type BoardFilter = { projects: string[]; agents: string[]; macs: string[]; search: string; showArchived: boolean };
export const emptyFilter = (): BoardFilter => ({ projects: [], agents: [], macs: [], search: '', showArchived: false });

// Saved filters come back as whatever was stored; keep only the shape the
// board understands.
export function normalizeFilter(raw: unknown): BoardFilter {
  const filter = emptyFilter();
  if (!raw || typeof raw !== 'object') return filter;
  const value = raw as Record<string, unknown>;
  const strings = (v: unknown): string[] => Array.isArray(v) ? v.filter((x): x is string => typeof x === 'string') : [];
  filter.projects = strings(value.projects);
  filter.agents = strings(value.agents);
  filter.macs = strings(value.macs);
  filter.search = typeof value.search === 'string' ? value.search : '';
  filter.showArchived = value.showArchived === true;
  return filter;
}

export const isFilterActive = (filter: BoardFilter) =>
  filter.projects.length > 0 || filter.agents.length > 0 || filter.macs.length > 0
  || filter.search.trim() !== '' || filter.showArchived === true;

function matchesFilter(chat: ChatFacts, filter: BoardFilter): boolean {
  if (filter.projects.length && !filter.projects.includes(projectKeyOf(chat))) return false;
  if (filter.agents.length && !filter.agents.includes(chat.session.providerId)) return false;
  if (filter.macs.length && !filter.macs.includes(chat.hostId)) return false;
  return queryMatches(chat, filter.search);
}

// The pull request as one short line. Checks and requested changes only
// matter while it is open.
export function pullRequestLine(pr: PullRequest | null | undefined): string {
  if (!pr) return '';
  const parts = [`#${pr.number}`];
  const state = (pr.state || 'open').toLowerCase();
  if (state === 'open') {
    if (pr.isDraft) parts.push('draft');
    const checks = checksOf(pr);
    if (checks) parts.push(`checks ${checks}`);
    if (pr.reviewDecision === 'CHANGES_REQUESTED') parts.push('changes requested');
  } else {
    parts.push(state);
  }
  return parts.join(' · ');
}

export type BoardCard = {
  id: string; chat: ChatFacts; title: string; projectKey: string; projectName: string;
  agentId: string; agentName: string; branch: string; macId: string; macName: string;
  pinned: boolean; archived: boolean; progress: BoardProgress; age: string; pullRequestLine: string;
};
export type BoardColumn = { key: BoardProgress; title: string; empty: string; count: number; cards: BoardCard[] };
export type BuiltBoard = {
  columns: BoardColumn[]; total: number; shown: number; archivedCount: number;
  emptyKind: 'noChats' | 'noMatches' | null; filterActive: boolean; unreachableMacs: string[];
  projects: ProjectOption[]; agents: { key: string; label: string }[]; macs: ReturnType<typeof macOptions>;
};

// The whole board. Pinned chats stay in their real column; archived chats
// are hidden unless the filter asks for them.
export function buildBoard(macs: MacView[], chats: ChatFacts[], rawFilter: unknown, now: number): BuiltBoard {
  const filter = normalizeFilter(rawFilter);
  const options = projectOptions(macs, chats);
  const projectsByKey = new Map(options.map(o => [o.key, o]));
  const multipleMacs = macs.length > 1;

  const visible = chats.filter(chat =>
    (filter.showArchived || chat.session.archivedAt == null) && matchesFilter(chat, filter));
  visible.sort((a, b) => activeAt(b) - activeAt(a) || (a.session.name || '').localeCompare(b.session.name || ''));

  const progressOf = (chat: ChatFacts): BoardProgress => {
    const status = statusOf(chat);
    return boardColumns.some(c => c.key === status) ? status as BoardProgress : 'done';
  };
  const cardFor = (chat: ChatFacts): BoardCard => {
    const project = chat.session.projectId == null ? undefined : projectsByKey.get(projectKeyOf(chat));
    return {
      id: chat.session.id, chat, title: chat.session.name || '',
      projectKey: projectKeyOf(chat),
      projectName: project ? project.label : standaloneName,
      agentId: chat.session.providerId, agentName: agentName(chat.session.providerId),
      branch: chat.session.branch || '', macId: chat.hostId,
      // A disambiguated project label already names its Mac; saying it twice helps nobody.
      macName: multipleMacs && !(project && project.labelIncludesMac) ? chat.mac : '',
      pinned: chat.session.pinnedAt != null, archived: chat.session.archivedAt != null,
      progress: progressOf(chat), age: age(activeAt(chat), now),
      pullRequestLine: pullRequestLine(chat.pullRequest),
    };
  };

  const columns = boardColumns.map(column => {
    const cards = visible.filter(chat => progressOf(chat) === column.key).map(cardFor);
    return { key: column.key, title: column.title, empty: column.empty, count: cards.length, cards };
  });

  return {
    columns,
    total: chats.length,
    shown: visible.length,
    archivedCount: chats.filter(c => c.session.archivedAt != null).length,
    emptyKind: chats.length === 0 ? 'noChats' : visible.length === 0 ? 'noMatches' : null,
    filterActive: isFilterActive(filter),
    unreachableMacs: macs.filter(mac => mac.state === 'unreachable').map(mac => mac.name),
    projects: options,
    agents: agentOptions(chats),
    macs: macOptions(macs),
  };
}

// A filter choice for something that no longer exists would hide chats for
// no visible reason, so choices are pruned to what is on offer.
export function pruneFilter(filter: BoardFilter, built: BuiltBoard): BoardFilter {
  return {
    ...filter,
    projects: filter.projects.filter(key => built.projects.some(o => o.key === key)),
    agents: filter.agents.filter(key => built.agents.some(o => o.key === key)),
    macs: filter.macs.filter(key => built.macs.some(o => o.key === key)),
  };
}
