const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const ts = require('typescript');

require.extensions['.ts'] = (module, path) => {
  const source = fs.readFileSync(path, 'utf8');
  module._compile(ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 } }).outputText, path);
};
const { composerActions, queuedMessages, settledByQueue } = require('../src/messageQueue.ts');

const chat = (providerId, status, id = 'c1') => ({ id, providerId, status });
const queued = (id, text, attachments = []) => ({ id, text, attachments, queuedAt: 0 });
const snapshot = (extra = {}) => ({ projects: [], sessions: [], providers: [], alive: ['c1'], messageQueue: true, steerAgents: ['claude', 'muse'], ...extra });

test('mid-turn, Send becomes Queue and Stop stays for an empty composer', () => {
  assert.equal(composerActions(snapshot(), chat('codex', 'running'), true).primary, 'queue');
  assert.equal(composerActions(snapshot(), chat('codex', 'running'), false).primary, 'stop');
  assert.equal(composerActions(snapshot(), chat('claude', 'waiting_input'), true).primary, 'queue');
  assert.equal(composerActions(snapshot(), chat('codex', 'idle'), true).primary, 'send');
});

test('Steer reaches Claude, and is greyed out for Codex and OpenCode with why', () => {
  const claude = composerActions(snapshot(), chat('claude', 'running'), true);
  assert.deepEqual(claude.steer, { enabled: true, reason: null });
  assert.equal(claude.interrupt, true);
  const codex = composerActions(snapshot(), chat('codex', 'running'), true);
  assert.deepEqual(codex.steer, { enabled: false, reason: 'Codex reads messages between turns' });
  assert.equal(codex.interrupt, true);
  assert.equal(composerActions(snapshot(), chat('opencode', 'running'), true).steer.reason, 'OpenCode reads messages between turns');
  // Nothing typed or queued: nothing to steer with.
  assert.equal(composerActions(snapshot(), chat('claude', 'running'), false).steer, null);
  // Queued messages alone can be steered or interrupted with.
  const withQueue = snapshot({ queuedMessages: { c1: [queued('q1', 'also the README')] } });
  assert.equal(composerActions(withQueue, chat('claude', 'running'), false).steer.enabled, true);
});

test('the queue says when it goes', () => {
  const withQueue = snapshot({ queuedMessages: { c1: [queued('q1', 'one'), queued('q2', 'two')] } });
  assert.deepEqual(queuedMessages(withQueue, 'c1').map(x => x.id), ['q1', 'q2']);
  assert.equal(composerActions(withQueue, chat('codex', 'running'), false).queueCaption, 'Sent together when this turn ends.');
  assert.match(composerActions(withQueue, chat('codex', 'finished'), false).queueCaption, /^Not sent yet/);
  assert.equal(composerActions(snapshot(), chat('codex', 'running'), false).queueCaption, null);
});

test('a Mac too old to queue keeps Stop and offers no Steer', () => {
  const old = snapshot({ messageQueue: undefined });
  assert.deepEqual(composerActions(old, chat('claude', 'running'), true), { primary: 'stop', steer: null, interrupt: false, queueCaption: null });
  assert.equal(composerActions(old, chat('claude', 'idle'), true).primary, 'send');
});

test('a message sent mid-turn settles once the queue shows it, each queued message once', () => {
  const pending = [
    { id: 'p1', text: 'same', attachments: [], afterSeq: 0, status: 'accepted' },
    { id: 'p2', text: 'same', attachments: [], afterSeq: 0, status: 'accepted' },
    { id: 'p3', text: 'still sending', attachments: [], afterSeq: 0, status: 'sending' },
  ];
  assert.deepEqual(settledByQueue(pending, [queued('q1', 'same')]), ['p1']);
  assert.deepEqual(settledByQueue(pending, [queued('q1', 'same'), queued('q2', 'same\n')]), ['p1', 'p2']);
  assert.deepEqual(settledByQueue(pending, [queued('q3', 'still sending')]), []);
  assert.deepEqual(settledByQueue([{ ...pending[0], attachments: [{ id: 'a' }] }], [queued('q1', 'same')]), []);
});
