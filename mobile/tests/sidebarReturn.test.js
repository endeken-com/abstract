const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const ts = require('typescript');

require.extensions['.ts'] = (module, path) => {
  const source = fs.readFileSync(path, 'utf8');
  module._compile(ts.transpileModule(source, { fileName: path, compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 } }).outputText, path);
};
const { nextSidebarReturn, restorable, returnChat } = require('../src/sidebarReturn.ts');

const sidebar = { name: 'Sidebar' };
const chat = (sessionId, hostId = 'm1') => ({ name: 'Chat', params: { hostId, sessionId } });
const review = (sessionId, hostId = 'm1') => ({ name: 'Review', params: { hostId, sessionId } });
const files = (sessionId, hostId = 'm1') => ({ name: 'Files', params: { hostId, root: '/r', sessionId } });
const mac = (id, sessions, snapshot = true) => ({ id, name: id, state: 'online', snapshot: snapshot ? { projects: [], sessions: sessions.map(id => ({ id })), providers: [], alive: [] } : null });

// Walks a sequence of stacks the way the navigation container reports them.
const walk = (...stacks) => stacks.reduce((state, next) => ({ previous: next, remembered: nextSidebarReturn(state.previous, next, state.remembered) }), { previous: [], remembered: null }).remembered;

test('a cold launch has nothing to return to', () => {
  assert.equal(walk([sidebar]), null);
  assert.equal(restorable(null, [mac('m1', ['a'])]), null);
});

test('opening the sidebar from a chat returns to that chat, not the newest', () => {
  const remembered = walk([sidebar], [sidebar, chat('old')], [sidebar]);
  assert.deepEqual(remembered, [chat('old')]);
  assert.deepEqual(returnChat(remembered), { hostId: 'm1', sessionId: 'old' });
});

test('a side view open over the chat comes back with it', () => {
  for (const side of [review, files, s => ({ name: 'PullRequest', params: { hostId: 'm1', sessionId: s } }), s => ({ name: 'Terminal', params: { hostId: 'm1', root: '/r', sessionId: s } })]) {
    const remembered = walk([sidebar], [sidebar, chat('a')], [sidebar, chat('a'), side('a')], [sidebar]);
    assert.deepEqual(remembered, [chat('a'), side('a')]);
  }
});

test('going back from a side view returns to its chat, then the sidebar remembers the chat', () => {
  const remembered = walk([sidebar], [sidebar, chat('a')], [sidebar, chat('a'), review('a')], [sidebar, chat('a')], [sidebar]);
  assert.deepEqual(remembered, [chat('a')]);
});

test('switching chats remembers the chosen one', () => {
  const remembered = walk([sidebar], [sidebar, chat('a')], [sidebar], [sidebar, chat('b')], [sidebar]);
  assert.deepEqual(remembered, [chat('b')]);
});

test('visiting a destination from the sidebar keeps the chat it was opened from', () => {
  for (const name of ['Settings', 'Automations', 'Worktrees', 'PullRequests', 'Kanban', 'NewChat']) {
    const remembered = walk([sidebar], [sidebar, chat('a')], [sidebar], [sidebar, { name }], [sidebar]);
    assert.deepEqual(remembered, [chat('a')], name);
  }
});

test('a chat opened from a destination returns with that destination under it', () => {
  const remembered = walk([sidebar], [sidebar, { name: 'Kanban' }], [sidebar, { name: 'Kanban' }, chat('a')], [sidebar]);
  assert.deepEqual(remembered, [{ name: 'Kanban', params: undefined }, chat('a')]);
});

test('restoring the stack does not change what is remembered', () => {
  const remembered = walk([sidebar], [sidebar, chat('a'), review('a')], [sidebar], [sidebar, chat('a'), review('a')]);
  assert.deepEqual(remembered, [chat('a'), review('a')]);
});

test('a chat deleted while the sidebar is open leaves nothing to return to', () => {
  const remembered = [chat('a'), review('a')];
  assert.deepEqual(restorable(remembered, [mac('m1', ['a', 'b'])]), remembered);
  assert.equal(restorable(remembered, [mac('m1', ['b'])]), null);
  assert.equal(restorable(remembered, []), null, 'its Mac was forgotten');
});

test('a Mac still connecting keeps the chat', () => {
  const remembered = [chat('a')];
  assert.deepEqual(restorable(remembered, [mac('m1', [], false)]), remembered);
});

test('the same chat id on two Macs is told apart', () => {
  assert.equal(restorable([chat('a', 'm2')], [mac('m1', ['a']), mac('m2', [])]), null);
});
