import type { PendingPermission, PlanState, Policy } from './types';

// The composer's modes, in the Mac's order. The last two are read-only:
// Plan writes a plan for approval, Ask only looks and answers.
export const MODE_CHOICES: Array<{ id: Policy; title: string; short: string }> = [
  { id: 'ask', title: 'Ask before acting', short: 'Ask first' },
  { id: 'auto-edits', title: 'Accept edits', short: 'Accept edits' },
  { id: 'bypass', title: 'Full autonomy', short: 'Full autonomy' },
  { id: 'plan', title: 'Plan', short: 'Plan' },
  { id: 'read-only', title: 'Ask (read-only)', short: 'Ask' },
];

export const policyTitle = (policy?: string | null): string =>
  MODE_CHOICES.find(choice => choice.id === policy)?.title || 'Ask before acting';

export const policyShort = (policy?: string | null): string =>
  MODE_CHOICES.find(choice => choice.id === policy)?.short || 'Ask first';

export const isReadOnlyMode = (policy?: string | null): boolean => policy === 'plan' || policy === 'read-only';

export const isExitPlanMode = (toolName?: string | null): boolean =>
  (toolName || '').toLowerCase() === 'exitplanmode';

// Shown while the plan still needs a decision, or is being revised.
export const visiblePlan = (plan?: PlanState | null): PlanState | null =>
  plan?.revisions?.length && (plan.status === 'waiting' || plan.status === 'changesRequested') ? plan : null;

export const currentPlan = (plan?: PlanState | null): string | null => plan?.revisions?.at(-1) || null;

export const planHistory = (plan?: PlanState | null): string[] => (plan?.revisions || []).slice(0, -1);

export const planTitle = (plan: PlanState): string =>
  plan.revisions.length > 1 ? `Plan · revision ${plan.revisions.length}` : 'Plan';

// A Mac from before plan snapshots still sends Claude's ExitPlanMode as a
// pending permission; its input carries the plan.
export const planFromPermissions = (permissions?: PendingPermission[] | null): PlanState | null => {
  const request = (permissions || []).find(item => isExitPlanMode(item.toolName));
  const text = typeof request?.input?.plan === 'string' ? request.input.plan.trim() : '';
  return text ? { revisions: [text], status: 'waiting' } : null;
};

export const pendingPlanRequest = (permissions?: PendingPermission[] | null): PendingPermission | null =>
  (permissions || []).find(item => isExitPlanMode(item.toolName)) || null;

// The plan to show: the Mac's snapshot first, the pending tool call as fallback.
export const effectivePlan = (plan?: PlanState | null, permissions?: PendingPermission[] | null): PlanState | null =>
  visiblePlan(plan) || planFromPermissions(permissions);

// Permission cards minus the plan tool call, which the plan card covers.
export const nonPlanPermissions = (permissions?: PendingPermission[] | null): PendingPermission[] =>
  (permissions || []).filter(item => !isExitPlanMode(item.toolName));

// The plan as a quote, waiting in the composer for what to change.
export const quotedPlan = (plan: string): string =>
  plan.split('\n').map(line => (line ? `> ${line}` : '>')).join('\n');
