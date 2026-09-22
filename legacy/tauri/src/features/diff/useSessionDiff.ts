import { useCallback, useEffect, useRef, useState } from 'react';
import { diff } from '../../lib/ipc';
import type { SessionDiff } from '../../lib/types';
import { errText } from './lib';

export interface SessionDiffState {
  data: SessionDiff | null;
  loading: boolean;
  error: string | null;
  /** Bumped on every successful collect, so views can drop cached contents. */
  revision: number;
  reload: () => Promise<void>;
}

/**
 * Owns `diff.collect` for one session. Every mutation in the feature funnels
 * back through `reload`, so what is on screen is always what git just reported.
 */
export function useSessionDiff(sessionId: string): SessionDiffState {
  const [data, setData] = useState<SessionDiff | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [revision, setRevision] = useState(0);

  const liveRef = useRef(true);
  const seqRef = useRef(0);

  useEffect(() => {
    liveRef.current = true;
    return () => {
      liveRef.current = false;
    };
  }, []);

  const reload = useCallback(async () => {
    const seq = ++seqRef.current;
    setLoading(true);
    try {
      const next = await diff.collect(sessionId);
      if (!liveRef.current || seq !== seqRef.current) return;
      setData(next);
      setError(null);
      setRevision((r) => r + 1);
    } catch (e) {
      if (!liveRef.current || seq !== seqRef.current) return;
      setError(errText(e));
    } finally {
      if (liveRef.current && seq === seqRef.current) setLoading(false);
    }
  }, [sessionId]);

  useEffect(() => {
    setData(null);
    setError(null);
    void reload();
  }, [reload]);

  return { data, loading, error, revision, reload };
}
