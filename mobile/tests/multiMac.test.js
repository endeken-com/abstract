const { test, afterEach } = require('node:test');
const assert = require('node:assert/strict');
const { EventEmitter } = require('node:events');
const Module = require('node:module');
const fs = require('node:fs');
const ts = require('typescript');

// Three fake Macs. Studio and Laptop each have a project and a chat with the
// same id and the same name, so nothing may tell them apart except the Mac.
const macs = {
  '192.0.2.10': { peer: { id: 'mac-a', name: 'Studio', publicKey: 'a' }, up: true, createdAt: 10 },
  '192.0.2.20': { peer: { id: 'mac-b', name: 'Laptop', publicKey: 'b' }, up: true, createdAt: 20 },
  '192.0.2.30': { peer: { id: 'mac-c', name: 'Mini', publicKey: 'c' }, up: true, createdAt: 30 },
};
const device = host => ({ peer: macs[host].peer, address: `${host}:52000`, pairedAt: 1 });
let stored = [];
let sockets = [];
let requests = [];

function snapshotOf(mac) {
  return {
    pagedHistory: true, providers: ['claude'], alive: [],
    projects: [{ id: 'p1', name: 'Website', rootPath: '/work/website', defaultBaseRef: 'main', defaultProviderId: 'claude', defaultPermissionPolicy: 'ask' }],
    sessions: [{ id: 's1', projectId: 'p1', name: 'Fix login', providerId: 'claude', status: 'idle', createdAt: mac.createdAt, archivedAt: null }],
    pullRequests: { s1: { number: mac.createdAt, title: `Pull request on ${mac.peer.name}`, state: 'OPEN', isDraft: false } },
  };
}
function frame(value) {
  const body = Buffer.from(typeof value === 'string' ? value : JSON.stringify(value));
  const header = Buffer.alloc(4);
  header.writeUInt32BE(body.length);
  return Buffer.concat([header, body]);
}
class Socket extends EventEmitter {
  constructor(host) { super(); this.host = host; this.destroyed = false; this.writes = 0; }
  write(data) {
    const body = Buffer.from(data).subarray(4);
    this.writes++;
    if (this.writes === 1) {
      this.pairing = body.toString() === 'pair';
      queueMicrotask(() => this.emit('data', frame({ peer: macs[this.host].peer })));
      return;
    }
    if (this.writes === 2) {
      if (this.pairing) queueMicrotask(() => this.emit('data', frame({ event: { _0: { paired: { _0: true } } } })));
      return;
    }
    const request = JSON.parse(body.toString()).request;
    const name = Object.keys(request._1)[0];
    requests.push({ mac: macs[this.host].peer.name, name, args: request._1[name] });
    queueMicrotask(() => {
      if (name === 'snapshot') this.emit('data', frame({ event: { _0: { snapshot: { _0: snapshotOf(macs[this.host]) } } } }));
      this.emit('data', frame({ response: { id: request.id, _1: { ok: {} } } }));
    });
  }
  destroy() { if (!this.destroyed) { this.destroyed = true; this.emit('close'); } }
}
const mocks = {
  'react-native-tcp-socket': {
    createConnection: ({ host }, connected) => {
      const socket = new Socket(host); sockets.push(socket);
      queueMicrotask(() => macs[host]?.up ? (socket.emit('connect'), connected()) : socket.emit('error', Error('Host is down.')));
      return socket;
    },
  },
  'react-native-zeroconf': class extends EventEmitter { scan() {} },
  '@react-native-async-storage/async-storage': { getItem: async () => JSON.stringify(stored), setItem: async (_, value) => { stored = JSON.parse(value); } },
  'react-native': { PermissionsAndroid: {}, Platform: { OS: 'ios' } },
  './internet': { validInternetAddress: () => false, parseInvitation: () => { throw Error('not an invitation'); }, InternetSocket: class {} },
  './secure': {
    identity: async () => ({}),
    beginHandshake: (_, pairing) => ({
      hello: Buffer.from(pairing ? 'pair' : 'hello'),
      finish: (reply, pinned) => {
        const { peer } = JSON.parse(reply.toString());
        if (pinned && pinned.id !== peer.id) throw Error('This is a different Mac.');
        return { peer, code: '123456', finish: Buffer.from('finish'), cipher: { seal: x => x, open: x => x } };
      },
    }),
  },
  './framing': { FrameDecoder: class { push(data) { return [data.subarray(4)]; } } },
};
const originalLoad = Module._load;
Module._load = function (name, parent, main) { return name in mocks ? mocks[name] : originalLoad.call(this, name, parent, main); };
require.extensions['.ts'] = (module, path) => {
  const source = fs.readFileSync(path, 'utf8');
  module._compile(ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022, esModuleInterop: true } }).outputText, path);
};
const { RemoteStore } = require('../src/remote.ts');
const { itemKey, macChats, macProjects, macPullRequests } = require('../src/macs.ts');
Module._load = originalLoad;

