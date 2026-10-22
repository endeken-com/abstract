import type { Project } from './types';

// A project's icon as its chat rows show it, following the Mac's sidebar
// (Packages/AbstractCore/Sources/AbstractCore/Sessions/SidebarChats.swift and
// Abstract/Features/ProjectSettings/ProjectIcon.swift). Keep the two in step.
// An uploaded image travels in the snapshot as base64 bytes (`projectIcons`);
// its `iconImagePath` names a file on the Mac and is never read here.

export type ProjectMark = { name: string; symbol?: string; color?: string; imageData?: string };
export type ChatIcon = { kind: 'agent' } | { kind: 'project'; mark: ProjectMark };

// The icon a chat's row leads with: its project's icon, or (standalone) its
// agent's logo. An uploaded image wins only when the project chose one and
// its Mac sent the bytes; an older Mac that sends none falls back to the tile.
export function iconFor(project: Project | null | undefined, remoteImage?: string | null): ChatIcon {
  if (!project) return { kind: 'agent' };
  const mark: ProjectMark = { name: project.name };
  if (project.iconSymbol) mark.symbol = project.iconSymbol;
  if (project.iconColor) mark.color = project.iconColor;
  if (remoteImage) mark.imageData = remoteImage;
  return { kind: 'project', mark };
}

// The tile colours a project icon can take, stored by name; none (or a name
// the Mac no longer offers) is the neutral default. Values from ProjectIcon.swift;
// the neutral fill and glyph are btInset and btTextSecondary in Graphite.
export const projectIconColors: Record<string, string> = {
  graphite: '#4A4A51', slate: '#7A7A83', stone: '#8E877C', sage: '#7C8B74',
  rose: '#9E7F7F', plum: '#86778A', sand: '#A09780',
};

// The symbols Project Settings offers, by SF Symbol name, with the Material
// Symbols name Android and Web draw instead. A symbol outside this list has
// no cross-platform glyph here, so the tile shows the project's initial.
const materialSymbols: Record<string, string> = {
  'folder': 'folder', 'shippingbox': 'inventory_2', 'cube': 'deployed_code',
  'square.stack.3d.up': 'layers', 'hammer': 'hardware', 'wrench.and.screwdriver': 'build',
  'terminal': 'terminal', 'chevron.left.forwardslash.chevron.right': 'code', 'curlybraces': 'data_object',
  'server.rack': 'dns', 'cloud': 'cloud', 'globe': 'public', 'iphone': 'smartphone',
  'macwindow': 'web_asset', 'gamecontroller': 'sports_esports', 'paintbrush.pointed': 'brush',
  'book.closed': 'menu_book', 'chart.bar': 'bar_chart', 'leaf': 'eco', 'bolt': 'bolt',
  'person.crop.circle': 'account_circle', 'magnifyingglass': 'search',
  'list.bullet.clipboard': 'assignment', 'ladybug': 'bug_report',
  'doc.text.magnifyingglass': 'find_in_page', 'lightbulb': 'lightbulb',
  'paintpalette': 'palette', 'checkmark.seal': 'verified',
  'testtube.2': 'science', 'text.book.closed': 'menu_book',
  'shield.lefthalf.filled': 'shield', 'sparkles': 'auto_awesome',
  'point.3.connected.trianglepath.dotted': 'schema',
};
export const materialSymbol = (symbol?: string | null) => (symbol ? materialSymbols[symbol] : undefined);

export type ProjectTile = { background: string; foreground: string; symbol?: string; initial: string };

// The symbol (or initial) on the project's colour, as the Mac's tile draws it.
export function tileFor(mark: ProjectMark): ProjectTile {
  const tint = mark.color ? projectIconColors[mark.color] : undefined;
  const tile: ProjectTile = {
    background: tint ?? '#303036',
    foreground: tint ? 'rgba(255,255,255,0.92)' : '#A4A4AD',
    initial: (mark.name.trim().charAt(0) || '?').toUpperCase(),
  };
  if (mark.symbol && materialSymbols[mark.symbol]) tile.symbol = mark.symbol;
  return tile;
}

// The first bytes of base64 image data say what it is. Uploaded icons are
// PNGs the Mac wrote; anything unrecognised is offered as one.
export function imageUri(imageData?: string | null): string | undefined {
  if (!imageData) return undefined;
  const head: number[] = [];
  const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  for (const group of imageData.slice(0, 16).match(/.{4}/g) || []) {
    const v = [...group].map(c => chars.indexOf(c));
    head.push((v[0] << 2) | (v[1] >> 4), ((v[1] & 15) << 4) | (v[2] >> 2), ((v[2] & 3) << 6) | v[3]);
  }
  const is = (...bytes: number[]) => bytes.every((b, i) => head[i] === b);
  const mime = is(0xff, 0xd8, 0xff) ? 'image/jpeg'
    : is(0x47, 0x49, 0x46, 0x38) ? 'image/gif'
    : is(0x52, 0x49, 0x46, 0x46) && head.slice(8, 12).join() === '87,69,66,80' ? 'image/webp'
    : 'image/png';
  return `data:${mime};base64,${imageData}`;
}
