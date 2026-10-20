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
const k = require('../src/kanban.ts');

const now = 1_000_000_000;
const pr = (number, state = 'OPEN', fields = {}) => ({ number, title: 't', state, isDraft: false, checks: [], ...fields });
const mac = (id, name, projects = [], state = 'online') => ({ id, name, state, snapshot: { projects, sessions: [], providers: [], alive: [] } });
const project = (id, name) => ({ id, name, rootPath: '/x', defaultBaseRef: 'main', defaultProviderId: 'claude', defaultPermissionPolicy: 'ask' });
const chat = (id, status = 'idle', o = {}) => {
  const { ago = 60, pullRequest = null, backgroundTasks = false, projectId = 'p1', projectName = 'abstract', branch = null, providerId = 'claude', pinnedAt = null, archived = false, macName = 'Studio', hostId = 'h1', macState = 'online', title } = o;
  return {
    hostId, mac: macName, macState,
    session: { id, name: title || id, status, providerId, branch, projectId, worktreePath: '/w/' + id, createdAt: now - ago - 10, lastEventAt: now - ago, pinnedAt, archivedAt: archived ? now : null },
    pullRequest, hasChanges: 'hasChanges' in o ? o.hasChanges : false, backgroundTasks, projectName,
  };
};
const macs1 = [mac('h1', 'Studio', [project('p1', 'abstract')])];
const cols = built => Object.fromEntries(built.columns.map(c => [c.key, c.cards.map(card => card.id)]));

test('columns match board.js order, titles and empties', () => {
  assert.deepEqual(k.boardColumns.map(c => c.key), ['needsYou', 'working', 'readyToReview', 'done']);
  assert.deepEqual(k.boardColumns.map(c => c.title), ['Needs you', 'Working', 'Ready to review', 'Done']);
  assert.equal(k.boardColumns[0].empty, 'Nothing needs you.');
});

test('progress grouping follows SidebarChats.status via board.js rules', () => {
  const built = k.buildBoard(macs1, [
    chat('asking', 'waiting_input'), chat('failed', 'errored'), chat('run', 'running'), chat('prov', 'provisioning'),
    chat('bg', 'idle', { backgroundTasks: true }), chat('open-pr', 'idle', { pullRequest: pr(7) }),
    chat('merged', 'idle', { pullRequest: pr(8, 'MERGED') }), chat('closed', 'idle', { pullRequest: pr(9, 'CLOSED') }),
    chat('dirty', 'idle', { hasChanges: true }), chat('unknown', 'idle', { hasChanges: undefined }), chat('clean', 'finished'),
  ], k.emptyFilter(), now);
  const c = cols(built);
  assert.deepEqual(c.needsYou.sort(), ['asking', 'failed']);
  assert.deepEqual(c.working.sort(), ['bg', 'prov', 'run']);
  assert.deepEqual(c.readyToReview.sort(), ['dirty', 'open-pr', 'unknown']);
  assert.deepEqual(c.done.sort(), ['clean', 'closed', 'merged']);
});

test('pinned chats stay in their real column; archived hidden unless asked', () => {
  const chats = [chat('pin', 'finished', { pinnedAt: now }), chat('arch', 'finished', { archived: true })];
  assert.deepEqual(cols(k.buildBoard(macs1, chats, k.emptyFilter(), now)).done, ['pin']);
  const shown = k.buildBoard(macs1, chats, { ...k.emptyFilter(), showArchived: true }, now);
  assert.deepEqual(cols(shown).done.sort(), ['arch', 'pin']);
  assert.equal(shown.archivedCount, 1);
  assert.equal(shown.columns.find(c => c.key === 'done').cards.find(card => card.id === 'pin').pinned, true);
});

test('cards sort most-recently-active first, then title', () => {
  const built = k.buildBoard(macs1, [chat('b', 'running', { ago: 10, title: 'Beta' }), chat('a', 'running', { ago: 10, title: 'Alpha' }), chat('old', 'running', { ago: 500 })], k.emptyFilter(), now);
  assert.deepEqual(cols(built).working, ['a', 'b', 'old']);
});

test('project options: same name on two Macs stays apart and names its Mac', () => {
  const macs = [mac('h1', 'Studio', [project('p1', 'abstract')]), mac('h2', 'Laptop', [project('p9', 'abstract'), project('p2', 'zeta')])];
  const chats = [chat('solo', 'idle', { projectId: null, projectName: null })];
  const options = k.projectOptions(macs, chats);
  assert.deepEqual(options.map(o => o.key), ['h1:p1', 'h2:p9', 'h2:p2', '__standalone__']);
  assert.equal(options[0].label, 'abstract · Studio');
  assert.equal(options[1].label, 'abstract · Laptop');
  assert.equal(options[2].label, 'zeta');
  assert.equal(options[3].label, 'Standalone');
  assert.equal(options[3].standalone, true);
});

