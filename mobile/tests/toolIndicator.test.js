const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const ts = require('typescript');

require.extensions['.ts'] = (module, path) => {
  const source = fs.readFileSync(path, 'utf8');
  const js = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 } }).outputText;
  module._compile(js, path);
};
const { resolveToolIndicator, toolMonogram, brandGlyph } = require('../src/toolPresentation.ts');
const { chatTimeline } = require('../src/chatTimeline.ts');
const shell = command => resolveToolIndicator('Bash', { command });
const kind = indicator => indicator.kind === 'brand' ? indicator.id : indicator.kind === 'symbol' ? indicator.symbol : indicator.name;

test('CLI brands use their bundled marks', () => {
  for (const [command, expected] of [
    ['gh pr list', 'GitHub'], ['bkt pr list', 'Bitbucket'], ['acli jira issue view A-1', 'Jira'],
    ['linear issue list', 'Linear'], ['sudo -E linear issue list', 'Linear'],
    ['env NO_COLOR=1 bkt pr list', 'Bitbucket'], ['/usr/local/bin/gh pr list', 'GitHub'],
    ['npx tsc', 'TypeScript'], ['npx unknown-tool', 'Npm'], ['uv run pytest', 'Pytest'],
    ['pnpm test', 'Pnpm'], ['cd app && gh pr list | jq .', 'GitHub'],
    ['bash -c "gh pr list"', 'GitHub'],
  ]) {
    assert.equal(kind(shell(command)), expected, command);
    assert.ok(brandGlyph(expected), expected);
  }
});

test('unknown commands never claim a brand', () => {
  for (const command of ['echo linear', 'unknown-tool --flag', 'acli confluence page list', '$GH pr list', 'sudo --preserve-env=HOME gh pr list'])
    assert.equal(kind(shell(command)), 'terminal', command);
  assert.equal(kind(shell('grep gh file')), 'magnifyingglass');
  assert.equal(kind(shell('git log --grep=linear')), 'Git');
});

test('MCP aliases, private servers, and plugin IDs', () => {
  assert.equal(kind(resolveToolIndicator('mcp__github__list_prs')), 'GitHub');
  assert.equal(kind(resolveToolIndicator('mcp__github__code_history')), 'GitHub');
  assert.equal(kind(resolveToolIndicator('linear_get_issue')), 'Linear');
  assert.equal(kind(resolveToolIndicator('mcp__abstract-code-history__code_history')), 'Abstract');
  assert.equal(kind(resolveToolIndicator('mcp__weather__forecast')), 'weather');
  assert.equal(kind(resolveToolIndicator('weather_forecast')), 'wrench.and.screwdriver');
  assert.equal(kind(resolveToolIndicator('mcp__abstract-plugins__github_list_prs', {}, [{ id: 'sh.abstract.github', name: 'GitHub' }])), 'GitHub');
  assert.equal(kind(resolveToolIndicator('mcp__abstract-plugins__github_list_prs', {}, [{ id: 'dev.example.github', name: 'GitHub' }])), 'puzzlepiece.extension');
  assert.equal(kind(resolveToolIndicator('mcp__abstract-plugins__github_list_prs')), 'Abstract');
  assert.deepEqual(toolMonogram('weather'), toolMonogram('weather'));
});

test('Codex tool input reaches the phone indicator', () => {
  const item = { id: 'command-1', type: 'command_execution', command: '/bin/zsh -lc "gh pr list"', status: 'completed', exit_code: 0 };
  const lines = ['item.started', 'item.completed'].map((type, index) => ({ seq: index + 1, line: { stream: 'stdout', line: JSON.stringify({ type, item }) } }));
  const row = chatTimeline(lines, 'icons-codex').find(item => item.kind === 'tool');
  assert.equal(kind(resolveToolIndicator(row.toolName, row.toolInput)), 'GitHub');
});
