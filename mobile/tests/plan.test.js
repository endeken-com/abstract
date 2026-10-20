const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const ts = require('typescript');

require.extensions['.ts'] = (module, path) => {
  const source = fs.readFileSync(path, 'utf8');
  module._compile(ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 } }).outputText, path);
};
const plan = require('../src/plan.ts');

test('mode choices offer Plan and Ask after the autonomy levels', () => {
  assert.deepEqual(plan.MODE_CHOICES.map(choice => choice.id), ['ask', 'auto-edits', 'bypass', 'plan', 'read-only']);
  assert.equal(plan.policyTitle('plan'), 'Plan');
  assert.equal(plan.policyTitle('read-only'), 'Ask (read-only)');
  assert.equal(plan.policyShort('read-only'), 'Ask');
  assert.equal(plan.policyTitle('bogus'), 'Ask before acting');
  assert.equal(plan.isReadOnlyMode('plan'), true);
  assert.equal(plan.isReadOnlyMode('read-only'), true);
  assert.equal(plan.isReadOnlyMode('ask'), false);
});

test('only waiting or revising plans with text are visible', () => {
  const waiting = { revisions: ['first', 'second'], status: 'waiting' };
  assert.equal(plan.visiblePlan(waiting), waiting);
  assert.equal(plan.visiblePlan({ ...waiting, status: 'changesRequested' })?.status, 'changesRequested');
  assert.equal(plan.visiblePlan({ ...waiting, status: 'approved' }), null);
  assert.equal(plan.visiblePlan({ ...waiting, status: 'discarded' }), null);
  assert.equal(plan.visiblePlan({ revisions: [], status: 'waiting' }), null);
  assert.equal(plan.visiblePlan(null), null);
  assert.equal(plan.currentPlan(waiting), 'second');
  assert.deepEqual(plan.planHistory(waiting), ['first']);
  assert.equal(plan.planTitle(waiting), 'Plan · revision 2');
  assert.equal(plan.planTitle({ revisions: ['only'], status: 'waiting' }), 'Plan');
});

test('an older Mac plan comes from its ExitPlanMode permission', () => {
  const permissions = [
    { requestId: 'a', toolName: 'Bash', input: {} },
    { requestId: 'b', toolName: 'ExitPlanMode', input: { plan: '  # Do it\n' } },
  ];
  assert.deepEqual(plan.planFromPermissions(permissions), { revisions: ['# Do it'], status: 'waiting' });
  assert.equal(plan.pendingPlanRequest(permissions)?.requestId, 'b');
  assert.equal(plan.isExitPlanMode('exitplanmode'), true);
  assert.equal(plan.isExitPlanMode('Bash'), false);
  assert.equal(plan.planFromPermissions([{ requestId: 'b', toolName: 'ExitPlanMode', input: { plan: ' ' } }]), null);
  // The snapshot plan wins; the permission is only a fallback.
  const snapshot = { revisions: ['from snapshot'], status: 'waiting' };
  assert.equal(plan.effectivePlan(snapshot, permissions), snapshot);
  assert.equal(plan.effectivePlan({ ...snapshot, status: 'approved' }, permissions)?.revisions[0], '# Do it');
  assert.equal(plan.effectivePlan(null, []), null);
  assert.deepEqual(plan.nonPlanPermissions(permissions).map(item => item.requestId), ['a']);
});

test('requesting changes quotes the plan for the composer', () => {
  assert.equal(plan.quotedPlan('one\n\ntwo'), '> one\n>\n> two');
  assert.equal(plan.quotedPlan(''), '>');
});
