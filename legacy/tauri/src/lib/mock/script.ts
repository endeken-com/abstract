/**
 * Synthetic claude stream-json lines, shaped exactly like the recorded
 * fixture, so the real parser and store run unmodified in the browser mock.
 */

const sid = (n: number) => `mock-${n.toString(16).padStart(8, '0')}-7c1e-4a8b-9f00-3b2e1d0c9a${n % 10}${n % 7}`;

function j(o: unknown): string {
  return JSON.stringify(o);
}

export interface ScriptStep {
  delay: number;
  line: string;
}

let msgCounter = 0;

function streamText(text: string, sessionId: string, index = 0): ScriptStep[] {
  const id = `msg_mock_${++msgCounter}`;
  const steps: ScriptStep[] = [
    { delay: 180, line: j({ type: 'stream_event', session_id: sessionId, event: { type: 'message_start', message: { id, role: 'assistant' } } }) },
    { delay: 40, line: j({ type: 'stream_event', session_id: sessionId, event: { type: 'content_block_start', index, content_block: { type: 'text', text: '' } } }) },
  ];
  const words = text.split(/(?<=\s)/);
  for (let i = 0; i < words.length; i += 3) {
    steps.push({
      delay: 45,
      line: j({ type: 'stream_event', session_id: sessionId, event: { type: 'content_block_delta', index, delta: { type: 'text_delta', text: words.slice(i, i + 3).join('') } } }),
    });
  }
  steps.push({ delay: 30, line: j({ type: 'assistant', session_id: sessionId, message: { id, role: 'assistant', content: [{ type: 'text', text }] } }) });
  steps.push({ delay: 10, line: j({ type: 'stream_event', session_id: sessionId, event: { type: 'content_block_stop', index } }) });
  return steps;
}

function toolCall(
  sessionId: string,
  name: string,
  input: Record<string, unknown>,
  output: string,
  toolUseResult?: Record<string, unknown>,
): ScriptStep[] {
  const id = `toolu_mock_${++msgCounter}`;
  const msgId = `msg_mock_${++msgCounter}`;
  return [
    { delay: 260, line: j({ type: 'assistant', session_id: sessionId, message: { id: msgId, role: 'assistant', content: [{ type: 'tool_use', id, name, input }] } }) },
    {
      delay: 420,
      line: j({
        type: 'user',
        session_id: sessionId,
        message: { role: 'user', content: [{ tool_use_id: id, type: 'tool_result', content: output }] },
        ...(toolUseResult ? { tool_use_result: toolUseResult } : {}),
      }),
    },
  ];
}

export function claudeScript(opts: {
  n: number;
  cwd: string;
  prompt: string;
  permission: boolean;
}): { steps: ScriptStep[]; permissionAt: number | null; sessionId: string } {
  const sessionId = sid(opts.n);
  const steps: ScriptStep[] = [
    {
      delay: 350,
      line: j({ type: 'system', subtype: 'init', session_id: sessionId, cwd: opts.cwd, model: 'claude-opus-5', permissionMode: opts.permission ? 'default' : 'acceptEdits', tools: ['Read', 'Edit', 'Write', 'Bash'] }),
    },
    ...streamText(
      `I'll start by looking at how the session list is rendered, then make the change you asked for:\n\n> ${opts.prompt.split('\n')[0]}\n\nFirst, a quick read of the relevant files.`,
      sessionId,
    ),
    ...toolCall(sessionId, 'Read', { file_path: `${opts.cwd}/src/features/sessions/SessionList.tsx` }, '120 lines'),
    ...toolCall(sessionId, 'Bash', { command: 'rg -n "status" src/features/sessions --type ts' }, 'src/features/sessions/SessionList.tsx:42:  const status = session.status;\nsrc/features/sessions/SessionList.tsx:88:      <StatusDot status={status} />\nsrc/features/sessions/useSessions.ts:17:  status: SessionStatus;'),
  ];

  let permissionAt: number | null = null;
  if (opts.permission) {
    permissionAt = steps.length;
    steps.push({
      delay: 300,
      line: j({
        type: 'control_request',
        request_id: `req_mock_${opts.n}`,
        request: { subtype: 'can_use_tool', tool_name: 'Edit', input: { file_path: `${opts.cwd}/src/features/sessions/SessionList.tsx`, old_string: 'const status = session.status;', new_string: 'const status = deriveStatus(session);' } },
      }),
    });
  }

  steps.push(
    ...toolCall(
      sessionId,
      'Edit',
      { file_path: `${opts.cwd}/src/features/sessions/SessionList.tsx`, old_string: 'const status = session.status;', new_string: 'const status = deriveStatus(session);' },
      'The file has been updated.',
      {
        type: 'update',
        filePath: `${opts.cwd}/src/features/sessions/SessionList.tsx`,
        structuredPatch: [
          { oldStart: 40, oldLines: 5, newStart: 40, newLines: 7, lines: ['   export function SessionRow({ session }: Props) {', '-  const status = session.status;', '+  const status = deriveStatus(session);', '+  const isLive = status === "running";', '   return (', '-    <Row>', '+    <Row data-live={isLive}>'] },
        ],
      },
    ),
    ...streamText(
      `Done. The row now derives its status instead of reading the raw field, so a session whose process died shows **Error** rather than a stale **Running**.\n\n- \`deriveStatus\` checks \`alive\` before trusting \`status\`\n- live rows get a \`data-live\` attribute for the pulse animation\n\nRun \`bun test\` to confirm nothing else depends on the old field.`,
      sessionId,
    ),
    { delay: 120, line: j({ type: 'system', subtype: 'post_turn_summary', session_id: sessionId, status_category: 'completed', status_detail: 'Session rows derive status', needs_action: '' }) },
    {
      delay: 60,
      line: j({ type: 'result', subtype: 'success', session_id: sessionId, is_error: false, duration_ms: 18_400, num_turns: 4, result: 'Done.', total_cost_usd: 0.1842, usage: { input_tokens: 6, output_tokens: 612, cache_read_input_tokens: 48_210, cache_creation_input_tokens: 9_870 } }),
    },
  );
  return { steps, permissionAt, sessionId };
}

export function followUpScript(sessionId: string, text: string): ScriptStep[] {
  return [
    ...streamText(`Sure — ${text.charAt(0).toLowerCase()}${text.slice(1)}\n\nI checked the call sites and nothing else reads the old field, so no further changes are needed.`, sessionId),
    { delay: 60, line: j({ type: 'result', subtype: 'success', session_id: sessionId, is_error: false, duration_ms: 4_100, num_turns: 1, result: 'ok', total_cost_usd: 0.021, usage: { input_tokens: 2, output_tokens: 88, cache_read_input_tokens: 52_000, cache_creation_input_tokens: 400 } }) },
  ];
}
