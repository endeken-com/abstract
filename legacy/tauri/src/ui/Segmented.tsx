import { motion } from 'motion/react';
import { useId, type ReactNode } from 'react';
import { cn } from './cn';

/** A pill-style segmented control whose selection slides between options. */
export function Segmented<T extends string>({
  value,
  onChange,
  options,
  size = 'sm',
}: {
  value: T;
  onChange: (v: T) => void;
  options: { value: T; label: ReactNode; icon?: ReactNode }[];
  size?: 'xs' | 'sm';
}) {
  const id = useId();
  return (
    <div
      role="tablist"
      className="inline-flex items-center gap-0.5 rounded-[9px] p-[3px]"
      style={{ background: 'var(--bt-surface-2)', boxShadow: 'inset 0 0 0 1px var(--bt-border)' }}
    >
      {options.map((o) => {
        const active = o.value === value;
        return (
          <button
            key={o.value}
            role="tab"
            aria-selected={active}
            onClick={() => onChange(o.value)}
            className={cn(
              'relative inline-flex items-center gap-1.5 rounded-[6px] font-medium transition-colors duration-150',
              size === 'xs' ? 'h-[22px] px-2 text-[11.5px]' : 'h-[26px] px-2.5 text-[12.5px]',
              active ? 'text-[var(--bt-text)]' : 'text-[var(--bt-text-faint)] hover:text-[var(--bt-text-dim)]',
            )}
          >
            {active ? (
              <motion.span
                layoutId={`seg-${id}`}
                className="absolute inset-0 rounded-[6px]"
                style={{ background: 'var(--bt-surface-4)', boxShadow: 'inset 0 1px 0 var(--bt-highlight), 0 1px 2px rgb(0 0 0 / 0.35)' }}
                transition={{ type: 'spring', stiffness: 600, damping: 40 }}
              />
            ) : null}
            <span className="relative inline-flex items-center gap-1.5">
              {o.icon}
              {o.label}
            </span>
          </button>
        );
      })}
    </div>
  );
}
