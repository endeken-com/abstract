/** Local time/date formatting. No date library — these five helpers are the whole need. */

function gap(ms: number): string {
  const seconds = Math.round(ms / 1000);
  if (seconds < 60) return `${seconds}s`;
  const minutes = Math.round(seconds / 60);
  if (minutes < 60) return `${minutes}m`;
  const hours = Math.round(minutes / 60);
  if (hours < 24) return `${hours}h`;
  const days = Math.round(hours / 24);
  if (days < 30) return `${days}d`;
  const months = Math.round(days / 30);
  if (months < 12) return `${months}mo`;
  return `${Math.round(months / 12)}y`;
}

/** `in 2h`, `3d ago`, `just now`. Returns `—` for anything unparseable. */
export function formatRelative(iso: string | null | undefined): string {
  if (!iso) return '—';
  const at = Date.parse(iso);
  if (Number.isNaN(at)) return '—';
  const delta = at - Date.now();
  if (Math.abs(delta) < 45_000) return delta >= 0 ? 'any moment' : 'just now';
  return delta > 0 ? `in ${gap(delta)}` : `${gap(-delta)} ago`;
}

/** `22 Sep, 09:00` in the viewer's own locale and zone. */
export function formatDateTime(iso: string): string {
  const at = Date.parse(iso);
  if (Number.isNaN(at)) return iso;
  return new Date(at).toLocaleString(undefined, {
    month: 'short',
    day: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
  });
}

/** `09:00` — the part of a run row people actually scan. */
export function formatClock(iso: string): string {
  const at = Date.parse(iso);
  if (Number.isNaN(at)) return iso;
  return new Date(at).toLocaleTimeString(undefined, { hour: '2-digit', minute: '2-digit' });
}

export function pad2(n: number): string {
  return n < 10 ? `0${n}` : `${n}`;
}

export function hostTimezone(): string {
  try {
    return Intl.DateTimeFormat().resolvedOptions().timeZone || 'UTC';
  } catch {
    return 'UTC';
  }
}
