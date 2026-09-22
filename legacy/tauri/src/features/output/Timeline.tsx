import { memo, useEffect, useMemo, useRef, useState, type ReactNode } from 'react';
import { AnimatePresence, motion } from 'motion/react';
import Markdown from 'react-markdown';
import remarkGfm from 'remark-gfm';
import {
  ArrowDown,
  Bot,
  Brain,
  Check,
  ChevronRight,
  Copy,
  FileCode2,
  FilePlus2,
  FileText,
  Globe,
  ListTodo,
  Pencil,
  Search,
  ShieldAlert,
  Sparkles,
  SquareTerminal,
  TriangleAlert,
  Wrench,
  X,
} from 'lucide-react';
import { EMPTY_PERMISSIONS, EMPTY_TIMELINE, useApp, type TimelineEntry } from '../../store/app';
import type { AgentEvent, EditPreview } from '../../providers/types';
import { Button, Spinner, formatDuration, formatTokens } from '../../ui';

/**
 * Agent output as a readable document rather than a scrolling terminal.
 * Prose is rendered markdown, tool activity collapses into compact cards,
 * edits carry an inline diff, and a permission request is the only thing
 * allowed to raise its voice.
 */
export function Timeline({ sessionId, status, providerName }: { sessionId: string; status: string; providerName: string }) {
  const entries = useApp((s) => s.timelines[sessionId] ?? EMPTY_TIMELINE);
  const permissions = useApp((s) => s.permissions[sessionId] ?? EMPTY_PERMISSIONS);
  const answerPermission = useApp((s) => s.answerPermission);
  const scroller = useRef<HTMLDivElement>(null);
  const [follow, setFollow] = useState(true);

  const blocks = useMemo(() => buildBlocks(entries), [entries]);
  const working = status === 'running' || status === 'provisioning';

  useEffect(() => {
    if (!follow) return;
    const el = scroller.current;
    if (el) el.scrollTo({ top: el.scrollHeight, behavior: entries.length > 3 ? 'smooth' : 'auto' });
  }, [entries, permissions.length, follow]);

  function onScroll() {
    const el = scroller.current;
    if (!el) return;
    setFollow(el.scrollHeight - el.scrollTop - el.clientHeight < 60);
  }

  return (
    <div className="relative flex min-h-0 flex-1 flex-col">
      <div ref={scroller} onScroll={onScroll} className="min-h-0 flex-1 overflow-y-auto">
        <div className="mx-auto flex w-full max-w-[780px] flex-col gap-5 px-8 pt-6 pb-10">
          {blocks.length === 0 && !working ? (
            <p className="py-10 text-center text-[12.5px]" style={{ color: 'var(--bt-text-faint)' }}>
              Nothing here yet.
            </p>
          ) : null}

          {blocks.map((b) => (
            <BlockView key={b.key} block={b} providerName={providerName} />
          ))}

          <AnimatePresence>
            {permissions.map((p) => (
              <PermissionCard
                key={p.requestId}
                providerName={providerName}
                toolName={p.toolName}
                input={p.input}
                onAllow={() => void answerPermission(sessionId, p.requestId, true)}
                onDeny={() => void answerPermission(sessionId, p.requestId, false)}
              />
            ))}
          </AnimatePresence>

          {working && permissions.length === 0 ? <WorkingIndicator entries={entries} /> : null}
        </div>
      </div>

      <AnimatePresence>
        {!follow ? (
          <motion.button
            initial={{ opacity: 0, y: 8 }}
            animate={{ opacity: 1, y: 0 }}
            exit={{ opacity: 0, y: 8 }}
            onClick={() => {
              setFollow(true);
              scroller.current?.scrollTo({ top: scroller.current.scrollHeight, behavior: 'smooth' });
            }}
            className="absolute bottom-4 left-1/2 flex h-8 -translate-x-1/2 items-center gap-1.5 rounded-full px-3 text-[12px] font-medium"
            style={{ background: 'var(--bt-elevated)', color: 'var(--bt-text-dim)', boxShadow: 'var(--bt-shadow-lg)' }}
          >
            <ArrowDown size={13} /> Latest
          </motion.button>
        ) : null}
      </AnimatePresence>
    </div>
  );
}

// ---------------- blocks ----------------

