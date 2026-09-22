import { cn } from './cn';

const isMac = typeof navigator !== 'undefined' && /Mac|iPhone|iPad/.test(navigator.platform);

/** Renders a shortcut like "mod+k" as ⌘K on macOS and Ctrl K elsewhere. */
export function formatShortcut(shortcut: string): string[] {
  return shortcut.split('+').map((k) => {
    const key = k.trim().toLowerCase();
    if (key === 'mod') return isMac ? '⌘' : 'Ctrl';
    if (key === 'shift') return isMac ? '⇧' : 'Shift';
    if (key === 'alt') return isMac ? '⌥' : 'Alt';
    if (key === 'enter') return '↵';
    if (key === 'esc') return 'Esc';
    if (key === 'up') return '↑';
    if (key === 'down') return '↓';
    return key.length === 1 ? key.toUpperCase() : key;
  });
}

export function Kbd({ shortcut, className }: { shortcut: string; className?: string }) {
  return (
    <span className={cn('inline-flex items-center gap-0.5', className)}>
      {formatShortcut(shortcut).map((k, i) => (
        <kbd
          key={i}
          className="inline-flex h-[18px] min-w-[18px] items-center justify-center rounded-[5px] px-1 font-sans text-[10.5px] font-medium leading-none"
          style={{
            background: 'var(--bt-surface-4)',
            color: 'var(--bt-text-dim)',
            boxShadow: '0 1px 0 rgb(0 0 0 / 0.4), inset 0 1px 0 var(--bt-highlight)',
          }}
        >
          {k}
        </kbd>
      ))}
    </span>
  );
}
