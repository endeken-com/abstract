const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const Module = require('node:module');
const ts = require('typescript');

const transpile = (module, path) => {
  const source = fs.readFileSync(path, 'utf8');
  const js = ts.transpileModule(source, { fileName: path, compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022, jsx: ts.JsxEmit.React, esModuleInterop: true } }).outputText;
  module._compile(js, path);
};
require.extensions['.ts'] = transpile;
require.extensions['.tsx'] = transpile;
// The native modules are stood in by their element names, so a row renders to a plain element tree.
const stubs = {
  'react-native': { Pressable: 'Pressable', Text: 'Text', TextInput: 'TextInput', View: 'View', StyleSheet: { create: styles => styles, hairlineWidth: 0.5 } },
  'expo-symbols': { SymbolView: 'SymbolView' },
  'react-native-svg': { __esModule: true, default: 'Svg', Path: 'Path' },
  '@react-native-menu/menu': { MenuView: 'MenuView' },
  '@react-native-async-storage/async-storage': { __esModule: true, default: { getItem: async () => null, setItem: async () => {} } },
  './ProviderLogo': { ProviderLogo: 'ProviderLogo' },
};
const load = Module._load;
Module._load = function (request, ...rest) { return stubs[request] || load.call(this, request, ...rest); };
const g = require('../src/chatGroups.ts');
const { SecondLine } = require('../src/ChatList.tsx');

const now = 1_000_000_000;
const pr = (number, state = 'OPEN', fields = {}) => ({ number, title: 't', state, isDraft: false, ...fields });
const chat = (id, status = 'idle', { ago = 60, pullRequest = null, hasChanges = false, backgroundTasks = false, projectName = 'abstract', branch = null, providerId = 'claude', pinnedAt = null, archived = false, mac = 'Studio', hostId = 'h1', macState = 'online' } = {}) => ({
  hostId, mac, macState,
  session: { id, name: id, status, providerId, branch, projectId: projectName ? `p-${projectName}` : null, worktreePath: '/w/' + id, createdAt: now - ago - 10, lastEventAt: now - ago, pinnedAt, archivedAt: archived ? now : null },
  pullRequest, hasChanges, backgroundTasks, projectName,
});
const groups = chats => Object.fromEntries(g.sections(chats, now).map(s => [s.group, s.chats.map(c => c.session.id)]));

test('each state finds its group', () => {
  const r = groups([chat('asking', 'waiting_input'), chat('failed', 'errored'), chat('running', 'running'), chat('starting', 'provisioning'),
    chat('dirty', 'idle', { hasChanges: true }), chat('clean', 'finished')]);
  assert.deepEqual(r.needsYou.sort(), ['asking', 'failed']);
  assert.deepEqual(r.working.sort(), ['running', 'starting']);
  assert.deepEqual(r.readyToReview, ['dirty']);
  assert.deepEqual(r.done, ['clean']);
});

test('pull requests decide idle chats, and merged wins over leftover changes', () => {
  const r = groups([chat('merged', 'idle', { pullRequest: pr(1, 'MERGED'), hasChanges: true }), chat('closed', 'idle', { pullRequest: pr(2, 'CLOSED') }),
    chat('failing', 'idle', { pullRequest: pr(3, 'OPEN', { checks: [{ name: 'a', outcome: 'failed' }] }) }), chat('draft', 'idle', { pullRequest: pr(4, 'OPEN', { isDraft: true }) })]);
  assert.deepEqual(r.done.sort(), ['closed', 'merged']);
  assert.deepEqual(r.readyToReview.sort(), ['draft', 'failing']);
});

test('a running agent or background tasks outrank the pull request', () => {
  const r = groups([chat('working', 'running', { pullRequest: pr(5) }), chat('tasks', 'idle', { pullRequest: pr(6, 'MERGED'), backgroundTasks: true })]);
  assert.deepEqual(r.working.sort(), ['tasks', 'working']);
});

test('work the Mac has not read yet is ready to review', () => {
  const unread = { ...chat('unread', 'idle'), hasChanges: undefined };
  const r = groups([unread, chat('clean', 'idle')]);
  assert.deepEqual(r.readyToReview, ['unread']);
  assert.deepEqual(r.done, ['clean']);
});

