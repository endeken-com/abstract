import { create } from 'zustand';
import {
  isPermissionGranted,
  requestPermission,
  sendNotification,
} from '@tauri-apps/plugin-notification';
import * as ipc from '../lib/ipc';
import { getProvider, PROVIDERS } from '../providers/registry';
import type { AgentEvent, OutputParser, PermissionPolicy } from '../providers/types';
import type {
  AppSettings,
  Automation,
  FirePayload,
  Project,
  ProviderStatus,
  Session,
  SessionStreamEvent,
} from '../lib/types';

export type View = 'chat' | 'diff' | 'worktrees' | 'automations' | 'settings';
export type ChatTab = 'chat' | 'diff';

/**
 * Selectors must return stable references. zustand v5 on React 19 treats a
 * fresh `[]` from `s.map[id] ?? []` as a changed snapshot on every read and
 * loops until React gives up and unmounts the tree (the "app turns black"
 * bug). Use these shared empties instead of inline literals.
 */
export const EMPTY_TIMELINE: readonly TimelineEntry[] = Object.freeze([]);
export const EMPTY_PERMISSIONS: readonly PendingPermission[] = Object.freeze([]);

export interface TimelineEntry {
  id: string;
  at: number;
  event: AgentEvent;
}

export interface PendingPermission {
  requestId: string;
  toolName: string;
  input: unknown;
}

/** Parsers are mutable and long-lived; they never belong in React state. */
const parsers = new Map<string, OutputParser>();
const seenSeq = new Map<string, number>();

function parserFor(session: Session): OutputParser {
  let p = parsers.get(session.id);
  if (!p) {
    p = getProvider(session.provider_id).createParser();
    parsers.set(session.id, p);
  }
  return p;
}

function resetParser(session: Session) {
  parsers.set(session.id, getProvider(session.provider_id).createParser());
}

interface AppStore {
  ready: boolean;
  error: string | null;
  settings: AppSettings;
  projects: Project[];
  sessions: Session[];
  automations: Automation[];
  providerStatus: Record<string, ProviderStatus>;
  timelines: Record<string, TimelineEntry[]>;
  permissions: Record<string, PendingPermission[]>;
  selectedSessionId: string | null;
  selectedAutomationId: string | null;
  selectedProjectId: string | null;
  view: View;
  collapsedProjects: Record<string, boolean>;
  showArchived: boolean;
  chatTab: ChatTab;
  paletteOpen: boolean;
  /** undefined = closed; null = open with no preselected project. */
  newChatFor: string | null | undefined;
  addProjectOpen: boolean;

  init: () => Promise<void>;
  refreshProjects: () => Promise<void>;
  refreshSessions: () => Promise<void>;
  refreshAutomations: () => Promise<void>;
  setSetting: (key: string, value: unknown) => Promise<void>;
  applyAppearance: () => void;

  selectSession: (id: string | null) => Promise<void>;
  selectAutomation: (id: string | null) => void;
  setView: (v: View) => void;
  toggleProject: (id: string) => void;
  setShowArchived: (v: boolean) => void;
  setChatTab: (t: ChatTab) => void;
  setPaletteOpen: (v: boolean) => void;
  openNewChat: (projectId: string | null) => void;
  closeNewChat: () => void;
  setAddProjectOpen: (v: boolean) => void;
  renameSession: (id: string, name: string) => Promise<void>;
  archiveSession: (id: string, archived: boolean) => Promise<void>;

  startChat: (args: {
    projectId: string | null;
    providerId: string;
    prompt: string;
    baseRef?: string;
    permissionPolicy?: PermissionPolicy;
  }) => Promise<Session>;
  sendFollowUp: (sessionId: string, text: string) => Promise<void>;
  answerPermission: (sessionId: string, requestId: string, allow: boolean) => Promise<void>;
  stopSession: (sessionId: string) => Promise<void>;
  restartSession: (sessionId: string) => Promise<void>;
  deleteSession: (sessionId: string, removeWorktree: boolean, deleteBranch: boolean) => Promise<void>;
}

