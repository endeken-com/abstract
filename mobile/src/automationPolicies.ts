import type { AutomationConcurrency, AutomationMissedRuns, AutomationRun } from './types';

// The Mac's words for what still-going, missed and unchanged runs do
// (AutomationSupport.swift). Values are the raw values the Mac stores.
export const RUN_EACH_LIMIT = 5;

export const CONCURRENCY_OPTIONS: { value: AutomationConcurrency; label: string; phrase: string }[] = [
  { value: 'skip_if_active', label: 'Skip This One', phrase: 'skip this one' },
  { value: 'run_after', label: 'Run After It Finishes', phrase: 'run after it finishes' },
  { value: 'start_another', label: 'Start Another', phrase: 'start another' },
];

export const MISSED_OPTIONS: { value: AutomationMissedRuns; label: string; phrase: string }[] = [
  { value: 'skip', label: 'Skip Them', phrase: 'skip them' },
  { value: 'run_once', label: 'Run Once', phrase: 'run once' },
  { value: 'run_each', label: `Run Each, Up to ${RUN_EACH_LIMIT}`, phrase: `run each, up to ${RUN_EACH_LIMIT}` },
];

export const CHANGED_OPTIONS: { value: boolean; label: string; phrase: string }[] = [
  { value: false, label: 'Whether or Not the Project Changed', phrase: 'whether or not the project changed' },
  { value: true, label: 'Only When the Project Changed Since the Last Run', phrase: 'only when the project changed since the last run' },
];

export type AutomationPolicies = { concurrency: AutomationConcurrency; missedRuns: AutomationMissedRuns; onlyWhenChanged: boolean };
type WorkspaceMode = 'new_worktree' | 'pinned';

// A run that continues one chat skips rather than piling onto it.
export const defaultConcurrency = (mode: WorkspaceMode): AutomationConcurrency => mode === 'pinned' ? 'skip_if_active' : 'start_another';

// The switch the missed-runs choice replaced, kept in step for older Macs.
export const catchUpOf = (missedRuns: AutomationMissedRuns): boolean => missedRuns !== 'skip';

// An older Mac's automations carry only the catch-up switch. Anything
// unrecognised falls back the way the Mac's own decoder does.
export function policiesOf(
  a: { concurrency?: string | null; missedRuns?: string | null; onlyWhenChanged?: boolean | null; catchUp?: boolean | null } | undefined,
  mode: WorkspaceMode,
): AutomationPolicies {
  const concurrency = CONCURRENCY_OPTIONS.find(o => o.value === a?.concurrency)?.value ?? defaultConcurrency(mode);
  const missedRuns = MISSED_OPTIONS.find(o => o.value === a?.missedRuns)?.value ?? (a?.catchUp ? 'run_once' : 'skip');
  return { concurrency, missedRuns, onlyWhenChanged: a?.onlyWhenChanged ?? false };
}

// Switch where runs happen: a still-going choice nobody changed follows
// to the new place's default; one they picked stays.
export const concurrencyForWorkspace = (current: AutomationConcurrency, from: WorkspaceMode, to: WorkspaceMode): AutomationConcurrency =>
  current === defaultConcurrency(from) ? defaultConcurrency(to) : current;

// A project on that Mac is what "changed since the last run" reads.
export const showsChanged = (a: { projectId: string | null; deviceId?: string | null }): boolean => a.projectId != null && !a.deviceId;

export function runStatusLabel(run: Pick<AutomationRun, 'status'>): string {
  switch (run.status) {
    case 'creating': return 'Starting…';
    case 'created': return 'Created';
    case 'failed': return 'Failed';
    case 'skipped': return 'Skipped';
    default: return run.status;
  }
}

// The line under a run: why a skipped run didn't start (capitalised, as
// the Mac's run history shows it), or what a failed run hit.
export function runDetail(run: Pick<AutomationRun, 'status' | 'reason' | 'error'>): string | null {
  if (run.status === 'skipped') {
    const reason = run.reason?.trim();
    return reason ? reason.charAt(0).toUpperCase() + reason.slice(1) + '.' : null;
  }
  return run.error?.trim() || null;
}
