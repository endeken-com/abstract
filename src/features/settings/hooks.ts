import { useCallback, useEffect, useRef, useState } from 'react';
import { useApp } from '../../store/app';

/**
 * A text setting edited in place. The field stays responsive while typing and
 * the value lands in the store (and on disk) once typing pauses. Settings is
 * the only editor of these keys, so there is no need to re-sync from the store.
 */
export function useDebouncedSetting(
  key: string,
  fallback: string,
  delay = 400,
): readonly [string, (next: string) => void] {
  const setSetting = useApp((s) => s.setSetting);
  const [value, setValue] = useState<string>(() => {
    const stored = useApp.getState().settings[key];
    return typeof stored === 'string' ? stored : fallback;
  });
  const touched = useRef(false);

  useEffect(() => {
    if (!touched.current) return;
    const id = window.setTimeout(() => void setSetting(key, value), delay);
    return () => window.clearTimeout(id);
  }, [value, key, delay, setSetting]);

  const update = useCallback((next: string) => {
    touched.current = true;
    setValue(next);
  }, []);

  return [value, update] as const;
}

/** `true` unless the setting is explicitly `false` — notification toggles default ON. */
export function useOnByDefault(key: string): readonly [boolean, (next: boolean) => void] {
  const stored = useApp((s) => s.settings[key]);
  const setSetting = useApp((s) => s.setSetting);
  const value = stored !== false;
  const update = useCallback((next: boolean) => void setSetting(key, next), [key, setSetting]);
  return [value, update] as const;
}

export const hostTimezone = (): string => {
  try {
    return Intl.DateTimeFormat().resolvedOptions().timeZone || 'UTC';
  } catch {
    return 'UTC';
  }
};
