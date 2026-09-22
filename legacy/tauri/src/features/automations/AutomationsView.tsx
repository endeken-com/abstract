import { useState, type JSX } from 'react';
import { useApp } from '../../store/app';
import { AutomationList } from './AutomationList';
import { AutomationDetail } from './AutomationDetail';
import { AutomationForm } from './AutomationForm';
import { Muted } from './ui';

export function AutomationsView(): JSX.Element {
  const automations = useApp((s) => s.automations);
  const selectedId = useApp((s) => s.selectedAutomationId);
  const selectAutomation = useApp((s) => s.selectAutomation);
  const [creating, setCreating] = useState(false);

  const selected = automations.find((a) => a.id === selectedId) ?? null;

  return (
    <div
      className="flex h-full min-h-0"
      style={{ background: 'var(--bt-bg)', color: 'var(--bt-text)' }}
    >
      <AutomationList
        creating={creating}
        onNew={() => {
          setCreating(true);
          selectAutomation(null);
        }}
        onSelect={(id) => {
          setCreating(false);
          selectAutomation(id);
        }}
      />

      <div className="flex-1 min-w-0 overflow-y-auto">
        <div className="max-w-3xl px-8 py-8">
          {creating ? (
            <div className="flex flex-col gap-6">
              <header className="flex flex-col gap-1">
                <h1 className="m-0 text-[1.3em] font-semibold" style={{ color: 'var(--bt-text)' }}>
                  New automation
                </h1>
                <Muted>
                  An automation launches an agent on a schedule, in its own workspace, whether or not
                  you are watching.
                </Muted>
              </header>
              <AutomationForm
                onSaved={(saved) => {
                  setCreating(false);
                  selectAutomation(saved.id);
                }}
                onCancel={() => setCreating(false)}
              />
            </div>
          ) : selected ? (
            <AutomationDetail key={selected.id} automation={selected} />
          ) : (
            <div className="flex flex-col gap-3">
              <h1 className="m-0 text-[1.3em] font-semibold" style={{ color: 'var(--bt-text)' }}>
                Automations
              </h1>
              <Muted>
                Pick an automation on the left to see its run history, or create one to have an agent
                pick up a recurring job on its own. Backtick keeps firing them from the tray after you
                close the window.
              </Muted>
            </div>
          )}
        </div>
      </div>
    </div>
  );
}
