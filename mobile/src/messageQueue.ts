import type { PendingPhoneMessage } from './chatSending';
import type { QueuedMessage, Session, Snapshot } from './types';

// Messages sent while the agent works (ABS-103), as the Mac keeps them
// (Abstract/App/AppModel+Queue.swift). The Mac decides whether a message
// waits: mid-turn, `send` queues it, and the queue goes as one message when
// the turn ends. The phone shows the queue and offers Steer and Interrupt.

const providerNames: Record<string, string> = { codex: 'Codex', claude: 'Claude Code', opencode: 'OpenCode', muse: 'Muse Code' };
const midTurn = ['running', 'provisioning', 'waiting_input'];

export const queuedMessages = (snapshot: Snapshot | null | undefined, chatId: string): QueuedMessage[] =>
  snapshot?.queuedMessages?.[chatId] ?? [];

export type ComposerActions = {
  // The round button: send now, queue for the turn's end, or stop the turn.
  primary: 'send' | 'queue' | 'stop';
  // Shown when there's something to send mid-turn; `reason` says why it's greyed out.
  steer: { enabled: boolean; reason: string | null } | null;
  interrupt: boolean;
  // Waiting messages, and whether they go when the turn ends or with your next Send.
  queueCaption: string | null;
};

// What the composer offers. A Mac too old to queue keeps Stop while the agent runs.
export function composerActions(snapshot: Snapshot | null | undefined, chat: Session, hasDraft: boolean): ComposerActions {
  const queue = queuedMessages(snapshot, chat.id);
  if (snapshot?.messageQueue !== true) {
    return { primary: chat.status === 'running' ? 'stop' : 'send', steer: null, interrupt: false, queueCaption: null };
  }
  const working = midTurn.includes(chat.status);
  if (!working) {
    return { primary: 'send', steer: null, interrupt: false,
      queueCaption: queue.length ? 'Not sent yet. Send them now with your next message, or remove them.' : null };
  }
  const pending = hasDraft || queue.length > 0;
  const steerable = (snapshot.steerAgents ?? []).includes(chat.providerId);
  const alive = snapshot.alive.includes(chat.id);
  return {
    primary: hasDraft ? 'queue' : 'stop',
    steer: pending ? {
      enabled: steerable && alive && chat.status !== 'provisioning',
      reason: steerable ? null : `${providerNames[chat.providerId] || chat.providerId} reads messages between turns`,
    } : null,
    interrupt: pending,
    queueCaption: queue.length ? 'Sent together when this turn ends.' : null,
  };
}

// Messages sent from here that now wait in the Mac's queue: the queue shows
// them from then on, so their "Sending…" bubbles can go. Each queued message
// settles at most one.
export function settledByQueue(pending: PendingPhoneMessage[], queue: QueuedMessage[]): string[] {
  const used = new Set<string>();
  const settled: string[] = [];
  for (const message of pending) {
    if (message.status !== 'accepted') continue;
    const found = queue.find(item => !used.has(item.id) && item.text.trim() === message.text.trim()
      && item.attachments.length === message.attachments.length);
    if (!found) continue;
    used.add(found.id);
    settled.push(message.id);
  }
  return settled;
}
