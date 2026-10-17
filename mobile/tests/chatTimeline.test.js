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
const line = (seq, stream, value) => ({ seq, line: { stream, line: typeof value === 'string' ? value : JSON.stringify(value) } });

test('Mac follow-ups stay visible alongside agent output and replay', () => {
  const lines = [line(1, 'user', 'First request'), line(2, 'stdout', { type: 'assistant', message: { content: [{ type: 'text', text: 'Done.' }] } })];
  assert.deepEqual(chatTimeline(lines, 'mac-followup').map(row => row.text), ['First request', 'Done.']);
  lines.push(line(3, 'user', 'Follow-up from the Mac'));
  assert.deepEqual(chatTimeline(lines, 'mac-followup').filter(row => row.kind === 'user').map(row => row.text), ['First request', 'Follow-up from the Mac']);
});

test('edit summaries count the full Claude patch', () => {
  const lines = [
    line(1, 'stdout', { type: 'assistant', message: { content: [{ type: 'tool_use', id: 'edit-1', name: 'Edit', input: { file_path: '/a.swift' } }] } }),
    line(2, 'stdout', { type: 'user', message: { content: [{ type: 'tool_result', tool_use_id: 'edit-1', content: 'ok' }] }, tool_use_result: { structuredPatch: [{ lines: [2, ' keep', '-old', '+new', '+more'] }] } }),
  ];
  const edit = chatTimeline(lines, 'claude-edit').find(row => row.kind === 'tool');
  assert.equal(edit.additions, 2);
  assert.equal(edit.deletions, 1);
});

test('Codex change diffs count each file once', () => {
  const lines = [line(1, 'stdout', { type: 'item.completed', item: { id: 'change-1', type: 'file_change', diff: '@@ -1 +1 @@\n-old\n+new', changes: [{ path: '/a.ts', diff: '@@ -1 +1 @@\n-old\n+new' }] } })];
  const edit = chatTimeline(lines, 'codex-edit').find(row => row.kind === 'tool');
  assert.equal(edit.additions, 1);
  assert.equal(edit.deletions, 1);
});

test('JavaScript tool calls read as commands with their task title', () => {
  const lines = [line(1, 'stdout', { type: 'item.completed', item: { id: 'js-1', type: 'mcp_tool_call', server: 'cua_repl', tool: 'js', arguments: "{'code': 'await app.getAXState();', 'title': 'Inspect chat'}", result: { content: [{ type: 'text', text: 'Done' }] }, status: 'completed' } })];
  const row = chatTimeline(lines, 'js-tool')[0];
  assert.equal(toolKind(row.toolName), 'command');
  assert.equal(row.text, 'Ran');
  assert.equal(row.target, 'Inspect chat');
  assert.match(row.detail, /Done/);
  const mcpLines = [line(1, 'stdout', { type: 'assistant', message: { content: [{ type: 'tool_use', id: 'js-2', name: 'mcp__cua_repl__js', input: { code: 'await app.getAXState()', title: 'Inspect screen' } }] } })];
  const mcpRow = chatTimeline(mcpLines, 'mcp-js')[0];
  assert.equal(toolKind(mcpRow.toolName), 'command');
  assert.equal(mcpRow.text, 'Running');
  assert.equal(mcpRow.target, 'Inspect screen');
});

test('Codex reuses item IDs in later turns without losing messages or commands', () => {
  const lines = [
    line(1, 'stdout', { type: 'turn.started' }),
    line(2, 'stdout', { type: 'item.completed', item: { id: 'item_1', type: 'agent_message', text: 'First reply' } }),
    line(3, 'stdout', { type: 'item.completed', item: { id: 'item_2', type: 'command_execution', command: 'echo first', aggregated_output: 'first' } }),
    line(4, 'user', 'Follow-up'),
    line(5, 'stdout', { type: 'turn.started' }),
    line(6, 'stdout', { type: 'item.completed', item: { id: 'item_1', type: 'agent_message', text: 'Second reply' } }),
    line(7, 'stdout', { type: 'item.completed', item: { id: 'item_2', type: 'command_execution', command: 'echo second', aggregated_output: 'second' } }),
  ];
  chatTimeline(lines.slice(0, 3), 'reused-codex-items');
  const rows = chatTimeline(lines, 'reused-codex-items');
  assert.deepEqual(rows.map(row => row.text), ['First reply', 'Ran', 'Follow-up', 'Second reply', 'Ran']);
  assert.deepEqual(rows.filter(row => row.kind === 'tool').map(row => row.target), ['echo first', 'echo second']);
});

