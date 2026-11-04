import AsyncStorage from '@react-native-async-storage/async-storage';
import { useEffect, useState } from 'react';

// The theme the Mac draws in, as colours (ABS-185). Themes are plugins on the
// Mac; the phone runs none of their code (ABS-84 §6), it only takes the derived
// palette the snapshot carries, keyed by Abstract's palette roles
// (Packages/AbstractCore/Sources/AbstractCore/Theme/ThemePalette.swift).

export type ThemeTokens = Record<string, string>;
export type RemoteTheme = { id: string; name: string; appearance: 'light' | 'dark'; tokens: ThemeTokens };
export type RemoteTheming = { followsSystem: boolean; light: RemoteTheme; dark: RemoteTheme };

// Graphite (Abstract/Resources/Plugins/theme-graphite.abstractplugin), until a Mac says otherwise.
export const graphite: RemoteTheme = {
  id: 'sh.abstract.theme.graphite/theme/graphite', name: 'Graphite', appearance: 'dark',
  tokens: {"accent": "#ececef", "added": "#4cc38a", "addedWash": "#4cc38a1a", "attention": "#f2f2f4", "border": "#ffffff13", "borderStrong": "#ffffff1f", "canvas": "#1e1e21", "code": "#18181b", "field": "#232327", "fieldBorder": "#ffffff1c", "fieldBorderFocused": "#ffffff57", "findCurrent": "#e2c0448c", "findMatch": "#ffffff29", "hover": "#ffffff0d", "inset": "#303036", "onAccent": "#1e1e21", "prose": "#dcdce1", "pullRequestClosed": "#da3633", "pullRequestClosedInk": "#f08a84", "pullRequestDraft": "#6e7681", "pullRequestDraftInk": "#a0a8b2", "pullRequestMerged": "#8957e5", "pullRequestMergedInk": "#b79cf0", "pullRequestOpen": "#238636", "pullRequestOpenInk": "#6bc98a", "removed": "#ef6461", "removedWash": "#ef64611a", "selection": "#ffffff16", "sidebar": "#19191c", "surface": "#252529", "surfaceRaised": "#2b2b30", "syntaxComment": "#5c6370", "syntaxFunction": "#61afef", "syntaxKeyword": "#c678dd", "syntaxLiteral": "#d19a66", "syntaxOperator": "#56b6c2", "syntaxPlain": "#abb2bf", "syntaxString": "#98c379", "syntaxTag": "#e06c75", "syntaxType": "#e5c07b", "terminalBlack": "#3e3e46", "terminalBlue": "#5b9cf6", "terminalBrightBlack": "#74747e", "terminalBrightBlue": "#88b9ff", "terminalBrightCyan": "#7dd8de", "terminalBrightGreen": "#72dba6", "terminalBrightMagenta": "#d8a8f8", "terminalBrightRed": "#ff8a86", "terminalBrightWhite": "#f4f4f6", "terminalBrightYellow": "#f5c26b", "terminalCyan": "#4ebfc7", "terminalGreen": "#4cc38a", "terminalMagenta": "#c080e8", "terminalRed": "#ef6461", "terminalWhite": "#c8c8ce", "terminalYellow": "#e5a33a", "text": "#ececef", "textSecondary": "#a4a4ad", "textTertiary": "#75757e", "usageClaude": "#d97757", "usageCodex": "#8e9db5", "usageMuse": "#b49bdb", "usageOpenCode": "#6fc2ab", "warning": "#d2d2d8"},
};

const HEX = /^#(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$/;

function validTheme(value: any): value is RemoteTheme {
  return !!value && typeof value.id === 'string' && typeof value.name === 'string'
    && (value.appearance === 'light' || value.appearance === 'dark')
    && !!value.tokens && typeof value.tokens === 'object'
    && Object.values(value.tokens).every(color => typeof color === 'string' && HEX.test(color));
}

/** The side of a Mac's theming the phone draws in: Match System follows the
 * phone's own appearance, a named theme is both sides. Anything unreadable is Graphite. */
export function pickTheme(theming: RemoteTheming | null | undefined, scheme: string | null | undefined): RemoteTheme {
  if (!theming) return graphite;
  const side = theming.followsSystem && scheme === 'light' ? theming.light : theming.dark;
  if (!validTheme(side)) return graphite;
  // A role the Mac didn't send (an older Mac, a newer role) keeps Graphite's.
  return { ...side, tokens: { ...graphite.tokens, ...side.tokens } };
}

/** The theming of the first paired Mac that sends one. */
export function themingOf(macs: Array<{ snapshot?: { theme?: RemoteTheming } | null }>): RemoteTheming | null {
  return macs.find(mac => mac.snapshot?.theme)?.snapshot?.theme || null;
}

const STORAGE_KEY = 'abstract.theme.v1';
let current: RemoteTheme = graphite;
let version = 0;
const listeners = new Set<() => void>();

export function theme(): RemoteTheme { return current; }
export function isDarkTheme(): boolean { return current.appearance === 'dark'; }

function same(a: RemoteTheme, b: RemoteTheme) {
  return a.id === b.id && a.appearance === b.appearance && JSON.stringify(a.tokens) === JSON.stringify(b.tokens);
}

/** Draws in `next` from now on; screens redraw. Returns whether it changed. */
export function setTheme(next: RemoteTheme, persist = true): boolean {
  if (same(current, next)) return false;
  current = next;
  version += 1;
  if (persist) AsyncStorage.setItem(STORAGE_KEY, JSON.stringify(next)).catch(() => {});
  listeners.forEach(listener => listener());
  return true;
}

/** The theme last seen, so the phone opens in it before any Mac answers. */
export async function loadTheme() {
  try {
    const saved = JSON.parse((await AsyncStorage.getItem(STORAGE_KEY)) || 'null');
    if (validTheme(saved)) setTheme(pickTheme({ followsSystem: false, light: saved, dark: saved }, null), false);
  } catch {}
}

/** Calls `apply` with the colours now and on every change: how a screen
 * keeps its module-level colour names current. */
export function onTheme(apply: (tokens: ThemeTokens, theme: RemoteTheme) => void) {
  apply(current.tokens, current);
  const listener = () => apply(current.tokens, current);
  listeners.add(listener);
  return () => { listeners.delete(listener); };
}

/** A style sheet rebuilt the first time it's read after the theme changes. */
export function themedStyles<T extends object>(make: () => T): T {
  let made: T | null = null, madeAt = -1;
  const sheet = () => { if (madeAt !== version || !made) { made = make(); madeAt = version; } return made; };
  return new Proxy({} as T, { get: (_, key) => (sheet() as any)[key] });
}

/** Rerenders the caller when the theme changes; returns its version. */
export function useThemeVersion(): number {
  const [seen, setSeen] = useState(version);
  useEffect(() => {
    const listener = () => setSeen(version);
    listeners.add(listener);
    setSeen(version);
    return () => { listeners.delete(listener); };
  }, []);
  return seen;
}

/** The current theme's colours by role, read when used: `palette.text`. */
export const palette: ThemeTokens = new Proxy({} as ThemeTokens, { get: (_, role) => current.tokens[role as string] });
