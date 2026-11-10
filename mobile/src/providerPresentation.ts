import type { ProviderPresentation, Snapshot } from './types';

// Only older hosts need this compatibility list. New hosts supply labels.
const legacyLabels: Record<string, string> = { claude: 'Claude Code', codex: 'Codex', opencode: 'OpenCode', muse: 'Muse Code' };
export const providerPresentation = (snapshot: Snapshot | null | undefined, id: string): ProviderPresentation | undefined =>
  snapshot?.providerPresentations?.find(provider => provider.id === id);
export const providerLabel = (snapshot: Snapshot | null | undefined, id: string): string =>
  providerPresentation(snapshot, id)?.label || legacyLabels[id] || id;
