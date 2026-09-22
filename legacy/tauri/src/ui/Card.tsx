import type { HTMLAttributes, ReactNode } from 'react';
import { cn } from './cn';

export function Card({
  children,
  className,
  padded = true,
  ...rest
}: { children: ReactNode; padded?: boolean } & HTMLAttributes<HTMLDivElement>) {
  return (
    <div
      className={cn('rounded-[12px]', padded && 'p-4', className)}
      style={{ background: 'var(--bt-surface)', boxShadow: 'inset 0 0 0 1px var(--bt-border), inset 0 1px 0 var(--bt-highlight)' }}
      {...rest}
    >
      {children}
    </div>
  );
}

export function EmptyState({
  icon,
  title,
  description,
  action,
}: {
  icon?: ReactNode;
  title: ReactNode;
  description?: ReactNode;
  action?: ReactNode;
}) {
  return (
    <div className="flex h-full flex-col items-center justify-center gap-3 px-8 text-center">
      {icon ? (
        <div
          className="mb-1 flex h-11 w-11 items-center justify-center rounded-[12px]"
          style={{ background: 'var(--bt-surface-2)', color: 'var(--bt-text-dim)', boxShadow: 'inset 0 0 0 1px var(--bt-border), inset 0 1px 0 var(--bt-highlight)' }}
        >
          {icon}
        </div>
      ) : null}
      <p className="text-[14px] font-medium" style={{ color: 'var(--bt-text)' }}>
        {title}
      </p>
      {description ? (
        <p className="max-w-[44ch] text-[12.5px] leading-relaxed" style={{ color: 'var(--bt-text-faint)' }}>
          {description}
        </p>
      ) : null}
      {action ? <div className="mt-2">{action}</div> : null}
    </div>
  );
}
