import { describe, expect, it } from 'vitest';
import fixture from './__fixtures__/claude-stream.jsonl?raw';
import { claudeProvider } from './claude';
import type { AgentEvent, LaunchContext } from './types';

function runFixture(): AgentEvent[] {
  const parser = claudeProvider.createParser();
  const events: AgentEvent[] = [];
  for (const line of fixture.split('\n')) {
    if (line.trim() === '') continue;
    events.push(...parser.feed(line, 'stdout'));
  }
  return events;
}

const ctx: LaunchContext = {
  cwd: '/tmp/work',
  prompt: 'make hi.txt',
  permissionPolicy: 'auto-edits',
};

describe('claudeProvider.buildLaunch', () => {
  it('never puts the prompt in argv and sends it on stdin instead', () => {
    const spec = claudeProvider.buildLaunch(ctx);
    expect(spec.command).toBe('claude');
    expect(spec.args).not.toContain('make hi.txt');
    expect(spec.args).toEqual([
      '-p',
      '--output-format',
      'stream-json',
      '--input-format',
      'stream-json',
      '--verbose',
      '--include-partial-messages',
      '--permission-mode',
      'acceptEdits',
    ]);
    expect(spec.keepStdinOpen).toBe(true);
    expect(spec.stdinInitial).toBe(
      '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"make hi.txt"}]}}\n',
    );
  });

  it('maps every permission policy', () => {
    expect(claudeProvider.buildLaunch({ ...ctx, permissionPolicy: 'ask' }).args).toContain(
      '--permission-prompts',
    );
    expect(claudeProvider.buildLaunch({ ...ctx, permissionPolicy: 'bypass' }).args).toContain(
      'bypassPermissions',
    );
  });

  it('appends extraArgs', () => {
    const spec = claudeProvider.buildLaunch({ ...ctx, extraArgs: ['--model', 'opus'] });
    expect(spec.args.slice(-2)).toEqual(['--model', 'opus']);
  });

  it('adds --resume on buildResume', () => {
    const spec = claudeProvider.buildResume({ ...ctx, resumeId: 'sess-1' });
    expect(spec.args).toContain('--resume');
    expect(spec.args[spec.args.indexOf('--resume') + 1]).toBe('sess-1');
  });
});

describe('claudeProvider.buildPermissionResponse', () => {
  it('emits allow and deny control_response lines', () => {
    const allow = claudeProvider.buildPermissionResponse?.('req-1', true, { a: 1 });
    expect(allow).toBe(
      '{"type":"control_response","response":{"subtype":"success","request_id":"req-1","response":{"behavior":"allow","updatedInput":{"a":1}}}}\n',
    );
    const deny = claudeProvider.buildPermissionResponse?.('req-1', false);
    expect(deny).toBe(
      '{"type":"control_response","response":{"subtype":"success","request_id":"req-1","response":{"behavior":"deny","message":"Denied by user"}}}\n',
    );
  });
});

describe('claudeProvider parser against the recorded fixture', () => {
  const events = runFixture();

  it('emits the session id', () => {
    expect(events).toContainEqual({
      type: 'session_id',
      id: '481e8596-8328-48b5-91e9-ff1d9c7b9681',
    });
  });

  it('emits a system event with the model and permission mode', () => {
    const system = events.find((e) => e.type === 'system');
    expect(system).toBeDefined();
    if (system?.type !== 'system') throw new Error('expected system event');
    expect(system.model).toBe('claude-opus-5[1m]');
    expect(system.permissionMode).toBe('acceptEdits');
  });

  it('emits a complete Write tool_use', () => {
    const toolUse = events.find((e) => e.type === 'tool_use');
    if (toolUse?.type !== 'tool_use') throw new Error('expected tool_use event');
    expect(toolUse.name).toBe('Write');
    expect(toolUse.id).toBe('toolu_01PDRtLov18XvHuvMmw7buyu');
    const input = toolUse.input as Record<string, unknown>;
    expect(typeof input.file_path).toBe('string');
    expect(String(input.file_path)).toMatch(/hi\.txt$/);
  });

  it('emits a tool_result for that tool_use, with a create EditPreview', () => {
    const toolUse = events.find((e) => e.type === 'tool_use');
    if (toolUse?.type !== 'tool_use') throw new Error('expected tool_use event');
    const result = events.find((e) => e.type === 'tool_result');
    if (result?.type !== 'tool_result') throw new Error('expected tool_result event');
    expect(result.toolUseId).toBe(toolUse.id);
    expect(result.isError).toBe(false);
    expect(result.output).toContain('File created successfully');
    expect(result.edit).toBeDefined();
    expect(result.edit?.filePath).toMatch(/hi\.txt$/);
    expect(result.edit?.additions).toBe(1);
    expect(result.edit?.deletions).toBe(0);
    expect(result.edit?.lines).toEqual([{ origin: '+', content: 'hi' }]);
  });

  it('streams partial assistant text with a stable blockId, then the final text', () => {
    const texts = events.filter(
      (e): e is Extract<AgentEvent, { type: 'text' }> => e.type === 'text',
    );
    const partials = texts.filter((t) => t.partial === true);
    expect(partials.length).toBeGreaterThan(0);
    expect(new Set(partials.map((t) => t.blockId)).size).toBe(1);
    expect(partials.map((t) => t.text).join('')).toBe('hi.txt made.');

    const final = texts.filter((t) => t.partial === false);
    expect(final.map((t) => t.text)).toEqual(['hi.txt made.']);
    expect(final[0].blockId).toBe(partials[0].blockId);
  });

  it('emits a post_turn_summary turn_end', () => {
    const turnEnd = events.find((e) => e.type === 'turn_end');
    if (turnEnd?.type !== 'turn_end') throw new Error('expected turn_end event');
    expect(turnEnd.summary).toBe('hi.txt created');
  });

  it('emits usage matching the result line', () => {
    const usage = events.find((e) => e.type === 'usage');
    if (usage?.type !== 'usage') throw new Error('expected usage event');
    expect(usage.costUsd).toBeCloseTo(0.2080365, 7);
    expect(usage.usage.inputTokens).toBe(4);
    expect(usage.usage.outputTokens).toBe(154);
    expect(usage.usage.cacheRead).toBe(52173);
    expect(usage.usage.cacheWrite).toBe(17808);
    expect(usage.durationMs).toBe(4762);
    expect(usage.turns).toBe(2);
  });

  it('parks the session as idle after a successful result', () => {
    const last = events[events.length - 1];
    expect(last).toEqual({ type: 'status', status: 'idle' });
  });

  it('understands every line in the fixture (no raw events)', () => {
    const raws = events.filter((e) => e.type === 'raw');
    expect(raws).toHaveLength(0);
  });
});

describe('claudeProvider parser robustness', () => {
  it('produces exactly one raw event for a malformed line and does not throw', () => {
    const parser = claudeProvider.createParser();
    const events = parser.feed('{not json', 'stdout');
    expect(events).toEqual([{ type: 'raw', line: '{not json', stream: 'stdout' }]);
  });

  it('maps stderr lines to raw', () => {
    const parser = claudeProvider.createParser();
    expect(parser.feed('boom', 'stderr')).toEqual([
      { type: 'raw', line: 'boom', stream: 'stderr' },
    ]);
  });

  it('reports exit status', () => {
    expect(claudeProvider.createParser().onExit(0)).toEqual([
      { type: 'status', status: 'finished' },
    ]);
    const failed = claudeProvider.createParser().onExit(1);
    expect(failed[0].type).toBe('error');
    expect(failed[1]).toEqual({ type: 'status', status: 'errored' });
  });
});
