const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const ts = require('typescript');

const transpile = (module, path) => {
  const source = fs.readFileSync(path, 'utf8');
  const js = ts.transpileModule(source, { fileName: path, compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022, esModuleInterop: true } }).outputText;
  module._compile(js, path);
};
require.extensions['.ts'] = transpile;
const p = require('../src/automationPolicies.ts');

test('labels match the Mac editor, word for word', () => {
  assert.deepEqual(p.CONCURRENCY_OPTIONS, [
    { value: 'skip_if_active', label: 'Skip This One', phrase: 'skip this one' },
    { value: 'run_after', label: 'Run After It Finishes', phrase: 'run after it finishes' },
    { value: 'start_another', label: 'Start Another', phrase: 'start another' },
  ]);
  assert.deepEqual(p.MISSED_OPTIONS, [
    { value: 'skip', label: 'Skip Them', phrase: 'skip them' },
    { value: 'run_once', label: 'Run Once', phrase: 'run once' },
    { value: 'run_each', label: 'Run Each, Up to 5', phrase: 'run each, up to 5' },
  ]);
  assert.deepEqual(p.CHANGED_OPTIONS, [
    { value: false, label: 'Whether or Not the Project Changed', phrase: 'whether or not the project changed' },
    { value: true, label: 'Only When the Project Changed Since the Last Run', phrase: 'only when the project changed since the last run' },
  ]);
});

test('defaults follow where runs happen, like the Mac', () => {
  assert.equal(p.defaultConcurrency('pinned'), 'skip_if_active');
  assert.equal(p.defaultConcurrency('new_worktree'), 'start_another');
  assert.deepEqual(p.policiesOf(undefined, 'pinned'), { concurrency: 'skip_if_active', missedRuns: 'skip', onlyWhenChanged: false });
  assert.deepEqual(p.policiesOf(undefined, 'new_worktree'), { concurrency: 'start_another', missedRuns: 'skip', onlyWhenChanged: false });
});

test('an older Mac snapshot (only the catch-up switch) reads as run-once/skip', () => {
  assert.deepEqual(p.policiesOf({ catchUp: true }, 'pinned'), { concurrency: 'skip_if_active', missedRuns: 'run_once', onlyWhenChanged: false });
  assert.deepEqual(p.policiesOf({ catchUp: false }, 'new_worktree'), { concurrency: 'start_another', missedRuns: 'skip', onlyWhenChanged: false });
});

test('saved choices survive, and unknown values fall back instead of reaching the Mac', () => {
  const saved = { concurrency: 'run_after', missedRuns: 'run_each', onlyWhenChanged: true, catchUp: true };
  assert.deepEqual(p.policiesOf(saved, 'pinned'), { concurrency: 'run_after', missedRuns: 'run_each', onlyWhenChanged: true });
  assert.deepEqual(p.policiesOf({ concurrency: 'bogus', missedRuns: 'later', catchUp: true }, 'new_worktree'),
    { concurrency: 'start_another', missedRuns: 'run_once', onlyWhenChanged: false });
});

test('the old catch-up switch stays in step for older Macs', () => {
  assert.equal(p.catchUpOf('skip'), false);
  assert.equal(p.catchUpOf('run_once'), true);
  assert.equal(p.catchUpOf('run_each'), true);
});

test('switching workspace moves an untouched still-going default, keeps a chosen one', () => {
  assert.equal(p.concurrencyForWorkspace('start_another', 'new_worktree', 'pinned'), 'skip_if_active');
  assert.equal(p.concurrencyForWorkspace('skip_if_active', 'pinned', 'new_worktree'), 'start_another');
  assert.equal(p.concurrencyForWorkspace('run_after', 'new_worktree', 'pinned'), 'run_after');
});

test('the changed choice only shows for a project on that Mac', () => {
  assert.equal(p.showsChanged({ projectId: 'p1', deviceId: null }), true);
  assert.equal(p.showsChanged({ projectId: null, deviceId: null }), false);
  assert.equal(p.showsChanged({ projectId: 'p1', deviceId: 'other-mac' }), false);
});

test('skipped runs read with their reason, as on the Mac', () => {
  const skipped = { status: 'skipped', reason: 'skipped: last run still going', error: null };
  assert.equal(p.runStatusLabel(skipped), 'Skipped');
  assert.equal(p.runDetail(skipped), 'Skipped: last run still going.');
  assert.equal(p.runDetail({ status: 'skipped', reason: null, error: null }), null);
  assert.equal(p.runDetail({ status: 'skipped', reason: 'skipped: missed while Abstract was closed' }), 'Skipped: missed while Abstract was closed.');
  assert.equal(p.runDetail({ status: 'skipped', reason: "skipped: project hasn't changed since the last run" }), "Skipped: project hasn't changed since the last run.");
});

test('other runs keep their labels and errors', () => {
  assert.equal(p.runStatusLabel({ status: 'creating' }), 'Starting…');
  assert.equal(p.runStatusLabel({ status: 'created' }), 'Created');
  assert.equal(p.runStatusLabel({ status: 'failed' }), 'Failed');
  assert.equal(p.runDetail({ status: 'failed', error: 'boom' }), 'boom');
  assert.equal(p.runDetail({ status: 'created', error: null, reason: null }), null);
  assert.equal(p.runDetail({ status: 'failed', error: null }), null);
});
