import type { ReactNode } from 'react';

type Tone = 'default' | 'accept' | 'reject';

const TONE_COLOR: Record<Tone, string> = {
  default: 'var(--bt-text-dim)',
  accept: 'var(--bt-added)',
  reject: 'var(--bt-removed)',
};

export function Btn({
  children,
  onClick,
  disabled = false,
  active = false,
  tone = 'default',
  title,
}: {
  children: ReactNode;
  onClick: () => void;
  disabled?: boolean;
  active?: boolean;
  tone?: Tone;
  title?: string;
}): React.JSX.Element {
  return (
    <button
      type="button"
      title={title}
      disabled={disabled}
      onClick={onClick}
      className="px-2.5 py-1 whitespace-nowrap transition-colors"
      style={{
        border: `1px solid ${active ? 'var(--bt-accent)' : 'var(--bt-border)'}`,
        background: active ? 'var(--bt-surface-3)' : 'var(--bt-surface-2)',
        color: active ? 'var(--bt-accent)' : TONE_COLOR[tone],
        opacity: disabled ? 0.45 : 1,
        cursor: disabled ? 'not-allowed' : 'pointer',
      }}
    >
      {children}
    </button>
  );
}

/** `+N −M`, the only place the added/removed tokens carry meaning on their own. */
export function Counts({
  additions,
  deletions,
  className = '',
}: {
  additions: number;
  deletions: number;
  className?: string;
}): React.JSX.Element {
  return (
    <span className={`font-mono tabular-nums whitespace-nowrap ${className}`}>
      <span style={{ color: 'var(--bt-added)' }}>+{additions}</span>
      <span style={{ color: 'var(--bt-text-faint)' }}> </span>
      <span style={{ color: 'var(--bt-removed)' }}>&minus;{deletions}</span>
    </span>
  );
}

export function Notice({
  text,
  onDismiss,
}: {
  text: string;
  onDismiss?: () => void;
}): React.JSX.Element {
  return (
    <div
      className="flex items-start gap-3 px-4 py-3 text-sm"
      style={{
        background: 'var(--bt-surface-2)',
        borderBottom: '1px solid var(--bt-border)',
        color: 'var(--bt-removed)',
      }}
    >
      <pre className="font-mono whitespace-pre-wrap break-words flex-1 m-0 leading-relaxed">
        {text}
      </pre>
      {onDismiss ? (
        <button
          type="button"
          onClick={onDismiss}
          className="px-2 py-0.5"
          style={{ color: 'var(--bt-text-faint)', border: '1px solid var(--bt-border)' }}
        >
          dismiss
        </button>
      ) : null}
    </div>
  );
}

export function Centered({ children }: { children: ReactNode }): React.JSX.Element {
  return (
    <div
      className="flex-1 flex items-center justify-center px-8 py-12 text-center"
      style={{ background: 'var(--bt-bg)' }}
    >
      <div className="max-w-md flex flex-col gap-3">{children}</div>
    </div>
  );
}
