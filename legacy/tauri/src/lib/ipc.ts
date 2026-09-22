import { Channel, invoke } from '@tauri-apps/api/core';
import { listen, type UnlistenFn } from '@tauri-apps/api/event';
import type { LaunchSpec } from '../providers/types';
import type {
  AppSettings,
  Automation,
  AutomationRun,
  FileDiff,
  FirePayload,
  ProbeResult,
  Project,
  ProviderStatus,
  Session,
  SessionDiff,
  SessionStreamEvent,
  UsageDay,
  UsageSummary,
  WorktreeInfo,
} from './types';

/**
 * Every backend call goes through here. `deviceId` is reserved for the LAN
 * remote-control layer: today only the local device exists, and remote calls
 * will be routed by the Rust side under the same signatures.
 */

export const settings = {
  getAll: () => invoke<AppSettings>('settings_get_all'),
  set: (key: string, value: unknown) => invoke<void>('settings_set', { key, value }),
};

export const projects = {
  probe: (path: string) => invoke<ProbeResult>('project_probe', { args: { path } }),
  add: (args: {
    name: string;
    root_path: string;
    default_base_ref?: string;
    default_provider_id?: string;
    default_permission_policy?: string;
    nested_repos?: string[];
  }) => invoke<Project>('project_add', { args }),
  list: () => invoke<Project[]>('projects_list'),
  update: (project: Project) => invoke<void>('project_update', { project }),
  remove: (id: string) => invoke<void>('project_delete', { id }),
};

export const providers = {
  detect: (
    list: { id: string; binary: string; detect_args: string[] }[],
    projectId?: string,
  ) => invoke<ProviderStatus[]>('providers_detect', { args: { providers: list, project_id: projectId } }),
};

export const sessions = {
  create: (args: {
    project_id: string | null;
    provider_id: string;
    prompt: string;
    name?: string;
    base_ref?: string;
    permission_policy?: string;
    automation_id?: string;
  }) => invoke<Session>('session_create', { args }),
  list: () => invoke<Session[]>('sessions_list'),
  get: (id: string) => invoke<Session>('session_get', { id }),
  launch: (id: string, spec: LaunchSpec) =>
    invoke<void>('session_launch', {
      id,
      spec: {
        command: spec.command,
        args: spec.args,
        cwd: spec.cwd,
        env: spec.env ?? {},
        stdin_initial: spec.stdinInitial ?? null,
        keep_stdin_open: spec.keepStdinOpen,
      },
    }),
  write: (id: string, data: string) => invoke<void>('session_write', { id, data }),
  stop: (id: string) => invoke<void>('session_stop', { id }),
  setStatus: (id: string, status: string, detail?: string) =>
    invoke<void>('session_set_status', { id, status, detail: detail ?? null }),
  setProviderSessionId: (id: string, providerSessionId: string) =>
    invoke<void>('session_set_provider_session_id', { id, providerSessionId }),
  rename: (id: string, name: string) => invoke<void>('session_rename', { id, name }),
  archive: (id: string, archived: boolean) => invoke<void>('session_archive', { id, archived }),
  replay: (id: string, fromSeq = 0) =>
    invoke<SessionStreamEvent[]>('session_replay', { id, fromSeq }),
  remove: (id: string, removeWorktree: boolean, deleteBranch: boolean) =>
    invoke<void>('session_delete', {
      args: { id, remove_worktree: removeWorktree, delete_branch: deleteBranch },
    }),
  /** One global stream of raw agent output; callers filter by session id. */
  subscribe: (onEvent: (ev: SessionStreamEvent) => void) => {
    const channel = new Channel<SessionStreamEvent>();
    channel.onmessage = onEvent;
    return invoke<void>('session_subscribe', { channel });
  },
};

export const usage = {
  record: (record: {
    session_id: string;
    project_id: string | null;
    provider_id: string;
    input_tokens: number;
    output_tokens: number;
    cache_read: number;
    cache_write: number;
    cost_usd: number;
    duration_ms: number;
    turns: number;
  }) => invoke<void>('usage_record', { record }),
  summary: (since?: string, projectId?: string) =>
    invoke<UsageSummary[]>('usage_summary', { since: since ?? null, projectId: projectId ?? null }),
  byDay: (since?: string) => invoke<UsageDay[]>('usage_by_day', { since: since ?? null }),
};

export const worktrees = {
  list: (projectId: string) => invoke<WorktreeInfo[]>('worktrees_list', { projectId }),
  remove: (projectId: string, path: string, deleteBranch?: string) =>
    invoke<void>('worktree_remove', {
      args: { project_id: projectId, path, delete_branch: deleteBranch ?? null },
    }),
  prune: (projectId: string) => invoke<void>('worktree_prune', { projectId }),
};

export const diff = {
  collect: (sessionId: string) => invoke<SessionDiff>('diff_collect', { sessionId }),
  fileContents: (sessionId: string, path: string) =>
    invoke<{ original: string; modified: string }>('diff_file_contents', { sessionId, path }),
  accept: (sessionId: string, path?: string, hunks: number[] = []) =>
    invoke<void>('diff_accept', { args: { session_id: sessionId, path: path ?? null, hunks } }),
  reject: (sessionId: string, path?: string, hunks: number[] = []) =>
    invoke<void>('diff_reject', { args: { session_id: sessionId, path: path ?? null, hunks } }),
};

export const automations = {
  save: (args: {
    id?: string;
    name: string;
    prompt: string;
    provider_id: string;
    project_id: string | null;
    rrule: string;
    timezone: string;
    dtstart?: string;
    workspace_mode?: 'new_worktree' | 'pinned';
    pinned_session_id?: string | null;
    continue_agent_session?: boolean;
    permission_policy?: string;
    catch_up?: boolean;
    enabled?: boolean;
  }) => invoke<Automation>('automation_save', { args }),
  list: () => invoke<Automation[]>('automations_list'),
  get: (id: string) => invoke<Automation>('automation_get', { id }),
  setEnabled: (id: string, enabled: boolean) =>
    invoke<Automation>('automation_set_enabled', { id, enabled }),
  remove: (id: string) => invoke<void>('automation_delete', { id }),
  runs: (id: string, limit = 20) => invoke<AutomationRun[]>('automation_runs', { id, limit }),
  runNow: (id: string) => invoke<string>('automation_run_now', { id }),
  reportRun: (runId: string, status: string, sessionId?: string, error?: string) =>
    invoke<void>('automation_run_report', {
      runId,
      status,
      sessionId: sessionId ?? null,
      error: error ?? null,
    }),
  schedulePreview: (rrule: string, timezone: string, dtstart?: string, count = 3) =>
    invoke<string[]>('schedule_preview', { rrule, timezone, dtstart: dtstart ?? null, count }),
  presetRrule: (preset: string, hour: number, minute: number) =>
    invoke<string>('schedule_preset', { preset, hour, minute }),
};

/** Backend-pushed events. */
export const events = {
  onAutomationFire: (cb: (p: FirePayload) => void): Promise<UnlistenFn> =>
    listen<FirePayload>('automation://fire', (e) => cb(e.payload)),
  onAutomationFailed: (cb: (runId: string, error: string) => void): Promise<UnlistenFn> =>
    listen<[string, string]>('automation://failed', (e) => cb(e.payload[0], e.payload[1])),
  onAutomationsChanged: (cb: () => void): Promise<UnlistenFn> =>
    listen('automations://changed', () => cb()),
  onSessionsChanged: (cb: () => void): Promise<UnlistenFn> =>
    listen('sessions://changed', () => cb()),
};

export type { FileDiff };
