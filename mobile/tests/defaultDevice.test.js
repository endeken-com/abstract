const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const ts = require('typescript');

require.extensions['.ts'] = (module, path) => {
  const source = fs.readFileSync(path, 'utf8');
  module._compile(ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022, esModuleInterop: true } }).outputText, path);
};
const { counterpartProject, defaultMacName, resolveChatTarget } = require('../src/macs.ts');

// A project's default Mac lives on its record on the Mac that owns it
// (defaultDeviceId, null = that Mac). These mirror the Mac Launcher: the
// default is pre-selected when reachable, else the chat runs on the owning
// Mac with a note saying why.
const project = (over = {}) => ({ id: 'p1', name: 'api', rootPath: '/r/api', defaultBaseRef: 'HEAD', defaultProviderId: 'claude', defaultPermissionPolicy: 'ask', ...over });
const mac = (id, name, state, projects) => ({ id, name, state, snapshot: { projects, sessions: [], providers: ['claude'], alive: [] } });

test('the same project on another Mac is found by id, then by name', () => {
  const there = [project({ id: 'p9', name: 'web' }), project({ id: 'p2', rootPath: '/other/api' })];
  assert.equal(counterpartProject(project(), there)?.id, 'p2');
  assert.equal(counterpartProject(project(), [project()])?.id, 'p1');
  assert.equal(counterpartProject(project(), [...there, project()])?.id, 'p1');
  assert.equal(counterpartProject(project({ name: 'nope' }), there), undefined);
});

test('no default Mac means the owning Mac, and nothing to explain', () => {
  const macs = [mac('mac-a', 'Studio', 'online', [project()]), mac('mac-b', 'Mini', 'online', [project({ id: 'p2' })])];
  assert.deepEqual(resolveChatTarget(macs, 'mac-a', project()), { macId: 'mac-a', projectId: 'p1', notice: null });
  assert.equal(defaultMacName(macs, macs[0], project()), 'Studio');
});

test('a connected default Mac with the project is pre-selected, with its own record', () => {
  const mine = project({ defaultDeviceId: 'mac-b' });
  const macs = [mac('mac-a', 'Studio', 'online', [mine]), mac('mac-b', 'Mini', 'online', [project({ id: 'p2', rootPath: '/other/api' })])];
  assert.deepEqual(resolveChatTarget(macs, 'mac-a', mine), { macId: 'mac-b', projectId: 'p2', notice: null });
  assert.equal(defaultMacName(macs, macs[0], mine), 'Mini');
});

test('a default Mac the phone cannot reach falls back to the owning Mac, with a note', () => {
  const mine = project({ defaultDeviceId: 'mac-b' });
  const offline = [mac('mac-a', 'Studio', 'online', [mine]), mac('mac-b', 'Mini', 'unreachable', [project({ id: 'p2' })])];
  assert.deepEqual(resolveChatTarget(offline, 'mac-a', mine),
    { macId: 'mac-a', projectId: 'p1', notice: "Mini isn't connected, so this chat runs on Studio." });
  const unpaired = [mac('mac-a', 'Studio', 'online', [mine])];
  assert.deepEqual(resolveChatTarget(unpaired, 'mac-a', mine),
    { macId: 'mac-a', projectId: 'p1', notice: "Its default Mac isn't connected, so this chat runs on Studio." });
  assert.equal(defaultMacName(unpaired, unpaired[0], mine), 'A paired Mac');
});

test("a default Mac without the project falls back to the owning Mac, with a note", () => {
  const mine = project({ defaultDeviceId: 'mac-b' });
  const macs = [mac('mac-a', 'Studio', 'online', [mine]), mac('mac-b', 'Mini', 'online', [project({ id: 'p9', name: 'web' })])];
  assert.deepEqual(resolveChatTarget(macs, 'mac-a', mine),
    { macId: 'mac-a', projectId: 'p1', notice: "Mini doesn't have a project called “api”, so this chat runs on Studio." });
});

test('a default Mac that is the owning Mac itself just runs there', () => {
  const mine = project({ defaultDeviceId: 'mac-a' });
  const macs = [mac('mac-a', 'Studio', 'online', [mine])];
  assert.deepEqual(resolveChatTarget(macs, 'mac-a', mine), { macId: 'mac-a', projectId: 'p1', notice: null });
});
