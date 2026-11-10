const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const ts = require('typescript');

require.extensions['.ts'] = (module, path) => {
  const source = fs.readFileSync(path, 'utf8');
  const js = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 } }).outputText;
  module._compile(js, path);
};
const { chatTimeline } = require('../src/chatTimeline.ts');
const { toolKind } = require('../src/toolPresentation.ts');
const line = (seq, events, stream = 'stdout') => ({ seq, line: { stream, line: '{"event":"provider-specific"}' }, events });

test('synthetic plugin events show on the phone without a provider parser', () => {
  const lines = [
    line(1, [{ type: 'text', role: 'user', text: 'Inspect this' }], 'user'),
    line(2, [{ type: 'toolUse', id: 'orbit:1', name: 'read_file', input: { file_path: '/workspace/README.md' } }]),
    line(3, [{ type: 'toolResult', toolUseId: 'orbit:1', output: 'Hello', isError: false },
      { type: 'text', role: 'assistant', text: 'It says hello.', blockId: 'answer', partial: false }]),
  ];
  const rows = chatTimeline(lines, 'orbit');
  assert.deepEqual(rows.map(row => row.kind), ['user', 'tool', 'prose']);
  assert.deepEqual(rows.map(row => row.text), ['Inspect this', 'Read', 'It says hello.']);
  assert.equal(rows[1].target, 'README.md');
  assert.equal(rows[1].detail, 'Hello');
});

test('streaming blocks complete in place and replay identically', () => {
  const lines = [
    line(1, [{ type: 'thinking', text: 'Checking ', blockId: 'reason', partial: true }]),
    line(2, [{ type: 'thinking', text: 'the file', blockId: 'reason', partial: true },
      { type: 'text', role: 'assistant', text: 'First ', blockId: 'answer', partial: true }]),
  ];
  assert.deepEqual(chatTimeline(lines, 'stream').map(row => [row.text, row.pending]),
    [['Checking the file', true], ['First ', true]]);
  lines.push(line(3, [{ type: 'thinking', text: 'Checked the file', blockId: 'reason', partial: false },
    { type: 'text', role: 'assistant', text: 'First answer', blockId: 'answer', partial: false }]));
  const rows = chatTimeline(lines, 'stream');
  assert.deepEqual(rows.map(row => [row.text, row.pending]),
    [['Checked the file', false], ['First answer', false]]);
  assert.deepEqual(chatTimeline(lines, 'stream-replay'), rows);
});

test('host scoped IDs preserve reused tool names across turns', () => {
  const lines = [
    line(1, [{ type: 'toolUse', id: 'codex:1:item_2', name: 'command_execution', input: { command: 'echo first' } },
      { type: 'toolResult', toolUseId: 'codex:1:item_2', output: 'first', isError: false }]),
    line(2, [{ type: 'text', role: 'user', text: 'Again' }], 'user'),
    line(3, [{ type: 'toolUse', id: 'codex:2:item_2', name: 'command_execution', input: { command: 'echo second' } },
      { type: 'toolResult', toolUseId: 'codex:2:item_2', output: 'second', isError: false }]),
  ];
  const rows = chatTimeline(lines, 'scoped-ids');
  assert.deepEqual(rows.filter(row => row.kind === 'tool').map(row => row.target), ['echo first', 'echo second']);
  assert.deepEqual(rows.filter(row => row.kind === 'tool').map(row => row.detail), ['first', 'second']);
});

test('host edit previews, results, and failures render without wire knowledge', () => {
  const edit = { filePath: '/workspace/App.swift', additions: 2, deletions: 1,
    lines: [{ origin: '-', content: 'old', oldLine: 1 }, { origin: '+', content: 'new', newLine: 1 }] };
  const lines = [
    line(1, [{ type: 'toolUse', id: 'gemini:2', name: 'write_to_file', input: { file_path: '/workspace/App.swift' }, edit }]),
    line(2, [{ type: 'toolResult', toolUseId: 'gemini:2', output: 'Permission denied', isError: true }]),
  ];
  const row = chatTimeline(lines, 'gemini-edit')[0];
  assert.equal(row.failed, true);
  assert.equal(row.detail, 'Permission denied');
  assert.equal(row.additions, 2);
  assert.equal(row.deletions, 1);
  assert.equal(row.edits[0].lines[0].text, '-old');
});

test('generic tool rows keep names, targets, and turn timing', () => {
  const lines = [line(1, [
    { type: 'toolUse', id: 'tool:1', name: 'mcp__cua_repl__js', input: { title: 'Inspect screen', code: 'await app.getAXState()' } },
    { type: 'toolResult', toolUseId: 'tool:1', output: 'Done', isError: false },
    { type: 'turnEnd', durationMs: 1200 },
  ])];
  const rows = chatTimeline(lines, 'js-tool');
  assert.equal(toolKind(rows[0].toolName), 'command');
  assert.equal(rows[0].text, 'Ran');
  assert.equal(rows[0].target, 'Inspect screen');
  assert.equal(rows[1].durationMs, 1200);
});

test('historical pages rebuild from normalized events and raw output never parses', () => {
  const recent = [line(3, [{ type: 'text', role: 'assistant', text: 'new' }]),
    line(4, [{ type: 'error', message: 'Try again' }])];
  assert.deepEqual(chatTimeline(recent, 'pages').map(row => row.text), ['new', 'Try again']);
  const older = [line(1, [{ type: 'text', role: 'user', text: 'old' }], 'user'),
    line(2, []), ...recent];
  assert.deepEqual(chatTimeline(older, 'pages').map(row => row.text), ['old', 'new', 'Try again']);
  const noEvents = [line(1, undefined)];
  assert.deepEqual(chatTimeline(noEvents, 'no-events'), []);
});
