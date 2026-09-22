import { useEffect, useMemo, useRef, useState } from 'react';
import Markdown from 'react-markdown';
import remarkGfm from 'remark-gfm';
import { useApp, type TimelineEntry } from '../../store/app';
import type { AgentEvent, EditPreview } from '../../providers/types';
import { Button, formatDuration, formatTokens } from '../../app/ui';

/**
 * The reason this app exists: agent output as a readable document, not a
 * scrolling terminal. Prose is rendered markdown, tool calls collapse to one
 * line, edits show an inline mini-diff, and permission requests are the only
 * thing allowed to shout.
 */
export function Timeline({ sessionId }: { sessionId: string }) {
  const entries = useApp((s) => s.timelines[sessionId] ?? []);
  const permissions = useApp((s) => s.permissions[sessionId] ?? []);
  const answerPermission = useApp((s) => s.answerPermission);
  const scroller = useRef<HTMLDivElement>(null);
  const [follow, setFollow] = useState(true);

  useEffect(() => {
    if (!follow) return;
    const el = scroller.current;
    if (el) el.scrollTop = el.scrollHeight;
  }, [entries.length, follow]);

  function onScroll() {
    const el = scroller.current;
    if (!el) return;
    const atBottom = el.scrollHeight - el.scrollTop - el.clientHeight < 40;
    setFollow(atBottom);
  }

  const groups = useMemo(() => groupEntries(entries), [entries]);

  return (
    <div className="relative flex min-h-0 flex-1 flex-col">
      <div ref={scroller} onScroll={onScroll} className="min-h-0 flex-1 overflow-y-auto px-5 py-4">
        {groups.length === 0 ? (
          <p className="text-xs" style={{ color: 'var(--bt-text-faint)' }}>
            Waiting for the agent's first output.
          </p>
        ) : (
          <div className="flex flex-col gap-3">
            {groups.map((g) => (
              <GroupRow key={g.key} group={g} />
            ))}
          </div>
        )}

        {permissions.map((p) => (
          <PermissionCard
            key={p.requestId}
            toolName={p.toolName}
            input={p.input}
            onAllow={() => void answerPermission(sessionId, p.requestId, true)}
            onDeny={() => void answerPermission(sessionId, p.requestId, false)}
          />
        ))}
      </div>

      {!follow ? (
        <button
          onClick={() => {
            setFollow(true);
            const el = scroller.current;
            if (el) el.scrollTop = el.scrollHeight;
          }}
          className="absolute bottom-3 left-1/2 -translate-x-1/2 px-3 py-1 text-xs"
          style={{
            background: 'var(--bt-surface-3)',
            border: '1px solid var(--bt-border-strong)',
            color: 'var(--bt-text-dim)',
          }}
        >
          Jump to latest
        </button>
      ) : null}
    </div>
  );
}

// ---------- grouping ----------

type Group =
  | { key: string; kind: 'entry'; entry: TimelineEntry }
  | { key: string; kind: 'tools'; entries: TimelineEntry[] };

/** Consecutive tool activity folds into one expandable group. */
function groupEntries(entries: TimelineEntry[]): Group[] {
  const out: Group[] = [];
  let bucket: TimelineEntry[] = [];
  const flush = () => {
    if (bucket.length === 0) return;
    out.push({ key: `tools-${bucket[0].id}`, kind: 'tools', entries: bucket });
    bucket = [];
  };
  for (const e of entries) {
    if (e.event.type === 'tool_use' || e.event.type === 'tool_result') {
      bucket.push(e);
      continue;
    }
    flush();
    out.push({ key: e.id, kind: 'entry', entry: e });
  }
  flush();
  return out;
}

function GroupRow({ group }: { group: Group }) {
  if (group.kind === 'entry') return <EntryRow entry={group.entry} />;
  return <ToolGroup entries={group.entries} />;
}

// ---------- individual events ----------

function EntryRow({ entry }: { entry: TimelineEntry }) {
  const e = entry.event;
  switch (e.type) {
    case 'text':
      return e.role === 'user' ? <UserMessage text={e.text} /> : <AssistantText text={e.text} />;
    case 'thinking':
      return <Thinking text={e.text} />;
    case 'system':
      return <SystemLine event={e} />;
    case 'turn_end':
      return <TurnRule event={e} />;
    case 'usage':
      return null;
    case 'status':
      return null;
    case 'error':
      return <ErrorCard message={e.message} />;
    case 'raw':
      return <RawLine line={e.line} stream={e.stream} />;
    default:
      return null;
  }
}

function AssistantText({ text }: { text: string }) {
  if (!text.trim()) return null;
  return (
    <div className="bt-prose">
      <Markdown remarkPlugins={[remarkGfm]}>{text}</Markdown>
    </div>
  );
}

function UserMessage({ text }: { text: string }) {
  return (
    <div className="flex justify-end">
      <div
        className="max-w-[70ch] px-3 py-2 text-sm whitespace-pre-wrap"
        style={{ background: 'var(--bt-surface-2)', border: '1px solid var(--bt-border)' }}
      >
        {text}
      </div>
    </div>
  );
}

