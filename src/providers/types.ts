/**
 * Provider plugin contract.
 *
 * The Rust core knows nothing about any specific agent CLI. It spawns a
 * `LaunchSpec`, relays raw stdout/stderr lines back, and writes whatever we
 * hand it to stdin. Everything agent-specific lives in a `ProviderDefinition`.
 *
 * Adding a provider = one file in this directory + one line in registry.ts.
 */

export type PermissionPolicy = 'ask' | 'auto-edits' | 'bypass';

export interface LaunchContext {
  /** Working directory on the executor host (the session's worktree). */
  cwd: string;
  prompt: string;
  /** Provider-native session id, when resuming a previous run. */
  resumeId?: string;
  permissionPolicy: PermissionPolicy;
  /** Extra args from settings (per provider). */
  extraArgs?: string[];
  /** Overridden binary path from settings, when set. */
  binaryOverride?: string;
}

export interface LaunchSpec {
  command: string;
  args: string[];
  cwd: string;
  env?: Record<string, string>;
  /** Written to stdin immediately after spawn. */
  stdinInitial?: string;
  /** Keep stdin open for follow-up turns and permission answers. */
  keepStdinOpen: boolean;
}

export type SessionStatus =
  | 'created'
  | 'provisioning'
  | 'running'
  | 'waiting_input'
  | 'finished'
  | 'errored';

/** A single edit produced by a tool call, for the inline mini-diff. */
export interface EditPreview {
  filePath: string;
  additions: number;
  deletions: number;
  /** Unified-diff-ish lines, already trimmed for display. */
  lines: { origin: ' ' | '+' | '-'; content: string }[];
}

export type AgentEvent =
  | { type: 'status'; status: SessionStatus; detail?: string }
  | { type: 'session_id'; id: string }
  | { type: 'system'; model?: string; cwd?: string; permissionMode?: string; sessionId?: string }
  | { type: 'text'; role: 'assistant' | 'user'; text: string; blockId?: string; partial?: boolean }
  | { type: 'thinking'; text: string; blockId?: string; partial?: boolean }
  | { type: 'tool_use'; id: string; name: string; input: unknown; edit?: EditPreview }
  | { type: 'tool_result'; toolUseId: string; output: string; isError?: boolean; edit?: EditPreview }
  | { type: 'permission_request'; requestId: string; toolName: string; input: unknown }
  | { type: 'turn_end'; durationMs?: number; costUsd?: number; usage?: UsageTotals; summary?: string }
  | { type: 'usage'; usage: UsageTotals; costUsd?: number; durationMs?: number; turns?: number }
  | { type: 'error'; message: string }
  | { type: 'raw'; line: string; stream: 'stdout' | 'stderr' };

export interface UsageTotals {
  inputTokens: number;
  outputTokens: number;
  cacheRead: number;
  cacheWrite: number;
}

export interface OutputParser {
  /** One raw line from the agent process. Returns normalized events. */
  feed(line: string, stream: 'stdout' | 'stderr'): AgentEvent[];
  /** Process exited. */
  onExit(code: number | null): AgentEvent[];
}

export interface ProviderDefinition {
  id: string;
  name: string;
  /** Default binary name, looked up on the executor host's PATH. */
  binary: string;
  detectArgs: string[];
  /** Whether follow-up turns reuse the live process (true) or spawn a resume (false). */
  followUpMode: 'stdin' | 'respawn';
  buildLaunch(ctx: LaunchContext): LaunchSpec;
  /** Relaunch continuing a provider-native session. */
  buildResume(ctx: LaunchContext & { resumeId: string }): LaunchSpec;
  createParser(): OutputParser;
  /** Line written to stdin for a follow-up turn (stdin mode only). */
  buildUserMessage?(text: string): string;
  /** Line written to stdin answering a permission request (stdin mode only). */
  buildPermissionResponse?(requestId: string, allow: boolean, updatedInput?: unknown): string;
}