type Block =
  | { key: string; kind: 'user'; text: string }
  | { key: string; kind: 'assistant'; text: string; streaming: boolean; first: boolean }
  | { key: string; kind: 'thinking'; text: string }
  | { key: string; kind: 'tools'; calls: ToolCall[] }
  | { key: string; kind: 'system'; event: Extract<AgentEvent, { type: 'system' }> }
  | { key: string; kind: 'turn'; event: Extract<AgentEvent, { type: 'turn_end' }>; usage?: Extract<AgentEvent, { type: 'usage' }> }
  | { key: string; kind: 'error'; message: string }
  | { key: string; kind: 'raw'; lines: { line: string; stream: string }[] };

interface ToolCall {
  key: string;
  call: Extract<AgentEvent, { type: 'tool_use' }>;
  result?: Extract<AgentEvent, { type: 'tool_result' }>;
}

/** Fold the flat event list into the shapes the reader actually cares about. */
function buildBlocks(entries: readonly TimelineEntry[]): Block[] {
  const out: Block[] = [];
  const results = new Map<string, Extract<AgentEvent, { type: 'tool_result' }>>();
  for (const e of entries) if (e.event.type === 'tool_result') results.set(e.event.toolUseId, e.event);

  let lastWasAssistant = false;
  let pendingTurn: Extract<Block, { kind: 'turn' }> | null = null;

  for (const e of entries) {
    const ev = e.event;
    const prev = out[out.length - 1];
    switch (ev.type) {
      case 'text':
        if (ev.role === 'user') {
          out.push({ key: e.id, kind: 'user', text: ev.text });
          lastWasAssistant = false;
        } else if (ev.text.trim()) {
          out.push({ key: e.id, kind: 'assistant', text: ev.text, streaming: !!ev.partial, first: !lastWasAssistant });
          lastWasAssistant = true;
        }
        break;
      case 'thinking':
        if (ev.text.trim()) out.push({ key: e.id, kind: 'thinking', text: ev.text });
        break;
      case 'tool_use': {
        const call: ToolCall = { key: e.id, call: ev, result: results.get(ev.id) };
        if (prev?.kind === 'tools') prev.calls.push(call);
        else out.push({ key: e.id, kind: 'tools', calls: [call] });
        lastWasAssistant = true;
        break;
      }
      case 'system':
        out.push({ key: e.id, kind: 'system', event: ev });
        break;
      case 'turn_end':
        pendingTurn = { key: e.id, kind: 'turn', event: ev };
        out.push(pendingTurn);
        lastWasAssistant = false;
        break;
      case 'usage':
        // Usage arrives right after the turn summary; attach it to that rule.
        if (pendingTurn && !pendingTurn.usage) pendingTurn.usage = ev;
        else out.push({ key: e.id, kind: 'turn', event: { type: 'turn_end', durationMs: ev.durationMs, costUsd: ev.costUsd, usage: ev.usage }, usage: ev });
        pendingTurn = null;
        lastWasAssistant = false;
        break;
      case 'error':
        out.push({ key: e.id, kind: 'error', message: ev.message });
        break;
      case 'raw':
        if (prev?.kind === 'raw') prev.lines.push({ line: ev.line, stream: ev.stream });
        else out.push({ key: e.id, kind: 'raw', lines: [{ line: ev.line, stream: ev.stream }] });
        break;
      default:
        break;
    }
  }
  return out;
}

const BlockView = memo(function BlockView({ block, providerName }: { block: Block; providerName: string }) {
  switch (block.kind) {
    case 'user':
      return <UserMessage text={block.text} />;
    case 'assistant':
      return <AssistantText text={block.text} streaming={block.streaming} header={block.first ? providerName : null} />;
    case 'thinking':
      return <Thinking text={block.text} />;
    case 'tools':
      return <ToolGroup calls={block.calls} />;
    case 'system':
      return <SystemLine event={block.event} />;
    case 'turn':
      return <TurnRule event={block.event} usage={block.usage} />;
    case 'error':
      return <ErrorCard message={block.message} />;
    case 'raw':
      return <RawLines lines={block.lines} />;
  }
});

function Appear({ children, className }: { children: ReactNode; className?: string }) {
  return (
    <motion.div
      className={className}
      initial={{ opacity: 0, y: 6 }}
      animate={{ opacity: 1, y: 0 }}
      transition={{ duration: 0.28, ease: [0.22, 1, 0.36, 1] }}
    >
      {children}
    </motion.div>
  );
}

