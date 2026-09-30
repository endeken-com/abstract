export type Policy = 'ask' | 'auto-edits' | 'bypass';
export type Project = {
  id: string; name: string; rootPath: string; defaultBaseRef: string;
  defaultProviderId: string; defaultPermissionPolicy: Policy;
};
export type Session = {
  id: string; projectId: string | null; name: string; providerId: string;
  worktreePath: string | null; branch: string | null; baseRef: string | null;
  status: string; statusDetail: string | null; permissionPolicy: Policy;
  prompt: string | null; archivedAt: number | null; createdAt: number;
  lastEventAt?: number | null;
  model: string | null; effort: string | null;
};
export type AutomationTrigger = { id: string; rrule: string; timezone: string; dtstart: number };
export type Automation = {
  id: string; name: string; prompt: string; providerId: string;
  projectId: string | null; triggers: AutomationTrigger[];
  workspaceMode: 'new_worktree' | 'pinned'; pinnedSessionId: string | null;
  continueAgentSession: boolean; permissionPolicy: Policy; catchUp: boolean;
  enabled: boolean; nextRunAt: number | null; createdAt: number;
  updatedAt: number; model: string | null; effort: string | null;
};
export type AutomationRun = { id: string; automationId: string; firedAt: number; trigger: string; status: string; sessionId: string | null; error: string | null };
export type PendingPermission = { requestId: string; toolName: string; input: any };
export type PullRequestCheck = { name: string; workflow?: string | null; outcome: 'passed' | 'failed' | 'pending' | 'skipped'; url?: string | null };
export type PullRequestComment = { author: string; body: string; createdAt?: number | null; isBot: boolean };
export type PullRequestReview = { author: string; verdict: string; body: string; submittedAt?: number | null };
export type PullRequestThread = { id: string; path: string; line?: number | null; isResolved: boolean; isOutdated: boolean; comments: PullRequestComment[] };
export type PullRequest = { number: number; title: string; state: string; isDraft: boolean; url?: string; standing?: string | null; reviewDecision?: string | null; hasConflicts?: boolean; checks?: PullRequestCheck[]; head?: string | null; base?: string | null; author?: string | null; additions?: number | null; deletions?: number | null; body?: string | null; reviews?: PullRequestReview[]; comments?: PullRequestComment[]; threads?: PullRequestThread[] };
export type ModelOption = { id: string; label: string; detail?: string | null; efforts: string[]; defaultEffort?: string | null };
export type ModelCatalog = { accountDefault?: ModelOption | null; models: ModelOption[]; versions: ModelOption[] };
export type Snapshot = { projects: Project[]; sessions: Session[]; providers: string[]; alive: string[]; home?: string; modelCatalogs?: Record<string, ModelCatalog>; defaultModelNames?: Record<string, string>; automations?: Automation[]; pendingPermissions?: Record<string, PendingPermission[]>; pullRequests?: Record<string, PullRequest>; turnStartedAt?: Record<string, number>; pagedHistory?: boolean; internetAddress?: InternetAddress };
export type Peer = { id: string; name: string; publicKey: string };
export type InternetAddress = { endpointId: string };
export type Device = { peer: Peer; address: string; pairedAt: number; internetAddress?: InternetAddress };
export type Nearby = { id: string; name: string; address: string };
export type RemoteLine = { seq: number; line: { stream: string; line: string } };
export const swiftDate = () => Date.now() / 1000 - 978307200;
export const displayDate = (value?: number | null) => value == null ? '' : new Date((value + 978307200) * 1000).toLocaleString();
