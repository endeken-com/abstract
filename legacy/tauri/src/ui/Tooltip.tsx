import * as T from '@radix-ui/react-tooltip';
import type { ReactNode } from 'react';
import { Kbd } from './Kbd';

export function TooltipProvider({ children }: { children: ReactNode }) {
  return (
    <T.Provider delayDuration={350} skipDelayDuration={150}>
      {children}
    </T.Provider>
  );
}

export function Tooltip({
  label,
  shortcut,
  side = 'bottom',
  children,
}: {
  label: ReactNode;
  shortcut?: string;
  side?: 'top' | 'bottom' | 'left' | 'right';
  children: ReactNode;
}) {
  return (
    <T.Root>
      <T.Trigger asChild>{children}</T.Trigger>
      <T.Portal>
        <T.Content
          side={side}
          sideOffset={6}
          className="bt-tooltip z-[100] flex items-center gap-2 rounded-[7px] px-2 py-1 text-[12px]"
          style={{
            background: 'var(--bt-surface-4)',
            color: 'var(--bt-text)',
            boxShadow: 'var(--bt-shadow-lg)',
          }}
        >
          {label}
          {shortcut ? <Kbd shortcut={shortcut} /> : null}
        </T.Content>
      </T.Portal>
    </T.Root>
  );
}
