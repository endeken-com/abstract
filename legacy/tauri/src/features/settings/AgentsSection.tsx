import { useCallback, useEffect, useRef, useState, type JSX } from 'react';
import { useApp } from '../../store/app';
import type { ProviderStatus } from '../../lib/types';
import { PROVIDERS } from '../../providers/registry';
import { Card, Dot, Field, Muted, Section } from './ui';
import { UsageBlock } from './UsageBlock';

type Override = { path?: string; extraArgs?: string[]; policy?: string };

/** Space-separated in the field, an array in the setting. */
function parseArgs(text: string): string[] {
  return text.split(/\s+/).filter((part) => part.length > 0);
}

/**
 * Reads the freshest `provider_overrides` at write time and puts the whole
 * object back, so two providers edited in the same breath cannot clobber each
 * other — and `policy`, which this screen does not edit, survives untouched.
 */
function writeOverride(providerId: string, patch: Override): void {
  const store = useApp.getState();
  const current: Record<string, Override> = store.settings.provider_overrides ?? {};
  const merged: Override = { ...current[providerId], ...patch };
  if (!merged.path) delete merged.path;
  if (!merged.extraArgs || merged.extraArgs.length === 0) delete merged.extraArgs;

  const next: Record<string, Override> = { ...current };
  if (Object.keys(merged).length === 0) delete next[providerId];
  else next[providerId] = merged;

  void store.setSetting('provider_overrides', next);
}

function DetectionLine({ status }: { status: ProviderStatus | undefined }): JSX.Element {
  if (!status) {
    return (
      <div className="flex items-center gap-2" style={{ color: 'var(--bt-text-faint)' }}>
        <Dot tone="off" />
        <span>Checking…</span>
      </div>
    );
  }
  if (!status.available) {
    return (
      <div className="flex items-center gap-2">
        <Dot tone="off" />
        <span style={{ color: 'var(--bt-text-dim)' }}>Not found on PATH</span>
      </div>
    );
  }
  return (
    <div className="flex flex-wrap items-center gap-x-3 gap-y-1">
      <span className="flex items-center gap-2">
        <Dot tone="ok" />
        <span style={{ color: 'var(--bt-text)' }}>Found</span>
      </span>
      {status.path ? (
        <span className="font-mono break-all" style={{ color: 'var(--bt-text-dim)', fontSize: 'var(--bt-code-size)' }}>
          {status.path}
        </span>
      ) : null}
      {status.version ? (
        <span style={{ color: 'var(--bt-text-faint)' }}>version {status.version}</span>
      ) : null}
    </div>
  );
}

function ProviderBlock({
  providerId,
  providerName,
}: {
  providerId: string;
  providerName: string;
}): JSX.Element {
  const status = useApp((s) => s.providerStatus[providerId]);
  const initial = useRef<Override>(
    useApp.getState().settings.provider_overrides?.[providerId] ?? {},
  );
  const [pathText, setPathText] = useState(initial.current.path ?? '');
  const [argsText, setArgsText] = useState((initial.current.extraArgs ?? []).join(' '));
  const touched = useRef(false);

  useEffect(() => {
    if (!touched.current) return;
    const id = window.setTimeout(
      () => writeOverride(providerId, { path: pathText.trim(), extraArgs: parseArgs(argsText) }),
      400,
    );
    return () => window.clearTimeout(id);
  }, [pathText, argsText, providerId]);

  const edit = useCallback((setter: (v: string) => void) => {
    return (value: string) => {
      touched.current = true;
      setter(value);
    };
  }, []);

  return (
    <Card>
      <div className="flex flex-col gap-5">
        <div className="flex flex-col gap-1.5">
          <div className="flex items-baseline gap-3">
            <span className="font-medium" style={{ color: 'var(--bt-text)' }}>
              {providerName}
            </span>
            <span className="font-mono" style={{ color: 'var(--bt-text-faint)', fontSize: 'var(--bt-code-size)' }}>
              {providerId}
            </span>
          </div>
          <DetectionLine status={status} />
        </div>

        <Field
          label="Binary path override"
          hint="Leave empty to use whatever is on PATH. Point this at a specific build when you need one."
        >
          <input
            className="w-full font-mono"
            style={{ fontSize: 'var(--bt-code-size)' }}
            spellCheck={false}
            value={pathText}
            placeholder={status?.path ?? `/usr/local/bin/${providerId}`}
            onChange={(e) => edit(setPathText)(e.target.value)}
          />
        </Field>

        <Field
          label="Extra CLI arguments"
          hint="Space separated. Appended to every launch of this agent, including automation runs."
        >
          <input
            className="w-full font-mono"
            style={{ fontSize: 'var(--bt-code-size)' }}
            spellCheck={false}
            value={argsText}
            placeholder="--model opus --verbose"
            onChange={(e) => edit(setArgsText)(e.target.value)}
          />
        </Field>
      </div>
    </Card>
  );
}

export function AgentsSection(): JSX.Element {
  return (
    <Section
      title="Agents"
      lead="Abstract drives whichever agent CLIs it can find. Detection runs at startup; the overrides below win over it."
    >
      {PROVIDERS.map((provider) => (
        <ProviderBlock key={provider.id} providerId={provider.id} providerName={provider.name} />
      ))}

      <Muted>Overrides take effect on the next session or automation run — running agents keep their current command line.</Muted>

      <UsageBlock />
    </Section>
  );
}
