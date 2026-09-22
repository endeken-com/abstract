/**
 * Presentational primitives for the Automations view. Kept local to the feature
 * so the directory stands on its own; colour comes only from `--bt-*` tokens.
 */
import type { JSX, ReactNode } from 'react';

export type Tone = 'ok' | 'off' | 'warn' | 'bad' | 'accent';

export function Dot({ tone }: { tone: Tone }): JSX.Element {
  const color =
    tone === 'ok'
      ? 'var(--bt-added)'
      : tone === 'warn'
        ? 'var(--bt-warn)'
        : tone === 'bad'
          ? 'var(--bt-removed)'
          : tone === 'accent'
            ? 'var(--bt-accent)'
            : 'var(--bt-text-faint)';
  return (
    <span aria-hidden="true" className="inline-block w-[7px] h-[7px] shrink-0" style={{ background: color }} />
  );
}

/** Never colour alone: the word carries the meaning, the dot merely repeats it. */
export function StatusWord({ tone, children }: { tone: Tone; children: ReactNode }): JSX.Element {
  return (
    <span className="inline-flex items-center gap-1.5 whitespace-nowrap">
      <Dot tone={tone} />
      <span style={{ color: 'var(--bt-text-dim)' }}>{children}</span>
    </span>
  );
}

export function Card({ children, className = '' }: { children: ReactNode; className?: string }): JSX.Element {
  return (
    <div
      className={`p-5 ${className}`}
      style={{ background: 'var(--bt-surface)', border: '1px solid var(--bt-border)' }}
    >
      {children}
    </div>
  );
}

export function Field({
  step,
  label,
  hint,
  children,
}: {
  step?: number;
  label: string;
  hint?: ReactNode;
  children: ReactNode;
}): JSX.Element {
  return (
    <div className="flex flex-col gap-2">
      <div className="flex flex-col gap-0.5">
        <span className="font-medium flex items-baseline gap-2" style={{ color: 'var(--bt-text)' }}>
          {step !== undefined ? (
            <span className="tabular-nums" style={{ color: 'var(--bt-text-faint)' }}>
              {step}.
            </span>
          ) : null}
          {label}
        </span>
        {hint ? (
          <span className="max-w-[70ch]" style={{ color: 'var(--bt-text-dim)' }}>
            {hint}
          </span>
        ) : null}
      </div>
      {children}
    </div>
  );
}

export function Muted({ children }: { children: ReactNode }): JSX.Element {
  return (
    <p className="max-w-[72ch] m-0" style={{ color: 'var(--bt-text-faint)' }}>
      {children}
    </p>
  );
}

export function Button({
  children,
  onClick,
  variant = 'plain',
  disabled = false,
  title,
}: {
  children: ReactNode;
  onClick: () => void;
  variant?: 'plain' | 'accent' | 'danger';
  disabled?: boolean;
  title?: string;
}): JSX.Element {
  const border =
    variant === 'accent'
      ? 'var(--bt-accent)'
      : variant === 'danger'
        ? 'var(--bt-removed)'
        : 'var(--bt-border-strong)';
  const color =
    variant === 'accent'
      ? 'var(--bt-accent)'
      : variant === 'danger'
        ? 'var(--bt-removed)'
        : 'var(--bt-text)';
  return (
    <button
      type="button"
      title={title}
      disabled={disabled}
      onClick={onClick}
      className="px-3 py-1.5 whitespace-nowrap disabled:cursor-not-allowed"
      style={{
        background: 'var(--bt-surface-2)',
        border: `1px solid ${disabled ? 'var(--bt-border)' : border}`,
        color: disabled ? 'var(--bt-text-faint)' : color,
      }}
    >
      {children}
    </button>
  );
}

/** An inline, clickable part of a sentence. Disabled chips still read as text. */
export function Chip({
  children,
  onClick,
  disabled = false,
  title,
}: {
  children: ReactNode;
  onClick: () => void;
  disabled?: boolean;
  title?: string;
}): JSX.Element {
  return (
    <button
      type="button"
      title={title}
      disabled={disabled}
      onClick={onClick}
      className="px-2 py-0.5 mx-1 align-baseline disabled:cursor-not-allowed"
      style={{
        background: disabled ? 'var(--bt-surface-2)' : 'var(--bt-surface-3)',
        border: `1px solid ${disabled ? 'var(--bt-border)' : 'var(--bt-accent)'}`,
        color: disabled ? 'var(--bt-text-faint)' : 'var(--bt-accent)',
      }}
    >
      {children}
    </button>
  );
}

export function Toggle({
  checked,
  onChange,
  label,
  hint,
}: {
  checked: boolean;
  onChange: (v: boolean) => void;
  label: string;
  hint?: ReactNode;
}): JSX.Element {
  return (
    <div className="flex items-start gap-3">
      <button
        type="button"
        role="switch"
        aria-checked={checked}
        aria-label={label}
        onClick={() => onChange(!checked)}
        className="mt-1 shrink-0 flex items-center w-10 h-[22px] p-[3px]"
        style={{
          background: checked ? 'var(--bt-surface-3)' : 'var(--bt-surface-2)',
          border: `1px solid ${checked ? 'var(--bt-accent)' : 'var(--bt-border-strong)'}`,
          justifyContent: checked ? 'flex-end' : 'flex-start',
        }}
      >
        <span
          className="block w-3.5 h-full"
          style={{ background: checked ? 'var(--bt-accent)' : 'var(--bt-text-faint)' }}
        />
      </button>
      <div className="flex flex-col gap-0.5">
        <span style={{ color: 'var(--bt-text)' }}>
          {label}{' '}
          <span style={{ color: checked ? 'var(--bt-text-dim)' : 'var(--bt-text-faint)' }}>
            — {checked ? 'On' : 'Off'}
          </span>
        </span>
        {hint ? (
          <span className="max-w-[70ch]" style={{ color: 'var(--bt-text-dim)' }}>
            {hint}
          </span>
        ) : null}
      </div>
    </div>
  );
}