test('project filter uses host:project keys, not names', () => {
  const macs = [mac('h1', 'Studio', [project('p1', 'abstract')]), mac('h2', 'Laptop', [project('p9', 'abstract')])];
  const chats = [chat('one', 'finished'), chat('two', 'finished', { hostId: 'h2', macName: 'Laptop', projectId: 'p9' }), chat('solo', 'finished', { projectId: null, projectName: null })];
  assert.deepEqual(cols(k.buildBoard(macs, chats, { ...k.emptyFilter(), projects: ['h2:p9'] }, now)).done, ['two']);
  assert.deepEqual(cols(k.buildBoard(macs, chats, { ...k.emptyFilter(), projects: ['__standalone__'] }, now)).done, ['solo']);
});

test('search matches title, branch, or bare PR number; agent and mac filters narrow', () => {
  const chats = [chat('x', 'finished', { title: 'Fix login', branch: 'feat/login', pullRequest: pr(42) }), chat('y', 'finished', { title: 'Other', providerId: 'codex' })];
  assert.deepEqual(cols(k.buildBoard(macs1, chats, { ...k.emptyFilter(), search: '#42' }, now)).readyToReview, ['x']);
  assert.deepEqual(cols(k.buildBoard(macs1, chats, { ...k.emptyFilter(), search: 'feat/log' }, now)).readyToReview, ['x']);
  assert.deepEqual(cols(k.buildBoard(macs1, chats, { ...k.emptyFilter(), search: 'LOGIN' }, now)).readyToReview, ['x']);
  assert.deepEqual(cols(k.buildBoard(macs1, chats, { ...k.emptyFilter(), agents: ['codex'] }, now)).done, ['y']);
  assert.deepEqual(cols(k.buildBoard(macs1, chats, { ...k.emptyFilter(), macs: ['h9'] }, now)).done, []);
});

test('card fields: agent names, PR line, mac only with several Macs, age', () => {
  assert.equal(k.agentName('muse'), 'Muse Code');
  assert.equal(k.agentName('ollama'), 'Codex · Ollama');
  assert.equal(k.agentName('mystery'), 'mystery');
  const open = pr(5, 'OPEN', { isDraft: true, reviewDecision: 'CHANGES_REQUESTED', checks: [{ name: 'ci', outcome: 'failed' }] });
  assert.equal(k.pullRequestLine(open), '#5 · draft · checks failing · changes requested');
  assert.equal(k.pullRequestLine(pr(6, 'MERGED', { isDraft: true, checks: [{ name: 'ci', outcome: 'failed' }] })), '#6 · merged');
  assert.equal(k.pullRequestLine(null), '');
  const two = [mac('h1', 'Studio', [project('p1', 'abstract')]), mac('h2', 'Laptop', [])];
  const built = k.buildBoard(two, [chat('x', 'finished', { ago: 7200 })], k.emptyFilter(), now);
  const card = built.columns.find(c => c.key === 'done').cards[0];
  assert.equal(card.macName, 'Studio');
  assert.equal(card.age, '2h');
  assert.equal(card.projectName, 'abstract');
  const solo = k.buildBoard(macs1, [chat('s', 'finished', { projectId: null, projectName: null })], k.emptyFilter(), now);
  assert.equal(solo.columns.find(c => c.key === 'done').cards[0].projectName, 'Standalone');
});

test('emptyKind, totals, unreachable Macs, unknown project fallback', () => {
  assert.equal(k.buildBoard(macs1, [], k.emptyFilter(), now).emptyKind, 'noChats');
  const none = k.buildBoard([mac('h1', 'Studio', [], 'unreachable')], [chat('x', 'finished', { projectId: 'gone', projectName: null, macState: 'unreachable' })], { ...k.emptyFilter(), search: 'zzz' }, now);
  assert.equal(none.emptyKind, 'noMatches');
  assert.deepEqual(none.unreachableMacs, ['Studio']);
  assert.equal(none.projects.find(o => o.key === 'h1:gone')?.label, 'Project');
  assert.equal(none.total, 1);
  assert.equal(none.shown, 0);
});

test('normalizeFilter keeps only the stored shape; prune drops vanished choices', () => {
  assert.deepEqual(k.normalizeFilter({ projects: ['a', 3], agents: 'x', search: 9, showArchived: 1, extra: true }), { projects: ['a'], agents: [], macs: [], search: '', showArchived: false });
  assert.deepEqual(k.normalizeFilter(null), k.emptyFilter());
  assert.equal(k.isFilterActive(k.emptyFilter()), false);
  assert.equal(k.isFilterActive({ ...k.emptyFilter(), search: ' x ' }), true);
  const built = k.buildBoard(macs1, [chat('x', 'finished')], k.emptyFilter(), now);
  const pruned = k.pruneFilter({ projects: ['h1:p1', 'h9:gone'], agents: ['claude', 'gone'], macs: ['h1', 'h9'], search: 'x', showArchived: true }, built);
  assert.deepEqual(pruned, { projects: ['h1:p1'], agents: ['claude'], macs: ['h1'], search: 'x', showArchived: true });
});
