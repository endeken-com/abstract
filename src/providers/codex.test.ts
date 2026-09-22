import { describe, expect, it } from 'vitest';
import fixture from './__fixtures__/codex-stream.jsonl?raw';
import { codexProvider } from './codex';
import type { AgentEvent, LaunchContext } from './types';

function runFixture(): AgentEvent[] {
  const parser = codexProvider.createParser();
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

describe('codexProvider.buildLaunch', () => {
  it('passes the prompt as the final positional arg', () => {
    const spec = codexProvider.buildLaunch(ctx);
    expect(spec.command).toBe('codex');
    expect(spec.args).toEqual([
      'exec',
      '--json',
      '-C',
      '/tmp/work',
      '--skip-git-repo-check',
      '-s',
      'workspace-write',
      'make hi.txt',
    ]);
    expect(spec.keepStdinOpen).toBe(false);
    expect(spec.stdinInitial).toBeUndefined();
    expect(codexProvider.followUpMode).toBe('respawn');
  });

  it('maps sandbox policies', () => {
    expect(codexProvider.buildLaunch({ ...ctx, permissionPolicy: 'ask' }).args).toContain(
      'workspace-write',
    );
    expect(codexProvider.buildLaunch({ ...ctx, permissionPolicy: 'bypass' }).args).toContain(
      'danger-full-access',
    );
  });

  it('builds a resume invocation', () => {
    const spec = codexProvider.buildResume({ ...ctx, resumeId: 'thread-1' });
    expect(spec.args.slice(0, 3)).toEqual(['exec', 'resume', 'thread-1']);
    expect(spec.args[spec.args.length - 1]).toBe('make hi.txt');
  });
});

describe('codexProvider parser against the recorded fixture', () => {
  const events = runFixture();

  it('emits the thread id as the session id', () => {
    expect(events[0]).toEqual({
      type: 'session_id',
      id: '01a0cad4-f355-7380-b8cd-3b7b34fac1a4',
    });
  });

  it('marks the turn as running', () => {
    expect(events).toContainEqual({ type: 'status', status: 'running' });
  });

  it('captures agent_message text', () => {
    const texts = events.filter(
      (e): e is Extract<AgentEvent, { type: 'text' }> => e.type === 'text',
    );
    expect(texts).toHaveLength(2);
    expect(texts[0].text).toContain('create `hi.txt`');
    expect(texts[0].partial).toBe(false);
    expect(texts[1].text).toBe('Created `hi.txt` containing `hi`.');
    expect(texts[1].blockId).toBe('item_2');
  });

  it('turns a command_execution into a Bash tool_use plus tool_result', () => {
    const toolUse = events.find((e) => e.type === 'tool_use');
    if (toolUse?.type !== 'tool_use') throw new Error('expected tool_use event');
    expect(toolUse.name).toBe('Bash');
    expect(toolUse.id).toBe('item_1');
    expect(toolUse.input).toEqual({
      command: '/bin/zsh -lc "printf \'hi\\\\n\' > hi.txt"',
    });

    const toolUses = events.filter((e) => e.type === 'tool_use');
    expect(toolUses).toHaveLength(1);

    const result = events.find((e) => e.type === 'tool_result');
    if (result?.type !== 'tool_result') throw new Error('expected tool_result event');
    expect(result.toolUseId).toBe('item_1');
    expect(result.isError).toBe(false);
  });

  it('emits usage and a finished status on turn.completed', () => {
    const usage = events.find((e) => e.type === 'usage');
    if (usage?.type !== 'usage') throw new Error('expected usage event');
    expect(usage.usage).toEqual({
      inputTokens: 34277,
      outputTokens: 66,
      cacheRead: 29056,
      cacheWrite: 0,
    });
    expect(events[events.length - 1]).toEqual({ type: 'status', status: 'finished' });
  });

  it('understands every line in the fixture (no raw events)', () => {
    expect(events.filter((e) => e.type === 'raw')).toHaveLength(0);
  });
});

describe('codexProvider parser robustness', () => {
  it('produces exactly one raw event for a malformed line and does not throw', () => {
    const parser = codexProvider.createParser();
    const events = parser.feed('{not json', 'stdout');
    expect(events).toEqual([{ type: 'raw', line: '{not json', stream: 'stdout' }]);
  });

  it('falls back to raw for unknown event types', () => {
    const parser = codexProvider.createParser();
    expect(parser.feed('{"type":"something.new"}', 'stdout')).toEqual([
      { type: 'raw', line: '{"type":"something.new"}', stream: 'stdout' },
    ]);
  });

  it('errors on turn.failed', () => {
    const parser = codexProvider.createParser();
    const events = parser.feed('{"type":"turn.failed","error":{"message":"nope"}}', 'stdout');
    expect(events).toEqual([
      { type: 'error', message: 'nope' },
      { type: 'status', status: 'errored' },
    ]);
  });

  it('reports exit status', () => {
    expect(codexProvider.createParser().onExit(0)).toEqual([
      { type: 'status', status: 'finished' },
    ]);
  });
});
