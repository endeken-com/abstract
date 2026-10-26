import type { MenuAction } from '@react-native-menu/menu';

// Agent, model, effort and mode in one composer menu: each a submenu that
// names its current value, so nothing has to be read off a truncated chip.
export type SettingKind = 'agent' | 'model' | 'effort' | 'mode';
export type SettingChoice = { id: string; title: string; selected?: boolean; image?: string };
export type ComposerSetting = { kind: SettingKind; title: string; value: string; image?: string; choices: SettingChoice[] };

export function settingsMenuActions(settings: ComposerSetting[], platform: string): MenuAction[] {
  return settings.map(setting => ({
    id: setting.kind,
    // Android menus have no subtitles, so the value joins the title there.
    title: platform === 'ios' ? setting.title : `${setting.title}: ${setting.value}`,
    subtitle: platform === 'ios' ? setting.value : undefined,
    image: platform === 'ios' ? setting.image : undefined,
    subactions: setting.choices.map(choice => ({
      id: `${setting.kind}:${choice.id}`,
      title: choice.title,
      state: choice.selected ? 'on' : 'off',
      image: platform === 'ios' ? choice.image : undefined,
    })),
  }));
}

export function settingFromAction(event: string): { kind: SettingKind; id: string } | null {
  const split = event.indexOf(':');
  const kind = split < 0 ? '' : event.slice(0, split);
  if (!['agent', 'model', 'effort', 'mode'].includes(kind)) return null;
  return { kind: kind as SettingKind, id: event.slice(split + 1) };
}

export function settingsAccessibilityLabel(settings: ComposerSetting[]): string {
  return `Agent settings: ${settings.map(setting => `${setting.title} ${setting.value}`).join(', ')}`;
}
