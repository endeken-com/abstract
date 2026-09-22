/** Mirrors the Rust models in src-tauri/src/models.rs. */

export interface Project {
  id: string;
  name: string;
  executor: 'local' | 'ssh';
  root_path: string;
  ssh_host: string | null;
  ssh_extra_args: string | null;
  default_base_ref: string;
  default_provider_id: string;
  default_permission_policy: string;
  nested_repos: string[];
  worktree_template: string | null;
  branch_prefix: string | null;
  sort_order: number;
  created_at: string;
  archived_at: string | null;
}

export interface Session {
  id: string;
  project_id: string | null;
  name: string;
  provider_id: string;
  provider_session_id: string | null;
  worktree_path: string | null;
  branch: string | null;
  base_ref: string | null;
  status: string;
  status_detail: string | null;
  permission_policy: string;
  prompt: string | null;
  automation_id: string | null;
  created_at: string;
  last_event_at: string | null;
  archived_at: string | null;
  alive: boolean;
}

export interface Automation {
  id: string;
  name: string;
  prompt: string;
  provider_id: string;
  project_id: string | null;
  rrule: string;
  timezone: string;
  dtstart: string;
  workspace_mode: 'new_worktree' | 'pinned';
  pinned_session_id: string | null;
  continue_agent_session: boolean;
  permission_policy: string;
  catch_up: boolean;
  enabled: boolean;
  next_run_at: string | null;
  created_at: string;
  updated_at: string;
}

export interface AutomationRun {
  id: string;
  automation_id: string;
  fired_at: string;
  trigger: 'schedule' | 'manual';
  status: 'creating' | 'created' | 'failed';
  session_id: string | null;
  error: string | null;
}

export interface WorktreeInfo {
  path: string;
  head: string | null;
  branch: string | null;
  bare: boolean;
  detached: boolean;
  locked: boolean;
  session_id: string | null;
  session_name: string | null;
  orphan: boolean;
}

export interface DiffLine {
  origin: ' ' | '+' | '-' | '\\';
  content: string;
}

export interface Hunk {
  index: number;
  header: string;
  old_start: number;
  old_lines: number;
  new_start: number;
  new_lines: number;
  lines: DiffLine[];
  additions: number;
  deletions: number;
  raw: string;
}

export interface FileDiff {
  path: string;
  old_path: string | null;
  status: 'added' | 'modified' | 'deleted' | 'renamed';
  binary: boolean;
  additions: number;
  deletions: number;
  hunks: Hunk[];
  raw_header: string;
}

export interface SessionDiff {
  files: FileDiff[];
  worktree_path: string | null;
  excluded: string[];
}

export interface UsageSummary {
  provider_id: string;
  sessions: number;
  turns: number;
  input_tokens: number;
  output_tokens: number;
  cache_read: number;
  cache_write: number;
  cost_usd: number;
  duration_ms: number;
}

export interface UsageDay {
  day: string;
  provider_id: string;
  input_tokens: number;
  output_tokens: number;
  cost_usd: number;
}

export interface ProviderStatus {
  id: string;
  available: boolean;
  path: string | null;
  version: string | null;
}

export interface ProbeResult {
  root_path: string;
  name: string;
  is_root: boolean;
  nested_repos: string[];
  default_branch: string;
}

export type SessionStreamEvent =
  | { kind: 'line'; session_id: string; seq: number; stream: 'stdout' | 'stderr'; line: string }
  | { kind: 'exit'; session_id: string; code: number | null }
  | { kind: 'status'; session_id: string; status: string; detail: string | null };

export interface FirePayload {
  runId: string;
  automationId: string;
  automationName: string;
  sessionId: string;
  providerId: string;
  prompt: string;
  cwd: string;
  permissionPolicy: string;
  mode: 'launch' | 'resume' | 'continue';
  resumeId: string | null;
}

export interface AppSettings {
  worktree_template?: string;
  branch_prefix?: string;
  accent?: string;
  theme?: 'near-black' | 'black' | 'gray';
  density?: 'comfortable' | 'compact';
  ui_font_size?: number;
  code_font_size?: number;
  notify_attention?: boolean;
  notify_finished?: boolean;
  notify_automation_failed?: boolean;
  default_timezone?: string;
  provider_overrides?: Record<string, { path?: string; extraArgs?: string[]; policy?: string }>;
  [key: string]: unknown;
}
