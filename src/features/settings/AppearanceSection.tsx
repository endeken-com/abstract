import { useEffect, useState, type JSX } from 'react';
import { useApp } from '../../store/app';
import { Card, Field, Muted, Section, Segment } from './ui';

/**
 * The only hardcoded colours in the feature: they are the values being chosen,
 * not the palette the UI is painted with.
 */
const ACCENT_PRESETS: { hex: string; name: string }[] = [
  { hex: '#ff5f1f', name: 'Ember' },
  { hex: '#e5484d', name: 'Signal' },
  { hex: '#d29922', name: 'Amber' },
  { hex: '#3fb950', name: 'Moss' },
  { hex: '#3b82f6', name: 'Cobalt' },
  { hex: '#a855f7', name: 'Iris' },
];

const DEFAULT_ACCENT = '#ff5f1f';
const HEX = /^#[0-9a-fA-F]{6}$/;

function AccentPicker(): JSX.Element {
  const accent = useApp((s) => s.settings.accent) ?? DEFAULT_ACCENT;
  const setSetting = useApp((s) => s.setSetting);
  const [text, setText] = useState(accent);

  useEffect(() => {
    setText(accent);
  }, [accent]);

  const valid = HEX.test(text);

  return (
    <Field
      label="Accent colour"
      hint="Used for active state and anything that needs you. Exactly one colour carries that job."
    >
      <div className="flex flex-col gap-3">
        <div className="flex flex-wrap gap-2">
          {ACCENT_PRESETS.map((preset) => {
            const active = preset.hex.toLowerCase() === accent.toLowerCase();
            return (
              <button
                key={preset.hex}
                type="button"
                title={preset.name}
                aria-label={preset.name}
                aria-pressed={active}
                onClick={() => void setSetting('accent', preset.hex)}
                className="flex items-center gap-2 px-2.5 py-1.5"
                style={{
                  background: active ? 'var(--bt-surface-3)' : 'var(--bt-surface-2)',
                  border: `1px solid ${active ? 'var(--bt-border-strong)' : 'var(--bt-border)'}`,
                  color: active ? 'var(--bt-text)' : 'var(--bt-text-dim)',
                }}
              >
                <span className="block w-4 h-4" style={{ background: preset.hex }} />
                <span>{preset.name}</span>
              </button>
            );
          })}
        </div>

        <div className="flex items-center gap-3">
          <input
            className="w-32 font-mono"
            style={{ fontSize: 'var(--bt-code-size)' }}
            spellCheck={false}
            value={text}
            aria-label="Accent hex value"
            onChange={(e) => {
              const next = e.target.value;
              setText(next);
              if (HEX.test(next)) void setSetting('accent', next);
            }}
          />
          <span style={{ color: valid ? 'var(--bt-text-faint)' : 'var(--bt-warn)' }}>
            {valid ? 'Applied live' : 'Needs a 6-digit hex, e.g. #ff5f1f'}
          </span>
        </div>
      </div>
    </Field>
  );
}

function SizeSlider({
  label,
  hint,
  settingKey,
  min,
  max,
  fallback,
  sample,
  mono,
}: {
  label: string;
  hint: string;
  settingKey: string;
  min: number;
  max: number;
  fallback: number;
  sample: string;
  mono: boolean;
}): JSX.Element {
  const stored = useApp((s) => s.settings[settingKey]);
  const setSetting = useApp((s) => s.setSetting);
  const value = typeof stored === 'number' ? stored : fallback;

  return (
    <Field label={label} hint={hint}>
      <div className="flex flex-col gap-2">
        <div className="flex items-center gap-4">
          <input
            type="range"
            min={min}
            max={max}
            step={1}
            value={value}
            aria-label={label}
            className="w-56"
            style={{ accentColor: 'var(--bt-accent)', background: 'transparent', border: 'none', padding: 0 }}
            onChange={(e) => void setSetting(settingKey, Number(e.target.value))}
          />
          <span className="tabular-nums" style={{ color: 'var(--bt-text-dim)' }}>
            {value}px
          </span>
        </div>
        <span
          className={mono ? 'font-mono' : undefined}
          style={{ fontSize: `${value}px`, color: 'var(--bt-text-faint)' }}
        >
          {sample}
        </span>
      </div>
    </Field>
  );
}

export function AppearanceSection(): JSX.Element {
  const theme = useApp((s) => s.settings.theme) ?? 'near-black';
  const density = useApp((s) => s.settings.density) ?? 'comfortable';
  const setSetting = useApp((s) => s.setSetting);

  return (
    <Section
      title="Appearance"
      lead="Changes land immediately — nothing here needs a restart."
    >
      <Card>
        <div className="flex flex-col gap-6">
          <Field label="Theme" hint="How dark the surfaces behind everything sit.">
            <Segment
              ariaLabel="Theme"
              value={theme}
              options={[
                { value: 'near-black' as const, label: 'Near black' },
                { value: 'black' as const, label: 'Black' },
                { value: 'gray' as const, label: 'Gray' },
              ]}
              onChange={(v) => void setSetting('theme', v)}
            />
          </Field>

          <AccentPicker />

          <Field label="Density" hint="Row height and the gaps between things.">
            <Segment
              ariaLabel="Density"
              value={density}
              options={[
                { value: 'comfortable' as const, label: 'Comfortable' },
                { value: 'compact' as const, label: 'Compact' },
              ]}
              onChange={(v) => void setSetting('density', v)}
            />
          </Field>
        </div>
      </Card>

      <Card>
        <div className="flex flex-col gap-6">
          <SizeSlider
            label="Interface text size"
            hint="Labels, lists and prose across the app."
            settingKey="ui_font_size"
            min={13}
            max={16}
            fallback={14}
            sample="Session list, prompts and buttons read at this size."
            mono={false}
          />
          <SizeSlider
            label="Code text size"
            hint="Diffs, agent output and anything monospaced."
            settingKey="code_font_size"
            min={12}
            max={15}
            fallback={13}
            sample="const worktree = await createWorktree(session);"
            mono
          />
        </div>
      </Card>

      <Muted>Sharp corners are fixed and not configurable — no radius option exists anywhere in Backtick.</Muted>
    </Section>
  );
}
