/** Schedule helpers. The backend owns RRULE generation; this only reads one back. */

export type Preset = 'hourly' | 'daily' | 'weekdays' | 'weekly' | 'custom';

export const PRESETS: { value: Preset; label: string }[] = [
  { value: 'hourly', label: 'Hourly' },
  { value: 'daily', label: 'Daily' },
  { value: 'weekdays', label: 'Weekdays' },
  { value: 'weekly', label: 'Weekly' },
  { value: 'custom', label: 'Custom' },
];

const WEEKDAY_SET = 'MO,TU,WE,TH,FR';

function parts(rrule: string): Record<string, string> {
  const map: Record<string, string> = {};
  for (const chunk of rrule.replace(/^RRULE:/i, '').split(';')) {
    const eq = chunk.indexOf('=');
    if (eq <= 0) continue;
    map[chunk.slice(0, eq).trim().toUpperCase()] = chunk.slice(eq + 1).trim().toUpperCase();
  }
  return map;
}

function num(value: string | undefined, fallback: number): number {
  const parsed = Number.parseInt(value ?? '', 10);
  return Number.isFinite(parsed) ? parsed : fallback;
}

/**
 * Best-effort reverse mapping so editing an existing automation lands on the
 * preset that made it. Anything we cannot recognise falls back to Custom, which
 * shows the raw rule rather than silently rewriting it.
 */
export function inferPreset(rrule: string): { preset: Preset; hour: number; minute: number } {
  const map = parts(rrule);
  const hour = num(map.BYHOUR, 9);
  const minute = num(map.BYMINUTE, 0);
  const interval = num(map.INTERVAL, 1);
  const fallback = { preset: 'custom' as Preset, hour, minute };

  if (interval !== 1) return fallback;

  switch (map.FREQ) {
    case 'HOURLY':
      return map.BYDAY ? fallback : { preset: 'hourly', hour, minute };
    case 'DAILY':
      return map.BYDAY ? fallback : { preset: 'daily', hour, minute };
    case 'WEEKLY':
      if (map.BYDAY === WEEKDAY_SET) return { preset: 'weekdays', hour, minute };
      if (!map.BYDAY || !map.BYDAY.includes(',')) return { preset: 'weekly', hour, minute };
      return fallback;
    default:
      return fallback;
  }
}

export const HOURS: number[] = Array.from({ length: 24 }, (_, i) => i);
export const MINUTES: number[] = Array.from({ length: 12 }, (_, i) => i * 5);
