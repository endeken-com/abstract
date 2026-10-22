const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const ts = require('typescript');

require.extensions['.ts'] = (module, path) => {
  const source = fs.readFileSync(path, 'utf8');
  const js = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 } }).outputText;
  module._compile(js, path);
};
const { connectionNotice, lastSeenText } = require('../src/composerStatus.ts');
const { settingFromAction, settingsAccessibilityLabel, settingsMenuActions } = require('../src/composerSettings.ts');

const now = Date.UTC(2026, 9, 22, 12);

test('an online Mac shows no connection state at all', () => {
  assert.equal(connectionNotice({ status: 'online', unreachable: false, macName: 'Studio', now }), null);
});

test('connecting says so without an action', () => {
  for (const status of ['connecting', 'pairing']) {
    assert.deepEqual(connectionNotice({ status, unreachable: true, macName: 'Studio', now }), { tone: 'connecting', title: 'Connecting to Studio…', detail: null, action: null });
  }
  // A Mac not tried yet is on its way, not failed.
  assert.equal(connectionNotice({ status: 'offline', unreachable: false, macName: 'Studio', now }).tone, 'connecting');
});

test('an unreachable Mac offers Retry, says when it was last seen and keeps the draft', () => {
  const notice = connectionNotice({ status: 'offline', unreachable: true, macName: 'Studio', lastSeenAt: now - 12 * 60_000, error: 'Error: Connection timed out', now });
  assert.equal(notice.tone, 'offline');
  assert.equal(notice.title, "Studio isn't reachable");
  assert.equal(notice.action, 'retry');
  assert.equal(notice.detail, 'Last seen 12 min ago. Connection timed out. Your draft stays here.');
});

test('a chat whose Mac is no longer paired points to Settings', () => {
  const notice = connectionNotice({ status: 'offline', unreachable: false, macName: null, now });
  assert.equal(notice.action, 'settings');
  assert.equal(notice.title, 'Not connected to a Mac');
});

test('last seen reads in plain words', () => {
  assert.equal(lastSeenText(null, now), null);
  assert.equal(lastSeenText(now - 20_000, now), 'Last seen just now.');
  assert.equal(lastSeenText(now - 3 * 3_600_000, now), 'Last seen 3 h ago.');
});

const settings = [
  { kind: 'agent', title: 'Agent', value: 'Claude Code', image: 'ProviderClaude', choices: [{ id: 'claude', title: 'Claude Code', selected: true }, { id: 'codex', title: 'Codex' }] },
  { kind: 'model', title: 'Model', value: 'Opus 4.5', image: 'cpu', choices: [{ id: '', title: 'Default model' }, { id: 'opus', title: 'Opus 4.5', selected: true }] },
  { kind: 'effort', title: 'Reasoning effort', value: 'High', choices: [{ id: '', title: 'Default effort' }, { id: 'high', title: 'High', selected: true }] },
  { kind: 'mode', title: 'Mode', value: 'Ask before acting', choices: [{ id: 'ask', title: 'Ask before acting', selected: true }, { id: 'plan', title: 'Plan' }] },
];

test('every setting is one submenu naming its current value and checking it', () => {
  const ios = settingsMenuActions(settings, 'ios');
  assert.deepEqual(ios.map(action => [action.title, action.subtitle]), [['Agent', 'Claude Code'], ['Model', 'Opus 4.5'], ['Reasoning effort', 'High'], ['Mode', 'Ask before acting']]);
  assert.deepEqual(ios[1].subactions.map(action => [action.id, action.state]), [['model:', 'off'], ['model:opus', 'on']]);
  const android = settingsMenuActions(settings, 'android');
  assert.equal(android[3].title, 'Mode: Ask before acting');
  assert.equal(android[0].image, undefined);
});

test('a menu choice maps back to its setting, defaults included', () => {
  assert.deepEqual(settingFromAction('agent:codex'), { kind: 'agent', id: 'codex' });
  assert.deepEqual(settingFromAction('model:'), { kind: 'model', id: '' });
  assert.deepEqual(settingFromAction('mode:auto-edits'), { kind: 'mode', id: 'auto-edits' });
  assert.equal(settingFromAction('model'), null);
  assert.equal(settingFromAction('terminal:x'), null);
});

test('VoiceOver reads every current setting from the one control', () => {
  assert.equal(settingsAccessibilityLabel(settings), 'Agent settings: Agent Claude Code, Model Opus 4.5, Reasoning effort High, Mode Ask before acting');
});