function UserMessage({ text }: { text: string }) {
  return (
    <Appear className="flex justify-end">
      <div
        className="bt-selectable max-w-[78%] whitespace-pre-wrap rounded-[16px] rounded-br-[6px] px-4 py-2.5 text-[13.5px] leading-[1.6]"
        style={{ background: 'var(--bt-surface-3)', color: 'var(--bt-text)', boxShadow: 'inset 0 1px 0 var(--bt-highlight), inset 0 0 0 1px var(--bt-border)' }}
      >
        {text}
      </div>
    </Appear>
  );
}

function AgentAvatar() {
  return (
    <span
      className="inline-flex h-[22px] w-[22px] items-center justify-center rounded-[7px]"
      style={{ background: 'var(--bt-accent-soft)', color: 'var(--bt-accent)', boxShadow: 'inset 0 0 0 1px var(--bt-accent-line)' }}
    >
      <Sparkles size={12} />
    </span>
  );
}

function AssistantText({ text, streaming, header }: { text: string; streaming: boolean; header: string | null }) {
  return (
    <Appear>
      {header ? (
        <div className="mb-2 flex items-center gap-2">
          <AgentAvatar />
          <span className="text-[12.5px] font-medium" style={{ color: 'var(--bt-text-dim)' }}>
            {header}
          </span>
        </div>
      ) : null}
      <div className="bt-prose">
        <Markdown remarkPlugins={[remarkGfm]} components={{ pre: CodeBlock }}>
          {text}
        </Markdown>
        {streaming ? (
          <span
            aria-hidden
            className="ml-0.5 inline-block h-[1.05em] w-[2px] translate-y-[3px] rounded-full"
            style={{ background: 'var(--bt-accent)', animation: 'bt-caret 1s steps(1) infinite' }}
          />
        ) : null}
      </div>
    </Appear>
  );
}

function CodeBlock({ children }: { children?: ReactNode }) {
  const ref = useRef<HTMLPreElement>(null);
  const [copied, setCopied] = useState(false);
  return (
    <div className="group relative">
      <pre ref={ref}>{children}</pre>
      <button
        onClick={() => {
          void navigator.clipboard.writeText(ref.current?.innerText ?? '');
          setCopied(true);
          setTimeout(() => setCopied(false), 1200);
        }}
        aria-label="Copy code"
        className="absolute right-2 top-2 inline-flex h-6 w-6 items-center justify-center rounded-[6px] opacity-0 transition-opacity group-hover:opacity-100"
        style={{ background: 'var(--bt-surface-3)', color: 'var(--bt-text-dim)' }}
      >
        {copied ? <Check size={12} /> : <Copy size={12} />}
      </button>
    </div>
  );
}

function Thinking({ text }: { text: string }) {
  const [open, setOpen] = useState(false);
  return (
    <Appear>
      <button
        onClick={() => setOpen(!open)}
        className="flex items-center gap-1.5 text-[12.5px] transition-colors hover:text-[var(--bt-text-dim)]"
        style={{ color: 'var(--bt-text-faint)' }}
      >
        <Brain size={13} />
        Thought process
        <motion.span animate={{ rotate: open ? 90 : 0 }} className="flex">
          <ChevronRight size={12} />
        </motion.span>
      </button>
      <Collapse open={open}>
        <div
          className="bt-selectable mt-2 whitespace-pre-wrap border-l-2 py-0.5 pl-3 text-[12.5px] leading-relaxed"
          style={{ borderColor: 'var(--bt-border-strong)', color: 'var(--bt-text-dim)' }}
        >
          {text}
        </div>
      </Collapse>
    </Appear>
  );
}

function SystemLine({ event }: { event: Extract<AgentEvent, { type: 'system' }> }) {
  const bits = [event.model, event.permissionMode].filter(Boolean);
  if (bits.length === 0) return null;
  return (
    <div className="flex items-center justify-center gap-2 text-[11.5px]" style={{ color: 'var(--bt-text-ghost)' }}>
      <Bot size={12} />
      <span className="font-mono">{bits.join(' · ')}</span>
    </div>
  );
}

