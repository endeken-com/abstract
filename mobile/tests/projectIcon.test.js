const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const Module = require('node:module');
const ts = require('typescript');

const transpile = (module, path) => {
  const source = fs.readFileSync(path, 'utf8');
  const js = ts.transpileModule(source, { fileName: path, compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022, jsx: ts.JsxEmit.React, esModuleInterop: true } }).outputText;
  module._compile(js, path);
};
require.extensions['.ts'] = transpile;
require.extensions['.tsx'] = transpile;
// The native modules are stood in by their element names, so a row renders to a plain element tree.
const stubs = {
  'react-native': { Pressable: 'Pressable', Text: 'Text', TextInput: 'TextInput', View: 'View', Image: 'Image', StyleSheet: { create: styles => styles, hairlineWidth: 0.5 } },
  'expo-symbols': { SymbolView: 'SymbolView' },
  'react-native-svg': { __esModule: true, default: 'Svg', Path: 'Path' },
  '@react-native-menu/menu': { MenuView: 'MenuView' },
  '@react-native-async-storage/async-storage': { __esModule: true, default: { getItem: async () => null, setItem: async () => {} } },
};
const load = Module._load;
Module._load = function (request, ...rest) { return stubs[request] || load.call(this, request, ...rest); };
const React = require('react');
const p = require('../src/projectIcons.ts');
const g = require('../src/chatGroups.ts');
const { ChatRow } = require('../src/ChatList.tsx');

const project = (fields = {}) => ({ id: 'p1', name: 'Alpha', rootPath: '/tmp/a', defaultBaseRef: 'main', defaultProviderId: 'claude', defaultPermissionPolicy: 'ask', ...fields });
const png = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1, 2]).toString('base64');
const jpeg = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 1, 2]).toString('base64');

test('icon resolution follows the Mac sidebar', () => {
  const uploaded = project({ iconSymbol: 'cube', iconColor: 'sage', iconImagePath: '/icons/a.png' });
  // An uploaded image whose bytes the snapshot carries wins over the symbol.
  assert.deepEqual(p.iconFor(uploaded, png), { kind: 'project', mark: { name: 'Alpha', symbol: 'cube', color: 'sage', imageData: png } });
  // An older Mac sends no bytes: the symbol tile, never the Mac-only file path.
  assert.deepEqual(p.iconFor(uploaded, undefined), { kind: 'project', mark: { name: 'Alpha', symbol: 'cube', color: 'sage' } });
  assert.deepEqual(p.iconFor(uploaded, ''), { kind: 'project', mark: { name: 'Alpha', symbol: 'cube', color: 'sage' } });
  // The host strips its local path from the snapshot; the bytes alone are enough.
  assert.deepEqual(p.iconFor(project({ iconSymbol: 'bolt', iconColor: 'rose' }), png),
    { kind: 'project', mark: { name: 'Alpha', symbol: 'bolt', color: 'rose', imageData: png } });
  // No image bytes: still the project's (default) tile, not the agent's logo.
  assert.deepEqual(p.iconFor(project()), { kind: 'project', mark: { name: 'Alpha' } });
  // A standalone chat keeps its agent's logo.
  assert.deepEqual(p.iconFor(null, png), { kind: 'agent' });
  assert.deepEqual(p.iconFor(undefined), { kind: 'agent' });
});