export const useApp = create<AppStore>((set, get) => ({
  ready: false,
  error: null,
  settings: {},
  projects: [],
  sessions: [],
  automations: [],
  providerStatus: {},
  timelines: {},
  permissions: {},
  selectedSessionId: null,
  selectedAutomationId: null,
  selectedProjectId: null,
  view: 'chat',
  collapsedProjects: {},
  showArchived: false,
  chatTab: 'chat',
  paletteOpen: false,
  newChatFor: undefined,
  addProjectOpen: false,

  async init() {
    try {
      const [settings, projects, sessions, automations] = await Promise.all([
        ipc.settings.getAll(),
        ipc.projects.list(),
        ipc.sessions.list(),
        ipc.automations.list(),
      ]);
      set({ settings, projects, sessions, automations, ready: true });
      get().applyAppearance();

      void ipc.providers
        .detect(PROVIDERS.map((p) => ({ id: p.id, binary: p.binary, detect_args: p.detectArgs })))
        .then((list) => {
          const map: Record<string, ProviderStatus> = {};
          for (const s of list) map[s.id] = s;
          set({ providerStatus: map });
        })
        .catch(() => undefined);

      await ipc.sessions.subscribe((ev) => handleStreamEvent(ev, set, get));
      await ipc.events.onAutomationFire((p) => void handleAutomationFire(p, get));
      await ipc.events.onAutomationsChanged(() => void get().refreshAutomations());
      await ipc.events.onSessionsChanged(() => void get().refreshSessions());
      await ipc.events.onAutomationFailed((_runId, error) => {
        if (get().settings.notify_automation_failed !== false) {
          void notify('Automation failed', error);
        }
      });
    } catch (e) {
      set({ error: String(e), ready: true });
    }
  },

  async refreshProjects() {
    set({ projects: await ipc.projects.list() });
  },
  async refreshSessions() {
    set({ sessions: await ipc.sessions.list() });
  },
  async refreshAutomations() {
    set({ automations: await ipc.automations.list() });
  },

  async setSetting(key, value) {
    await ipc.settings.set(key, value);
    set({ settings: { ...get().settings, [key]: value } });
    get().applyAppearance();
  },

  applyAppearance() {
    const s = get().settings;
    const root = document.documentElement;
    root.dataset.theme = s.theme ?? 'near-black';
    root.dataset.density = s.density ?? 'comfortable';
    root.style.setProperty('--bt-accent', s.accent ?? '#ff5f1f');
    root.style.setProperty('--bt-ui-size', `${s.ui_font_size ?? 14}px`);
    root.style.setProperty('--bt-code-size', `${s.code_font_size ?? 13}px`);
  },

  async selectSession(id) {
    const changed = id !== get().selectedSessionId;
    set({
      selectedSessionId: id,
      selectedAutomationId: null,
      view: 'chat',
      chatTab: changed ? 'chat' : get().chatTab,
    });
    if (!id) return;
    if (get().timelines[id]?.length) return;

    const session = get().sessions.find((s) => s.id === id);
    if (!session) return;
    // Rebuild the timeline from the recorded raw output.
    resetParser(session);
    const parser = parserFor(session);
    const replay = await ipc.sessions.replay(id, 0);
    let entries: TimelineEntry[] = [];
    let maxSeq = 0;
    for (const ev of replay) {
      if (ev.kind !== 'line') continue;
      maxSeq = Math.max(maxSeq, ev.seq);
      for (const agentEvent of safeFeed(parser, ev.line, ev.stream)) {
        entries = appendEvent(entries, agentEvent);
      }
    }
    seenSeq.set(id, maxSeq);
    set({ timelines: { ...get().timelines, [id]: entries } });
  },

  selectAutomation(id) {
    set({ selectedAutomationId: id, view: 'automations' });
  },
  setView(v) {
    set({ view: v, paletteOpen: false });
  },
  toggleProject(id) {
    const c = { ...get().collapsedProjects };
    c[id] = !c[id];
    set({ collapsedProjects: c });
  },
  setShowArchived(v) {
    set({ showArchived: v });
  },
  setChatTab(t) {
    set({ chatTab: t, view: 'chat' });
  },
  setPaletteOpen(v) {
    set({ paletteOpen: v });
  },
  openNewChat(projectId) {
    set({ newChatFor: projectId, paletteOpen: false });
  },
  closeNewChat() {
    set({ newChatFor: undefined });
  },
  setAddProjectOpen(v) {
    set({ addProjectOpen: v, paletteOpen: false });
  },
  async renameSession(id, name) {
    await ipc.sessions.rename(id, name);
    await get().refreshSessions();
  },
  async archiveSession(id, archived) {
    await ipc.sessions.archive(id, archived);
    if (archived && get().selectedSessionId === id) set({ selectedSessionId: null });
    await get().refreshSessions();
  },

  async startChat({ projectId, providerId, prompt, baseRef, permissionPolicy }) {
    const project = get().projects.find((p) => p.id === projectId) ?? null;
    const policy =
      permissionPolicy ?? ((project?.default_permission_policy as PermissionPolicy) || 'ask');
    const session = await ipc.sessions.create({
      project_id: projectId,
      provider_id: providerId,
      prompt,
      base_ref: baseRef,
      permission_policy: policy,
    });
    await get().refreshSessions();
    set({ selectedSessionId: session.id, view: 'chat', timelines: { ...get().timelines, [session.id]: [] } });

    const provider = getProvider(providerId);
    resetParser(session);
    const spec = provider.buildLaunch({
      cwd: session.worktree_path ?? '',
      prompt,
      permissionPolicy: policy,
      extraArgs: extraArgsFor(get().settings, providerId),
      binaryOverride: binaryFor(get().settings, providerId),
    });
    await ipc.sessions.launch(session.id, spec);
    await get().refreshSessions();
    return session;
  },

  async sendFollowUp(sessionId, text) {
    const session = get().sessions.find((s) => s.id === sessionId);
    if (!session) return;
    const provider = getProvider(session.provider_id);

    pushEvent(set, get, sessionId, { type: 'text', role: 'user', text });

    if (provider.followUpMode === 'stdin' && session.alive && provider.buildUserMessage) {
      await ipc.sessions.write(sessionId, provider.buildUserMessage(text));
      await ipc.sessions.setStatus(sessionId, 'running');
      await get().refreshSessions();
      return;
    }
    // Respawn providers (and dead stdin ones) continue by resuming.
    const resumeId = session.provider_session_id;
    const ctx = {
      cwd: session.worktree_path ?? '',
      prompt: text,
      permissionPolicy: session.permission_policy as PermissionPolicy,
      extraArgs: extraArgsFor(get().settings, session.provider_id),
      binaryOverride: binaryFor(get().settings, session.provider_id),
    };
    const spec = resumeId
      ? provider.buildResume({ ...ctx, resumeId })
      : provider.buildLaunch(ctx);
    resetParser(session);
    await ipc.sessions.launch(sessionId, spec);
    await get().refreshSessions();
  },

  async answerPermission(sessionId, requestId, allow) {
    const session = get().sessions.find((s) => s.id === sessionId);
    if (!session) return;
    const provider = getProvider(session.provider_id);
    const pending = get().permissions[sessionId] ?? [];
    const request = pending.find((p) => p.requestId === requestId);
    if (provider.buildPermissionResponse) {
      await ipc.sessions.write(
        sessionId,
        provider.buildPermissionResponse(requestId, allow, request?.input),
      );
    }
    set({
      permissions: {
        ...get().permissions,
        [sessionId]: pending.filter((p) => p.requestId !== requestId),
      },
    });
    await ipc.sessions.setStatus(sessionId, 'running');
    await get().refreshSessions();
  },

  async stopSession(sessionId) {
    await ipc.sessions.stop(sessionId);
    await get().refreshSessions();
  },

  async restartSession(sessionId) {
    const session = get().sessions.find((s) => s.id === sessionId);
    if (!session) return;
    const provider = getProvider(session.provider_id);
    const ctx = {
      cwd: session.worktree_path ?? '',
      prompt: session.prompt ?? '',
      permissionPolicy: session.permission_policy as PermissionPolicy,
      extraArgs: extraArgsFor(get().settings, session.provider_id),
      binaryOverride: binaryFor(get().settings, session.provider_id),
    };
    const spec = session.provider_session_id
      ? provider.buildResume({ ...ctx, resumeId: session.provider_session_id })
      : provider.buildLaunch(ctx);
    resetParser(session);
    await ipc.sessions.launch(sessionId, spec);
    await get().refreshSessions();
  },

  async deleteSession(sessionId, removeWorktree, deleteBranch) {
    await ipc.sessions.remove(sessionId, removeWorktree, deleteBranch);
    parsers.delete(sessionId);
    seenSeq.delete(sessionId);
    const timelines = { ...get().timelines };
    delete timelines[sessionId];
    set({
      timelines,
      selectedSessionId: get().selectedSessionId === sessionId ? null : get().selectedSessionId,
    });
    await get().refreshSessions();
  },
}));

