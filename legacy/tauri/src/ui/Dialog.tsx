import * as D from '@radix-ui/react-dialog';
import { AnimatePresence, motion } from 'motion/react';
import type { ReactNode } from 'react';
import { X } from 'lucide-react';
import { cn } from './cn';

/**
 * Centered dialog with a soft scale-and-fade entrance. Controlled: the parent
 * decides `open` and gets `onOpenChange`.
 */
export function Dialog({
  open,
  onOpenChange,
  title,
  description,
  children,
  footer,
  width = 560,
  className,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  title: ReactNode;
  description?: ReactNode;
  children: ReactNode;
  footer?: ReactNode;
  width?: number;
  className?: string;
}) {
  return (
    <D.Root open={open} onOpenChange={onOpenChange}>
      <AnimatePresence>
        {open ? (
          <D.Portal forceMount>
            <D.Overlay asChild forceMount>
              <motion.div
                className="fixed inset-0 z-50"
                style={{ background: 'rgb(0 0 0 / 0.55)', backdropFilter: 'blur(3px)' }}
                initial={{ opacity: 0 }}
                animate={{ opacity: 1 }}
                exit={{ opacity: 0 }}
                transition={{ duration: 0.16 }}
              />
            </D.Overlay>
            <D.Content asChild forceMount aria-describedby={description ? undefined : undefined}>
              <motion.div
                className={cn(
                  'fixed left-1/2 top-[14vh] z-50 flex max-h-[76vh] -translate-x-1/2 flex-col overflow-hidden rounded-[16px] outline-none',
                  className,
                )}
                style={{ width, maxWidth: 'calc(100vw - 32px)', background: 'var(--bt-elevated)', boxShadow: 'var(--bt-shadow-lg)' }}
                initial={{ opacity: 0, y: 8, scale: 0.975 }}
                animate={{ opacity: 1, y: 0, scale: 1 }}
                exit={{ opacity: 0, y: 4, scale: 0.985 }}
                transition={{ type: 'spring', stiffness: 520, damping: 38, mass: 0.8 }}
              >
                <div className="flex items-start gap-3 px-5 pt-4 pb-3">
                  <div className="min-w-0 flex-1">
                    <D.Title className="m-0 text-[14.5px] font-semibold tracking-[-0.01em]" style={{ color: 'var(--bt-text)' }}>
                      {title}
                    </D.Title>
                    {description ? (
                      <D.Description className="mt-0.5 text-[12.5px]" style={{ color: 'var(--bt-text-faint)' }}>
                        {description}
                      </D.Description>
                    ) : (
                      <D.Description className="sr-only">{typeof title === 'string' ? title : 'Dialog'}</D.Description>
                    )}
                  </div>
                  <D.Close
                    aria-label="Close"
                    className="-mr-1 inline-flex h-7 w-7 items-center justify-center rounded-[7px] text-[var(--bt-text-faint)] transition-colors hover:bg-[var(--bt-hover)] hover:text-[var(--bt-text)]"
                  >
                    <X size={15} />
                  </D.Close>
                </div>
                <div className="min-h-0 flex-1 overflow-y-auto px-5 pb-5">{children}</div>
                {footer ? (
                  <div
                    className="flex items-center justify-end gap-2 px-5 py-3"
                    style={{ borderTop: '1px solid var(--bt-border)', background: 'var(--bt-surface)' }}
                  >
                    {footer}
                  </div>
                ) : null}
              </motion.div>
            </D.Content>
          </D.Portal>
        ) : null}
      </AnimatePresence>
    </D.Root>
  );
}
