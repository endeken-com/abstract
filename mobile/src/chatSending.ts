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

// Queued messages go joined into one, a blank line apart (ABS-103), so a
// message may be any part of the line the Mac logs.
function joinedPart(raw: string, text: string) {
  return raw.startsWith(`${text}\n\n`) || raw.endsWith(`\n\n${text}`) || raw.includes(`\n\n${text}\n\n`);
}

// 'whole': the line is this message alone, so it settles no other; 'part':
// the line joins it with other queued messages, which it settles too.
function matches(message: PendingPhoneMessage, raw: string): 'whole' | 'part' | null {
  const text = message.text.trim();
  if (!message.attachments.length) return raw === text ? 'whole' : text && joinedPart(raw, text) ? 'part' : null;
  const whole = text ? raw.startsWith(`${text}\n\n<attachment `) : raw.startsWith('<attachment ');
  const part = !whole && !!text && raw.includes(`\n\n${text}\n\n`);
  if (!whole && !part) return null;
  const attached = message.attachments.every(item => {
    const label = item.reference ? `${item.reference} ${item.title}` : item.title;
    return raw.includes(`<attachment kind="${item.kind}" label="${attribute(label)}"`);
  });
  return !attached ? null : whole ? 'whole' : 'part';
}

// Consume each Mac user line at most once, including when two accepted drafts
// have identical text and their transcript events arrive together. A line
// that joins queued messages settles each of them.
export function visiblePhoneMessages(pending: PendingPhoneMessage[], lines: RemoteLine[]): PendingPhoneMessage[] {
  const userLines = lines.filter(line => line.line.stream === 'user');
  const used = new Set<number>();
  return pending.filter(message => {
    for (const line of userLines) {
      if (line.seq <= message.afterSeq || used.has(line.seq)) continue;
      const match = matches(message, line.line.line);
      if (!match) continue;
      if (match === 'whole') used.add(line.seq);
      return false;
    }
    return true;
  });
}
