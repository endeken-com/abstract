/**
 * In-browser stand-in for the Rust core, used only when the frontend runs
 * outside Tauri (`bun run dev` in a normal browser). It lets the UI be built
 * and reviewed with hot reload against realistic data, and it drives the real
 * IPC layer, parsers and store — nothing in the app knows it is mocked.
 */
import { mockIPC, mockWindows } from '@tauri-apps/api/mocks';
import { emit } from '@tauri-apps/api/event';
import type { Channel } from '@tauri-apps/api/core';
import type {
  Automation,
  AutomationRun,
  FileDiff,
  Project,
  Session,
  SessionStreamEvent,
  WorktreeInfo,
} from '../types';
import { claudeScript, followUpScript, type ScriptStep } from './script';

const now = Date.now();
const ago = (min: number) => new Date(now - min * 60_000).toISOString();
const ahead = (min: number) => new Date(now + min * 60_000).toISOString();
const uid = () => Math.random().toString(36).slice(2, 10);

const projects: Project[] = [
  project('p1', 'abstract', '/Users/dev/code/abstract', 'main'),
  project('p2', 'payments-api', '/Users/dev/code/payments-api', 'develop', ['vendor/stripe-go']),
  project('p3', 'marketing-site', '/Users/dev/code/marketing-site', 'main'),
];

function project(id: string, name: string, root: string, base: string, nested: string[] = []): Project {
  return {
    id, name, executor: 'local', root_path: root, ssh_host: null, ssh_extra_args: null,
    default_base_ref: base, default_provider_id: 'claude', default_permission_policy: 'ask',
    nested_repos: nested, worktree_template: null, branch_prefix: null, sort_order: 0,
    created_at: ago(60 * 24 * 7), archived_at: null,
  };
}

const sessions: Session[] = [
  session('s1', 'p1', 'Derive session status from process liveness', 'finished', 12, 'claude'),
  session('s2', 'p1', 'Add command palette with fuzzy search', 'running', 1, 'claude'),
  session('s3', 'p2', 'Retry idempotent webhook deliveries', 'waiting_input', 3, 'claude'),
  session('s4', 'p2', 'Migrate invoices table to bigint ids', 'errored', 55, 'codex'),
  session('s5', 'p3', 'Tighten hero copy and fix CLS on mobile', 'finished', 60 * 5, 'codex'),
  { ...session('s6', 'p1', 'Nightly dependency bump · Sep 22 09:00', 'finished', 60 * 9, 'claude'), automation_id: 'a1' },
];

function session(id: string, projectId: string, name: string, status: string, minAgo: number, provider: string): Session {
  const p = projects.find((x) => x.id === projectId)!;
  const slug = name.toLowerCase().replace(/[^a-z0-9]+/g, '-').slice(0, 40).replace(/-$/, '');
  return {
    id, project_id: projectId, name, provider_id: provider, provider_session_id: null,
    worktree_path: `/Users/dev/.abstract/worktrees/${p.name}-3f9a21c0/${slug}`,
    branch: `abstract/${slug}`, base_ref: p.default_base_ref, status, status_detail: null,
    permission_policy: 'ask', prompt: name, automation_id: null, created_at: ago(minAgo + 30),
    last_event_at: ago(minAgo), archived_at: null, alive: status === 'running' || status === 'waiting_input',
  };
}

const automations: Automation[] = [
  automation('a1', 'Nightly dependency bump', 'p1', 'FREQ=DAILY;BYHOUR=9;BYMINUTE=0;BYSECOND=0', true, ahead(60 * 14)),
  automation('a2', 'Triage new issues', 'p2', 'FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR;BYHOUR=8;BYMINUTE=30;BYSECOND=0', true, ahead(60 * 13 + 30)),
  automation('a3', 'Weekly flaky-test sweep', null, 'FREQ=WEEKLY;BYDAY=MO;BYHOUR=7;BYMINUTE=0;BYSECOND=0', false, null),
];