function TurnRule({ event, usage }: { event: Extract<AgentEvent, { type: 'turn_end' }>; usage?: Extract<AgentEvent, { type: 'usage' }> }) {
  const duration = event.durationMs ?? usage?.durationMs;
  const tokens = event.usage ?? usage?.usage;
  const cost = event.costUsd ?? usage?.costUsd;
  const parts: string[] = [];
  if (duration) parts.push(formatDuration(duration));
  if (tokens) parts.push(`${formatTokens(tokens.inputTokens + tokens.cacheRead + tokens.cacheWrite)} in · ${formatTokens(tokens.outputTokens)} out`);
  if (typeof cost === 'number' && cost > 0) parts.push(`$${cost.toFixed(2)}`);
  if (!event.summary && parts.length === 0) return null;
  return (
    <Appear className="flex items-center gap-3 py-1">
      <div className="h-px flex-1" style={{ background: 'linear-gradient(90deg, transparent, var(--bt-border))' }} />
      <div
        className="flex items-center gap-2 rounded-full px-3 py-1 text-[11.5px]"
        style={{ background: 'var(--bt-surface-2)', color: 'var(--bt-text-faint)', boxShadow: 'inset 0 0 0 1px var(--bt-border)' }}
      >
        <Check size={12} style={{ color: 'var(--bt-added)' }} />
        {event.summary ? <span style={{ color: 'var(--bt-text-dim)' }}>{event.summary}</span> : null}
        {parts.length ? <span className="tabular-nums">{parts.join(' · ')}</span> : null}
      </div>
      <div className="h-px flex-1" style={{ background: 'linear-gradient(270deg, transparent, var(--bt-border))' }} />
    </Appear>
  );
}

function ErrorCard({ message }: { message: string }) {
  return (
    <Appear>
      <div
        className="bt-selectable flex items-start gap-2.5 rounded-[12px] px-4 py-3 text-[13px] leading-relaxed"
        style={{ background: 'var(--bt-removed-soft)', color: 'var(--bt-text)', boxShadow: 'inset 0 0 0 1px color-mix(in srgb, var(--bt-removed) 28%, transparent)' }}
      >
        <TriangleAlert size={15} className="mt-0.5 shrink-0" style={{ color: 'var(--bt-removed)' }} />
        <span>{message}</span>
      </div>
    </Appear>
  );
}

function RawLines({ lines }: { lines: { line: string; stream: string }[] }) {
  const [open, setOpen] = useState(false);
  return (
    <div>
      <button onClick={() => setOpen(!open)} className="flex items-center gap-1.5 text-[11.5px]" style={{ color: 'var(--bt-text-ghost)' }}>
        <motion.span animate={{ rotate: open ? 90 : 0 }} className="flex">
          <ChevronRight size={11} />
        </motion.span>
        {lines.length} unparsed output line{lines.length === 1 ? '' : 's'}
      </button>
      <Collapse open={open}>
        <pre
          className="mt-1.5 overflow-x-auto rounded-[9px] px-3 py-2 font-mono text-[11.5px] leading-relaxed"
          style={{ background: 'var(--bt-surface)', boxShadow: 'inset 0 0 0 1px var(--bt-border)' }}
        >
          {lines.map((l, i) => (
            <div key={i} style={{ color: l.stream === 'stderr' ? 'var(--bt-warn)' : 'var(--bt-text-faint)' }}>
              {l.line}
            </div>
          ))}
        </pre>
      </Collapse>
    </div>
  );
}

// ---------------- tools ----------------

function toolIcon(name: string, size = 13) {
  const n = name.toLowerCase();
  if (n === 'read' || n === 'notebookread') return <FileText size={size} />;
  if (n === 'write') return <FilePlus2 size={size} />;
  if (n === 'edit' || n === 'multiedit' || n === 'notebookedit' || n === 'apply_patch') return <Pencil size={size} />;
  if (n === 'bash' || n.includes('command') || n === 'shell') return <SquareTerminal size={size} />;
  if (n === 'grep' || n === 'glob' || n === 'search') return <Search size={size} />;
  if (n.includes('web')) return <Globe size={size} />;
  if (n.includes('todo')) return <ListTodo size={size} />;
  if (n === 'task' || n === 'agent') return <Bot size={size} />;
  if (n.includes('file')) return <FileCode2 size={size} />;
  return <Wrench size={size} />;
}

