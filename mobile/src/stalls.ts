import type { Stall } from './types';

// A working chat gone quiet, as its Mac's stall watch reads it
// (Packages/AbstractCore/Sources/AbstractCore/Sessions/StallWatch.swift).
// The snapshot carries the state; the phone only words it — the thresholds
// and the one notification stay on the Mac. Dates are Swift reference
// dates, in seconds.

// Whole minutes without output, for "No output for 5 min".
export const stallMinutes = (stall: Stall, now: number) => Math.max(0, Math.floor((now - stall.since) / 60));

// The chat's working line, as the Mac words it.
export const stallText = (stall: Stall, now: number) => stall.state === 'stalled'
  ? `Stalled — no output for ${stallMinutes(stall, now)} min`
  : `No output for ${stallMinutes(stall, now)} min`;

// The list row's second line: stalled is the whole word, as in the Mac's sidebar.
export const stallRowText = (stall: Stall, now: number) => stall.state === 'stalled'
  ? 'Stalled'
  : `No output for ${stallMinutes(stall, now)} min`;
