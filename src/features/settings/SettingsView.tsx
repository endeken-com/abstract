import { useState, type JSX } from 'react';
import { WorktreesSection } from './WorktreesSection';
import { AgentsSection } from './AgentsSection';
import { AppearanceSection } from './AppearanceSection';
import { GeneralSection } from './GeneralSection';

type Tab = 'worktrees' | 'agents' | 'appearance' | 'general';

const TABS: { value: Tab; label: string; blurb: string }[] = [
  { value: 'worktrees', label: 'Worktrees', blurb: 'Where sessions live' },
  { value: 'agents', label: 'Agents', blurb: 'CLIs and usage' },
  { value: 'appearance', label: 'Appearance', blurb: 'Theme and sizing' },
  { value: 'general', label: 'General', blurb: 'Notifications, tray' },
];

export function SettingsView(): JSX.Element {
  const [tab, setTab] = useState<Tab>('worktrees');

  return (
    <div className="flex h-full min-h-0" style={{ background: 'var(--bt-bg)', color: 'var(--bt-text)' }}>
      <nav
        aria-label="Settings sections"
        className="w-56 shrink-0 overflow-y-auto p-3"
        style={{ borderRight: '1px solid var(--bt-border)', background: 'var(--bt-surface)' }}
      >
        <div className="px-2 py-2 mb-2" style={{ color: 'var(--bt-text-faint)' }}>
          Settings
        </div>
        <ul className="flex flex-col gap-1 list-none m-0 p-0">
          {TABS.map((item) => {
            const active = item.value === tab;
            return (
              <li key={item.value}>
                <button
                  type="button"
                  aria-current={active ? 'page' : undefined}
                  onClick={() => setTab(item.value)}
                  className="w-full text-left px-2.5 py-2 flex flex-col gap-0.5"
                  style={{
                    background: active ? 'var(--bt-surface-3)' : 'transparent',
                    borderLeft: `2px solid ${active ? 'var(--bt-accent)' : 'transparent'}`,
                    color: active ? 'var(--bt-text)' : 'var(--bt-text-dim)',
                  }}
                >
                  <span>{item.label}</span>
                  <span style={{ color: 'var(--bt-text-faint)' }}>{item.blurb}</span>
                </button>
              </li>
            );
          })}
        </ul>
      </nav>

      <div className="flex-1 min-w-0 overflow-y-auto">
        <div className="max-w-3xl px-8 py-8">
          {tab === 'worktrees' ? <WorktreesSection /> : null}
          {tab === 'agents' ? <AgentsSection /> : null}
          {tab === 'appearance' ? <AppearanceSection /> : null}
          {tab === 'general' ? <GeneralSection /> : null}
        </div>
      </div>
    </div>
  );
}