test('Muse Code serve items show files, changes and searches', () => {
  const item = (seq, method, it) => line(seq, 'stdout', { jsonrpc: '2.0', method, params: { item: it } });
  const lines = [
    item(1, 'item/started', { itemId: 'i1', kind: 'toolCall', revision: 1, status: 'inProgress', tool: 'read_file', callId: 'c1', args: '{"path":"src/App.swift"}' }),
    item(2, 'item/completed', { itemId: 'i1', kind: 'toolCall', revision: 2, status: 'completed', tool: 'read_file', callId: 'c1', args: '{"path":"src/App.swift"}', visibleOutput: 'Read text file `App.swift`.' }),
    item(3, 'item/completed', { itemId: 'i2', kind: 'toolCall', revision: 2, status: 'completed', tool: 'search', callId: 'c2', args: '{"pattern":"needle"}', visibleOutput: 'App.swift:2:needle' }),
    item(4, 'item/completed', { itemId: 'i3', kind: 'toolCall', revision: 2, status: 'completed', tool: 'edit_file', callId: 'c3', args: '{"path":"App.swift","find":"old","replace":"new"}', visibleOutput: 'edited' }),
    item(5, 'item/completed', { itemId: 'i4', kind: 'toolCall', revision: 2, status: 'completed', tool: 'write_file', callId: 'c4', args: '{"path":"made.txt","content":"made"}', visibleOutput: 'wrote 4 bytes' }),
    item(6, 'item/completed', { itemId: 'i5', kind: 'toolCall', revision: 2, status: 'completed', tool: 'bash', callId: 'c5', args: '{"command":"echo hi"}', visibleOutput: 'hi' }),
    item(7, 'item/completed', { itemId: 'i6', kind: 'toolCall', revision: 2, status: 'completed', tool: 'web_search', callId: 'c6', args: '{"query":"swift version"}', visibleOutput: '{}' }),
    item(8, 'item/completed', { itemId: 'i7', kind: 'toolCall', revision: 2, status: 'failed', tool: 'read_file', callId: 'c7', args: '{"path":"missing.txt"}', failureReason: 'No such file' }),
    item(9, 'item/completed', { itemId: 'm1', kind: 'agentMessage', revision: 1, status: 'completed', text: 'done' }),
    line(10, 'stdout', { jsonrpc: '2.0', method: 'turn/completed', params: { terminal: 'completed', durationMs: 1200 } }),
  ];
  const rows = chatTimeline(lines, 'muse-serve');
  const tools = rows.filter(row => row.kind === 'tool');
  assert.deepEqual(tools.map(row => row.toolName), ['read_file', 'search', 'edit_file', 'write_file', 'bash', 'web_search', 'read_file']);
  assert.deepEqual(tools.map(row => row.text), ['Read', 'Searched', 'Edited', 'Created', 'Ran', 'Searched the web', 'Read']);
  assert.deepEqual(tools.map(row => row.target), ['App.swift', 'needle', 'App.swift', 'made.txt', 'echo hi', 'swift version', 'missing.txt']);
  assert.equal(tools[0].path, 'src/App.swift');
  assert.equal(toolKind('read_file'), 'explore');
  assert.equal(toolKind('edit_file'), 'edit');
  assert.equal(toolKind('web_fetch'), 'explore');
  assert.equal(tools[2].additions, 1);
  assert.equal(tools[2].deletions, 1);
  assert.equal(tools[3].additions, 1);
  assert.equal(tools.at(-1).failed, true);
  assert.equal(tools.at(-1).detail, 'No such file');
  assert.equal(rows.find(row => row.kind === 'prose')?.text, 'done');
  assert.equal(rows.find(row => row.kind === 'turn')?.durationMs, 1200);
});

test('Muse Code calls with unparsable arguments keep their output and no target', () => {
  const lines = [line(1, 'stdout', { jsonrpc: '2.0', method: 'item/completed', params: { item: { itemId: 'i1', kind: 'toolCall', revision: 1, status: 'completed', tool: 'read_file', callId: 'c1', args: '{path: x', visibleOutput: 'the output' } } })];
  const row = chatTimeline(lines, 'muse-bad-args').find(r => r.kind === 'tool');
  assert.equal(row.target, '');
  assert.equal(row.detail, 'the output');
});