const VERBS: Record<string, string> = {
  read: 'Read',
  write: 'Created',
  edit: 'Edited',
  multiedit: 'Edited',
  bash: 'Ran',
  grep: 'Searched',
  glob: 'Listed',
  webfetch: 'Fetched',
  websearch: 'Searched the web',
  task: 'Delegated',
  todowrite: 'Updated todos',
};

function ToolGroup({ calls }: { calls: ToolCall[] }) {
  const many = calls.length > 4;
  const [expanded, setExpanded] = useState(!many);
  const shown = expanded ? calls : calls.slice(-2);
  const hidden = calls.length - shown.length;

  return (
    <Appear>
      <div
        className="overflow-hidden rounded-[12px]"
        style={{ background: 'var(--bt-surface)', boxShadow: 'inset 0 0 0 1px var(--bt-border), inset 0 1px 0 var(--bt-highlight)' }}
      >
        {hidden > 0 ? (
          <button
            onClick={() => setExpanded(true)}
            className="flex h-8 w-full items-center gap-2 px-3 text-[12px] transition-colors hover:bg-[var(--bt-hover)]"
            style={{ color: 'var(--bt-text-faint)', boxShadow: 'inset 0 -1px 0 var(--bt-border)' }}
          >
            <ChevronRight size={12} />
            {hidden} earlier tool call{hidden === 1 ? '' : 's'}
          </button>
        ) : null}
        {shown.map((c, i) => (
          <ToolRow key={c.key} call={c.call} result={c.result} last={i === shown.length - 1} />
        ))}
      </div>
    </Appear>
  );
}

function ToolRow({
  call,
  result,
  last,
}: {
  call: Extract<AgentEvent, { type: 'tool_use' }>;
  result?: Extract<AgentEvent, { type: 'tool_result' }>;
  last: boolean;
}) {
  const [open, setOpen] = useState(false);
  const edit = call.edit ?? result?.edit;
  const target = describeTarget(call.name, call.input);
  const failed = result?.isError;
  const pending = !result;
  const verb = VERBS[call.name.toLowerCase()] ?? call.name;

  return (
    <div style={last ? undefined : { boxShadow: 'inset 0 -1px 0 var(--bt-border)' }}>
      <button
        onClick={() => setOpen(!open)}
        className="group flex h-9 w-full items-center gap-2.5 px-3 text-left text-[12.5px] transition-colors hover:bg-[var(--bt-hover)]"
      >
        <span
          className="flex h-5 w-5 shrink-0 items-center justify-center rounded-[6px]"
          style={{
            background: failed ? 'var(--bt-removed-soft)' : 'var(--bt-surface-3)',
            color: failed ? 'var(--bt-removed)' : 'var(--bt-text-dim)',
          }}
        >
          {toolIcon(call.name, 12)}
        </span>
        <span className="shrink-0 font-medium" style={{ color: 'var(--bt-text)' }}>
          {verb}
        </span>
        {target ? (
          <span className="min-w-0 truncate font-mono text-[12px]" style={{ color: 'var(--bt-text-dim)' }}>
            {target}
          </span>
        ) : null}
        <span className="flex-1" />
        {edit ? (
          <span className="shrink-0 font-mono text-[11.5px] tabular-nums">
            <span style={{ color: 'var(--bt-added)' }}>+{edit.additions}</span>{' '}
            <span style={{ color: 'var(--bt-removed)' }}>−{edit.deletions}</span>
          </span>
        ) : null}
        <span className="flex w-4 shrink-0 justify-center">
          {pending ? (
            <Spinner size={12} className="text-[var(--bt-text-faint)]" />
          ) : failed ? (
            <X size={13} style={{ color: 'var(--bt-removed)' }} />
          ) : (
            <Check size={13} style={{ color: 'var(--bt-text-faint)' }} />
          )}
        </span>
        <motion.span animate={{ rotate: open ? 90 : 0 }} className="flex shrink-0" style={{ color: 'var(--bt-text-ghost)' }}>
          <ChevronRight size={12} />
        </motion.span>
      </button>

      {edit && !open ? (
        <div className="px-3 pb-3">
          <MiniDiff edit={edit} maxLines={10} />
        </div>
      ) : null}

      <Collapse open={open}>
        <div className="flex flex-col gap-2 px-3 pb-3">
          <Labelled label="Input">
            <pre className="bt-selectable max-h-60 overflow-auto rounded-[8px] px-3 py-2 font-mono text-[11.5px] leading-relaxed" style={{ background: 'var(--bt-surface-2)', color: 'var(--bt-text-dim)' }}>
              {formatInput(call.input)}
            </pre>
          </Labelled>
          {edit ? <MiniDiff edit={edit} maxLines={60} /> : null}
          {result ? (
            <Labelled label={failed ? 'Error' : 'Output'}>
              <ToolOutput text={result.output} isError={result.isError} />
            </Labelled>
          ) : null}
        </div>
      </Collapse>
    </div>
  );
}

