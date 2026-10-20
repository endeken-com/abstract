const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const ts = require('typescript');

const transpile = (module, path) => {
  const source = fs.readFileSync(path, 'utf8');
  const js = ts.transpileModule(source, { fileName: path, compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022, esModuleInterop: true } }).outputText;
  module._compile(js, path);
};
require.extensions['.ts'] = transpile;
const p = require('../src/pause.ts');

const project = (id, name) => ({ id, name, rootPath: `/work/${id}`, defaultBaseRef: 'main', defaultProviderId: 'claude', defaultPermissionPolicy: 'ask' });
const snapshot = (fields = {}) => ({ projects: [project('web', 'Website'), project('api', 'API')], sessions: [], providers: [], alive: [], ...fields });
const capable = (fields = {}) => snapshot({ pauseControl: true, everythingPaused: false, pausedProjectIds: [], ...fields });
const mac = (id, name, snap, state = 'online') => ({ id, name, state, snapshot: snap, lastSeenAt: null });

test('an older Mac without pause fields offers nothing', () => {
  const old = snapshot();
  assert.equal(p.pauseSupported(old), false);
  assert.equal(p.globalPauseAction(old), null);
  assert.equal(p.projectPauseAction(old, 'web'), null);
  assert.equal(p.hasAnyPause(old), false);
  assert.deepEqual(p.pauseBannerRows([mac('m1', 'Studio', old)]), []);
  assert.equal(p.globalPauseAction(null), null);
  assert.equal(p.isProjectPaused(null, 'web'), false);
});

test('global action toggles on everythingPaused', () => {
  assert.equal(p.globalPauseAction(capable()), 'pause');
  assert.equal(p.globalPauseAction(capable({ pausedProjectIds: ['web'] })), 'pause');
  assert.equal(p.globalPauseAction(capable({ everythingPaused: true })), 'resume');
  assert.equal(p.globalPauseAction(capable({ everythingPaused: true, pausedProjectIds: ['web'] })), 'resume');
});

test('project action mirrors the Mac menu: hidden while everything is paused', () => {
  assert.equal(p.projectPauseAction(capable(), 'web'), 'pause');
  assert.equal(p.projectPauseAction(capable({ pausedProjectIds: ['web'] }), 'web'), 'resume');
  assert.equal(p.projectPauseAction(capable({ pausedProjectIds: ['web'] }), 'api'), 'pause');
  assert.equal(p.projectPauseAction(capable({ everythingPaused: true }), 'web'), null);
  assert.equal(p.projectPauseAction(capable({ everythingPaused: true, pausedProjectIds: ['web'] }), 'web'), null);
});

test('a project counts as paused under a global pause too', () => {
  assert.equal(p.isProjectPaused(capable({ everythingPaused: true }), 'api'), true);
  assert.equal(p.isProjectPaused(capable({ pausedProjectIds: ['web'] }), 'api'), false);
});

test('requests carry the exact names and args the Mac decodes', () => {
  assert.deepEqual(p.pauseRequest('pause'), { name: 'pauseEverything', args: {} });
  assert.deepEqual(p.pauseRequest('resume'), { name: 'resumeEverything', args: {} });
  assert.deepEqual(p.pauseRequest('pause', 'web'), { name: 'pauseProject', args: { projectId: 'web' } });
  assert.deepEqual(p.pauseRequest('resume', 'web'), { name: 'resumeProject', args: { projectId: 'web' } });
});

test('banner: one global row while everything is paused, project rows otherwise', () => {
  const all = p.pauseBannerRows([mac('m1', 'Studio', capable({ everythingPaused: true, pausedProjectIds: ['web'] }))]);
  assert.equal(all.length, 1);
  assert.equal(all[0].kind, 'all');
  assert.match(all[0].text, /Everything is paused on Studio/);
  assert.equal(all[0].button, 'Resume everything');
  assert.deepEqual(all[0].request, { name: 'resumeEverything', args: {} });
  assert.equal(all[0].canAct, true);

  const rows = p.pauseBannerRows([mac('m1', 'Studio', capable({ pausedProjectIds: ['api', 'web', 'gone'] }))]);
  // Snapshot project order, and a paused id no longer listed gets no row.
  assert.deepEqual(rows.map(r => r.projectId), ['web', 'api']);
  assert.match(rows[0].text, /“Website” is paused on Studio/);
  assert.equal(rows[0].button, 'Resume');
  assert.deepEqual(rows[0].request, { name: 'resumeProject', args: { projectId: 'web' } });
});

test('banner narrows to one project but keeps the global row', () => {
  const one = mac('m1', 'Studio', capable({ pausedProjectIds: ['web', 'api'] }));
  assert.deepEqual(p.pauseBannerRows([one], 'api').map(r => r.projectId), ['api']);
  const global = mac('m1', 'Studio', capable({ everythingPaused: true }));
  assert.equal(p.pauseBannerRows([global], 'api')[0].kind, 'all');
});

test('banner spans Macs; an unreachable Mac shows state but cannot act', () => {
  const rows = p.pauseBannerRows([
    mac('m1', 'Studio', capable({ everythingPaused: true }), 'unreachable'),
    mac('m2', 'Laptop', capable({ pausedProjectIds: ['web'] })),
    mac('m3', 'Mini', capable()),
    mac('m4', 'Old', snapshot()),
  ]);
  assert.deepEqual(rows.map(r => [r.hostId, r.kind, r.canAct]), [['m1', 'all', false], ['m2', 'project', true]]);
});

test('chat banner covers its project, everything, and standalone chats', () => {
  const projectPaused = mac('m1', 'Studio', capable({ pausedProjectIds: ['web'] }));
  assert.equal(p.chatPauseRow(projectPaused, 'web')?.projectId, 'web');
  assert.equal(p.chatPauseRow(projectPaused, 'api'), null);
  assert.equal(p.chatPauseRow(projectPaused, null), null);
  const all = mac('m1', 'Studio', capable({ everythingPaused: true }));
  assert.equal(p.chatPauseRow(all, null)?.kind, 'all');
  assert.equal(p.chatPauseRow(all, 'api')?.kind, 'all');
});

test('global pause confirmation names the Mac and what resume restores', () => {
  const { title, message } = p.globalPauseConfirm('Studio');
  assert.equal(title, 'Pause everything?');
  assert.match(message, /on Studio\?/);
  assert.match(message, /only the automations this pause switched off/);
  assert.match(message, /agents are not restarted/);
});
