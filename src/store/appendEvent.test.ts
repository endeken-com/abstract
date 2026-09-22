import { describe, expect, it } from 'vitest';
import { appendEvent, type TimelineEntry } from './app';
import type { AgentEvent } from '../providers/types';

function build(events: AgentEvent[]): TimelineEntry[] {
  return events.reduce<TimelineEntry[]>((acc, e) => appendEvent(acc, e), []);
}

describe('timeline assembly', () => {
  it('concatenates streaming chunks that share a block id', () => {
    const entries = build([
      { type: 'text', role: 'assistant', text: 'Hello', blockId: 'msg_1:0', partial: true },
      { type: 'text', role: 'assistant', text: ' there', blockId: 'msg_1:0', partial: true },
      { type: 'text', role: 'assistant', text: ', world', blockId: 'msg_1:0', partial: true },
    ]);
    expect(entries).toHaveLength(1);
    expect(entries[0].event).toMatchObject({ type: 'text', text: 'Hello there, world' });
  });

  it('replaces the streamed text with the final block rather than doubling it', () => {
    const entries = build([
      { type: 'text', role: 'assistant', text: 'par', blockId: 'msg_1:0', partial: true },
      { type: 'text', role: 'assistant', text: 'tial', blockId: 'msg_1:0', partial: true },
      { type: 'text', role: 'assistant', text: 'partial', blockId: 'msg_1:0', partial: false },
    ]);
    expect(entries).toHaveLength(1);
    const event = entries[0].event as Extract<AgentEvent, { type: 'text' }>;
    expect(event.text).toBe('partial');
    expect(event.partial).toBe(false);
  });

  it('keeps separate blocks and separate kinds apart', () => {
    const entries = build([
      { type: 'text', role: 'assistant', text: 'A', blockId: 'msg_1:0', partial: true },
      { type: 'thinking', text: 'hmm', blockId: 'msg_1:0', partial: true },
      { type: 'text', role: 'assistant', text: 'B', blockId: 'msg_1:1', partial: true },
    ]);
    expect(entries).toHaveLength(3);
  });

  it('appends events that carry no block id', () => {
    const entries = build([
      { type: 'tool_use', id: 't1', name: 'Write', input: { file_path: 'a.txt' } },
      { type: 'tool_result', toolUseId: 't1', output: 'done' },
      { type: 'raw', line: 'noise', stream: 'stderr' },
    ]);
    expect(entries.map((e) => e.event.type)).toEqual(['tool_use', 'tool_result', 'raw']);
  });

  it('gives every entry a distinct id so React keys stay stable', () => {
    const entries = build([
      { type: 'raw', line: 'a', stream: 'stdout' },
      { type: 'raw', line: 'a', stream: 'stdout' },
      { type: 'raw', line: 'a', stream: 'stdout' },
    ]);
    expect(new Set(entries.map((e) => e.id)).size).toBe(3);
  });
});