function Labelled({ label, children }: { label: string; children: ReactNode }) {
  return (
    <div className="flex flex-col gap-1">
      <span className="text-[10.5px] font-medium uppercase tracking-[0.06em]" style={{ color: 'var(--bt-text-ghost)' }}>
        {label}
      </span>
      {children}
    </div>
  );
}

function ToolOutput({ text, isError }: { text: string; isError?: boolean }) {
  const lines = text.split('\n');
  const [expanded, setExpanded] = useState(lines.length <= 16);
  const shown = expanded ? lines : lines.slice(0, 16);
  return (
    <div>
      <pre
        className="bt-selectable max-h-96 overflow-auto whitespace-pre-wrap rounded-[8px] px-3 py-2 font-mono text-[11.5px] leading-relaxed"
        style={{ background: 'var(--bt-surface-2)', color: isError ? 'var(--bt-removed)' : 'var(--bt-text-dim)' }}
      >
        {shown.join('\n') || '(no output)'}
      </pre>
      {lines.length > 16 ? (
        <button onClick={() => setExpanded(!expanded)} className="mt-1 text-[11.5px]" style={{ color: 'var(--bt-text-faint)' }}>
          {expanded ? 'Show less' : `Show ${lines.length - 16} more lines`}
        </button>
      ) : null}
    </div>
  );
}

function MiniDiff({ edit, maxLines }: { edit: EditPreview; maxLines: number }) {
  const lines = edit.lines.slice(0, maxLines);
  if (lines.length === 0) return null;
  return (
    <div
      className="bt-selectable overflow-hidden rounded-[8px] font-mono text-[11.5px] leading-[1.65]"
      style={{ background: 'var(--bt-bg)', boxShadow: 'inset 0 0 0 1px var(--bt-border)' }}
    >
      <div className="overflow-x-auto py-1">
        {lines.map((l, i) => (
          <div
            key={i}
            className="flex whitespace-pre"
            style={{
              background: l.origin === '+' ? 'var(--bt-added-soft)' : l.origin === '-' ? 'var(--bt-removed-soft)' : 'transparent',
            }}
          >
            <span
              className="w-6 shrink-0 select-none text-center"
              style={{ color: l.origin === '+' ? 'var(--bt-added)' : l.origin === '-' ? 'var(--bt-removed)' : 'var(--bt-text-ghost)' }}
            >
              {l.origin === ' ' ? '' : l.origin === '-' ? '−' : '+'}
            </span>
            <span className="pr-3" style={{ color: l.origin === ' ' ? 'var(--bt-text-faint)' : 'var(--bt-text)' }}>
              {l.content}
            </span>
          </div>
        ))}
      </div>
      {edit.lines.length > lines.length ? (
        <div className="px-3 py-1 text-[11px]" style={{ color: 'var(--bt-text-faint)', boxShadow: 'inset 0 1px 0 var(--bt-border)' }}>
          {edit.lines.length - lines.length} more lines
        </div>
      ) : null}
    </div>
  );
}

// ---------------- permission & working ----------------

