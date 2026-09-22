import { forwardRef, type ButtonHTMLAttributes, type ReactNode } from 'react';
import { cn } from './cn';
import { Spinner } from './Spinner';
import { Kbd } from './Kbd';
import { Tooltip } from './Tooltip';

type Variant = 'primary' | 'secondary' | 'ghost' | 'danger' | 'subtle';
type Size = 'xs' | 'sm' | 'md' | 'lg';

const VARIANTS: Record<Variant, string> = {
  primary: cn(
    'bg-[var(--bt-accent)] text-[var(--bt-accent-fg)] font-medium',
    'shadow-[inset_0_1px_0_rgb(255_255_255/0.25),0_1px_2px_rgb(0_0_0/0.4),0_0_0_1px_color-mix(in_srgb,var(--bt-accent)_60%,black)]',
    'hover:brightness-110 active:brightness-95',
  ),
  secondary: cn(
    'bg-[var(--bt-surface-3)] text-[var(--bt-text)]',
    'shadow-[inset_0_1px_0_var(--bt-highlight),0_1px_2px_rgb(0_0_0/0.3),0_0_0_1px_var(--bt-border-strong)]',
    'hover:bg-[var(--bt-surface-4)]',
  ),
  subtle: cn(
    'bg-[var(--bt-hover)] text-[var(--bt-text)]',
    'hover:bg-[var(--bt-active)]',
  ),
  ghost: cn('text-[var(--bt-text-dim)] hover:bg-[var(--bt-hover)] hover:text-[var(--bt-text)]'),
  danger: cn(
    'text-[var(--bt-removed)] hover:bg-[var(--bt-removed-soft)]',
  ),
};

const SIZES: Record<Size, string> = {
  xs: 'h-6 px-2 text-[12px] gap-1 rounded-[6px]',
  sm: 'h-7 px-2.5 text-[12.5px] gap-1.5 rounded-[7px]',
  md: 'h-8 px-3 text-[13px] gap-1.5 rounded-[8px]',
  lg: 'h-9 px-4 text-[13.5px] gap-2 rounded-[9px]',
};

export interface ButtonProps extends ButtonHTMLAttributes<HTMLButtonElement> {
  variant?: Variant;
  size?: Size;
  icon?: ReactNode;
  iconRight?: ReactNode;
  loading?: boolean;
  shortcut?: string;
}

export const Button = forwardRef<HTMLButtonElement, ButtonProps>(function Button(
  { variant = 'secondary', size = 'md', icon, iconRight, loading, shortcut, className, children, disabled, type = 'button', ...rest },
  ref,
) {
  return (
    <button
      ref={ref}
      type={type}
      disabled={disabled || loading}
      className={cn(
        'relative inline-flex shrink-0 select-none items-center justify-center whitespace-nowrap',
        'transition-[background,filter,color,transform,box-shadow] duration-150 ease-[var(--ease-out-soft)]',
        'active:scale-[0.97] disabled:pointer-events-none disabled:opacity-45',
        VARIANTS[variant],
        SIZES[size],
        className,
      )}
      {...rest}
    >
      {loading ? <Spinner size={size === 'xs' ? 11 : 13} /> : icon}
      {children}
      {iconRight}
      {shortcut ? <Kbd shortcut={shortcut} className="ml-1 opacity-80" /> : null}
    </button>
  );
});

export interface IconButtonProps extends ButtonHTMLAttributes<HTMLButtonElement> {
  label: string;
  shortcut?: string;
  size?: 'xs' | 'sm' | 'md';
  variant?: 'ghost' | 'subtle' | 'secondary' | 'danger';
  active?: boolean;
  tooltipSide?: 'top' | 'bottom' | 'left' | 'right';
}

const ICON_SIZES = { xs: 'h-6 w-6 rounded-[6px]', sm: 'h-7 w-7 rounded-[7px]', md: 'h-8 w-8 rounded-[8px]' };

/** Square icon-only button. Always has an accessible label and a tooltip. */
export const IconButton = forwardRef<HTMLButtonElement, IconButtonProps>(function IconButton(
  { label, shortcut, size = 'sm', variant = 'ghost', active, tooltipSide, className, children, type = 'button', ...rest },
  ref,
) {
  return (
    <Tooltip label={label} shortcut={shortcut} side={tooltipSide}>
      <button
        ref={ref}
        type={type}
        aria-label={label}
        className={cn(
          'inline-flex shrink-0 items-center justify-center',
          'transition-[background,color,transform] duration-150 active:scale-[0.94] disabled:opacity-40',
          VARIANTS[variant],
          ICON_SIZES[size],
          active && 'bg-[var(--bt-active)] text-[var(--bt-text)]',
          className,
        )}
        {...rest}
      >
        {children}
      </button>
    </Tooltip>
  );
});
