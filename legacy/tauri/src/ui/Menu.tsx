import * as M from '@radix-ui/react-dropdown-menu';
import type { ReactNode } from 'react';
import { cn } from './cn';
import { Kbd } from './Kbd';

const panel =
  'z-[90] min-w-[190px] overflow-hidden rounded-[11px] p-1 text-[13px] outline-none bt-menu';

export function Menu({
  trigger,
  children,
  align = 'end',
  side = 'bottom',
}: {
  trigger: ReactNode;
  children: ReactNode;
  align?: 'start' | 'center' | 'end';
  side?: 'top' | 'bottom' | 'left' | 'right';
}) {
  return (
    <M.Root>
      <M.Trigger asChild>{trigger}</M.Trigger>
      <M.Portal>
        <M.Content
          align={align}
          side={side}
          sideOffset={6}
          className={panel}
          style={{ background: 'var(--bt-elevated)', boxShadow: 'var(--bt-shadow-lg)', backdropFilter: 'blur(12px)' }}
        >
          {children}
        </M.Content>
      </M.Portal>
    </M.Root>
  );
}

export function MenuItem({
  icon,
  children,
  shortcut,
  onSelect,
  danger,
  disabled,
}: {
  icon?: ReactNode;
  children: ReactNode;
  shortcut?: string;
  onSelect?: () => void;
  danger?: boolean;
  disabled?: boolean;
}) {
  return (
    <M.Item
      disabled={disabled}
      onSelect={onSelect}
      className={cn(
        'flex h-8 cursor-default select-none items-center gap-2.5 rounded-[7px] px-2 outline-none',
        'data-[highlighted]:bg-[var(--bt-active)] data-[disabled]:opacity-40',
        danger ? 'text-[var(--bt-removed)]' : 'text-[var(--bt-text)]',
      )}
    >
      {icon ? <span className={cn('flex w-4 justify-center', !danger && 'text-[var(--bt-text-dim)]')}>{icon}</span> : null}
      <span className="flex-1">{children}</span>
      {shortcut ? <Kbd shortcut={shortcut} /> : null}
    </M.Item>
  );
}

export function MenuSeparator() {
  return <M.Separator className="my-1 h-px" style={{ background: 'var(--bt-border)' }} />;
}

export function MenuLabel({ children }: { children: ReactNode }) {
  return (
    <M.Label className="px-2 pt-1.5 pb-1 text-[11px] font-medium" style={{ color: 'var(--bt-text-faint)' }}>
      {children}
    </M.Label>
  );
}
