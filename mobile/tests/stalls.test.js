const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const ts = require('typescript');

require.extensions['.ts'] = (module, path) => {
  const source = fs.readFileSync(path, 'utf8');
  const js = ts.transpileModule(source, { fileName: path, compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022, esModuleInterop: true } }).outputText;
  module._compile(js, path);
};
const stalls = require('../src/stalls.ts');
const g = require('../src/chatGroups.ts');

const now = 1_000_000_000; // Swift reference seconds, as the snapshot sends dates.
const quiet = { state: 'quiet', since: now - 7 * 60 };
const stalled = { state: 'stalled', since: now - 22 * 60 };

test('labels match the Mac working line and sidebar', () => {
  assert.equal(stalls.stallText(quiet, now), 'No output for 7 min');
  assert.equal(stalls.stallText(stalled, now), 'Stalled — no output for 22 min');
  assert.equal(stalls.stallRowText(quiet, now), 'No output for 7 min');
  assert.equal(stalls.stallRowText(stalled, now), 'Stalled');
  assert.equal(stalls.stallText({ state: 'quiet', since: now + 60 }, now), 'No output for 0 min');
});

const chat = (id, stall = null, status = 'running') => ({
  hostId: 'h1', mac: 'Studio', macState: 'online',
  session: { id, name: id, status, providerId: 'claude', branch: null, projectId: 'p1', worktreePath: '/w/' + id, createdAt: now - 100, lastEventAt: now - 60, pinnedAt: null, archivedAt: null },
  pullRequest: null, hasChanges: false, backgroundTasks: false, projectName: 'abstract', stall,
});

test('a stalled chat moves to Needs you; a quiet one stays Working', () => {
  const groups = Object.fromEntries(g.sections([chat('plain'), chat('hushed', quiet), chat('stuck', stalled)], now).map(s => [s.group, s.chats.map(c => c.session.id)]));
  assert.deepEqual(groups.needsYou, ['stuck']);
  assert.deepEqual(groups.working.sort(), ['hushed', 'plain']);
});

test('the row line leads with the stall, and a stall alone fills the line', () => {
  assert.equal(g.lineText(g.lineOf(chat('stuck', stalled), true, false, now)), 'Stalled · abstract');
  assert.equal(g.lineText(g.lineOf(chat('hushed', quiet), false, false, now)), 'No output for 7 min');
  assert.equal(g.lineIsEmpty(g.lineOf(chat('hushed', quiet), false, false, now)), false);
  assert.equal(g.lineOf(chat('stuck', stalled), true, false, now).stalled, true);
  assert.equal(g.lineOf(chat('hushed', quiet), true, false, now).stalled, false);
});

test('chatsFromSnapshot carries stalls by chat id, and older snapshots have none', () => {
  const mac = { id: 'h1', name: 'Studio', state: 'online' };
  const base = { projects: [{ id: 'p1', name: 'abstract' }], providers: [], alive: [],
    sessions: [{ id: 'a', name: 'a', status: 'running', providerId: 'claude', projectId: 'p1', worktreePath: '/w/a', createdAt: now - 100, lastEventAt: now - 60 }] };
  assert.deepEqual(g.chatsFromSnapshot({ ...base, stalls: { a: stalled } }, mac)[0].stall, stalled);
  assert.equal(g.chatsFromSnapshot(base, mac)[0].stall, null);
});