function Thinking({ text }: { text: string }) {
  const [open, setOpen] = useState(false);
  if (!text.trim()) return null;
  return (
    <div>
      <button
        onClick={() => setOpen(!open)}
        className="text-xs italic"
        style={{ color: 'var(--bt-text-faint)' }}
      >
        {open ? 'Hide thinking' : 'Thinking…'}
      </button>
      {open ? (
        <div
          className="mt-1 px-3 py-2 text-xs whitespace-pre-wrap"
          style={{ background: 'var(--bt-surface)', color: 'var(--bt-text-dim)' }}
        >
          {text}
        </div>
      ) : null}
    </div>
  );
}

function SystemLine({ event }: { event: Extract<AgentEvent, { type: 'system' }> }) {
  const bits = [event.model, event.permissionMode, event.cwd].filter(Boolean);
  if (bits.length === 0) return null;
  return (
    <div className="flex items-center gap-2 text-xs" style={{ color: 'var(--bt-text-faint)' }}>
      <span className="font-mono">{bits.join(' · ')}</span>
      {event.sessionId ? (
        <button
          title="Copy the agent's session id"
          onClick={() => void navigator.clipboard.writeText(event.sessionId ?? '')}
          style={{ color: 'var(--bt-text-faint)' }}
        >
          copy id
        </button>
      ) : null}
    </div>
  );
}

function TurnRule({ event }: { event: Extract<AgentEvent, { type: 'turn_end' }> }) {
  const parts: string[] = [];
  if (event.durationMs) parts.push(formatDuration(event.durationMs));
  if (event.usage) {
    parts.push(`${formatTokens(event.usage.inputTokens)} in`);
    parts.push(`${formatTokens(event.usage.outputTokens)} out`);
  }
  if (typeof event.costUsd === 'number' && event.costUsd > 0) {
    parts.push(`$${event.costUsd.toFixed(4)}`);
  }
  return (
    <div className="my-1 flex items-center gap-3">
      <div className="h-px flex-1" style={{ background: 'var(--bt-border)' }} />
      <span className="text-xs" style={{ color: 'var(--bt-text-faint)' }}>
        {event.summary ? `${event.summary} · ` : ''}
        {parts.join(' · ')}
      </span>
      <div className="h-px flex-1" style={{ background: 'var(--bt-border)' }} />
    </div>
  );
}

function ErrorCard({ message }: { message: string }) {
  return (
    <div
      className="px-3 py-2 text-sm"
      style={{ background: 'var(--bt-surface-2)', borderLeft: '2px solid var(--bt-removed)' }}
    >
      <span style={{ color: 'var(--bt-removed)' }}>{message}</span>
    </div>
  );
}

function RawLine({ line, stream }: { line: string; stream: string }) {
  return (
    <pre
      className="overflow-x-auto px-3 py-1 font-mono text-xs"
      style={{
        background: 'var(--bt-surface)',
        color: stream === 'stderr' ? 'var(--bt-warn)' : 'var(--bt-text-faint)',
      }}
    >
      {line}
    </pre>
  );
}

// ---------- tools ----------

function ToolGroup({ entries }: { entries: TimelineEntry[] }) {
  const calls = entries.filter((e) => e.event.type === 'tool_use');
  const [expanded, setExpanded] = useState(calls.length <= 3);

  const results = new Map<string, Extract<AgentEvent, { type: 'tool_result' }>>();
  for (const e of entries) {
    if (e.event.type === 'tool_result') results.set(e.event.toolUseId, e.event);
  }

  if (!expanded) {
    return (
      <button
        onClick={() => setExpanded(true)}
        className="self-start px-2 py-1 text-xs"
        style={{ background: 'var(--bt-surface)', color: 'var(--bt-text-dim)' }}
      >
        {calls.length} tool calls
      </button>
    );
  }

  return (
    <div className="flex flex-col">
      {calls.map((e) => {
        const call = e.event as Extract<AgentEvent, { type: 'tool_use' }>;
        return <ToolRow key={e.id} call={call} result={results.get(call.id)} />;
      })}
      {calls.length > 3 ? (
        <button
          onClick={() => setExpanded(false)}
          className="mt-1 self-start text-xs"
          style={{ color: 'var(--bt-text-faint)' }}
        >
          collapse
        </button>
      ) : null}
    </div>
  );
}

