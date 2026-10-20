const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const ts = require('typescript');

require.extensions['.ts'] = (module, path) => {
  const js = ts.transpileModule(fs.readFileSync(path, 'utf8'), { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 } }).outputText;
  module._compile(js, path);
};
const { suggestedRule, buildRule, ruleDetail, isRuleExpired, rulesForProject, saveRuleArgs, deleteRuleArgs } = require('../src/permissionRules.ts');

// Mirrors PermissionRule.suggested on the Mac.
test('a command request suggests a command rule, shell wrapper unwrapped', () => {
  assert.deepEqual(suggestedRule('Bash', { command: 'npm test -- --watch=false' }, '/wt'), { kind: 'command', pattern: 'npm test -- --watch=false' });
  assert.deepEqual(suggestedRule('Bash', { command: '/bin/zsh -lc "npm test"' }, '/wt'), { kind: 'command', pattern: 'npm test' });
  assert.deepEqual(suggestedRule('Bash', { command: "sh -c 'ls -la'" }, ''), { kind: 'command', pattern: 'ls -la' });
});

test('a file request suggests its top folder, relative to the worktree root', () => {
  assert.deepEqual(suggestedRule('Edit', { file_path: '/wt/chat/src/app/main.swift' }, '/wt/chat'), { kind: 'path', pattern: 'src/**' });
  assert.deepEqual(suggestedRule('Write', { filePath: 'docs/guide.md' }, ''), { kind: 'path', pattern: 'docs/**' });
  assert.deepEqual(suggestedRule('Read', { path: './README.md' }, ''), { kind: 'path', pattern: './**' });
  assert.deepEqual(suggestedRule('Read', { file_path: '/elsewhere/x.txt' }, '/wt'), { kind: 'path', pattern: '/elsewhere/x.txt' });
});

test('anything else suggests a tool rule', () => {
  assert.deepEqual(suggestedRule('mcp__linear__get_issue', { id: 'A-1' }, '/wt'), { kind: 'tool', pattern: 'mcp__linear__get_issue' });
  assert.deepEqual(suggestedRule('Bash', { command: '   ' }, '/wt'), { kind: 'tool', pattern: 'Bash' });
  assert.deepEqual(suggestedRule('Bash', null, '/wt'), { kind: 'tool', pattern: 'Bash' });
});

test('buildRule trims the pattern and stamps Swift dates', () => {
  const now = 800_000_000;
  assert.deepEqual(buildRule({ id: 'r1', projectId: 'p1', kind: 'command', pattern: '  npm test* ', decision: 'allow', expiresInDays: null, now }),
    { id: 'r1', projectId: 'p1', kind: 'command', pattern: 'npm test*', decision: 'allow', expiresAt: null, createdAt: now });
  assert.equal(buildRule({ id: 'r2', projectId: 'p1', kind: 'path', pattern: 'src/**', decision: 'deny', expiresInDays: 7, now }).expiresAt, now + 7 * 86400);
});

test('expiry and the settings detail line follow the Mac wording', () => {
  const now = 800_000_000;
  const rule = { id: 'r', projectId: 'p', kind: 'command', pattern: 'rm *', decision: 'deny', expiresAt: now - 1, createdAt: now - 10 };
  assert.equal(isRuleExpired(rule, now), true);
  assert.equal(isRuleExpired({ ...rule, expiresAt: now + 5 }, now), false);
  assert.equal(isRuleExpired({ ...rule, expiresAt: null }, now), false);
  assert.match(ruleDetail(rule, now), /^Always deny · Command · expired /);
  assert.match(ruleDetail({ ...rule, decision: 'allow', kind: 'tool', expiresAt: now + 5 }, now), /^Always allow · Tool · expires /);
  assert.equal(ruleDetail({ ...rule, kind: 'path', expiresAt: null }, now), 'Always deny · Path');
});

test('rules come from the snapshot by project, oldest first; older Macs have none', () => {
  const a = { id: 'a', projectId: 'p1', kind: 'tool', pattern: 'Read', decision: 'allow', expiresAt: null, createdAt: 2 };
  const b = { id: 'b', projectId: 'p1', kind: 'tool', pattern: 'Write', decision: 'deny', expiresAt: null, createdAt: 1 };
  assert.deepEqual(rulesForProject({ permissionRules: { p1: [a, b] } }, 'p1').map(r => r.id), ['b', 'a']);
  assert.deepEqual(rulesForProject({ permissionRules: { p1: [a] } }, 'p2'), []);
  assert.deepEqual(rulesForProject({}, 'p1'), []);
  assert.deepEqual(rulesForProject(null, 'p1'), []);
});

test('request args match the Swift RemoteRequest encoding', () => {
  const rule = { id: 'r1', projectId: 'p1', kind: 'command', pattern: 'ls', decision: 'allow', expiresAt: null, createdAt: 1 };
  assert.deepEqual(saveRuleArgs(rule), { _0: rule });
  assert.deepEqual(deleteRuleArgs(rule), { id: 'r1' });
});
