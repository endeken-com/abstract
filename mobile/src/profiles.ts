import { swiftDate, type AgentProfile, type Automation, type Policy, type ProfileSnapshot, type Project, type Session } from './types';

// The icons the Mac offers beside a profile's name.
export const profileIcons = ['person.crop.circle', 'hammer', 'magnifyingglass', 'list.bullet.clipboard', 'ladybug', 'doc.text.magnifyingglass', 'wrench.and.screwdriver', 'lightbulb'];

export const sortedProfiles = (profiles: AgentProfile[] | undefined): AgentProfile[] =>
  [...(profiles || [])].sort((a, b) => a.sortOrder - b.sortOrder || a.createdAt - b.createdAt);

export const findProfile = (profiles: AgentProfile[] | undefined, id: string | null | undefined): AgentProfile | undefined =>
  id ? (profiles || []).find(profile => profile.id === id) : undefined;

// The profiles on offer for a project: all of them, unless the project
// picked which ones show. The chosen one stays offered even then.
export function visibleProfiles(profiles: AgentProfile[] | undefined, project: Project | null | undefined, chosenId?: string | null): AgentProfile[] {
  const all = sortedProfiles(profiles);
  const picked = project?.profileIds;
  const offered = picked == null ? all : all.filter(profile => picked.includes(profile.id));
  const chosen = findProfile(all, chosenId);
  return chosen && !offered.includes(chosen) ? [...offered, chosen] : offered;
}

// What choosing a profile fills in; each field can still be changed after.
export function appliedProfile(profile: AgentProfile): { providerId: string; model: string | null; effort: string | null; policy: Policy } {
  return { providerId: profile.providerId, model: profile.model || null, effort: profile.effort || null, policy: profile.permissionPolicy };
}

// What a chat started from this profile keeps with it.
export const profileSnapshotOf = (profile: AgentProfile): ProfileSnapshot =>
  ({ id: profile.id, name: profile.name, instructions: profile.instructions });

// The profile a chat started from, by the name it kept then.
export const sessionProfileName = (session: Session): string | null =>
  session.profileId && session.profileName ? session.profileName : null;

// The profile an automation runs from; a deleted one reads as none,
// matching the Mac, whose runs then use the automation's own settings.
export function automationProfileName(automation: Automation, profiles: AgentProfile[] | undefined): string | null {
  return findProfile(profiles, automation.profileId)?.name || null;
}

export function newProfile(profiles: AgentProfile[] | undefined, id: string): AgentProfile {
  return {
    id, name: 'New profile', iconSymbol: null, providerId: 'claude', model: null, effort: null,
    permissionPolicy: 'ask', instructions: '', skills: [], mcpServers: [],
    sortOrder: Math.max(-1, ...(profiles || []).map(profile => profile.sortOrder)) + 1,
    createdAt: swiftDate(),
  };
}
