import { useRef, useState } from 'react';
import { ArrowUp, GitBranch, Square } from 'lucide-react';
import { motion } from 'motion/react';
import { Kbd, Spinner, Textarea, Tooltip, cn } from '../../ui';

/**
 * The reply box: grows with its content, Enter sends, Shift+Enter breaks the
 * line, and the round button turns into Stop while the agent is working.
 */
export function Composer({
  providerName,
  branch,
  working,
  disabled,
  onSend,
  onStop,
}: {
  providerName: string;
  branch: string | null;
  working: boolean;
  disabled?: boolean;
  onSend: (text: string) => Promise<void>;
  onStop: () => Promise<void>;
}) {
  const [draft, setDraft] = useState('');
  const [sending, setSending] = useState(false);
  const [focused, setFocused] = useState(false);
  const ref = useRef<HTMLTextAreaElement>(null);
  const canSend = draft.trim().length > 0 && !sending && !disabled;

  async function send() {
    if (!canSend) return;
    const text = draft.trim();
    setDraft('');
    setSending(true);
    try {
      await onSend(text);
    } catch (e) {
      setDraft(text);
      throw e;
    } finally {
      setSending(false);
      ref.current?.focus();
    }
  }

  return (
    <div className="shrink-0 px-8 pb-5 pt-2">
      <motion.div
        animate={{
          boxShadow: focused
            ? '0 0 0 1px var(--bt-accent-line), 0 0 0 4px var(--bt-accent-soft), 0 16px 40px -16px rgb(0 0 0 / 0.8)'
            : '0 0 0 1px var(--bt-border-strong), 0 16px 40px -16px rgb(0 0 0 / 0.8)',
        }}
        transition={{ duration: 0.18 }}
        className="mx-auto w-full max-w-[780px] rounded-[16px]"
        style={{ background: 'var(--bt-elevated)' }}
        onClick={() => ref.current?.focus()}
      >
        <Textarea
          ref={ref}
          autoGrow
          maxRows={12}
          rows={1}
          value={draft}
          disabled={disabled}
          onFocus={() => setFocused(true)}
          onBlur={() => setFocused(false)}
          onChange={(e) => setDraft(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === 'Enter' && !e.shiftKey && !e.nativeEvent.isComposing) {
              e.preventDefault();
              void send();
            }
          }}
          placeholder={disabled ? 'This chat has no agent attached' : `Reply to ${providerName}…`}
          className="!border-0 !bg-transparent !shadow-none px-4 pt-3.5 pb-1 text-[13.5px]"
        />
        <div className="flex items-center gap-2 px-3 pb-2.5 pt-1">
          {branch ? (
            <span className="inline-flex h-6 items-center gap-1.5 rounded-[6px] px-2 font-mono text-[11px]" style={{ background: 'var(--bt-surface-3)', color: 'var(--bt-text-faint)' }}>
              <GitBranch size={11} />
              {branch}
            </span>
          ) : null}
          <span className="flex-1" />
          <span className="hidden items-center gap-1.5 text-[11px] sm:flex" style={{ color: 'var(--bt-text-ghost)' }}>
            <Kbd shortcut="enter" /> send
            <span className="mx-1">·</span>
            <Kbd shortcut="shift+enter" /> new line
          </span>
          {working ? (
            <Tooltip label="Stop the agent">
              <button
                onClick={(e) => {
                  e.stopPropagation();
                  void onStop();
                }}
                aria-label="Stop"
                className="inline-flex h-8 w-8 items-center justify-center rounded-full transition-transform active:scale-90"
                style={{ background: 'var(--bt-text)', color: 'var(--bt-bg)' }}
              >
                <Square size={11} fill="currentColor" />
              </button>
            </Tooltip>
          ) : (
            <button
              onClick={(e) => {
                e.stopPropagation();
                void send();
              }}
              disabled={!canSend}
              aria-label="Send"
              className={cn(
                'inline-flex h-8 w-8 items-center justify-center rounded-full transition-[transform,background,opacity] duration-150 active:scale-90',
                !canSend && 'opacity-35',
              )}
              style={{
                background: canSend ? 'var(--bt-accent)' : 'var(--bt-surface-4)',
                color: canSend ? 'var(--bt-accent-fg)' : 'var(--bt-text-dim)',
                boxShadow: canSend ? 'inset 0 1px 0 rgb(255 255 255 / 0.25)' : undefined,
              }}
            >
              {sending ? <Spinner size={13} /> : <ArrowUp size={15} strokeWidth={2.4} />}
            </button>
          )}
        </div>
      </motion.div>
    </div>
  );
}