test('pinned come first in pin order, archived last, most recent first within a group', () => {
  const s = g.sections([chat('later-pin', 'waiting_input', { pinnedAt: 20 }), chat('first-pin', 'idle', { pinnedAt: 10 }),
    chat('gone', 'waiting_input', { archived: true }), chat('old', 'running', { ago: 3600 }), chat('new', 'running', { ago: 5 })], now);
  assert.deepEqual(s.map(x => x.group), ['pinned', 'working', 'archived']);
  assert.deepEqual(s[0].chats.map(c => c.session.id), ['first-pin', 'later-pin']);
  assert.deepEqual(s[1].chats.map(c => c.session.id), ['new', 'old']);
});

test('done folds chats quiet for a week', () => {
  const [done] = g.sections([chat('yesterday', 'idle', { ago: 86_400 }), chat('last-month', 'idle', { ago: 30 * 86_400 }), chat('six-days', 'idle', { ago: 6 * 86_400 })], now);
  assert.deepEqual(done.chats.map(c => c.session.id), ['yesterday', 'six-days']);
  assert.deepEqual(done.older.map(c => c.session.id), ['last-month']);
});

test('every paired Mac\'s snapshot gives each chat its Mac, pull request, branch state, tasks and project', () => {
  const snapshot = {
    projects: [{ id: 'p1', name: 'abstract' }], providers: [], alive: [],
    sessions: [{ id: 'a', projectId: 'p1', worktreePath: '/w/a' }, { id: 'b', projectId: null, worktreePath: '/w/b' }, { id: 'c', projectId: null, worktreePath: null }],
    pullRequests: { a: pr(7) }, backgroundTasks: ['b'], unmergedWork: { a: true },
  };
  const other = { projects: [], providers: [], alive: [], sessions: [{ id: 'a', projectId: null, worktreePath: null }] };
  const macs = [{ id: 'h1', name: 'Studio', state: 'online', snapshot }, { id: 'h2', name: 'Mac mini', state: 'unreachable', snapshot: other }, { id: 'h3', name: 'Air', state: 'connecting', snapshot: null }];
  const all = g.chatsFromMacs(macs);
  assert.deepEqual(all.map(g.chatKey), ['h1/a', 'h1/b', 'h1/c', 'h2/a'], 'the same id on two Macs is two chats');
  assert.deepEqual([all[3].mac, all[3].macState], ['Mac mini', 'unreachable']);
  const [a, b, c] = all;
  assert.equal(a.pullRequest.number, 7); assert.equal(a.hasChanges, true); assert.equal(a.projectName, 'abstract');
  assert.equal(b.hasChanges, undefined, 'not read yet'); assert.equal(b.backgroundTasks, true); assert.equal(b.projectName, null);
  assert.equal(c.hasChanges, false, 'no folder, nothing to review');
  assert.deepEqual(g.chatsFromSnapshot(null, macs[0]), []);
});

test('the second line shows what applies', () => {
  const full = chat('x', 'idle', { pullRequest: pr(3981, 'OPEN', { checks: [{ name: 'a', outcome: 'passed' }], reviewDecision: 'CHANGES_REQUESTED' }) });
  assert.equal(g.lineText(g.lineOf(full, true)), 'abstract · #3981 · passed · changes requested');
  assert.equal(g.lineText(g.lineOf(full, false)), '#3981 · passed · changes requested');
  const merged = chat('m', 'idle', { pullRequest: pr(12, 'MERGED', { checks: [{ name: 'a', outcome: 'failed' }], reviewDecision: 'CHANGES_REQUESTED' }) });
  assert.equal(g.lineText(g.lineOf(merged, false)), '#12', 'checks and reviews only while open');
  assert.ok(g.lineIsEmpty(g.lineOf(chat('fresh'), false)), 'a fresh chat has one line');
  assert.equal(g.lineText(g.lineOf(chat('fresh'), true)), 'abstract');
  assert.equal(g.lineText(g.lineOf(full, true, true)), 'abstract · #3981 · passed · changes requested · Studio', 'the Mac, when more than one is paired');
  assert.ok(!g.lineIsEmpty(g.lineOf(chat('fresh'), false, true)));
});

test('chats on several Macs share the same groups', () => {
  const r = groups([chat('here', 'running'), chat('there', 'running', { mac: 'Mac mini', hostId: 'h2' }), chat('there-pr', 'idle', { pullRequest: pr(9), mac: 'Mac mini', hostId: 'h2' })]);
  assert.deepEqual(r.working.sort(), ['here', 'there']);
  assert.deepEqual(r.readyToReview, ['there-pr']);
});

test('checks read failing, then running, then passed', () => {
  const out = outcomes => g.checksOf(pr(1, 'OPEN', { checks: outcomes.map(outcome => ({ name: outcome, outcome })) }));
  assert.equal(out(['passed']), 'passed');
  assert.equal(out(['passed', 'pending']), 'running');
  assert.equal(out(['passed', 'pending', 'failed']), 'failing');
  assert.equal(out([]), null);
});

