// Linking issues and pull requests from the phone's composers (ABS-211).
// Tracker plugins run only on the Mac (ABS-84 §6), so the phone asks it:
// which trackers and code host a project offers, a search, and the picked
// issue whole. A Mac from before this answers none of it, and would drop
// the connection on a request it can't read, so it's asked only when its
// snapshot says `issueSearch`.

export type IssueTracker = {
  id: string; title: string; keyExample: string; version: string;
  link?: string | null; linkKey?: string | null;
  // Base64 of the SVG text or PNG bytes; absent when the phone has this version's.
  icon?: string | null; iconFormat?: 'svg' | 'png' | null; iconIsTemplate?: boolean | null;
};
export type IssueSources = { trackers: IssueTracker[]; linked: boolean; codeHost?: string | null; githubIssues: boolean; pullRequests: boolean };
// An attachment as the Mac encodes it (PromptAttachment).
export type MacAttachment = { id: string; kind: string; title: string; path?: string | null; reference?: string | null; url?: string | null; body?: string | null; details?: string[]; tracker?: string | null; trackerName?: string | null };
export type IssueResult = { reference: string; title: string; state?: string | null; attachment: MacAttachment };
export type IssueGroup = { sourceId: string; title: string; results: IssueResult[]; problem?: string | null };

// What the "Add to message" menu's link items open: one tracker (or every
// one the project offers, `trackerId` null), GitHub issues, or pull requests.
export type LinkSource = { kind: 'tracker'; trackerId: string | null } | { kind: 'githubIssue' } | { kind: 'pullRequest' };

export type LinkMenuAction = { id: string; title: string; subtitle?: string; image?: string; attributes?: { disabled?: boolean } };

export type LinkMenuInput = {
  // The Mac answers the issue requests (its snapshot's `issueSearch`).
  supported: boolean;
  online: boolean;
  macName: string;
  // What the Mac said this project offers, kept from the last time it was reachable.
  sources: IssueSources | null;
  // Why asking failed, in a sentence.
  error?: string | null;
  // A project (or a chat in one) whose repository GitHub could answer for, on an older Mac.
  hasRepository: boolean;
  platform: string;
};

const images: Record<string, string> = { tracker: 'ticket', githubIssue: 'smallcircle.filled.circle', pullRequest: 'arrow.triangle.pull' };

/// "Link a Jira issue", "Link an issue": what a tracker item says.
export function trackerItemTitle(sources: IssueSources, trackerId: string | null) {
  const tracker = sources.trackers.find(item => item.id === trackerId);
  return tracker ? `Link ${/^[aeiou]/i.test(tracker.title) ? 'an' : 'a'} ${tracker.title} issue` : 'Link an issue';
}

/// The link items for the "Add to message" menu, as the Mac's composer
/// offers them for the project: each linked tracker by name (or one item
/// across every tracker that's on), GitHub issues only for GitHub projects,
/// and pull requests from the project's code host.
export function linkMenuActions(input: LinkMenuInput): LinkMenuAction[] {
  const image = (key: string) => input.platform === 'ios' ? images[key] : undefined;
  const unreachable = `${input.macName} isn't reachable`;
  if (!input.supported) {
    // An older Mac: GitHub through its `gh`, as before; trackers need an update there.
    const disabled = input.online ? undefined : { disabled: true };
    const subtitle = input.online ? undefined : unreachable;
    return [
      { id: 'link:tracker:', title: 'Link a Linear or Jira issue', subtitle: input.online ? `Update Abstract on ${input.macName} to link Linear or Jira issues` : unreachable, image: image('tracker'), attributes: { disabled: true } },
      ...(input.hasRepository ? [
        { id: 'link:githubIssue', title: 'Link a GitHub issue', subtitle, image: image('githubIssue'), attributes: disabled },
        { id: 'link:pullRequest', title: 'Link a pull request', subtitle, image: image('pullRequest'), attributes: disabled },
      ] : []),
    ];
  }
  const sources = input.sources;
  if (!sources) {
    const subtitle = !input.online ? unreachable : input.error || `Asking ${input.macName}…`;
    return [{ id: 'link:tracker:', title: 'Link an issue', subtitle, image: image('tracker'), attributes: { disabled: true } }];
  }
  const out: LinkMenuAction[] = [];
  const trackers = sources.trackers;
  if (sources.linked || trackers.length === 1) {
    for (const tracker of trackers) out.push({ id: `link:tracker:${tracker.id}`, title: trackerItemTitle(sources, tracker.id), subtitle: tracker.link || undefined, image: image('tracker') });
  } else if (trackers.length > 1) {
    out.push({ id: 'link:tracker:', title: 'Link an issue', subtitle: trackers.map(item => item.title).join(' or '), image: image('tracker') });
  }
  if (sources.githubIssues) out.push({ id: 'link:githubIssue', title: 'Link a GitHub issue', image: image('githubIssue') });
  if (sources.pullRequests) out.push({ id: 'link:pullRequest', title: 'Link a pull request', subtitle: sources.codeHost || undefined, image: image('pullRequest') });
  if (!input.online) return out.map(action => ({ ...action, subtitle: unreachable, attributes: { disabled: true } }));
  return out;
}

