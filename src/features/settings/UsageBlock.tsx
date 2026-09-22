import { useEffect, useMemo, useState, type JSX } from 'react';
import { usage } from '../../lib/ipc';
import type { UsageDay, UsageSummary } from '../../lib/types';
import { PROVIDERS } from '../../providers/registry';
import { Card, Muted, Segment } from './ui';
import { formatCompact, formatCost, formatDayLabel, formatDuration, formatInt } from './format';

type Range = 'today' | '7d' | '30d' | 'all';

const RANGES: { value: Range; label: string }[] = [
  { value: 'today', label: 'Today' },
  { value: '7d', label: '7 days' },
  { value: '30d', label: '30 days' },
  { value: 'all', label: 'All' },
];

/** `undefined` means "no lower bound", which the backend reads as all time. */
function sinceFor(range: Range): string | undefined {
  if (range === 'all') return undefined;
  if (range === 'today') {
    const start = new Date();
    start.setHours(0, 0, 0, 0);
    return start.toISOString();
  }
  const days = range === '7d' ? 7 : 30;
  return new Date(Date.now() - days * 24 * 60 * 60 * 1000).toISOString();
}

function providerName(id: string): string {
  return PROVIDERS.find((p) => p.id === id)?.name ?? id;
}

/** One bar per calendar day, every provider folded together. */
function toDailyTotals(rows: UsageDay[]): { day: string; tokens: number }[] {
  const byDay = new Map<string, number>();
  for (const row of rows) {
    byDay.set(row.day, (byDay.get(row.day) ?? 0) + row.input_tokens + row.output_tokens);
  }
  return [...byDay.entries()]
    .map(([day, tokens]) => ({ day, tokens }))
    .sort((a, b) => a.day.localeCompare(b.day));
}

const CHART_W = 600;
const CHART_H = 90;

function DayChart({ days }: { days: { day: string; tokens: number }[] }): JSX.Element {
  if (days.length === 0) {
    return <p style={{ color: 'var(--bt-text-faint)' }}>No activity in this range.</p>;
  }
  const max = Math.max(1, ...days.map((d) => d.tokens));
  const slot = CHART_W / days.length;
  const barWidth = Math.max(1, Math.min(slot - 2, 28));
  const peak = days.reduce((a, b) => (b.tokens > a.tokens ? b : a), days[0]);

  return (
    <div className="flex flex-col gap-2">
      <svg
        viewBox={`0 0 ${CHART_W} ${CHART_H}`}
        width="100%"
        height={CHART_H}
        preserveAspectRatio="none"
        role="img"
        aria-label={`Tokens per day, peak ${formatInt(peak.tokens)} on ${peak.day}`}
      >
        {days.map((d, i) => {
          const height = d.tokens === 0 ? 1 : Math.max(2, Math.round((d.tokens / max) * CHART_H));
          return (
            <rect
              key={d.day}
              x={i * slot + (slot - barWidth) / 2}
              y={CHART_H - height}
              width={barWidth}
              height={height}
              fill="var(--bt-accent)"
            >
              <title>{`${d.day} · ${formatInt(d.tokens)} tokens`}</title>
            </rect>
          );
        })}
      </svg>
      <div className="flex justify-between" style={{ color: 'var(--bt-text-faint)' }}>
        <span>{formatDayLabel(days[0].day)}</span>
        <span>
          Peak {formatCompact(max)} tokens · {formatDayLabel(peak.day)}
        </span>
        <span>{formatDayLabel(days[days.length - 1].day)}</span>
      </div>
    </div>
  );
}

const COLUMNS: { key: string; label: string; align: 'left' | 'right' }[] = [
  { key: 'provider', label: 'Agent', align: 'left' },
  { key: 'sessions', label: 'Sessions', align: 'right' },
  { key: 'turns', label: 'Turns', align: 'right' },
  { key: 'input', label: 'Input tokens', align: 'right' },
  { key: 'output', label: 'Output tokens', align: 'right' },
  { key: 'cacheRead', label: 'Cache read', align: 'right' },
  { key: 'cacheWrite', label: 'Cache write', align: 'right' },
  { key: 'cost', label: 'Reported cost', align: 'right' },
  { key: 'wall', label: 'Wall time', align: 'right' },
];

