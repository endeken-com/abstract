// The one place a chat says its Mac isn't connected: the top edge of the
// composer, with what you can do about it.
export type ConnectionNotice = {
  tone: 'connecting' | 'offline';
  title: string;
  detail: string | null;
  action: 'retry' | 'settings' | null;
};

export function lastSeenText(lastSeenAt: number | null | undefined, now: number): string | null {
  if (lastSeenAt == null) return null;
  const minutes = Math.floor(Math.max(0, now - lastSeenAt) / 60_000);
  if (minutes < 1) return 'Last seen just now.';
  if (minutes < 60) return `Last seen ${minutes} min ago.`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `Last seen ${hours} h ago.`;
  return `Last seen ${new Date(lastSeenAt).toLocaleDateString()}.`;
}

export function connectionNotice({ status, unreachable, macName, lastSeenAt, error, now }: {
  status: string;
  unreachable: boolean;
  macName?: string | null;
  lastSeenAt?: number | null;
  error?: string | null;
  now: number;
}): ConnectionNotice | null {
  if (status === 'online') return null;
  // The chat's Mac is no longer paired: nothing to retry until one is.
  if (!macName) return { tone: 'offline', title: 'Not connected to a Mac', detail: 'Pair one in Settings to send. Your draft stays here.', action: 'settings' };
  if (status === 'connecting' || status === 'pairing' || !unreachable) return { tone: 'connecting', title: `Connecting to ${macName}…`, detail: null, action: null };
  const reason = error?.replace(/^Error:\s*/, '').trim();
  const detail = [lastSeenText(lastSeenAt, now), reason && /[.!?]$/.test(reason) ? reason : reason ? `${reason}.` : null, 'Your draft stays here.'].filter(Boolean).join(' ');
  return { tone: 'offline', title: `${macName} isn't reachable`, detail, action: 'retry' };
}
