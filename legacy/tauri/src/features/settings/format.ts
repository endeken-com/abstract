/** Tiny formatters. Deliberately local: no date library, no extra dependency. */

/** `252000` -> `4m 12s`. Always at most two units, always plain. */
export function formatDuration(ms: number): string {
  if (!Number.isFinite(ms) || ms <= 0) return '0s';
  const totalSeconds = Math.round(ms / 1000);
  const seconds = totalSeconds % 60;
  const totalMinutes = Math.floor(totalSeconds / 60);
  const minutes = totalMinutes % 60;
  const totalHours = Math.floor(totalMinutes / 60);
  const hours = totalHours % 24;
  const days = Math.floor(totalHours / 24);

  if (days > 0) return hours > 0 ? `${days}d ${hours}h` : `${days}d`;
  if (totalHours > 0) return minutes > 0 ? `${totalHours}h ${minutes}m` : `${totalHours}h`;
  if (totalMinutes > 0) return seconds > 0 ? `${totalMinutes}m ${seconds}s` : `${totalMinutes}m`;
  return `${totalSeconds}s`;
}

/** Thousands separators, so seven-figure token counts stay readable. */
export function formatInt(n: number): string {
  if (!Number.isFinite(n)) return '0';
  return Math.round(n).toLocaleString();
}

/** Compact token counts for the chart caption: `1.2M`, `48.3k`, `912`. */
export function formatCompact(n: number): string {
  if (!Number.isFinite(n)) return '0';
  const abs = Math.abs(n);
  if (abs >= 1_000_000) return `${(n / 1_000_000).toFixed(1)}M`;
  if (abs >= 1_000) return `${(n / 1_000).toFixed(1)}k`;
  return `${Math.round(n)}`;
}

/** Reported cost. Sub-cent totals still deserve a number, not a rounded `$0.00`. */
export function formatCost(n: number): string {
  if (!Number.isFinite(n) || n === 0) return '$0.00';
  if (Math.abs(n) < 0.01) return `$${n.toFixed(4)}`;
  return `$${n.toFixed(2)}`;
}

/** `2026-09-22` -> `Sep 22`, without pulling in a locale-heavy formatter. */
export function formatDayLabel(day: string): string {
  const parsed = Date.parse(day.length === 10 ? `${day}T00:00:00` : day);
  if (Number.isNaN(parsed)) return day;
  return new Date(parsed).toLocaleDateString(undefined, { month: 'short', day: 'numeric' });
}