test('the second line renders its parts with dots between, a failing check in red', () => {
  const line = g.lineOf(chat('x', 'idle', { pullRequest: pr(3981, 'OPEN', { checks: [{ name: 'a', outcome: 'failed' }] }) }), true);
  const el = SecondLine({ line });
  assert.equal(el.props.accessibilityLabel, 'abstract · #3981 · failing');
  const [first, second] = el.props.children;
  assert.equal(second, false, 'a chat without review feedback needs only one metadata line');
  const [project, dot, prPart, , checks] = first.props.children;
  assert.equal(project.props.children, 'abstract');
  assert.equal(dot.props.children, '·');
  assert.equal(prPart.props.children[1].props.children, '#3981');
  assert.equal(checks.props.children, 'failing');
  assert.equal(checks.props.style[1].color, '#EF6461');
});

test('review feedback moves to a second line while all facts remain accessible', () => {
  const line = g.lineOf(chat('x', 'idle', { projectName: 'A very long project name', mac: 'A very long Mac name',
    pullRequest: pr(3981, 'OPEN', { checks: [{ name: 'a', outcome: 'passed' }], reviewDecision: 'CHANGES_REQUESTED' }) }), true, true);
  const el = SecondLine({ line });
  assert.equal(el.props.accessibilityLabel, 'A very long project name · #3981 · passed · changes requested · A very long Mac name');
  const [first, second] = el.props.children;
  assert.deepEqual(first.props.children.filter(child => child.type === 'Text').map(child => child.props.children),
    ['A very long project name', '·', '·', 'passed']);
  assert.equal(second.props.children[0].props.children, 'changes requested');
  assert.equal(second.props.children[2].props.children[1].props.children, 'A very long Mac name');
  for (const item of [first.props.children[0], first.props.children[4], second.props.children[0], second.props.children[2].props.children[1]]) {
    assert.equal(item.props.numberOfLines, 1, 'metadata text cannot form a vertical word stack');
  }
});

// Check the rendered row styles with Yoga, the layout engine used by iOS and Android.
// Each Text measures as one line of 7-point characters at the selected text scale.
async function metadataLayout(line, width, scale) {
  const { loadYoga } = await import('yoga-layout/load');
  const Yoga = await loadYoga();
  const make = element => {
    const n = Yoga.Node.create();
    const style = Object.assign({}, ...(Array.isArray(element.props.style) ? element.props.style.filter(Boolean) : [element.props.style || {}]));
    if (style.flexDirection === 'row') n.setFlexDirection(Yoga.FLEX_DIRECTION_ROW);
    if (style.alignItems === 'center') n.setAlignItems(Yoga.ALIGN_CENTER);
    if (style.flexShrink != null) n.setFlexShrink(style.flexShrink);
    if (style.minWidth != null) n.setMinWidth(style.minWidth);
    if (style.maxWidth != null) n.setMaxWidth(style.maxWidth);
    if (style.gap != null) n.setGap(Yoga.GUTTER_ALL, style.gap);
    if (element.type === 'Text') {
      const natural = String(element.props.children).length * 7 * scale;
      n.setMeasureFunc((available, mode) => ({ width: mode === Yoga.MEASURE_MODE_UNDEFINED ? natural : Math.min(natural, available), height: 16 * scale }));
    } else if (element.type === 'SymbolView' || typeof element.type === 'function') {
      n.setWidth(element.props.style?.width || element.props.size || 12);
      n.setHeight(16 * scale);
    } else {
      for (const child of [element.props.children].flat().filter(Boolean)) n.insertChild(make(child), n.getChildCount());
    }
    return n;
  };
  const rows = SecondLine({ line }).props.children.filter(Boolean).map(make);
  const layouts = rows.map(row => {
    row.calculateLayout(width, undefined, Yoga.DIRECTION_LTR);
    return { height: row.getComputedLayout().height, items: Array.from({ length: row.getChildCount() }, (_, i) => row.getChild(i).getComputedLayout()) };
  });
  rows.forEach(row => row.freeRecursive());
  return layouts;
}