test('tile colours and glyphs match Project Settings', () => {
  assert.deepEqual(p.tileFor({ name: 'Alpha', symbol: 'cube', color: 'sage' }),
    { background: '#7C8B74', foreground: 'rgba(255,255,255,0.92)', symbol: 'cube', initial: 'A' });
  // A colour alone: the initial on that colour.
  assert.deepEqual(p.tileFor({ name: ' beta ', color: 'rose' }),
    { background: '#9E7F7F', foreground: 'rgba(255,255,255,0.92)', initial: 'B' });
  // Nothing chosen, or a colour the Mac no longer knows: the neutral tile.
  const neutral = { background: '#303036', foreground: '#A4A4AD', initial: 'G' };
  assert.deepEqual(p.tileFor({ name: 'Gamma' }), neutral);
  assert.deepEqual(p.tileFor({ name: 'Gamma', color: 'neon' }), neutral);
  assert.deepEqual(p.tileFor({ name: 'Gamma', symbol: 'not-a-symbol' }), neutral);
  // Every colour the picker offers resolves.
  for (const [name, hex] of Object.entries({ graphite: '#4A4A51', slate: '#7A7A83', stone: '#8E877C', sage: '#7C8B74', rose: '#9E7F7F', plum: '#86778A', sand: '#A09780' })) {
    assert.equal(p.tileFor({ name: 'A', color: name }).background, hex, name);
  }
  // Every symbol the picker offers has an Android/Web name.
  for (const symbol of ['folder', 'shippingbox', 'cube', 'square.stack.3d.up', 'hammer', 'wrench.and.screwdriver', 'terminal',
    'chevron.left.forwardslash.chevron.right', 'curlybraces', 'server.rack', 'cloud', 'globe', 'iphone', 'macwindow',
    'gamecontroller', 'paintbrush.pointed', 'book.closed', 'chart.bar', 'leaf', 'bolt']) {
    assert.ok(p.materialSymbol(symbol), symbol);
  }
  assert.equal(p.materialSymbol('not-a-symbol'), undefined);
});

test('uploaded bytes become an image URI with the sniffed type', () => {
  assert.equal(p.imageUri(png), `data:image/png;base64,${png}`);
  assert.equal(p.imageUri(jpeg), `data:image/jpeg;base64,${jpeg}`);
  assert.equal(p.imageUri(''), undefined);
  assert.equal(p.imageUri(undefined), undefined);
});

const snapshot = (fields = {}) => ({
  projects: [project({ iconSymbol: 'cube', iconColor: 'sage', iconImagePath: '/icons/a.png' }), project({ id: 'p2', name: 'Beta' })],
  sessions: [
    { id: 's1', projectId: 'p1', name: 'one', providerId: 'claude', worktreePath: '/w', status: 'idle', createdAt: 1, archivedAt: null },
    { id: 's2', projectId: 'p2', name: 'two', providerId: 'codex', worktreePath: '/w', status: 'idle', createdAt: 1, archivedAt: null },
    { id: 's3', projectId: null, name: 'three', providerId: 'claude', worktreePath: null, status: 'idle', createdAt: 1, archivedAt: null },
  ],
  providers: [], alive: [], projectIcons: { p1: png }, ...fields,
});
const mac = { id: 'h1', name: 'Studio', state: 'online', lastSeenAt: null };

test('chats from a snapshot carry their project icon', () => {
  const chats = g.chatsFromSnapshot(snapshot(), mac);
  assert.deepEqual(chats[0].icon, { kind: 'project', mark: { name: 'Alpha', symbol: 'cube', color: 'sage', imageData: png } });
  assert.deepEqual(chats[1].icon, { kind: 'project', mark: { name: 'Beta' } });
  assert.deepEqual(chats[2].icon, { kind: 'agent' });
  // An older Mac sends no projectIcons: the symbol tile.
  const older = g.chatsFromSnapshot(snapshot({ projectIcons: undefined }), mac);
  assert.deepEqual(older[0].icon, { kind: 'project', mark: { name: 'Alpha', symbol: 'cube', color: 'sage' } });
});

const flatten = (node, out = []) => {
  if (Array.isArray(node)) node.forEach(n => flatten(n, out));
  else if (node && typeof node === 'object') {
    out.push(node);
    if (typeof node.type === 'function') flatten(node.type(node.props), out);
    flatten(node.props?.children, out);
  }
  return out;
};

test('a chat row leads with its project icon, a standalone row with its agent', () => {
  const chats = g.chatsFromSnapshot(snapshot(), mac);
  const row = chat => flatten(ChatRow({ chat, showProject: true, now: 100, onPress: () => {} }));
  const uploaded = row(chats[0]);
  const image = uploaded.find(e => e.type === 'Image');
  assert.equal(image?.props.source.uri, `data:image/png;base64,${png}`);
  assert.ok(uploaded.some(e => e.props?.accessibilityLabel === 'Alpha, Claude Code, idle'), 'mark is labelled by project, agent and state');
  const plain = row(chats[1]);
  assert.ok(plain.some(e => e.props?.children === 'B'), 'no icon chosen: the initial tile');
  const solo = row(chats[2]);
  assert.ok(!solo.some(e => e.type === 'Image'), 'standalone keeps the agent logo, no project image');
});
