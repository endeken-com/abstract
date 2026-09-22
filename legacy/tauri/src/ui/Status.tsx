import { cn } from './cn';

export const STATUS_WORDS: Record<string, string> = {
  created: 'Ready',
  provisioning: 'Setting up',
  running: 'Running',
  waiting_input: 'Needs you',
  idle: 'Your turn',
  finished: 'Done',
  errored: 'Error',
};

const COLORS: Record<string, string> = {
  running: 'var(--bt-accent)',
  waiting_input: 'var(--bt-accent)',
  provisioning: 'var(--bt-text-dim)',
  errored: 'var(--bt-removed)',
  finished: 'var(--bt-added)',
  idle: 'var(--bt-added)',
};

export function statusColor(status: string): string {
  return COLORS[status] ?? 'var(--bt-text-faint)';
}

/**
 * A status dot. Running pulses; "needs you" radiates a ring so it can be
 * spotted from across the sidebar. Always paired with a word somewhere near
 * it, so colour is never the only signal.
 */
export function StatusDot({ status, size = 7 }: { status: string; size?: number }) {
  const color = statusColor(status);
  const live = status === 'running';
  const attention = status === 'waiting_input';
  return (
    <span className="relative inline-flex shrink-0" style={{ width: size, height: size }} aria-hidden>
      {attention ? (
        <span
          className="absolute inset-0 rounded-full"
          style={{ background: color, animation: 'bt-ping 1.8s cubic-bezier(0,0,0.2,1) infinite' }}
        />
      ) : null}
      <span
        className="relative inline-block rounded-full"
        style={{
          width: size,
          height: size,
          background: color,
          boxShadow: live || attention ? `0 0 8px ${color}` : undefined,
          animation: live ? 'bt-pulse 1.6s ease-in-out infinite' : undefined,
        }}
      />
    </span>
  );
}

export function StatusPill({ status, className }: { status: string; className?: string }) {
  const color = statusColor(status);
  const loud = status === 'waiting_input' || status === 'errored';
  return (
    <span
      className={cn('inline-flex h-[22px] items-center gap-1.5 rounded-full px-2 text-[11.5px] font-medium', className)}
      style={{
        background: loud ? `color-mix(in srgb, ${color} 14%, transparent)` : 'var(--bt-surface-3)',
        color: loud ? color : 'var(--bt-text-dim)',
        boxShadow: `inset 0 0 0 1px ${loud ? `color-mix(in srgb, ${color} 30%, transparent)` : 'var(--bt-border)'}`,
      }}
    >
      <StatusDot status={status} size={6} />
      {STATUS_WORDS[status] ?? status}
    </span>
  );
}
