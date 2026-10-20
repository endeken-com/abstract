const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const ts = require('typescript');

require.extensions['.ts'] = (module, path) => {
  const source = fs.readFileSync(path, 'utf8');
  const js = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 } }).outputText;
  module._compile(js, path);
};
const { historyTool, parseLineRange, toolKind, toolTarget, toolVerb } = require('../src/toolPresentation.ts');
const { chatTimeline } = require('../src/chatTimeline.ts');
const { relativePath } = require('../src/askAuthor.ts');
const line = (seq, value) => ({ seq, line: { stream: 'stdout', line: JSON.stringify(value) } });

test('history tools are recognised under every agent spelling', () => {
  assert.equal(historyTool('code_history'), 'code_history');
  assert.equal(historyTool('mcp__abstract-code-history__code_history'), 'code_history');
  assert.equal(historyTool('abstract-code-history_code_history'), 'code_history');
  assert.equal(historyTool('chat_excerpt'), 'chat_excerpt');
  assert.equal(historyTool('mcp__abstract-code-history__chat_excerpt'), 'chat_excerpt');
  assert.equal(historyTool('read'), null);
  assert.equal(historyTool('my_code_history_notes'), null);
});

test('history verbs and kind match the Mac', () => {
  assert.equal(toolVerb('mcp__abstract-code-history__code_history', true), 'Looking up history of');
  assert.equal(toolVerb('code_history'), 'Looked up history of');
  assert.equal(toolVerb('chat_excerpt', true), 'Reading more of an earlier chat');
  assert.equal(toolVerb('abstract-code-history_chat_excerpt'), 'Read more of an earlier chat');
  assert.equal(toolKind('code_history'), 'explore');
});

test('line ranges parse like the Mac', () => {
  assert.deepEqual(parseLineRange('220'), { first: 220, last: 220 });
  assert.deepEqual(parseLineRange('220-245'), { first: 220, last: 245 });
  assert.deepEqual(parseLineRange('220:245'), { first: 220, last: 245 });
  assert.equal(parseLineRange('245-220'), null);
  assert.equal(parseLineRange('abc'), null);
  assert.equal(parseLineRange(undefined), null);
});

test('a history lookup names its file and lines', () => {
  assert.deepEqual(toolTarget('code_history', { path: 'Sources/Diff.swift', lines: '220-245' }), { text: 'Diff.swift lines 220–245', path: 'Sources/Diff.swift' });
  assert.equal(toolTarget('mcp__abstract-code-history__code_history', { path: 'Sources/Diff.swift', lines: '220' }).text, 'Diff.swift line 220');
  assert.equal(toolTarget('code_history', { path: 'Sources/Diff.swift' }).text, 'Diff.swift');
  // Codex carries the arguments inside the item.
  assert.equal(toolTarget('code_history', { type: 'mcp_tool_call', arguments: { path: 'Sources/Diff.swift', lines: '1-2' } }).text, 'Diff.swift lines 1–2');
  assert.equal(toolTarget('code_history', { arguments: '{"path":"a/b.ts","lines":"3"}' }).text, 'b.ts line 3');
});

test('Claude history lookup reads readably in the timeline', () => {
  const lines = [
    line(1, { type: 'assistant', message: { content: [{ type: 'tool_use', id: 'h1', name: 'mcp__abstract-code-history__code_history', input: { path: 'Sources/Diff.swift', lines: '220-245' } }] } }),
    line(2, { type: 'user', message: { content: [{ type: 'tool_result', tool_use_id: 'h1', content: [{ type: 'text', text: 'Decided: never write the index.' }] }] } }),
  ];
  const row = chatTimeline(lines, 'claude-history').find(row => row.kind === 'tool');
  assert.equal(row.text, 'Looked up history of');
  assert.equal(row.target, 'Diff.swift lines 220–245');
  assert.equal(row.detail, 'Decided: never write the index.');
  assert.equal(row.pending, false);
});

test('Codex history lookup and failed excerpt read readably', () => {
  const lines = [
    line(1, { type: 'turn.started' }),
    line(2, { type: 'item.started', item: { id: 'i1', type: 'mcp_tool_call', server: 'abstract-code-history', tool: 'code_history', arguments: { path: 'Sources/Diff.swift', lines: '220-245' }, status: 'in_progress' } }),
    line(3, { type: 'item.completed', item: { id: 'i1', type: 'mcp_tool_call', server: 'abstract-code-history', tool: 'code_history', arguments: { path: 'Sources/Diff.swift', lines: '220-245' }, status: 'completed', result: { content: [{ type: 'text', text: 'Decided: never write the index.' }], isError: false } } }),
    line(4, { type: 'item.completed', item: { id: 'i2', type: 'mcp_tool_call', server: 'abstract-code-history', tool: 'chat_excerpt', arguments: { chat: 's-old', turn: 1 }, status: 'failed', error: { message: 'MCP tool call requires approval' } } }),
  ];
  const rows = chatTimeline(lines, 'codex-history').filter(row => row.kind === 'tool');
  assert.equal(rows[0].text, 'Looked up history of');
  assert.equal(rows[0].target, 'Diff.swift lines 220–245');
  assert.equal(rows[0].detail, 'Decided: never write the index.');
  assert.equal(rows[1].text, 'Read more of an earlier chat');
  assert.equal(rows[1].failed, true);
  assert.equal(rows[1].detail, 'MCP tool call requires approval');
});

test('OpenCode history lookup reads readably', () => {
  const lines = [line(1, { type: 'tool_use', part: { type: 'tool', tool: 'abstract-code-history_code_history', callID: 'c1', state: { status: 'completed', input: { path: 'Packages/Diff.swift' }, output: 'Decided: read with --no-optional-locks.' } } })];
  const row = chatTimeline(lines, 'opencode-history').find(row => row.kind === 'tool');
  assert.equal(row.text, 'Looked up history of');
  assert.equal(row.target, 'Diff.swift');
  assert.equal(row.detail, 'Decided: read with --no-optional-locks.');
});

test('relativePath stays inside the browsed root', () => {
  assert.equal(relativePath('/repo', '/repo/Sources/A.swift'), 'Sources/A.swift');
  assert.equal(relativePath('/repo/', '/repo/A.swift'), 'A.swift');
  assert.equal(relativePath('/repo', '/other/A.swift'), null);
  assert.equal(relativePath('/repo', '/repo/../secret'), null);
});
