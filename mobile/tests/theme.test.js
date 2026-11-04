const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const ts = require('typescript');
const Module = require('node:module');

require.extensions['.ts'] = (module, file) => {
  const source = fs.readFileSync(file, 'utf8');
  const js = ts.transpileModule(source, { fileName: file, compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022, esModuleInterop: true } }).outputText;
  module._compile(js, file);
};
// theme.ts persists the last theme and offers a hook; neither runs here.
const resolve = Module._resolveFilename;
Module._resolveFilename = function (request, ...rest) {
  if (request === '@react-native-async-storage/async-storage') return path.join(__dirname, 'theme.stubs.js');
  if (request === 'react') return path.join(__dirname, 'theme.stubs.js');
  return resolve.call(this, request, ...rest);
};
const t = require('../src/theme.ts');

// The Mac's derived palettes, as the snapshot carries them (RemoteTheming).
const repo = path.join(__dirname, '..', '..');
const before = JSON.parse(fs.readFileSync(path.join(repo, 'Packages/AbstractCore/Tests/AbstractCoreTests/Fixtures/theme-palettes-before-plugins.json'), 'utf8'));
const paper = { id: 'sh.abstract.theme.paper/theme/paper', name: 'Paper', appearance: 'light', tokens: before.paper };
const ink = { id: 'sh.abstract.theme.ink/theme/ink', name: 'Ink', appearance: 'dark', tokens: before.ink };
const graphite = { id: 'sh.abstract.theme.graphite/theme/graphite', name: 'Graphite', appearance: 'dark', tokens: before.graphite };

test('the phone starts in Graphite, with every role the Mac has', () => {
  assert.deepEqual(t.graphite.tokens, before.graphite);
  assert.equal(t.theme().id, graphite.id);
  assert.equal(t.palette.canvas, '#1e1e21');
});

test('a named theme is drawn whatever the phone is set to', () => {
  const named = { followsSystem: false, light: ink, dark: ink };
  assert.equal(t.pickTheme(named, 'light').id, ink.id);
  assert.equal(t.pickTheme(named, 'dark').tokens.canvas, '#000000');
});

test('Match System follows the phone', () => {
  const system = { followsSystem: true, light: paper, dark: graphite };
  assert.equal(t.pickTheme(system, 'light').name, 'Paper');
  assert.equal(t.pickTheme(system, 'dark').name, 'Graphite');
  assert.equal(t.pickTheme(system, null).name, 'Graphite');
});

test('an older Mac, or colours that are not hex, keep Graphite', () => {
  assert.equal(t.pickTheme(undefined, 'dark').id, graphite.id);
  const bad = { ...ink, tokens: { canvas: 'url(javascript:alert(1))' } };
  assert.equal(t.pickTheme({ followsSystem: false, light: bad, dark: bad }, 'dark').id, graphite.id);
  const sparse = { ...ink, tokens: { canvas: '#000000' } };
  assert.equal(t.pickTheme({ followsSystem: false, light: sparse, dark: sparse }, 'dark').tokens.text, before.graphite.text,
    'a role the Mac did not send keeps Graphite\'s');
});

test('the first paired Mac that sends a theme sets it', () => {
  const macs = [{ snapshot: null }, { snapshot: { theme: { followsSystem: false, light: ink, dark: ink } } }, { snapshot: { theme: { followsSystem: false, light: paper, dark: paper } } }];
  assert.equal(t.themingOf(macs).dark.id, ink.id);
  assert.equal(t.themingOf([{ snapshot: {} }]), null);
});

test('screens follow a new theme: colour names and style sheets', () => {
  let text = '';
  const stop = t.onTheme(tokens => { text = tokens.text; });
  let made = 0;
  const styles = t.themedStyles(() => { made += 1; return { page: { backgroundColor: t.palette.canvas } }; });
  assert.equal(styles.page.backgroundColor, '#1e1e21');
  assert.equal(t.setTheme(paper), true);
  assert.equal(text, before.paper.text);
  assert.equal(styles.page.backgroundColor, '#ffffff');
  assert.equal(t.isDarkTheme(), false);
  assert.equal(t.setTheme(paper), false, 'the same theme again changes nothing');
  assert.equal(made, 2);
  stop();
  t.setTheme(t.graphite, false);
  assert.equal(text, before.paper.text, 'a stopped listener hears nothing');
});
