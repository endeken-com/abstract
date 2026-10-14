import type { Project, PullRequest, Session, Snapshot } from './types';

// One paired Mac as the screens see it. A Mac that can't be reached keeps the
// last snapshot it sent, so its projects stay visible, greyed out.
export type MacState = 'online' | 'connecting' | 'unreachable';
export type MacView = { id: string; name: string; state: MacState; snapshot: Snapshot | null };
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

export function macPullRequests(macs: MacView[]): MacPullRequest[] {
  return macs.flatMap(mac => Object.entries(mac.snapshot?.pullRequests || {}).map(([sessionId, pr]) => ({
    mac, sessionId, pr, chat: mac.snapshot?.sessions.find(chat => chat.id === sessionId),
  })));
}