function automation(id: string, name: string, projectId: string | null, rrule: string, enabled: boolean, next: string | null): Automation {
  return {
    id, name, prompt: `# ${name}\n\nWork through this carefully and open a summary when done.`,
    provider_id: 'claude', project_id: projectId, rrule, timezone: 'America/Sao_Paulo',
    dtstart: ago(60 * 24 * 30), workspace_mode: 'new_worktree', pinned_session_id: null,
    continue_agent_session: false, permission_policy: 'auto-edits', catch_up: false, enabled,
    next_run_at: next, created_at: ago(60 * 24 * 30), updated_at: ago(60),
  };
}

const runs: AutomationRun[] = [
  { id: 'r1', automation_id: 'a1', fired_at: ago(60 * 9), trigger: 'schedule', status: 'created', session_id: 's6', error: null },
  { id: 'r2', automation_id: 'a1', fired_at: ago(60 * 33), trigger: 'schedule', status: 'created', session_id: null, error: null },
  { id: 'r3', automation_id: 'a1', fired_at: ago(60 * 57), trigger: 'manual', status: 'failed', session_id: null, error: 'git worktree add: fatal: invalid reference: main' },
  { id: 'r4', automation_id: 'a2', fired_at: ago(60 * 10), trigger: 'schedule', status: 'created', session_id: 's3', error: null },
];

const settings: Record<string, unknown> = {
  worktree_template: '{home}/.abstract/worktrees/{repo}-{hash}/{slug}',
  branch_prefix: 'abstract/',
};

// ---------- streaming ----------

const logs = new Map<string, { stream: 'stdout' | 'stderr'; line: string }[]>();
const channels: Channel<SessionStreamEvent>[] = [];
const timers = new Map<string, number[]>();
const paused = new Map<string, ScriptStep[]>();
let scriptCounter = 1;

function push(ev: SessionStreamEvent) {
  for (const c of channels) c.onmessage(ev);
}

function setStatus(id: string, status: string, detail: string | null = null) {
  const s = sessions.find((x) => x.id === id);
  if (!s) return;
  s.status = status;
  s.status_detail = detail;
  s.last_event_at = new Date().toISOString();
  push({ kind: 'status', session_id: id, status, detail });
}

function play(sessionId: string, steps: ScriptStep[], stopAt: number | null) {
  const list: number[] = [];
  let t = 0;
  const upto = stopAt ?? steps.length;
  for (let i = 0; i < upto; i++) {
    t += steps[i].delay;
    const step = steps[i];
    list.push(
      window.setTimeout(() => {
        const log = logs.get(sessionId) ?? [];
        log.push({ stream: 'stdout', line: step.line });
        logs.set(sessionId, log);
        push({ kind: 'line', session_id: sessionId, seq: log.length, stream: 'stdout', line: step.line });
      }, t),
    );
  }
  if (stopAt !== null) paused.set(sessionId, steps.slice(stopAt));
  timers.set(sessionId, list);
}

/** Pre-fill finished sessions so reopening them shows a full timeline. */
function seedLog(s: Session, permission = false) {
  const { steps, sessionId } = claudeScript({ n: scriptCounter++, cwd: s.worktree_path ?? '', prompt: s.name, permission });
  s.provider_session_id = sessionId;
  logs.set(s.id, steps.map((st) => ({ stream: 'stdout' as const, line: st.line })));
}

