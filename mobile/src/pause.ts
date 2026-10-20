import type { MacView } from './macs';
import type { Snapshot } from './types';

// "Pause everything" as the Mac runs it (PauseState): stops the agents at
// work in scope and pauses its automations. Resume turns back on only the
// automations the pause itself switched off; agents are never restarted.
// An older Mac never sends these fields, so it shows no pause state and
// takes no pause requests.

export type PauseAction = 'pause' | 'resume';
export type PauseRequest = {
  name: 'pauseEverything' | 'resumeEverything' | 'pauseProject' | 'resumeProject';
  args: Record<string, unknown>;
};

export const pauseSupported = (snapshot?: Snapshot | null) => snapshot?.pauseControl === true;
export const everythingPaused = (snapshot?: Snapshot | null) => snapshot?.everythingPaused === true;
export const isProjectPaused = (snapshot: Snapshot | null | undefined, projectId: string) =>
  !!snapshot && (snapshot.everythingPaused === true || (snapshot.pausedProjectIds || []).includes(projectId));
export const hasAnyPause = (snapshot?: Snapshot | null) =>
  snapshot?.everythingPaused === true || (snapshot?.pausedProjectIds?.length ?? 0) > 0;

// The one global toggle, as in the Mac's Chat menu: Resume everything only
// while everything is paused (it also clears every project pause).
export function globalPauseAction(snapshot?: Snapshot | null): PauseAction | null {
  if (!pauseSupported(snapshot)) return null;
  return everythingPaused(snapshot) ? 'resume' : 'pause';
}

// As in the Mac's project menu: while everything is paused a project offers
// neither, because resuming it would only lift its own mark until
// everything resumes.
export function projectPauseAction(snapshot: Snapshot | null | undefined, projectId: string): PauseAction | null {
  if (!pauseSupported(snapshot) || everythingPaused(snapshot)) return null;
  return (snapshot?.pausedProjectIds || []).includes(projectId) ? 'resume' : 'pause';
}

export function pauseRequest(action: PauseAction, projectId?: string): PauseRequest {
  if (projectId) return { name: action === 'pause' ? 'pauseProject' : 'resumeProject', args: { projectId } };
  return { name: action === 'pause' ? 'pauseEverything' : 'resumeEverything', args: {} };
}

export const globalPauseConfirm = (macName: string) => ({
  title: 'Pause everything?',
  message: `Stop every running agent and pause every automation on ${macName}? Resume turns back on only the automations this pause switched off; agents are not restarted.`,
});

export type PauseBannerRow = {
  key: string; hostId: string; kind: 'all' | 'project'; projectId?: string;
  text: string; button: string; canAct: boolean; request: PauseRequest;
};

// The banner rows across every Mac, as on the Mac: one global row while
// everything is paused, otherwise one row per paused project, in the
// Mac's project order. A paused id the snapshot no longer lists (archived
// or removed there) gets no row. `projectId` narrows to one project (the
// global row always stays).
export function pauseBannerRows(macs: MacView[], projectId?: string): PauseBannerRow[] {
  const rows: PauseBannerRow[] = [];
  for (const mac of macs) {
    const snapshot = mac.snapshot;
    if (!snapshot || !hasAnyPause(snapshot)) continue;
    const canAct = mac.state === 'online' && pauseSupported(snapshot);
    if (everythingPaused(snapshot)) {
      rows.push({
        key: `${mac.id}/all`, hostId: mac.id, kind: 'all', canAct,
        text: `Everything is paused on ${mac.name}. Agents are stopped and automations are off.`,
        button: 'Resume everything', request: pauseRequest('resume'),
      });
      continue;
    }
    for (const project of snapshot.projects) {
      if (!(snapshot.pausedProjectIds || []).includes(project.id)) continue;
      if (projectId && project.id !== projectId) continue;
      rows.push({
        key: `${mac.id}/${project.id}`, hostId: mac.id, kind: 'project', projectId: project.id, canAct,
        text: `“${project.name}” is paused on ${mac.name}. Its agents are stopped and its automations are off.`,
        button: 'Resume', request: pauseRequest('resume', project.id),
      });
    }
  }
  return rows;
}

// The banner for one chat: its project paused, or everything (which also
// covers standalone chats). Null when nothing covering it is paused.
export function chatPauseRow(mac: MacView, projectId: string | null): PauseBannerRow | null {
  const rows = pauseBannerRows([mac], projectId || undefined);
  if (!rows.length) return null;
  if (rows[0].kind === 'all') return rows[0];
  return projectId ? rows.find(row => row.projectId === projectId) || null : null;
}
