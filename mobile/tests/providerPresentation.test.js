const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const Module = require('node:module');
const ts = require('typescript');

require.extensions['.ts'] = (module, path) => {
  const source = fs.readFileSync(path, 'utf8');
  module._compile(ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022, jsx: ts.JsxEmit.React, esModuleInterop: true } }).outputText, path);
};
require.extensions['.tsx'] = require.extensions['.ts'];
const load = Module._load;
Module._load = function (request, ...rest) {
  if (request === 'react-native-svg') return { SvgXml: 'SvgXml' };
  if (request === 'expo-symbols') return { SymbolView: 'SymbolView' };
  if (request === './theme') return { palette: { textSecondary: '#888' } };
  return load.call(this, request, ...rest);
};
const { providerLabel, providerPresentation } = require('../src/providerPresentation.ts');
const { ProviderLogo, providerMenuImage } = require('../src/ProviderLogo.tsx');

test('synthetic plugin identity follows its host snapshot', () => {
  const snapshot = { providers: ['orbit'], providerPresentations: [{ id: 'orbit', label: 'Orbit Agent', icon: '<svg viewBox="0 0 24 24"></svg>' }] };
  assert.equal(providerLabel(snapshot, 'orbit'), 'Orbit Agent');
  assert.equal(providerPresentation(snapshot, 'orbit').icon, snapshot.providerPresentations[0].icon);
  const logo = ProviderLogo({ provider: 'orbit', presentation: snapshot.providerPresentations[0] });
  assert.equal(logo.type, 'SvgXml');
  assert.equal(logo.props.xml, snapshot.providerPresentations[0].icon);
  assert.equal(ProviderLogo({ provider: 'missing' }).type, 'SymbolView');
  assert.equal(providerLabel(snapshot, 'missing'), 'missing');
});

test('older snapshots keep their bundled labels', () => {
  assert.equal(providerLabel({ providers: ['claude'] }, 'claude'), 'Claude Code');
  assert.equal(providerLabel(undefined, 'codex'), 'Codex');
  assert.equal(ProviderLogo({ provider: 'claude' }).type, 'SvgXml');
  assert.equal(providerMenuImage('claude'), 'ProviderClaude');
  const codex = { id: 'codex', label: 'Codex', asset: 'ProviderOpenAI' };
  assert.equal(ProviderLogo({ provider: 'codex', presentation: codex }).type, 'SvgXml');
  assert.equal(providerMenuImage('codex', codex), 'ProviderCodex');
});