// ---------------- stream plumbing ----------------

type Setter = (partial: Partial<AppStore>) => void;
type Getter = () => AppStore;

function safeFeed(parser: OutputParser, line: string, stream: 'stdout' | 'stderr'): AgentEvent[] {
  try {
    return parser.feed(line, stream);
  } catch {
    return [{ type: 'raw', line, stream }];
  }
}

function handleStreamEvent(ev: SessionStreamEvent, set: Setter, get: Getter) {
  const sessionId = ev.session_id;
  const session = get().sessions.find((s) => s.id === sessionId);

  if (ev.kind === 'line') {
    // Replay already covered everything up to this sequence number.
    const seen = seenSeq.get(sessionId) ?? 0;
    if (ev.seq <= seen) return;
    seenSeq.set(sessionId, ev.seq);
    if (!session) {
      void get().refreshSessions();
      return;
    }
    const events = safeFeed(parserFor(session), ev.line, ev.stream);
    for (const agentEvent of events) applyAgentEvent(sessionId, agentEvent, set, get);
    return;
  }

  if (ev.kind === 'exit') {
    if (session) {
      const tail = parsers.get(sessionId)?.onExit(ev.code) ?? [];
      for (const agentEvent of tail) applyAgentEvent(sessionId, agentEvent, set, get);
    }
    void get().refreshSessions();
    return;
  }

  // Status pushed by the backend (spawn, exit).
  void get().refreshSessions();
}