/// The menu event's source, or null for an event that isn't a link item.
export function linkSourceOf(event: string): LinkSource | null {
  if (event === 'link:githubIssue') return { kind: 'githubIssue' };
  if (event === 'link:pullRequest') return { kind: 'pullRequest' };
  if (event.startsWith('link:tracker:')) return { kind: 'tracker', trackerId: event.slice('link:tracker:'.length) || null };
  return null;
}

/// The trackers one tracker item searches.
export function searchedTrackers(sources: IssueSources | null, source: LinkSource): IssueTracker[] {
  if (source.kind !== 'tracker' || !sources) return [];
  return source.trackerId ? sources.trackers.filter(item => item.id === source.trackerId) : sources.trackers;
}

export function sheetTitle(sources: IssueSources | null, source: LinkSource) {
  if (source.kind === 'pullRequest') return 'Find a pull request';
  if (source.kind === 'githubIssue') return 'Find a GitHub issue';
  const trackers = searchedTrackers(sources, source);
  return trackers.length === 1 ? `Find ${/^[aeiou]/i.test(trackers[0].title) ? 'an' : 'a'} ${trackers[0].title} issue` : 'Find an issue';
}

/// The search field's placeholder, as on the Mac.
export function searchPlaceholder(sources: IssueSources | null, source: LinkSource) {
  if (source.kind === 'pullRequest') return 'Search pull requests, or #number';
  if (source.kind === 'githubIssue') return 'Search issues, or #number';
  const trackers = searchedTrackers(sources, source);
  return trackers.length === 1
    ? `Search ${trackers[0].title} issues, or paste ${trackers[0].keyExample}`
    : `Search ${trackers.map(item => item.title).join(' and ') || 'issues'}, or paste a key or link`;
}

/// What the sheet asks the Mac for what was typed. A key or link pasted
/// whole goes as it is: the Mac asks the tracker for that one issue.
export function searchRequest(source: LinkSource, query: string, scope: { projectId: string | null; chatId: string | null }) {
  const q = query.trim();
  if (source.kind === 'tracker') return { name: 'searchIssues', args: { projectId: scope.projectId, chatId: scope.chatId, trackerId: source.trackerId, query: q, searchAll: false } };
  return { name: 'searchCodeHost', args: { projectId: scope.projectId, chatId: scope.chatId, query: q, pullRequests: source.kind === 'pullRequest' } };
}

/// GitHub through `gh` on a Mac from before ABS-211.
export function legacyGitHubArgs(source: LinkSource, query: string) {
  const pr = source.kind === 'pullRequest';
  const q = query.trim();
  const fields = pr ? 'number,title,url,state,body,isDraft,baseRefName,headRefName' : 'number,title,url,state,body';
  return [pr ? 'pr' : 'issue', 'list', '--limit', '30', '--json', fields, '--state', q ? 'all' : 'open', ...(q ? ['--search', q] : [])];
}