function PermissionCard({
  providerName,
  toolName,
  input,
  onAllow,
  onDeny,
}: {
  providerName: string;
  toolName: string;
  input: unknown;
  onAllow: () => void;
  onDeny: () => void;
}) {
  const target = describeTarget(toolName, input);
  const [busy, setBusy] = useState<'allow' | 'deny' | null>(null);
  return (
    <motion.div
      layout
      initial={{ opacity: 0, y: 10, scale: 0.98 }}
      animate={{ opacity: 1, y: 0, scale: 1 }}
      exit={{ opacity: 0, scale: 0.98 }}
      transition={{ type: 'spring', stiffness: 420, damping: 34 }}
      className="overflow-hidden rounded-[14px]"
      style={{
        background: 'linear-gradient(180deg, color-mix(in srgb, var(--bt-accent) 9%, var(--bt-surface)), var(--bt-surface))',
        boxShadow: '0 0 0 1px var(--bt-accent-line), 0 12px 40px -12px color-mix(in srgb, var(--bt-accent) 35%, transparent)',
      }}
    >
      <div className="flex items-start gap-3 px-4 pt-4">
        <span className="flex h-8 w-8 shrink-0 items-center justify-center rounded-[9px]" style={{ background: 'var(--bt-accent-soft)', color: 'var(--bt-accent)' }}>
          <ShieldAlert size={16} />
        </span>
        <div className="min-w-0 flex-1">
          <p className="text-[13.5px] font-medium" style={{ color: 'var(--bt-text)' }}>
            {providerName} wants to use {toolName}
          </p>
          {target ? (
            <p className="mt-0.5 truncate font-mono text-[12px]" style={{ color: 'var(--bt-text-dim)' }}>
              {target}
            </p>
          ) : null}
        </div>
      </div>
      <pre
        className="bt-selectable mx-4 mt-3 max-h-44 overflow-auto rounded-[9px] px-3 py-2 font-mono text-[11.5px] leading-relaxed"
        style={{ background: 'rgb(0 0 0 / 0.3)', color: 'var(--bt-text-dim)', boxShadow: 'inset 0 0 0 1px var(--bt-border)' }}
      >
        {formatInput(input)}
      </pre>
      <div className="flex items-center justify-end gap-2 px-4 py-3">
        <Button
          variant="ghost"
          loading={busy === 'deny'}
          onClick={() => {
            setBusy('deny');
            onDeny();
          }}
        >
          Deny
        </Button>
        <Button
          variant="primary"
          loading={busy === 'allow'}
          onClick={() => {
            setBusy('allow');
            onAllow();
          }}
        >
          Allow
        </Button>
      </div>
    </motion.div>
  );
}

function WorkingIndicator({ entries }: { entries: readonly TimelineEntry[] }) {
  const [now, setNow] = useState(Date.now());
  const startedAt = useRef(Date.now());
  useEffect(() => {
    const t = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(t);
  }, []);
  const last = entries[entries.length - 1]?.event;
  const streaming = last?.type === 'text' && last.partial;
  if (streaming) return null;
  const label =
    last?.type === 'tool_use' ? `Running ${last.name}` : last?.type === 'tool_result' ? 'Thinking' : 'Working';
  return (
    <motion.div initial={{ opacity: 0 }} animate={{ opacity: 1 }} className="flex items-center gap-2.5 pl-0.5 text-[12.5px]">
      <Spinner size={13} className="text-[var(--bt-accent)]" />
      <span className="bt-shimmer-text font-medium">{label}…</span>
      <span className="tabular-nums" style={{ color: 'var(--bt-text-ghost)' }}>
        {formatDuration(now - startedAt.current)}
      </span>
    </motion.div>
  );
}

// ---------------- helpers ----------------

function Collapse({ open, children }: { open: boolean; children: ReactNode }) {
  return (
    <AnimatePresence initial={false}>
      {open ? (
        <motion.div
          initial={{ height: 0, opacity: 0 }}
          animate={{ height: 'auto', opacity: 1 }}
          exit={{ height: 0, opacity: 0 }}
          transition={{ duration: 0.22, ease: [0.22, 1, 0.36, 1] }}
          className="overflow-hidden"
        >
          {children}
        </motion.div>
      ) : null}
    </AnimatePresence>
  );
}

function formatInput(input: unknown): string {
  if (input && typeof input === 'object') {
    const o = input as Record<string, unknown>;
    if (typeof o.command === 'string' && Object.keys(o).length <= 3) return o.command;
  }
  try {
    return JSON.stringify(input, null, 2);
  } catch {
    return String(input);
  }
}

function describeTarget(name: string, input: unknown): string {
  if (!input || typeof input !== 'object') return '';
  const o = input as Record<string, unknown>;
  for (const key of ['file_path', 'path', 'notebook_path', 'command', 'pattern', 'url', 'query']) {
    const v = o[key];
    if (typeof v === 'string' && v) {
      const short = key === 'command' ? v : v.split('/').slice(-3).join('/');
      return short.length > 96 ? `${short.slice(0, 96)}…` : short;
    }
  }
  return (name === 'Task' || name === 'Agent') && typeof o.description === 'string' ? o.description : '';
}

