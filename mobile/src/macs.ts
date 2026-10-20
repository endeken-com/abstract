import type { Project, PullRequest, Session, Snapshot } from './types';

// One paired Mac as the screens see it. A Mac that can't be reached keeps the
// last snapshot it sent, so its projects stay visible, greyed out.
export type MacState = 'online' | 'connecting' | 'unreachable';
export type MacView = { id: string; name: string; state: MacState; snapshot: Snapshot | null; lastSeenAt?: number | null };
export type MacProject = { mac: MacView; project: Project };
export type MacChat = { mac: MacView; chat: Session };
export type MacPullRequest = { mac: MacView; sessionId: string; pr: PullRequest; chat?: Session };

export function macState(client: { status: string; unreachable: boolean }): MacState {
  if (client.status === 'online') return 'online';
  return client.unreachable ? 'unreachable' : 'connecting';
}

// Items from different Macs never share a key, even when their ids or names match.
export const itemKey = (hostId: string, id: string) => `${hostId}/${id}`;

export function macProjects(macs: MacView[]): MacProject[] {
  return macs.flatMap(mac => (mac.snapshot?.projects || []).map(project => ({ mac, project })));
}

export function macChats(macs: MacView[]): MacChat[] {
  return macs
    .flatMap(mac => (mac.snapshot?.sessions || []).filter(chat => !chat.archivedAt).map(chat => ({ mac, chat })))
    .sort((a, b) => b.chat.createdAt - a.chat.createdAt);
}

// A project's default Mac is stored on its record on the Mac that owns it
// (`defaultDeviceId`, null = that Mac) — never on the phone. The phone reads
// it from each Mac's snapshot and changes it through that Mac.

// This project as another Mac has it: by id when both share one, else by
// name. Mirrors `Project.counterpart` on the Mac.
export function counterpartProject(project: Project, projects: Project[]): Project | undefined {
  return projects.find(x => x.id === project.id) || projects.find(x => x.name === project.name);
}

// What the project's default Mac is called here: its owning Mac when none is
// chosen, else that Mac's name when the phone is paired with it too.
export function defaultMacName(macs: MacView[], owner: MacView, project: Project): string {
  if (!project.defaultDeviceId) return owner.name;
  return macs.find(mac => mac.id === project.defaultDeviceId)?.name || 'A paired Mac';
}

export type ChatTarget = { macId: string; projectId: string; notice: string | null };

// Where a new chat for `project` (owned by `ownerMacId`) starts: its chosen
// default Mac, with that Mac's own record of the project, when the phone can
// reach it and it has the project. Otherwise the owning Mac, with a note
// saying why — the Mac Launcher's semantics.
export function resolveChatTarget(macs: MacView[], ownerMacId: string, project: Project): ChatTarget {
  const here: ChatTarget = { macId: ownerMacId, projectId: project.id, notice: null };
  const wanted = project.defaultDeviceId;
  if (!wanted || wanted === ownerMacId) return here;
  const ownerName = macs.find(mac => mac.id === ownerMacId)?.name || 'its Mac';
  const target = macs.find(mac => mac.id === wanted);
  if (!target || target.state !== 'online') {
    return { ...here, notice: `${target?.name || 'Its default Mac'} isn't connected, so this chat runs on ${ownerName}.` };
  }
  const counterpart = counterpartProject(project, target.snapshot?.projects || []);
  if (!counterpart) {
    return { ...here, notice: `${target.name} doesn't have a project called “${project.name}”, so this chat runs on ${ownerName}.` };
  }
  return { macId: target.id, projectId: counterpart.id, notice: null };
}

export function macPullRequests(macs: MacView[]): MacPullRequest[] {
  return macs.flatMap(mac => Object.entries(mac.snapshot?.pullRequests || {}).map(([sessionId, pr]) => ({
    mac, sessionId, pr, chat: mac.snapshot?.sessions.find(chat => chat.id === sessionId),
  })));
}