/// `gh`'s JSON as the Mac's groups would put it.
export function legacyGitHubGroup(source: LinkSource, items: Array<{ number: number; title: string; url: string; body?: string; state?: string; isDraft?: boolean; baseRefName?: string; headRefName?: string }>): IssueGroup {
  const pr = source.kind === 'pullRequest';
  return { sourceId: 'github', title: 'GitHub', results: items.map(item => ({
    reference: `#${item.number}`, title: item.title, state: item.isDraft ? 'Draft' : item.state ? item.state.charAt(0) + item.state.slice(1).toLowerCase() : null,
    attachment: { id: `${pr ? 'pr' : 'issue'}-${item.number}`, kind: pr ? 'pullRequest' : 'githubIssue', title: item.title, path: null, reference: `#${item.number}`, url: item.url,
      body: item.body?.slice(0, 12_000) || null,
      details: [item.baseRefName ? `Base: ${item.baseRefName}` : '', item.headRefName ? `Head: ${item.headRefName}` : ''].filter(Boolean) },
  })) };
}

/// Whether each group's tracker is named above its results: always for
/// trackers, as their icons tell Jira from Linear; never for one code host.
export function namesGroups(source: LinkSource, groups: IssueGroup[]) {
  return source.kind === 'tracker' || groups.length > 1;
}

// MARK: Tracker icons, kept per plugin version

export type TrackerIconData = { version: string; format: 'svg' | 'png'; data: string; template: boolean };
const icons = new Map<string, TrackerIconData>();

/// Keeps the icons the Mac sent, and returns the versions the phone has, to
/// send with the next ask so they aren't sent again.
export function rememberIcons(sources: IssueSources) {
  for (const tracker of sources.trackers) {
    if (tracker.icon && tracker.iconFormat) icons.set(tracker.id, { version: tracker.version, format: tracker.iconFormat, data: tracker.icon, template: tracker.iconIsTemplate !== false });
  }
}
export function knownIconVersions(): Record<string, string> {
  return Object.fromEntries([...icons].map(([id, icon]) => [id, icon.version]));
}
export function trackerIcon(trackerId?: string | null) {
  return trackerId ? icons.get(trackerId) || null : null;
}

// MARK: Showing attachments

/// A linked tracker's chip for the chat's context row: its icon and the
/// key it links ("DGDEV"), as the Mac's project header shows it.
export function linkedTrackerPills(sources: IssueSources | null) {
  if (!sources?.linked) return [];
  return sources.trackers.filter(item => item.link).map(item => ({ id: item.id, label: item.linkKey || item.link || item.title, title: `${item.title}: ${item.link}` }));
}

export type AttachmentChip = { kind: string; label: string; target: string | null; tracker: string | null };

const block = /<attachment kind="([A-Za-z]+)"(?: tracker="([^"]*)")? label="([^"]*)"(?: target="([^"]*)")?>\n[\s\S]*?\n<\/attachment>/g;
const unattribute = (value: string) => value.replace(/&quot;/g, '"').replace(/&amp;/g, '&');
const knownKinds = new Set(['file', 'image', 'githubIssue', 'pullRequest', 'trackerIssue', 'linearIssue', 'revundReview']);

/// A sent message's own text and its attachments' chips, as the Mac's
/// transcript splits them (`PromptAttachments.split`).
export function splitAttachments(message: string): { text: string; chips: AttachmentChip[] } {
  if (!message.includes('<attachment kind="')) return { text: message, chips: [] };
  const chips: AttachmentChip[] = [];
  const text = message.replace(block, (whole, kind: string, tracker: string | undefined, label: string, target: string | undefined) => {
    if (!knownKinds.has(kind)) return whole;
    const legacy = kind === 'linearIssue';
    chips.push({ kind: legacy ? 'trackerIssue' : kind, label: unattribute(label), target: target ? unattribute(target) : null,
      tracker: legacy ? 'sh.abstract.linear' : tracker ? unattribute(tracker) : null });
    return '';
  });
  return { text: text.trim(), chips };
}

/// The attachment the Mac sent back, as the composer keeps it.
export function pickedFromMac(attachment: MacAttachment) {
  return { id: attachment.id, kind: attachment.kind as 'trackerIssue' | 'githubIssue' | 'pullRequest', title: attachment.title, path: attachment.path ?? null,
    reference: attachment.reference ?? null, url: attachment.url ?? null, body: attachment.body ?? null, details: attachment.details || [],
    tracker: attachment.tracker ?? null, trackerName: attachment.trackerName ?? null, data: '', size: 0 };
}