for (const s of sessions) {
  if (s.status === 'finished') seedLog(s);
  if (s.status === 'errored') {
    logs.set(s.id, [
      { stream: 'stdout', line: JSON.stringify({ type: 'thread.started', thread_id: 'mock-thread-err' }) },
      { stream: 'stdout', line: JSON.stringify({ type: 'turn.started' }) },
      { stream: 'stdout', line: JSON.stringify({ type: 'item.completed', item: { id: 'i0', type: 'agent_message', text: 'Running the migration against the local database first.' } }) },
      { stream: 'stdout', line: JSON.stringify({ type: 'item.completed', item: { id: 'i1', type: 'command_execution', command: 'bun run db:migrate', aggregated_output: 'error: column "invoice_id" is referenced by constraint fk_line_items_invoice\nhint: drop or alter the constraint first', exit_code: 1, status: 'failed' } }) },
      { stream: 'stdout', line: JSON.stringify({ type: 'turn.failed', error: { message: 'Migration failed: foreign key constraint blocks the column type change.' } }) },
    ]);
  }
}
// s3 waits on a permission prompt; s2 is mid-run.
{
  const s3 = sessions.find((s) => s.id === 's3')!;
  const { steps, permissionAt, sessionId } = claudeScript({ n: scriptCounter++, cwd: s3.worktree_path ?? '', prompt: s3.name, permission: true });
  s3.provider_session_id = sessionId;
  logs.set('s3', steps.slice(0, (permissionAt ?? 0) + 1).map((st) => ({ stream: 'stdout' as const, line: st.line })));
  paused.set('s3', steps.slice((permissionAt ?? 0) + 1));
  const s2 = sessions.find((s) => s.id === 's2')!;
  const run = claudeScript({ n: scriptCounter++, cwd: s2.worktree_path ?? '', prompt: s2.name, permission: false });
  s2.provider_session_id = run.sessionId;
  logs.set('s2', run.steps.slice(0, 9).map((st) => ({ stream: 'stdout' as const, line: st.line })));
  window.setTimeout(() => play('s2', run.steps.slice(9), null), 1500);
}

// ---------- diff ----------

function sampleDiff(worktree: string): FileDiff[] {
  const hunk = (index: number, header: string, lines: [string, string][], os: number, ns: number) => ({
    index, header, old_start: os, old_lines: lines.filter(([o]) => o !== '+').length, new_start: ns,
    new_lines: lines.filter(([o]) => o !== '-').length,
    lines: lines.map(([origin, content]) => ({ origin: origin as ' ' | '+' | '-', content })),
    additions: lines.filter(([o]) => o === '+').length, deletions: lines.filter(([o]) => o === '-').length,
    raw: '',
  });
  void worktree;
  return [
    {
      path: 'src/features/sessions/SessionList.tsx', old_path: null, status: 'modified', binary: false,
      additions: 4, deletions: 2, raw_header: '',
      hunks: [
        hunk(0, '@@ -40,5 +40,7 @@ export function SessionRow', [[' ', 'export function SessionRow({ session }: Props) {'], ['-', '  const status = session.status;'], ['+', '  const status = deriveStatus(session);'], ['+', '  const isLive = status === "running";'], [' ', '  return (']], 40, 40),
        hunk(1, '@@ -88,3 +90,4 @@', [[' ', '      <StatusDot status={status} />'], ['-', '    </Row>'], ['+', '      {isLive ? <Pulse /> : null}'], ['+', '    </Row>']], 88, 90),
      ],
    },
    {
      path: 'src/features/sessions/deriveStatus.ts', old_path: null, status: 'added', binary: false,
      additions: 9, deletions: 0, raw_header: '',
      hunks: [hunk(0, '@@ -0,0 +1,9 @@', MODIFIED_DERIVE.split('\n').map((l) => ['+', l] as [string, string]), 0, 1)],
    },
    {
      path: 'src/features/sessions/legacyStatus.ts', old_path: null, status: 'deleted', binary: false,
      additions: 0, deletions: 3, raw_header: '',
      hunks: [hunk(0, '@@ -1,3 +0,0 @@', [['-', 'export function legacyStatus(s: string) {'], ['-', '  return s;'], ['-', '}']], 1, 0)],
    },
  ];
}

