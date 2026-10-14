import type { PickedAttachment } from './attachments';
import type { RemoteLine } from './types';

export type PhoneDraft = { text: string; attachments: PickedAttachment[] };
export type PendingPhoneMessage = PhoneDraft & { id: string; afterSeq: number; status: 'sending' | 'accepted' };

// The lock changes before the request starts, so two taps in the same render
// cannot send the same draft twice.
export async function sendPhoneDraft(
  lock: { current: boolean },
  draft: PhoneDraft,
  request: () => Promise<unknown>,
  onStart: () => void,
  onAccepted: () => void,
  onFailed: (error: unknown) => void,
): Promise<boolean> {
  if (lock.current || (!draft.text.trim() && !draft.attachments.length)) return false;
  lock.current = true;
  onStart();
  try {
    await request();
    lock.current = false;
    onAccepted();
    return true;
  } catch (error) {
    lock.current = false;
    onFailed(error);
    return false;
  }
}

function attribute(value: string) {
  return value.replace(/&/g, '&amp;').replace(/"/g, '&quot;');
}

function matches(message: PendingPhoneMessage, raw: string) {
  const text = message.text.trim();
  if (!message.attachments.length) return raw === text;
  if (text && !raw.startsWith(`${text}\n\n<attachment `)) return false;
  if (!text && !raw.startsWith('<attachment ')) return false;
  return message.attachments.every(item => {
    const label = item.reference ? `${item.reference} ${item.title}` : item.title;
    return raw.includes(`<attachment kind="${item.kind}" label="${attribute(label)}"`);
  });
}

// Consume each Mac user line at most once, including when two accepted drafts
// have identical text and their transcript events arrive together.
export function visiblePhoneMessages(pending: PendingPhoneMessage[], lines: RemoteLine[]): PendingPhoneMessage[] {
  const userLines = lines.filter(line => line.line.stream === 'user');
  const used = new Set<number>();
  return pending.filter(message => {
    const found = userLines.find(line => line.seq > message.afterSeq && !used.has(line.seq) && matches(message, line.line.line));
    if (!found) return true;
    used.add(found.seq);
    return false;
  });
}
