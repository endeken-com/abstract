import type { ReactNode } from 'react';
import { cn } from './cn';

export function Badge({
  children,
  tone = 'neutral',
  className,
  mono,
}: {
  children: ReactNode;
  tone?: 'neutral' | 'accent' | 'added' | 'removed' | 'warn';
  className?: string;
  mono?: boolean;
}) {
  const color =
    tone === 'accent'
      ? 'var(--bt-accent)'
      : tone === 'added'
        ? 'var(--bt-added)'
        : tone === 'removed'
          ? 'var(--bt-removed)'
          : tone === 'warn'
            ? 'var(--bt-warn)'
            : null;
  return (
    <span
      className={cn(
        'inline-flex h-[20px] items-center gap-1 rounded-[6px] px-1.5 text-[11px] font-medium',
        mono && 'font-mono',
        className,
      )}
      style={{
        background: color ? `color-mix(in srgb, ${color} 13%, transparent)` : 'var(--bt-surface-3)',
        color: color ?? 'var(--bt-text-dim)',
        boxShadow: `inset 0 0 0 1px ${color ? `color-mix(in srgb, ${color} 25%, transparent)` : 'var(--bt-border)'}`,
      }}
    >
      {children}
    </span>
  );
}
