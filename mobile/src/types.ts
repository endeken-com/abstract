export type Policy = 'ask' | 'auto-edits' | 'bypass' | 'plan' | 'read-only';
export type PlanStatus = 'waiting' | 'approved' | 'discarded' | 'changesRequested';
export type PlanState = { revisions: string[]; status: PlanStatus };
export type Project = {
  id: string; name: string; rootPath: string; defaultBaseRef: string;
  defaultProviderId: string; defaultPermissionPolicy: Policy;
  // The paired Mac new chats for this project start on, stored on this
  // record on the Mac that owns it; null/absent = that Mac.
  defaultDeviceId?: string | null;
  // The profiles this project offers; absent = every profile shows.
  profileIds?: string[] | null;
  /** Agents may look up code history; null/absent (older Macs) = yes. */
  agentHistory?: boolean | null;
  iconSymbol?: string | null; iconColor?: string | null; iconImagePath?: string | null;
};
// A named setup a chat or automation starts from, saved on the Mac.
export type AgentProfile = {
  id: string; name: string; iconSymbol?: string | null; providerId: string;
  model?: string | null; effort?: string | null; permissionPolicy: Policy;
  instructions: string; skills: string[]; mcpServers: string[];
  sortOrder: number; createdAt: number;
};
// What a chat started from a profile keeps: id, name, instructions then.
export type ProfileSnapshot = { id: string; name: string; instructions: string };
export type Session = {
  id: string; projectId: string | null; name: string; providerId: string;
  worktreePath: string | null; branch: string | null; baseRef: string | null;
  status: string; statusDetail: string | null; permissionPolicy: Policy;
  prompt: string | null; archivedAt: number | null; createdAt: number;
  lastEventAt?: number | null; pinnedAt?: number | null;
  model: string | null; effort: string | null;
  profileId?: string | null; profileName?: string | null; profileInstructions?: string | null;
};
export type AutomationTrigger = { id: string; rrule: string; timezone: string; dtstart: number };
// What a scheduled run does when the last one is still going / runs were missed.
export type AutomationConcurrency = 'skip_if_active' | 'run_after' | 'start_another';
export type AutomationMissedRuns = 'skip' | 'run_once' | 'run_each';
export type Automation = {
  id: string; name: string; prompt: string; providerId: string;
  projectId: string | null; triggers: AutomationTrigger[];
  workspaceMode: 'new_worktree' | 'pinned'; pinnedSessionId: string | null;
  continueAgentSession: boolean; permissionPolicy: Policy; catchUp: boolean;
  // Absent from an older Mac's snapshot; `policiesOf` fills them in.
  concurrency?: AutomationConcurrency; missedRuns?: AutomationMissedRuns; onlyWhenChanged?: boolean;
  enabled: boolean; nextRunAt: number | null; createdAt: number;
  updatedAt: number; model: string | null; effort: string | null;
  deviceId?: string | null; profileId?: string | null;
};
export type AutomationRun = { id: string; automationId: string; firedAt: number; trigger: string; status: string; sessionId?: string | null; error?: string | null; reason?: string | null; baseCommit?: string | null };
export type PendingPermission = { requestId: string; toolName: string; input: any };
export type PermissionRuleKind = 'command' | 'path' | 'tool';
export type PermissionDecision = 'allow' | 'deny';
export type PermissionRule = { id: string; projectId: string; kind: PermissionRuleKind; pattern: string; decision: PermissionDecision; expiresAt: number | null; createdAt: number };
export type PullRequestCheck = { name: string; workflow?: string | null; outcome: 'passed' | 'failed' | 'pending' | 'skipped'; url?: string | null };
export type PullRequestComment = { author: string; body: string; createdAt?: number | null; isBot: boolean };
export type PullRequestReview = { author: string; verdict: string; body: string; submittedAt?: number | null };
export type PullRequestThread = { id: string; path: string; line?: number | null; isResolved: boolean; isOutdated: boolean; comments: PullRequestComment[] };
export type PullRequest = { number: number; title: string; state: string; isDraft: boolean; url?: string; standing?: string | null; reviewDecision?: string | null; hasConflicts?: boolean; checks?: PullRequestCheck[]; head?: string | null; base?: string | null; author?: string | null; additions?: number | null; deletions?: number | null; body?: string | null; reviews?: PullRequestReview[]; comments?: PullRequestComment[]; threads?: PullRequestThread[] };
export type ModelOption = { id: string; label: string; detail?: string | null; efforts: string[]; defaultEffort?: string | null };
export type ModelCatalog = { accountDefault?: ModelOption | null; models: ModelOption[]; versions: ModelOption[] };
export type Stall = { state: 'quiet' | 'stalled'; since: number };
// A message sent while the agent worked, waiting for its turn to end (ABS-103).
export type QueuedMessage = { id: string; text: string; attachments: { id: string; kind: string; title: string; reference?: string | null }[]; queuedAt: number; sending?: boolean | null };
export type Snapshot = { projects: Project[]; sessions: Session[]; providers: string[]; alive: string[]; home?: string; modelCatalogs?: Record<string, ModelCatalog>; defaultModelNames?: Record<string, string>; automations?: Automation[]; pendingPermissions?: Record<string, PendingPermission[]>; permissionRules?: Record<string, PermissionRule[]>; pullRequests?: Record<string, PullRequest>; turnStartedAt?: Record<string, number>; pagedHistory?: boolean; internetAddress?: InternetAddress; backgroundTasks?: string[]; unmergedWork?: Record<string, boolean>; automationDevice?: boolean; projectDefaultDevice?: boolean; profiles?: AgentProfile[]; everythingPaused?: boolean; pausedProjectIds?: string[]; pauseControl?: boolean; stalls?: Record<string, Stall>; codeHistory?: boolean; plans?: Record<string, PlanState>; planApproval?: boolean; projectIcons?: Record<string, string>; queuedMessages?: Record<string, QueuedMessage[]>; messageQueue?: boolean; steerAgents?: string[] };
export type Peer = { id: string; name: string; publicKey: string };
export type InternetAddress = { endpointId: string };
export type Device = { peer: Peer; address: string; pairedAt: number; internetAddress?: InternetAddress };
export type Nearby = { id: string; name: string; address: string };
export type RemoteLine = { seq: number; line: { stream: string; line: string } };
export const swiftDate = () => Date.now() / 1000 - 978307200;
export const displayDate = (value?: number | null) => value == null ? '' : new Date((value + 978307200) * 1000).toLocaleString();
