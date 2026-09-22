import type { CSSProperties, ReactNode } from 'react';

export const STATUS_WORDS: Record<string, string> = {
  created: 'Ready',
  provisioning: 'Setting up',
  running: 'Running',
  waiting_input: 'Waiting',
  finished: 'Done',
  errored: 'Error',
};

export function statusColor(status: string): string {
  switch (status) {
    case 'running':
      return 'var(--bt-accent)';
    case 'waiting_input':
      return 'var(--bt-accent)';
    case 'errored':
      return 'var(--bt-removed)';
    case 'finished':
      return 'var(--bt-added)';
    default:
      return 'var(--bt-text-faint)';
  }
}

/** Status is always a word plus a dot, never colour alone. */
export function StatusTag({ status, alive }: { status: string; alive?: boolean }) {
  const word = STATUS_WORDS[status] ?? status;
  return (
    <span className="inline-flex items-center gap-1.5 text-xs" style={{ color: 'var(--bt-text-dim)' }}>
      <span
        aria-hidden
        className="inline-block"
        style={{
          width: 6,
          height: 6,
          background: statusColor(status),
          opacity: alive === false && status === 'running' ? 0.4 : 1,
        }}
      />
      {word}
    </span>
  );
}

export function Button({
  children,
  onClick,
  variant = 'default',
  disabled,
  title,
  type = 'button',
  className = '',
}: {
  children: ReactNode;
  onClick?: () => void;
  variant?: 'default' | 'accent' | 'ghost' | 'danger';
  disabled?: boolean;
  title?: string;
  type?: 'button' | 'submit';
  className?: string;
}) {
  const styles: Record<string, CSSProperties> = {
    default: {
      background: 'var(--bt-surface-2)',
      border: '1px solid var(--bt-border)',
      color: 'var(--bt-text)',
    },
    accent: {
      background: 'var(--bt-accent)',
      border: '1px solid var(--bt-accent)',
      color: '#0a0a0a',
      fontWeight: 600,
    },
    ghost: { background: 'transparent', border: '1px solid transparent', color: 'var(--bt-text-dim)' },
    danger: {
      background: 'transparent',
      border: '1px solid var(--bt-border)',
      color: 'var(--bt-removed)',
    },
  };
  return (
    <button
      type={type}
      title={title}
      disabled={disabled}
      onClick={onClick}
      className={`px-2.5 py-1 text-xs disabled:opacity-40 disabled:cursor-not-allowed ${className}`}
      style={styles[variant]}
    >
      {children}
    </button>
  );
}

export function Panel({ children, className = '' }: { children: ReactNode; className?: string }) {
  return (
    <div
      className={className}
      style={{ background: 'var(--bt-surface)', border: '1px solid var(--bt-border)' }}
    >
      {children}
    </div>
  );
}

export function Empty({ title, hint }: { title: string; hint?: string }) {
  return (
    <div className="flex h-full flex-col items-center justify-center gap-2 px-8 text-center">
      <p style={{ color: 'var(--bt-text-dim)' }}>{title}</p>
      {hint ? (
        <p className="text-xs" style={{ color: 'var(--bt-text-faint)' }}>
          {hint}
        </p>
      ) : null}
    </div>
  );
}

export function relativeTime(iso: string | null | undefined): string {
  if (!iso) return '';
  const then = new Date(iso).getTime();
  if (Number.isNaN(then)) return '';
  const diff = then - Date.now();
  const abs = Math.abs(diff);
  const units: [number, string][] = [
    [1000 * 60 * 60 * 24, 'd'],
    [1000 * 60 * 60, 'h'],
    [1000 * 60, 'm'],
    [1000, 's'],
  ];
  for (const [ms, label] of units) {
    if (abs >= ms) {
      const n = Math.round(abs / ms);
      return diff < 0 ? `${n}${label} ago` : `in ${n}${label}`;
    }
  }
  return diff < 0 ? 'just now' : 'now';
}

export function formatDuration(ms: number): string {
  if (!ms) return '0s';
  const s = Math.round(ms / 1000);
  if (s < 60) return `${s}s`;
  const m = Math.floor(s / 60);
  const rem = s % 60;
  if (m < 60) return rem ? `${m}m ${rem}s` : `${m}m`;
  const h = Math.floor(m / 60);
  return `${h}h ${m % 60}m`;
}

export function formatTokens(n: number): string {
  if (n < 1000) return String(n);
  if (n < 1_000_000) return `${(n / 1000).toFixed(n < 10_000 ? 1 : 0)}k`;
  return `${(n / 1_000_000).toFixed(1)}M`;
}
