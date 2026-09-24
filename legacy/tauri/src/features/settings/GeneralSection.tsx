import type { JSX } from 'react';
import { Card, Field, Muted, Section, Toggle } from './ui';
import { hostTimezone, useDebouncedSetting, useOnByDefault } from './hooks';

export function GeneralSection(): JSX.Element {
  const [attention, setAttention] = useOnByDefault('notify_attention');
  const [finished, setFinished] = useOnByDefault('notify_finished');
  const [automationFailed, setAutomationFailed] = useOnByDefault('notify_automation_failed');
  const [timezone, setTimezone] = useDebouncedSetting('default_timezone', hostTimezone());

  return (
    <Section
      title="General"
      lead="Notifications and the defaults Abstract falls back on when nothing more specific is set."
    >
      <Card>
        <div className="flex flex-col gap-5">
          <span className="font-medium" style={{ color: 'var(--bt-text)' }}>
            Notifications
          </span>
          <Toggle
            label="An agent needs you"
            hint="A session is waiting on an answer it cannot give itself."
            checked={attention}
            onChange={setAttention}
          />
          <Toggle
            label="An agent finished"
            hint="A session reached the end of its turn."
            checked={finished}
            onChange={setFinished}
          />
          <Toggle
            label="An automation failed"
            hint="A scheduled run could not create its workspace or launch its agent."
            checked={automationFailed}
            onChange={setAutomationFailed}
          />
        </div>
      </Card>

      <Card>
        <Field
          label="Default timezone"
          hint="New automations start in this zone. Each automation can still pick its own."
        >
          <input
            className="w-full max-w-sm font-mono"
            style={{ fontSize: 'var(--bt-code-size)' }}
            spellCheck={false}
            value={timezone}
            placeholder={hostTimezone()}
            onChange={(e) => setTimezone(e.target.value)}
          />
        </Field>
        <p className="mt-2" style={{ color: 'var(--bt-text-faint)' }}>
          An IANA zone name, for example {hostTimezone()}.
        </p>
      </Card>

      <Card>
        <div className="flex flex-col gap-2">
          <span className="font-medium" style={{ color: 'var(--bt-text)' }}>
            Closing the window
          </span>
          <p className="max-w-[70ch]" style={{ color: 'var(--bt-text-dim)' }}>
            Closing the window hides Abstract to the tray rather than quitting it, so automations keep
            firing on schedule. Choose Quit in the tray menu to exit fully — after that nothing fires
            until you open Abstract again.
          </p>
        </div>
      </Card>

      <Muted>
        Notifications use the operating system's own notification centre, so its Do Not Disturb rules
        apply on top of these switches.
      </Muted>
    </Section>
  );
}