const settle = () => new Promise(resolve => setTimeout(resolve, 20));
let store;
async function launch(...hosts) {
  stored = hosts.map(device);
  store = new RemoteStore();
  await store.load();
  await settle();
  return store;
}
afterEach(() => {
  store?.disconnect(); store = null;
  sockets = []; requests = [];
  for (const mac of Object.values(macs)) mac.up = true;
});

test('launch connects to every paired Mac, not just the first one paired', async () => {
  await launch('192.0.2.10', '192.0.2.20');
  assert.deepEqual(store.macs().map(mac => [mac.name, mac.state]), [['Studio', 'online'], ['Laptop', 'online']]);
  assert.deepEqual(requests.map(x => `${x.mac}:${x.name}`).sort(), ['Laptop:snapshot', 'Studio:snapshot']);
});

test('both Macs\' projects, chats and pull requests show together, each tagged with its Mac', async () => {
  await launch('192.0.2.10', '192.0.2.20');
  const macsNow = store.macs();
  assert.deepEqual(macProjects(macsNow).map(x => `${x.mac.name}/${x.project.name}`), ['Studio/Website', 'Laptop/Website']);
  assert.deepEqual(macChats(macsNow).map(x => `${x.mac.name}/${x.chat.name}`), ['Laptop/Fix login', 'Studio/Fix login']);
  assert.deepEqual(macPullRequests(macsNow).map(x => `${x.mac.name}/#${x.pr.number}/${x.chat.name}`), ['Studio/#10/Fix login', 'Laptop/#20/Fix login']);
});

test('a project and a chat with the same id and name on two Macs stay apart', async () => {
  await launch('192.0.2.10', '192.0.2.20');
  const keys = macChats(store.macs()).map(x => itemKey(x.mac.id, x.chat.id));
  assert.equal(new Set(keys).size, 2);
  assert.notEqual(store.client('mac-a'), store.client('mac-b'));
  assert.equal(store.client('mac-a').snapshot.pullRequests.s1.title, 'Pull request on Studio');
  assert.equal(store.client('mac-b').snapshot.pullRequests.s1.title, 'Pull request on Laptop');
});

test('messages and permission answers go to the Mac that owns the chat', async () => {
  await launch('192.0.2.10', '192.0.2.20');
  requests = [];
  await store.client('mac-b').request('send', { sessionId: 's1', text: 'Try again' });
  await store.client('mac-a').request('answer', { sessionId: 's1', requestId: 'r1', allow: true });
  assert.deepEqual(requests, [
    { mac: 'Laptop', name: 'send', args: { sessionId: 's1', text: 'Try again' } },
    { mac: 'Studio', name: 'answer', args: { sessionId: 's1', requestId: 'r1', allow: true } },
  ]);
});

test('when one Mac sleeps the other keeps working, and the sleeping one keeps its last projects', async () => {
  await launch('192.0.2.10', '192.0.2.20');
  macs['192.0.2.20'].up = false;
  sockets.filter(socket => socket.host === '192.0.2.20').forEach(socket => socket.destroy());
  await store.reconnect('mac-b').catch(() => {});
  assert.deepEqual(store.macs().map(mac => [mac.name, mac.state]), [['Studio', 'online'], ['Laptop', 'unreachable']]);
  assert.deepEqual(store.mac('mac-b').snapshot.projects.map(x => x.name), ['Website']);
  requests = [];
  await store.client('mac-a').request('send', { sessionId: 's1', text: 'Still here' });
  assert.deepEqual(requests.map(x => `${x.mac}:${x.name}`), ['Studio:send']);
  await assert.rejects(store.client('mac-b').request('send', { sessionId: 's1', text: 'Lost?' }), /Connect to a Mac first/);
});

test('a Mac that comes back is reached again without touching the other', async () => {
  await launch('192.0.2.10', '192.0.2.20');
  macs['192.0.2.20'].up = false;
  sockets.filter(socket => socket.host === '192.0.2.20').forEach(socket => socket.destroy());
  await store.reconnect('mac-b').catch(() => {});
  const studio = sockets.find(socket => socket.host === '192.0.2.10');
  macs['192.0.2.20'].up = true;
  await store.resume();
  assert.deepEqual(store.macs().map(mac => mac.state), ['online', 'online']);
  assert.equal(studio.destroyed, false);
});

test('pairing a new Mac adds it alongside the ones already connected', async () => {
  await launch('192.0.2.10');
  const pairing = store.connect('192.0.2.30:52000');
  await new Promise(resolve => setImmediate(resolve));
  await pairing;
  assert.equal(store.pairing, null);
  assert.deepEqual(store.macs().map(mac => [mac.name, mac.state]), [['Studio', 'online'], ['Mini', 'online']]);
  assert.deepEqual(stored.map(x => x.peer.id), ['mac-a', 'mac-c']);
});

test('forgetting a Mac drops only that Mac', async () => {
  await launch('192.0.2.10', '192.0.2.20');
  await store.forget('mac-a');
  assert.deepEqual(store.macs().map(mac => mac.name), ['Laptop']);
  assert.equal(store.client('mac-b').status, 'online');
  assert.equal(store.client('mac-a').snapshot, null);
});
