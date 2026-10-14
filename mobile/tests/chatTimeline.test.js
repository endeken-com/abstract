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

// Turn lengths, read from the times the Mac logs each line with (Swift reference-date seconds).
const { turnLabel, duration } = require('../src/chatTimeline.ts');
const fixture = name => fs.readFileSync(`${__dirname}/../../Packages/AbstractCore/Tests/AbstractCoreTests/Fixtures/${name}.jsonl`, 'utf8').split('\n').filter(Boolean);
const start = 800_000_000;
/** Your message, then the agent's lines a second apart, as the log keeps them. */
const timedLog = (firstSeq, message, agentLines, from = start) => [
  { seq: firstSeq, line: { stream: 'user', line: message, at: from } },
  ...agentLines.map((text, index) => ({ seq: firstSeq + index + 1, line: { stream: 'stdout', line: text, at: from + index + 1 } })),
];
const turns = rows => rows.filter(row => row.kind === 'turn');
const openCodeTurn = n => [
  { type: 'step_start', sessionID: 'ses_a', part: { type: 'step-start' } },
  { type: 'text', sessionID: 'ses_a', part: { id: `a${n}`, type: 'text', text: 'Looking.' } },
  { type: 'step_finish', sessionID: 'ses_a', part: { type: 'step-finish', tokens: { input: 10, output: 2 }, cost: 0.01 } },
  { type: 'step_start', sessionID: 'ses_a', part: { type: 'step-start' } },
  { type: 'text', sessionID: 'ses_a', part: { id: `b${n}`, type: 'text', text: 'Done.' } },
  { type: 'step_finish', sessionID: 'ses_a', part: { type: 'step-finish', tokens: { input: 20, output: 4 }, cost: 0.02 } },
].map(value => JSON.stringify(value));

test('a Claude turn runs from your message to its result', () => {
  const lines = fixture('claude-stream');
  const rows = turns(chatTimeline(timedLog(1, 'make hi.txt', lines), 'claude-turn', 'idle'));
  assert.equal(rows.length, 1);
  // The result is the second-to-last line; the task summary after it isn't the turn.
  assert.equal(rows[0].durationMs, (lines.length - 1) * 1000);
  assert.equal(rows[0].reportedMs, 4762);
  assert.equal(turnLabel(rows[0]), `hi.txt created · Done in ${duration((lines.length - 1) * 1000)}`);
});

test('a Codex turn gets its length, after its replies', () => {
  const lines = fixture('codex-stream');
  const rows = chatTimeline(timedLog(1, 'list files', lines), 'codex-turn', 'finished');
  assert.equal(rows.at(-1).kind, 'turn');
  assert.equal(turnLabel(rows.at(-1)), `${lines.length}s`);
});

test('OpenCode steps make one line per turn', () => {
  const log = [...timedLog(1, 'look', openCodeTurn(1)), ...timedLog(10, 'again', openCodeTurn(2), start + 60)];
  const rows = chatTimeline(log, 'opencode-turns', 'running');
  assert.deepEqual(rows.map(row => row.kind), ['user', 'prose', 'prose', 'turn', 'user', 'prose', 'prose', 'turn']);
  assert.deepEqual(turns(rows).map(row => row.durationMs), [6000, 6000]);
});

test('stopped and failed turns say how long they ran', () => {
  const stoppedTurn = timedLog(1, 'go', [
    JSON.stringify({ type: 'assistant', message: { content: [{ type: 'text', text: 'Working on it' }] } }),
    JSON.stringify({ type: 'user', message: { content: [{ type: 'text', text: '[Request interrupted by user]' }] } }),
    JSON.stringify({ type: 'result', subtype: 'error_during_execution', is_error: true, duration_ms: 2900, terminal_reason: 'aborted_streaming' }),
  ]);
  const rows = chatTimeline(stoppedTurn, 'claude-stopped', 'idle');
  assert.deepEqual(rows.map(row => row.kind), ['user', 'prose', 'turn']);
  assert.equal(turnLabel(rows.at(-1)), 'Stopped after 3s');
  const failed = chatTimeline(timedLog(1, 'go', [
    JSON.stringify({ type: 'item.completed', item: { id: 'i', type: 'agent_message', text: 'On it.' } }),
    JSON.stringify({ type: 'turn.failed', error: { message: 'boom' } }),
  ]), 'codex-failed', 'errored');
  assert.deepEqual(failed.map(row => row.kind), ['user', 'prose', 'error', 'turn']);
  assert.equal(turnLabel(failed.at(-1)), 'Failed after 2s');
});

test('a turn whose end never reached the log shows once the chat stops working', () => {
  const log = timedLog(1, 'go', [JSON.stringify({ type: 'item.completed', item: { id: 'i', type: 'agent_message', text: 'On it.' } })]);
  assert.equal(turns(chatTimeline(log, 'cut-off', 'running')).length, 0);
  assert.equal(turnLabel(turns(chatTimeline(log, 'cut-off', 'finished'))[0]), '1s');
  assert.equal(turnLabel(turns(chatTimeline(log, 'cut-off', 'errored'))[0]), 'Failed after 1s');
});

test('a log without times keeps Claude\'s own count and shows nothing it can\'t know', () => {
  const untimed = (name, message) => [line(1, 'user', message), ...fixture(name).map((text, index) => line(index + 2, 'stdout', text))];
  assert.equal(turns(chatTimeline(untimed('claude-stream', 'make hi.txt'), 'untimed-claude', 'idle'))[0].durationMs, 4762);
  assert.equal(turnLabel(turns(chatTimeline(untimed('codex-stream', 'list files'), 'untimed-codex', 'finished'))[0]), '—');
});

test('the newest line of an idle chat adds its turns up, without the time between them', () => {
  const lines = fixture('codex-stream');
  const log = [...timedLog(1, 'one', lines), ...timedLog(20, 'two', lines, start + 3600)];
  assert.equal(turns(chatTimeline(log, 'total-running', 'running')).at(-1).totalMs, undefined);
  const rows = turns(chatTimeline(log, 'total-idle', 'finished'));
  assert.equal(rows[0].totalMs, undefined);
  assert.equal(turnLabel(rows[1]), `${lines.length}s · ${2 * lines.length}s in total`);
});

test('turns read the same live as replayed', () => {
  const log = [...timedLog(1, 'look', openCodeTurn(1)), ...timedLog(10, 'again', openCodeTurn(2), start + 60)];
  for (let count = 1; count <= log.length; count++) chatTimeline(log.slice(0, count), 'opencode-live', 'running');
  assert.deepEqual(chatTimeline(log, 'opencode-live', 'running'), chatTimeline(log, 'opencode-replayed', 'running'));
});