function ToolRow({
  call,
  result,
}: {
  call: Extract<AgentEvent, { type: 'tool_use' }>;
  result?: Extract<AgentEvent, { type: 'tool_result' }>;
}) {
  const [open, setOpen] = useState(false);
  const edit = call.edit ?? result?.edit;
  const target = describeTarget(call.name, call.input);
  const failed = result?.isError;

  return (
    <div className="border-l pl-3" style={{ borderColor: 'var(--bt-border)' }}>
      <button
        onClick={() => setOpen(!open)}
        className="flex w-full items-center gap-2 py-0.5 text-left text-xs"
        style={{ color: failed ? 'var(--bt-removed)' : 'var(--bt-text-dim)' }}
      >
        <span style={{ color: 'var(--bt-text)' }}>{call.name}</span>
        {target ? <span className="truncate font-mono">{target}</span> : null}
        {edit ? (
          <span className="shrink-0 font-mono">
            <span style={{ color: 'var(--bt-added)' }}>+{edit.additions}</span>{' '}
            <span style={{ color: 'var(--bt-removed)' }}>−{edit.deletions}</span>
          </span>
        ) : null}
        {failed ? <span>failed</span> : null}
        {!result ? <span style={{ color: 'var(--bt-text-faint)' }}>…</span> : null}
      </button>

      {open ? (
        <div className="mb-1 flex flex-col gap-1">
          <pre
            className="overflow-x-auto px-2 py-1 font-mono text-xs"
            style={{ background: 'var(--bt-surface-2)', color: 'var(--bt-text-dim)' }}
          >
            {JSON.stringify(call.input, null, 2)}
          </pre>
          {edit ? <MiniDiff edit={edit} /> : null}
          {result ? <ToolOutput text={result.output} isError={result.isError} /> : null}
        </div>
      ) : edit ? (
        <MiniDiff edit={edit} />
      ) : null}
    </div>
  );
}

function ToolOutput({ text, isError }: { text: string; isError?: boolean }) {
  const lines = text.split('\n');
  const [expanded, setExpanded] = useState(lines.length <= 20);
  const shown = expanded ? lines : lines.slice(0, 20);
  return (
    <div>
      <pre
        className="overflow-x-auto px-2 py-1 font-mono text-xs whitespace-pre-wrap"
        style={{
          background: 'var(--bt-surface-2)',
          color: isError ? 'var(--bt-removed)' : 'var(--bt-text-dim)',
        }}
      >
        {shown.join('\n')}
      </pre>
      {lines.length > 20 ? (
        <button
          onClick={() => setExpanded(!expanded)}
          className="text-xs"
          style={{ color: 'var(--bt-text-faint)' }}
        >
          {expanded ? 'show less' : `show ${lines.length - 20} more lines`}
        </button>
      ) : null}
    </div>
  );
}

function MiniDiff({ edit }: { edit: EditPreview }) {
  const lines = edit.lines.slice(0, 40);
  if (lines.length === 0) return null;
  return (
    <div
      className="overflow-x-auto font-mono text-xs"
      style={{ background: 'var(--bt-surface-2)', border: '1px solid var(--bt-border)' }}
    >
      {lines.map((l, i) => (
        <div
          key={i}
          className="px-2 whitespace-pre"
          style={{
            color:
              l.origin === '+'
                ? 'var(--bt-added)'
                : l.origin === '-'
                  ? 'var(--bt-removed)'
                  : 'var(--bt-text-faint)',
            background:
              l.origin === '+'
                ? 'color-mix(in srgb, var(--bt-added) 8%, transparent)'
                : l.origin === '-'
                  ? 'color-mix(in srgb, var(--bt-removed) 8%, transparent)'
                  : 'transparent',
          }}
        >
          {l.origin}
          {l.content}
        </div>
      ))}
      {edit.lines.length > lines.length ? (
        <div className="px-2 py-0.5" style={{ color: 'var(--bt-text-faint)' }}>
          … {edit.lines.length - lines.length} more lines
        </div>
      ) : null}
    </div>
  );
}

function PermissionCard({
  toolName,
  input,
  onAllow,
  onDeny,
}: {
  toolName: string;
  input: unknown;
  onAllow: () => void;
  onDeny: () => void;
}) {
  return (
    <div
      className="mt-3 px-4 py-3"
      style={{ background: 'var(--bt-surface-2)', border: '1px solid var(--bt-accent)' }}
    >
      <p className="text-sm">
        <span style={{ color: 'var(--bt-accent)' }}>Permission needed</span> — the agent wants to run{' '}
        <span className="font-mono">{toolName}</span>.
      </p>
      <pre
        className="my-2 max-h-48 overflow-auto px-2 py-1 font-mono text-xs"
        style={{ background: 'var(--bt-surface-3)', color: 'var(--bt-text-dim)' }}
      >
        {JSON.stringify(input, null, 2)}
      </pre>
      <div className="flex gap-2">
        <Button variant="accent" onClick={onAllow}>
          Allow
        </Button>
        <Button onClick={onDeny}>Deny</Button>
      </div>
    </div>
  );
}

function describeTarget(name: string, input: unknown): string {
  if (!input || typeof input !== 'object') return '';
  const o = input as Record<string, unknown>;
  const candidates = ['file_path', 'path', 'notebook_path', 'command', 'pattern', 'url', 'query'];
  for (const key of candidates) {
    const v = o[key];
    if (typeof v === 'string' && v) {
      const short = key === 'command' ? v : v.split('/').slice(-2).join('/');
      return short.length > 90 ? `${short.slice(0, 90)}…` : short;
    }
  }
  return name === 'Task' && typeof o.description === 'string' ? o.description : '';
}
