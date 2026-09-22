import {
  forwardRef,
  useEffect,
  useImperativeHandle,
  useRef,
  type InputHTMLAttributes,
  type ReactNode,
  type SelectHTMLAttributes,
  type TextareaHTMLAttributes,
} from 'react';
import { cn } from './cn';

export function Field({
  label,
  hint,
  error,
  children,
  className,
}: {
  label: ReactNode;
  hint?: ReactNode;
  error?: ReactNode;
  children: ReactNode;
  className?: string;
}) {
  return (
    <label className={cn('flex flex-col gap-1.5', className)}>
      <span className="text-[12px] font-medium" style={{ color: 'var(--bt-text-dim)' }}>
        {label}
      </span>
      {children}
      {error ? (
        <span className="text-[12px]" style={{ color: 'var(--bt-removed)' }}>
          {error}
        </span>
      ) : hint ? (
        <span className="text-[12px] leading-snug" style={{ color: 'var(--bt-text-faint)' }}>
          {hint}
        </span>
      ) : null}
    </label>
  );
}

export const Input = forwardRef<HTMLInputElement, InputHTMLAttributes<HTMLInputElement> & { mono?: boolean }>(
  function Input({ className, mono, ...rest }, ref) {
    return <input ref={ref} className={cn('bt-input h-8 w-full', mono && 'font-mono text-[12.5px]', className)} {...rest} />;
  },
);

export const Select = forwardRef<HTMLSelectElement, SelectHTMLAttributes<HTMLSelectElement>>(function Select(
  { className, children, ...rest },
  ref,
) {
  return (
    <select ref={ref} className={cn('bt-select h-8 w-full', className)} {...rest}>
      {children}
    </select>
  );
});

/** Textarea that grows with its content up to `maxRows`. */
export const Textarea = forwardRef<
  HTMLTextAreaElement,
  TextareaHTMLAttributes<HTMLTextAreaElement> & { autoGrow?: boolean; maxRows?: number; mono?: boolean }
>(function Textarea({ className, autoGrow, maxRows = 14, mono, value, ...rest }, ref) {
  const inner = useRef<HTMLTextAreaElement>(null);
  useImperativeHandle(ref, () => inner.current as HTMLTextAreaElement);

  useEffect(() => {
    if (!autoGrow || !inner.current) return;
    const el = inner.current;
    el.style.height = 'auto';
    const line = parseFloat(getComputedStyle(el).lineHeight) || 20;
    const max = line * maxRows + 16;
    el.style.height = `${Math.min(el.scrollHeight, max)}px`;
    el.style.overflowY = el.scrollHeight > max ? 'auto' : 'hidden';
  }, [value, autoGrow, maxRows]);

  return (
    <textarea
      ref={inner}
      value={value}
      className={cn('bt-textarea w-full', mono && 'font-mono text-[12.5px]', className)}
      {...rest}
    />
  );
});