export function UsageBlock(): JSX.Element {
  const [range, setRange] = useState<Range>('7d');
  const [summary, setSummary] = useState<UsageSummary[]>([]);
  const [days, setDays] = useState<UsageDay[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    let cancelled = false;
    const since = sinceFor(range);
    setLoading(true);
    Promise.all([usage.summary(since), usage.byDay(since)])
      .then(([rows, dayRows]) => {
        if (cancelled) return;
        setSummary(rows);
        setDays(dayRows);
        setError(null);
      })
      .catch((e: unknown) => {
        if (!cancelled) setError(String(e));
      })
      .finally(() => {
        if (!cancelled) setLoading(false);
      });
    return () => {
      cancelled = true;
    };
  }, [range]);

  const daily = useMemo(() => toDailyTotals(days), [days]);
  const cellStyle = { borderBottom: '1px solid var(--bt-border)' };

  return (
    <div className="flex flex-col gap-4">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <span className="font-medium" style={{ color: 'var(--bt-text)' }}>
          Usage
        </span>
        <Segment value={range} options={RANGES} onChange={setRange} ariaLabel="Usage range" />
      </div>

      <Card>
        {error ? (
          <p style={{ color: 'var(--bt-removed)' }}>Could not read usage — {error}</p>
        ) : loading ? (
          <p style={{ color: 'var(--bt-text-faint)' }}>Reading usage…</p>
        ) : summary.length === 0 ? (
          <p style={{ color: 'var(--bt-text-faint)' }}>
            Nothing recorded in this range yet. Usage appears once an agent reports a turn.
          </p>
        ) : (
          <div className="overflow-x-auto">
            <table className="w-full border-collapse">
              <thead>
                <tr>
                  {COLUMNS.map((col) => (
                    <th
                      key={col.key}
                      className={`px-3 py-2.5 font-medium whitespace-nowrap ${
                        col.align === 'right' ? 'text-right' : 'text-left'
                      }`}
                      style={{ color: 'var(--bt-text-dim)', ...cellStyle }}
                    >
                      {col.label}
                    </th>
                  ))}
                </tr>
              </thead>
              <tbody>
                {summary.map((row) => (
                  <tr key={row.provider_id}>
                    <td className="px-3 py-3 whitespace-nowrap" style={cellStyle}>
                      {providerName(row.provider_id)}
                    </td>
                    <td className="px-3 py-3 text-right" style={cellStyle}>
                      {formatInt(row.sessions)}
                    </td>
                    <td className="px-3 py-3 text-right" style={cellStyle}>
                      {formatInt(row.turns)}
                    </td>
                    <td className="px-3 py-3 text-right" style={cellStyle}>
                      {formatInt(row.input_tokens)}
                    </td>
                    <td className="px-3 py-3 text-right" style={cellStyle}>
                      {formatInt(row.output_tokens)}
                    </td>
                    <td className="px-3 py-3 text-right" style={cellStyle}>
                      {formatInt(row.cache_read)}
                    </td>
                    <td className="px-3 py-3 text-right" style={cellStyle}>
                      {formatInt(row.cache_write)}
                    </td>
                    <td className="px-3 py-3 text-right whitespace-nowrap" style={cellStyle}>
                      {formatCost(row.cost_usd)}
                    </td>
                    <td className="px-3 py-3 text-right whitespace-nowrap" style={cellStyle}>
                      {formatDuration(row.duration_ms)}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </Card>

      <Card>
        <div className="flex flex-col gap-3">
          <span style={{ color: 'var(--bt-text-dim)' }}>Tokens per day</span>
          {loading && daily.length === 0 ? (
            <p style={{ color: 'var(--bt-text-faint)' }}>Reading usage…</p>
          ) : (
            <DayChart days={daily} />
          )}
        </div>
      </Card>

      <Muted>
        Cost is whatever the agent itself reported. On a subscription plan it is informational only —
        it does not mean you were billed that amount.
      </Muted>
    </div>
  );
}
