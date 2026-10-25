const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const ts = require('typescript');

require.extensions['.ts'] = (module, path) => {
  const js = ts.transpileModule(fs.readFileSync(path, 'utf8'), { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 } }).outputText;
  module._compile(js, path);
};
const {
  buildPluginDocument, capabilityLine, contributionsFor, hostMessageJS, invokeEnvelope,
  pluginMessageArgs, setPluginEnabledArgs, setPluginTranscriptProjectsArgs, transcriptProjectNames,
} = require('../src/plugins.ts');

const decode = b64 => Buffer.from(b64, 'base64').toString('utf8');
const enc = text => Buffer.from(text, 'utf8').toString('base64');

const plugin = (over = {}) => ({
  id: 'sh.example.widget', name: 'Widget', version: '1.0.0', source: 'user',
  enabled: true, usable: true, requestedCapabilities: ['usage.read', 'transcripts.read'],
  grantedCapabilities: ['usage.read', 'transcripts.read'], transcriptProjectKeys: ['mac1:p1'],
  viewId: 'main', viewTitle: 'Widget', appearances: [],
  contributions: [
    { place: 'main', id: 'main', title: 'Widget' },
    { place: 'chatPanel', id: 'tab', title: 'Widget tab' },
    { place: 'chatMenu', id: 'log', title: 'Log chat' },
    { place: 'home', id: 'card', title: 'Widget card' },
  ],
  ...over,
});

test('only usable plugins contribute, per place', () => {
  assert.equal(contributionsFor([plugin()], 'chatPanel').length, 1);
  assert.equal(contributionsFor([plugin()], 'palette').length, 0);
  assert.equal(contributionsFor([plugin({ usable: false })], 'chatMenu').length, 0);
  assert.equal(contributionsFor(undefined, 'home').length, 0);
});

test('capability lines name transcript projects, empty reads none', () => {
  assert.equal(capabilityLine('usage.read', []), 'See what your chats used and cost');
  assert.equal(capabilityLine('transcripts.read', []), "Read your chats' messages in no projects yet");
  assert.equal(capabilityLine('transcripts.read', ['Docs', 'App']), "Read your chats' messages in Docs, App");
  assert.deepEqual(transcriptProjectNames(['mac1:p2', 'gone', 'mac1:p1'],
    [{ key: 'mac1:p1', name: 'One' }, { key: 'mac1:p2', name: 'Two' }]), ['Two', 'One']);
});

test('request builders keep the wire shape', () => {
  assert.deepEqual(setPluginEnabledArgs('p', true, ['k']), { pluginId: 'p', enabled: true, transcriptProjectKeys: ['k'] });
  assert.deepEqual(setPluginEnabledArgs('p', false), { pluginId: 'p', enabled: false, transcriptProjectKeys: null });
  assert.deepEqual(setPluginTranscriptProjectsArgs('p', []), { pluginId: 'p', keys: [] });
  assert.deepEqual(pluginMessageArgs('p', '{}', 'chatPanel', 'tab', 'c1'),
    { pluginId: 'p', text: '{}', place: 'chatPanel', contributionId: 'tab', chatId: 'c1' });
  assert.equal(pluginMessageArgs('p', '{}', 'main', 'm').chatId, null);
});

test('invoke and host envelopes are plain JSON text', () => {
  assert.deepEqual(JSON.parse(invokeEnvelope('chatMenu', 'log', 'c1')),
    { api: 1, type: 'invoke', payload: { place: 'chatMenu', contributionId: 'log', chatId: 'c1' } });
  assert.deepEqual(JSON.parse(invokeEnvelope('palette', 'open')), { api: 1, type: 'invoke', payload: { place: 'palette', contributionId: 'open' } });
  const js = hostMessageJS('{"api":1,"type":"snapshot","payload":{}}');
  assert.match(js, /__abstractHostMessage\(/);
  assert.ok(js.includes(JSON.stringify('{"api":1,"type":"snapshot","payload":{}}')));
});

test('document inlines css, js and images, and swaps the CSP', () => {
  const files = {
    'index.html': enc(`<!DOCTYPE html><html><head><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'self'"><link rel="stylesheet" href="style.css"></head><body><img src="icon.png"><script src="app.js"></script></body></html>`),
    'style.css': enc('body { color: red; background: url(bg.png); }'),
    'app.js': enc('window.AbstractPlugin.on("snapshot", () => {});'),
    'icon.png': enc('PNG'),
    'bg.png': enc('BG'),
  };
  const doc = buildPluginDocument(files, 'index.html', decode);
  assert.ok(doc.includes('AbstractPlugin'), 'shim installed');
  assert.ok(doc.indexOf('ReactNativeWebView') < doc.indexOf('window.AbstractPlugin.on'), 'shim precedes plugin code');
  assert.ok(doc.includes('body { color: red;'));
  assert.ok(doc.includes(`data:image/png;base64,${enc('BG')}`), 'css image inlined');
  assert.ok(doc.includes(`data:image/png;base64,${enc('PNG')}`), 'img inlined');
  assert.ok(!doc.includes("script-src 'self'"), 'self CSP replaced');
  assert.ok(doc.includes("default-src 'none'; script-src 'unsafe-inline'"), 'inline lockdown kept');
  assert.ok(!doc.includes('src="app.js"') && !doc.includes('href="style.css"'));
});

test('document drops missing and external assets, and a missing entry fails', () => {
  const files = {
    'index.html': enc('<html><head><link rel="stylesheet" href="gone.css"><script src="https://example.com/x.js"></script><script src="gone.js"></script></head><body>hi</body></html>'),
  };
  const doc = buildPluginDocument(files, 'index.html', decode);
  assert.ok(!doc.includes('example.com'));
  assert.ok(!doc.includes('gone.css') && !doc.includes('gone.js'));
  assert.equal(buildPluginDocument({}, 'index.html', decode), null);
});

test('nested entry resolves sibling assets', () => {
  const files = {
    'pages/index.html': enc('<html><head><script src="../app.js"></script></head></html>'),
    'app.js': enc('console.log(1);'),
  };
  assert.ok(buildPluginDocument(files, 'pages/index.html', decode).includes('console.log(1);'));
});

test('documents without their own CSP receive a policy before plugin code', () => {
  const files = { 'index.html': enc('<html><head><script>window.ready = true;</script></head><body>Hi</body></html>') };
  const doc = buildPluginDocument(files, 'index.html', decode);
  assert.ok(doc.indexOf('Content-Security-Policy') < doc.indexOf('window.ready = true'));
  assert.ok(doc.includes("form-action 'none'; base-uri 'none'"));
});