const ORIGINAL_LIST = `import { StatusDot } from './StatusDot';
import type { Session } from '../../lib/types';

interface Props {
  session: Session;
}

export function SessionRow({ session }: Props) {
  const status = session.status;
  return (
    <Row>
      <Title>{session.name}</Title>
      <StatusDot status={status} />
    </Row>
  );
}
`;
const MODIFIED_LIST = `import { StatusDot } from './StatusDot';
import { deriveStatus } from './deriveStatus';
import type { Session } from '../../lib/types';

interface Props {
  session: Session;
}

export function SessionRow({ session }: Props) {
  const status = deriveStatus(session);
  const isLive = status === 'running';
  return (
    <Row data-live={isLive}>
      <Title>{session.name}</Title>
      <StatusDot status={status} />
      {isLive ? <Pulse /> : null}
    </Row>
  );
}
`;
const MODIFIED_DERIVE = `import type { Session } from '../../lib/types';

/** A process that died mid-run should not keep claiming to be running. */
export function deriveStatus(session: Session): string {
  if (session.status === 'running' && !session.alive) {
    return 'errored';
  }
  return session.status;
}`;

// ---------- install ----------

export function installMock() {
  mockWindows('main');
  mockIPC(
    async (cmd, raw) => {
      const args = (raw ?? {}) as Record<string, any>;
      switch (cmd) {
        case 'settings_get_all':
          return { ...settings };
        case 'settings_set':
          settings[args.key] = args.value;
          return null;

        case 'projects_list':
          return projects;
        case 'project_probe': {
          const path = String(args.args.path);
          const name = path.split('/').filter(Boolean).pop() ?? 'repo';
          return { root_path: path, name, is_root: true, nested_repos: [], default_branch: 'main' };
        }
        case 'project_add': {
          const p = project(`p${uid()}`, args.args.name, args.args.root_path, args.args.default_base_ref ?? 'HEAD', args.args.nested_repos ?? []);
          projects.push(p);
          return p;
        }
        case 'project_update': {
          const i = projects.findIndex((p) => p.id === args.project.id);
          if (i >= 0) projects[i] = args.project;
          return null;
        }
        case 'project_delete':
          projects.splice(projects.findIndex((p) => p.id === args.id), 1);
          return null;

        case 'providers_detect':
          return args.args.providers.map((p: { id: string; binary: string }) => ({
            id: p.id, available: true, path: `/opt/homebrew/bin/${p.binary}`,
            version: p.id === 'claude' ? '2.1.274 (Claude Code)' : 'codex-cli 0.153.4',
          }));

        case 'sessions_list':
          return sessions.map((s) => ({ ...s }));
        case 'session_get':
          return { ...sessions.find((s) => s.id === args.id) };
        case 'session_create': {
          const a = args.args;
          const s = session(`s${uid()}`, a.project_id, a.prompt.split('\n')[0].slice(0, 60), 'created', 0, a.provider_id);
          s.permission_policy = a.permission_policy ?? 'ask';
          s.prompt = a.prompt;
          s.alive = false;
          await sleep(500); // provisioning a worktree takes a moment
          sessions.unshift(s);
          return { ...s };
        }
        case 'session_launch': {
          const s = sessions.find((x) => x.id === args.id)!;
          s.alive = true;
          setStatus(s.id, 'running');
          const followUp = logs.has(s.id);
          if (followUp) {
            play(s.id, followUpScript(s.provider_session_id ?? '', 'picking this back up'), null);
          } else {
            const run = claudeScript({ n: scriptCounter++, cwd: s.worktree_path ?? '', prompt: s.prompt ?? s.name, permission: s.permission_policy === 'ask' });
            play(s.id, run.steps, run.permissionAt !== null ? run.permissionAt + 1 : null);
          }
          return null;
        }
        case 'session_write': {
          const data = String(args.data);
          const rest = paused.get(args.id);
          if (data.includes('control_response') && rest) {
            paused.delete(args.id);
            play(args.id, rest, null);
          } else if (data.includes('"type":"user"')) {
            const s = sessions.find((x) => x.id === args.id)!;
            const text = (JSON.parse(data).message?.content?.[0]?.text as string) ?? '';
            play(args.id, followUpScript(s.provider_session_id ?? '', text), null);
          }
          return null;
        }
        case 'session_stop': {
          for (const t of timers.get(args.id) ?? []) clearTimeout(t);
          const s = sessions.find((x) => x.id === args.id);
          if (s) s.alive = false;
          push({ kind: 'exit', session_id: args.id, code: 143 });
          setStatus(args.id, 'errored', 'stopped');
          return null;
        }
        case 'session_set_status':
          setStatus(args.id, args.status, args.detail ?? null);
          return null;
        case 'session_set_provider_session_id': {
          const s = sessions.find((x) => x.id === args.id);
          if (s) s.provider_session_id = args.providerSessionId;
          return null;
        }
        case 'session_rename': {
          const s = sessions.find((x) => x.id === args.id);
          if (s) s.name = args.name;
          return null;
        }
        case 'session_archive': {
          const s = sessions.find((x) => x.id === args.id);
          if (s) s.archived_at = args.archived ? new Date().toISOString() : null;
          return null;
        }
        case 'session_replay':
          return (logs.get(args.id) ?? [])
            .map((l, i) => ({ kind: 'line', session_id: args.id, seq: i + 1, stream: l.stream, line: l.line }))
            .filter((e) => e.seq > (args.fromSeq ?? 0));
        case 'session_subscribe':
          channels.push(args.channel);
          return null;
        case 'session_delete':
          sessions.splice(sessions.findIndex((s) => s.id === args.args.id), 1);
          return null;

        case 'usage_record':
          return null;
        case 'usage_summary':
          return [
            { provider_id: 'claude', sessions: 24, turns: 131, input_tokens: 1_840, output_tokens: 214_300, cache_read: 8_120_000, cache_write: 912_000, cost_usd: 38.42, duration_ms: 9_840_000 },
            { provider_id: 'codex', sessions: 9, turns: 41, input_tokens: 1_204_000, output_tokens: 61_200, cache_read: 980_000, cache_write: 0, cost_usd: 0, duration_ms: 2_610_000 },
          ];
        case 'usage_by_day':
          return Array.from({ length: 14 }, (_, i) => {
            const d = new Date(now - (13 - i) * 86_400_000).toISOString().slice(0, 10);
            return { day: d, provider_id: 'claude', input_tokens: 0, output_tokens: 8000 + ((i * 7919) % 21000), cost_usd: 1 + ((i * 37) % 9) / 3 };
          });

        case 'worktrees_list': {
          const p = projects.find((x) => x.id === args.projectId)!;
          const list: WorktreeInfo[] = [
            { path: p.root_path, head: 'a1b2c3d', branch: p.default_base_ref, bare: false, detached: false, locked: false, session_id: null, session_name: null, orphan: false },
            ...sessions.filter((s) => s.project_id === p.id).map((s) => ({ path: s.worktree_path ?? '', head: 'f00ba12', branch: s.branch, bare: false, detached: false, locked: false, session_id: s.id, session_name: s.name, orphan: false })),
            { path: `/Users/dev/.abstract/worktrees/${p.name}-3f9a21c0/old-experiment`, head: 'dead001', branch: 'abstract/old-experiment', bare: false, detached: false, locked: false, session_id: null, session_name: null, orphan: true },
          ];
          return list;
        }
        case 'worktree_remove':
        case 'worktree_prune':
          await sleep(300);
          return null;

        case 'diff_collect': {
          const s = sessions.find((x) => x.id === args.sessionId);
          const p = projects.find((x) => x.id === s?.project_id);
          return { files: sampleDiff(s?.worktree_path ?? ''), worktree_path: s?.worktree_path ?? null, excluded: p?.nested_repos ?? [] };
        }
        case 'diff_file_contents': {
          const path = String(args.path);
          if (path.endsWith('SessionList.tsx')) return { original: ORIGINAL_LIST, modified: MODIFIED_LIST };
          if (path.endsWith('deriveStatus.ts')) return { original: '', modified: MODIFIED_DERIVE };
          return { original: 'export function legacyStatus(s: string) {\n  return s;\n}\n', modified: '' };
        }
        case 'diff_accept':
        case 'diff_reject':
          await sleep(350);
          return null;

        case 'automations_list':
          return automations.map((a) => ({ ...a }));
        case 'automation_get':
          return { ...automations.find((a) => a.id === args.id) };
        case 'automation_save': {
          const a = args.args;
          const existing = automations.find((x) => x.id === a.id);
          const saved: Automation = {
            ...(existing ?? automation(`a${uid()}`, a.name, a.project_id, a.rrule, true, ahead(60))),
            ...a,
            id: existing?.id ?? `a${uid()}`,
            updated_at: new Date().toISOString(),
            next_run_at: a.enabled === false ? null : ahead(60),
          };
          if (existing) Object.assign(existing, saved);
          else automations.push(saved);
          return saved;
        }
        case 'automation_set_enabled': {
          const a = automations.find((x) => x.id === args.id)!;
          a.enabled = args.enabled;
          a.next_run_at = args.enabled ? ahead(60 * 3) : null;
          return { ...a };
        }
        case 'automation_delete':
          automations.splice(automations.findIndex((a) => a.id === args.id), 1);
          return null;
        case 'automation_runs':
          return runs.filter((r) => r.automation_id === args.id).slice(0, args.limit ?? 20);
        case 'automation_run_now': {
          const r: AutomationRun = { id: `r${uid()}`, automation_id: args.id, fired_at: new Date().toISOString(), trigger: 'manual', status: 'created', session_id: null, error: null };
          runs.unshift(r);
          void emit('automations://changed');
          return r.id;
        }
        case 'automation_run_report':
          return null;
        case 'schedule_preview': {
          if (!/FREQ=(MINUTELY|HOURLY|DAILY|WEEKLY|MONTHLY|YEARLY)/.test(String(args.rrule))) {
            throw 'invalid schedule: unknown FREQ';
          }
          return [1, 2, 3].map((i) => ahead(60 * 24 * i));
        }
        case 'schedule_preset': {
          const { preset, hour, minute } = args;
          const map: Record<string, string> = {
            hourly: `FREQ=HOURLY;BYMINUTE=${minute};BYSECOND=0`,
            daily: `FREQ=DAILY;BYHOUR=${hour};BYMINUTE=${minute};BYSECOND=0`,
            weekdays: `FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR;BYHOUR=${hour};BYMINUTE=${minute};BYSECOND=0`,
            weekly: `FREQ=WEEKLY;BYDAY=MO;BYHOUR=${hour};BYMINUTE=${minute};BYSECOND=0`,
          };
          return map[preset];
        }

        // Plugins
        case 'plugin:dialog|open':
          return '/Users/dev/code/new-project';
        case 'plugin:notification|is_permission_granted':
          return true;
        case 'plugin:notification|request_permission':
          return 'granted';
        case 'plugin:notification|notify':
          return null;
        default:
          if (cmd.startsWith('plugin:window|')) return null;
          console.warn('[mock] unhandled command', cmd, args);
          return null;
      }
    },
    { shouldMockEvents: true },
  );
}

function sleep(ms: number) {
  return new Promise((r) => setTimeout(r, ms));
}

/**
 * Browser-mock only: jump straight to a state from the URL so each screen can
 * be captured or reviewed directly, e.g. `/?session=s3`, `/?session=s1&tab=diff`,
 * `/?view=settings`, `/?palette=1`, `/?newchat=p1`.
 */
export async function applyUrlState() {
  const q = new URLSearchParams(location.search);
  const { useApp } = await import('../../store/app');
  const s = useApp.getState();
  const session = q.get('session');
  if (session) await s.selectSession(session);
  const tab = q.get('tab');
  if (tab === 'diff' || tab === 'chat') s.setChatTab(tab);
  const view = q.get('view');
  if (view === 'settings' || view === 'automations' || view === 'worktrees') s.setView(view);
  const automation = q.get('automation');
  if (automation) s.selectAutomation(automation);
  if (q.get('palette')) s.setPaletteOpen(true);
  const newchat = q.get('newchat');
  if (newchat !== null) s.openNewChat(newchat || null);
  if (q.get('addproject')) s.setAddProjectOpen(true);
}