function applyAgentEvent(sessionId: string, event: AgentEvent, set: Setter, get: Getter) {
  switch (event.type) {
    case 'session_id':
      void ipc.sessions.setProviderSessionId(sessionId, event.id);
      break;
    case 'status':
      void ipc.sessions.setStatus(sessionId, event.status, event.detail);
      if (event.status === 'waiting_input' || event.status === 'errored') {
        void maybeNotify(sessionId, event.status, event.detail, get);
      } else if (event.status === 'idle') {
        void maybeNotify(sessionId, 'finished', event.detail, get);
      }
      break;
    case 'permission_request': {
      const current = get().permissions[sessionId] ?? [];
      set({
        permissions: {
          ...get().permissions,
          [sessionId]: [
            ...current,
            { requestId: event.requestId, toolName: event.toolName, input: event.input },
          ],
        },
      });
      void maybeNotify(sessionId, 'waiting_input', `${event.toolName} needs approval`, get);
      break;
    }
    case 'usage': {
      const session = get().sessions.find((s) => s.id === sessionId);
      void ipc.usage.record({
        session_id: sessionId,
        project_id: session?.project_id ?? null,
        provider_id: session?.provider_id ?? 'unknown',
        input_tokens: event.usage.inputTokens,
        output_tokens: event.usage.outputTokens,
        cache_read: event.usage.cacheRead,
        cache_write: event.usage.cacheWrite,
        cost_usd: event.costUsd ?? 0,
        duration_ms: event.durationMs ?? 0,
        turns: event.turns ?? 1,
      });
      break;
    }
    default:
      break;
  }
  pushEvent(set, get, sessionId, event);
}

function pushEvent(set: Setter, get: Getter, sessionId: string, event: AgentEvent) {
  const current = get().timelines[sessionId] ?? [];
  set({ timelines: { ...get().timelines, [sessionId]: appendEvent(current, event) } });
}

let entryCounter = 0;

/**
 * Streaming text arrives as chunks that share a block id; the finished block
 * arrives once more with `partial: false`. Merge both into one entry so the
 * timeline reads like a document instead of a stutter.
 */
