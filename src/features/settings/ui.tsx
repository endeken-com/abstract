/**
 * Presentational primitives for the Settings view.
 *
 * Colour comes exclusively from the `--bt-*` custom properties; layout and
 * spacing come from Tailwind. Nothing here sets a border radius: a global rule
 * in styles.css pins every corner to zero on purpose.
 */
import type { JSX, ReactNode } from 'react';

export function Section({
  title,
  lead,
  children,
}: {
  title: string;
  lead?: string;
  children: ReactNode;
}): JSX.Element {
  return (
    <section className="mb-14">
      <h2 className="text-[1.15em] font-semibold" style={{ color: 'var(--bt-text)' }}>
        {title}
      </h2>
      {lead ? (
        <p className="mt-1.5 max-w-[70ch]" style={{ color: 'var(--bt-text-dim)' }}>
          {lead}
        </p>
      ) : null}
      <div className="mt-6 flex flex-col gap-6">{children}</div>
    </section>
  );
}

export function Card({
  children,
  className = '',
}: {
  children: ReactNode;
  className?: string;
}): JSX.Element {
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
  label,
  hint,
  children,
}: {
  label: string;
  hint?: string;
  children: ReactNode;
}): JSX.Element {
  return (
    <div className="flex flex-col gap-2">
      <div className="flex flex-col gap-0.5">
        <span className="font-medium" style={{ color: 'var(--bt-text)' }}>
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
    <p className="max-w-[70ch]" style={{ color: 'var(--bt-text-faint)' }}>
      {children}
    </p>
  );
}

export function Mono({ children }: { children: ReactNode }): JSX.Element {
  return (
    <span className="font-mono" style={{ fontSize: 'var(--bt-code-size)' }}>
      {children}
    </span>
  );
}

/** Status is always a word; the dot is decoration on top of the word. */
export function Dot({ tone }: { tone: 'ok' | 'off' | 'warn' | 'bad' | 'accent' }): JSX.Element {
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
    <span
      aria-hidden="true"
      className="inline-block w-[7px] h-[7px] shrink-0"
      style={{ background: color }}
    />
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
      className="px-3 py-1.5 disabled:cursor-not-allowed"
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

/** One choice out of a small, always-visible set. */
export function Segment<T extends string>({
  value,
  options,
  onChange,
  ariaLabel,
}: {
  value: T;
  options: { value: T; label: string }[];
  onChange: (v: T) => void;
  ariaLabel: string;
}): JSX.Element {
  return (
    <div role="radiogroup" aria-label={ariaLabel} className="flex flex-wrap gap-2">
      {options.map((option) => {
        const active = option.value === value;
        return (
          <button
            key={option.value}
            type="button"
            role="radio"
            aria-checked={active}
            onClick={() => onChange(option.value)}
            className="px-3 py-1.5"
            style={{
              background: active ? 'var(--bt-surface-3)' : 'var(--bt-surface-2)',
              border: `1px solid ${active ? 'var(--bt-accent)' : 'var(--bt-border)'}`,
              color: active ? 'var(--bt-accent)' : 'var(--bt-text-dim)',
            }}
          >
            {option.label}
          </button>
        );
      })}
    </div>
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
  hint?: string;
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