test('long names yield to whole PR statuses on a narrow phone and at larger text sizes', async () => {
  const base = { project: 'A very long project name that should be cut', mac: 'A very long Mac name that should be cut',
    pullRequest: pr(3981), changesRequested: true };
  for (const checks of ['passed', 'failing', 'running']) {
    for (const scale of [1, 1.6, 2]) {
      const rows = await metadataLayout({ ...base, checks }, 250, scale);
      assert.equal(rows.length, 2);
      for (const row of rows) {
        assert.ok(row.height <= Math.ceil(16 * scale), 'each metadata row remains one text line tall');
        for (const item of row.items) assert.ok(item.left + item.width <= 251, `${checks} at ${scale}x stays inside the phone row`);
      }
      if (scale <= 1.6) {
        assert.ok(rows[0].items[4].width >= checks.length * 7 * scale, 'check status stays readable');
        assert.ok(rows[1].items[0].width >= 'changes requested'.length * 7 * scale, `review status stays readable: ${JSON.stringify(rows[1])}`);
      }
    }
  }
  assert.equal((await metadataLayout({ project: base.project, mac: base.mac, changesRequested: false }, 250, 1.6)).length, 1,
    'a chat without a PR stays on one metadata line');
  const [checksOnly] = await metadataLayout({ ...base, changesRequested: false, checks: 'passed' }, 250, 1.6);
  assert.ok(checksOnly.items.every(item => item.left + item.width <= 251), 'checks without review fit on one line');
  assert.ok(checksOnly.items[4].width >= 'passed'.length * 7 * 1.6, 'the check result keeps its full width');
});

test('ages read in the fewest characters', () => {
  assert.equal(g.age(now - 10, now), 'now');
  assert.equal(g.age(now - 12 * 60, now), '12m');
  assert.equal(g.age(now - 3 * 3600 - 59, now), '3h');
  assert.equal(g.age(now - 2 * 86_400, now), '2d');
  assert.equal(g.age(now - 15 * 86_400, now), '2w');
});

test('search matches title, branch and the exact pull request number', () => {
  const target = chat('Fix login', 'idle', { pullRequest: pr(3981), branch: 'abstract/oauth-callback' });
  const other = chat('Tidy notes', 'idle', { pullRequest: pr(39812) });
  assert.ok(g.queryMatches(target, '3981'));
  assert.ok(g.queryMatches(target, '#3981'));
  assert.ok(!g.queryMatches(other, '3981'), 'a number means that pull request, not a longer one');
  assert.ok(g.queryMatches(target, 'LOGIN'));
  assert.ok(g.queryMatches(target, 'oauth'));
  assert.ok(g.queryMatches(target, '  '));
  assert.ok(!g.queryMatches(target, 'payments'));
});

test('filters narrow by project, agent and Mac', () => {
  const here = chat('a', 'idle', { projectName: 'abstract' });
  const pay = chat('b', 'idle', { projectName: 'payments-api', providerId: 'codex', mac: 'Mac mini' });
  const loose = chat('c', 'idle', { projectName: null, providerId: 'opencode' });
  const all = [here, pay, loose];
  assert.ok(g.filterIsEmpty(g.noFilter));
  const only = f => all.filter(c => g.filterMatches({ ...g.noFilter, ...f }, c)).map(c => c.session.id);
  assert.deepEqual(only({ projects: ['payments-api', 'Standalone'] }), ['b', 'c']);
  assert.deepEqual(only({ agents: ['claude'] }), ['a']);
  assert.deepEqual(only({ macs: ['Mac mini'] }), ['b']);
  assert.ok(!g.filterMatches({ ...g.noFilter, projects: ['abstract'], agents: ['codex'] }, here), 'every filter must pass');
  const archived = chat('d', 'idle', { archived: true });
  assert.deepEqual(g.narrow([...all, archived], g.defaultPrefs, '').map(c => c.session.id), ['a', 'b', 'c'], 'archived chats only when asked for');
  assert.deepEqual(g.narrow([...all, archived], { ...g.defaultPrefs, showArchived: true }, 'd').map(c => c.session.id), ['d']);
});

test('the choices survive a relaunch, and bad stored values fall back', () => {
  const prefs = { arrangement: 'project', filter: { projects: ['abstract'], agents: ['codex'], macs: ['Studio'] }, showArchived: true };
  assert.deepEqual(g.parsePrefs(JSON.stringify(prefs)), prefs);
  assert.deepEqual(g.parsePrefs(null), g.defaultPrefs);
  assert.deepEqual(g.parsePrefs('not json'), g.defaultPrefs);
  assert.equal(g.parsePrefs('{"arrangement":"kanban"}').arrangement, 'status');
  assert.deepEqual(g.parsePrefs('{"filter":{"projects":["abstract"]}}').filter, { projects: ['abstract'], agents: [], macs: [] }, 'saved before Mac filters existed');
});