export function appendEvent(entries: TimelineEntry[], event: AgentEvent): TimelineEntry[] {
  const blockId =
    (event.type === 'text' || event.type === 'thinking') && event.blockId ? event.blockId : null;

  if (blockId) {
    const idx = entries.findIndex(
      (e) =>
        (e.event.type === 'text' || e.event.type === 'thinking') &&
        e.event.blockId === blockId &&
        e.event.type === event.type,
    );
    if (idx >= 0) {
      const existing = entries[idx].event as Extract<AgentEvent, { type: 'text' | 'thinking' }>;
      const incoming = event as Extract<AgentEvent, { type: 'text' | 'thinking' }>;
      const merged = incoming.partial
        ? { ...existing, text: existing.text + incoming.text }
        : { ...incoming };
      const copy = entries.slice();
      copy[idx] = { ...entries[idx], event: merged as AgentEvent };
      return copy;
    }
  }

  if (event.type === 'tool_result') {
    // Attach results next to their call by appending; the renderer pairs them.
    return [...entries, { id: `e${++entryCounter}`, at: Date.now(), event }];
  }

  return [...entries, { id: `e${++entryCounter}`, at: Date.now(), event }];
}

// ---------------- automations ----------------

async function handleAutomationFire(payload: FirePayload, get: Getter) {
  const provider = getProvider(payload.providerId);
  const settings = get().settings;
  const ctx = {
    cwd: payload.cwd,
    prompt: payload.prompt,
    permissionPolicy: payload.permissionPolicy as PermissionPolicy,
    extraArgs: extraArgsFor(settings, payload.providerId),
    binaryOverride: binaryFor(settings, payload.providerId),
  };
  try {
    if (payload.mode === 'continue' && provider.buildUserMessage) {
      await ipc.sessions.write(payload.sessionId, provider.buildUserMessage(payload.prompt));
      await ipc.sessions.setStatus(payload.sessionId, 'running');
    } else if (payload.mode === 'resume' && payload.resumeId) {
      const session = get().sessions.find((s) => s.id === payload.sessionId);
      if (session) resetParser(session);
      await ipc.sessions.launch(
        payload.sessionId,
        provider.buildResume({ ...ctx, resumeId: payload.resumeId }),
      );
    } else {
      await ipc.sessions.launch(payload.sessionId, provider.buildLaunch(ctx));
    }
    await ipc.automations.reportRun(payload.runId, 'created', payload.sessionId);
  } catch (e) {
    await ipc.automations.reportRun(payload.runId, 'failed', payload.sessionId, String(e));
    if (get().settings.notify_automation_failed !== false) {
      void notify(`${payload.automationName} failed`, String(e));
    }
  }
  await get().refreshSessions();
  await get().refreshAutomations();
}

// ---------------- helpers ----------------

function extraArgsFor(settings: AppSettings, providerId: string): string[] | undefined {
  return settings.provider_overrides?.[providerId]?.extraArgs;
}

function binaryFor(settings: AppSettings, providerId: string): string | undefined {
  return settings.provider_overrides?.[providerId]?.path;
}

let permissionGranted: boolean | null = null;

async function notify(title: string, body: string) {
  try {
    if (permissionGranted === null) {
      permissionGranted = await isPermissionGranted();
      if (!permissionGranted) permissionGranted = (await requestPermission()) === 'granted';
    }
    if (permissionGranted) sendNotification({ title, body });
  } catch {
    // Notifications are a nicety, never a failure path.
  }
}

async function maybeNotify(
  sessionId: string,
  status: string,
  detail: string | null | undefined,
  get: Getter,
) {
  const settings = get().settings;
  const session = get().sessions.find((s) => s.id === sessionId);
  const name = session?.name ?? 'Session';
  if (status === 'waiting_input' && settings.notify_attention === false) return;
  if (status === 'finished' && settings.notify_finished === false) return;
  if (document.hasFocus() && get().selectedSessionId === sessionId) return;
  const label =
    status === 'waiting_input' ? 'needs you' : status === 'errored' ? 'errored' : 'finished';
  await notify(`${name} ${label}`, detail ?? '');
}
