const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const ts = require('typescript');

require.extensions['.ts'] = (module, path) => {
  const source = fs.readFileSync(path, 'utf8');
  const js = ts.transpileModule(source, { fileName: path, compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022, esModuleInterop: true } }).outputText;
  module._compile(js, path);
};
const p = require('../src/profiles.ts');

const profile = (id, fields = {}) => ({
  id, name: id, providerId: 'claude', model: null, effort: null,
  permissionPolicy: 'ask', instructions: `be ${id}`, skills: [], mcpServers: [],
  sortOrder: 0, createdAt: 1, ...fields,
});
const project = (profileIds) => ({ id: 'p1', name: 'P', rootPath: '/p', defaultBaseRef: 'HEAD', defaultProviderId: 'claude', defaultPermissionPolicy: 'ask', profileIds });

test('profiles sort by sort order, then creation', () => {
  const all = [profile('b', { sortOrder: 1, createdAt: 1 }), profile('a', { sortOrder: 0, createdAt: 9 }), profile('c', { sortOrder: 1, createdAt: 0 })];
  assert.deepEqual(p.sortedProfiles(all).map(x => x.id), ['a', 'c', 'b']);
  assert.deepEqual(p.sortedProfiles(undefined), []);
});

test('a project that picked profiles offers only those, plus the chosen one', () => {
  const all = [profile('a'), profile('b'), profile('c')];
  assert.deepEqual(p.visibleProfiles(all, project(['b'])).map(x => x.id), ['b']);
  assert.deepEqual(p.visibleProfiles(all, project(['b']), 'c').map(x => x.id), ['b', 'c']);
  assert.deepEqual(p.visibleProfiles(all, project(['b']), 'gone').map(x => x.id), ['b']);
});

test('no picked list offers every profile; standalone sees all', () => {
  const all = [profile('a'), profile('b')];
  assert.deepEqual(p.visibleProfiles(all, project(null)).map(x => x.id), ['a', 'b']);
  assert.deepEqual(p.visibleProfiles(all, project(undefined)).map(x => x.id), ['a', 'b']);
  assert.deepEqual(p.visibleProfiles(all, null).map(x => x.id), ['a', 'b']);
  assert.deepEqual(p.visibleProfiles(undefined, null), []);
});

test('choosing a profile fills agent, model, effort and permissions', () => {
  const filled = p.appliedProfile(profile('r', { providerId: 'codex', model: 'opus', effort: 'high', permissionPolicy: 'auto-edits' }));
  assert.deepEqual(filled, { providerId: 'codex', model: 'opus', effort: 'high', policy: 'auto-edits' });
  assert.deepEqual(p.appliedProfile(profile('d')), { providerId: 'claude', model: null, effort: null, policy: 'ask' });
});

test('a started chat keeps the profile snapshot: id, name, instructions', () => {
  assert.deepEqual(p.profileSnapshotOf(profile('r', { name: 'Reviewer', instructions: 'review it' })),
    { id: 'r', name: 'Reviewer', instructions: 'review it' });
});

test('chat and automation profile labels', () => {
  assert.equal(p.sessionProfileName({ profileId: 'r', profileName: 'Reviewer' }), 'Reviewer');
  assert.equal(p.sessionProfileName({ profileId: null, profileName: null }), null);
  assert.equal(p.sessionProfileName({ profileId: 'r', profileName: null }), null);
  const automation = { profileId: 'r' };
  assert.equal(p.automationProfileName(automation, [profile('r', { name: 'Reviewer' })]), 'Reviewer');
  // A profile deleted on the Mac reads as none, like the Mac editor.
  assert.equal(p.automationProfileName(automation, []), null);
  assert.equal(p.automationProfileName({ profileId: null }, [profile('r')]), null);
});

test('a new profile starts empty after the last one', () => {
  const made = p.newProfile([profile('a', { sortOrder: 3 }), profile('b', { sortOrder: 7 })], 'new-id');
  assert.equal(made.id, 'new-id');
  assert.equal(made.name, 'New profile');
  assert.equal(made.sortOrder, 8);
  assert.equal(made.permissionPolicy, 'ask');
  assert.deepEqual(made.skills, []);
  assert.equal(p.newProfile(undefined, 'x').sortOrder, 0);
});
