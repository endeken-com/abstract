const { test } = require('node:test');
const assert = require('node:assert/strict');
const { EventEmitter } = require('node:events');
const Module = require('node:module');
const fs = require('node:fs');
const ts = require('typescript');

const device = { peer: { id: 'mac-1', name: 'Mac', publicKey: 'key' }, address: '192.0.2.1:52000', pairedAt: 1 };
const sockets = [];
const requests = [];
let browser;

function frame(value) {
  const body = Buffer.from(typeof value === 'string' ? value : JSON.stringify(value));
  const header = Buffer.alloc(4);
  header.writeUInt32BE(body.length);
  return Buffer.concat([header, body]);
}

class Socket extends EventEmitter {
  constructor(host) { super(); this.host = host; this.destroyed = false; this.writes = 0; }
  write(data) {
    this.writes++;
    if (this.writes === 1) {
      this.pairing = Buffer.from(data).subarray(4).toString() === 'pair';
      queueMicrotask(() => this.emit('data', frame('{}')));
      return;
    }
    if (this.writes === 2) {
      if (this.pairing) queueMicrotask(() => this.emit('data', frame({ event: { _0: { paired: { _0: true } } } })));
      return;
    }
    const request = JSON.parse(Buffer.from(data).subarray(4).toString()).request;
    const name = Object.keys(request._1)[0];
    requests.push(name);
    queueMicrotask(() => {
      if (name === 'snapshot') this.emit('data', frame({ event: { _0: { snapshot: { _0: { pagedHistory: true, sessions: [], projects: [] } } } } }));
      this.emit('data', frame({ response: { id: request.id, _1: name === 'subscribeRecent' ? { historyPage: { beforeSeq: null, hasMore: false } } : { ok: {} } } }));
    });
  }
  destroy() { if (!this.destroyed) { this.destroyed = true; this.emit('close'); } }
}

class Zeroconf extends EventEmitter {
  constructor() { super(); browser = this; }
  scan() {}
}

const mocks = {
  'react-native-tcp-socket': { createConnection: ({ host }, connected) => { const socket = new Socket(host); sockets.push(socket); if (host !== '192.0.2.1') queueMicrotask(() => { socket.emit('connect'); connected(); }); return socket; } },
  'react-native-zeroconf': Zeroconf,
  '@react-native-async-storage/async-storage': { getItem: async () => JSON.stringify([device]), setItem: async () => {} },
  'react-native': { PermissionsAndroid: {}, Platform: { OS: 'ios' } },
  './internet': {
    validInternetAddress: x => /^[a-f0-9]{64}$/.test(x?.endpointId || ''),
    parseInvitation: () => { throw Error('not an invitation'); },
    InternetSocket: class {
      constructor() {
        this.raw = new Socket('internet'); this.frames = []; this.readers = [];
        this.raw.on('data', data => {
          const frame = data.subarray(4); const reader = this.readers.shift();
          if (reader) reader.resolve(frame); else this.frames.push(frame);
        });
      }
      async connect() {}
      read() { return this.frames.length ? Promise.resolve(this.frames.shift()) : new Promise((resolve, reject) => this.readers.push({resolve, reject})); }
      write(data) { const header = Buffer.alloc(4); header.writeUInt32BE(data.length); this.raw.write(Buffer.concat([header, data])); }
      close() { this.raw.destroy(); this.readers.splice(0).forEach(x => x.reject(Error('closed'))); this.onClose?.(Error('closed')); }
    }
  },
  './secure': { identity: async () => ({}), beginHandshake: (_, pairing) => ({ hello: Buffer.from(pairing ? 'pair' : 'hello'), finish: () => ({ peer: device.peer, finish: Buffer.from('finish'), cipher: { seal: x => x, open: x => x } }) }) },
  './framing': { FrameDecoder: class { push(data) { return [data.subarray(4)]; } } },
};
const originalLoad = Module._load;
Module._load = function (name, parent, main) { return name in mocks ? mocks[name] : originalLoad.call(this, name, parent, main); };
require.extensions['.ts'] = (module, path) => {
  const source = fs.readFileSync(path, 'utf8');
  module._compile(ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022, esModuleInterop: true } }).outputText, path);
};
const { RemoteClient } = require('../src/remote.ts');
Module._load = originalLoad;

test('discovery replaces a stale dial and waits for snapshot before bounded chat replay', async () => {
  const client = new RemoteClient();
  await client.load();
  assert.equal(client.status, 'connecting');
  browser.emit('resolved', { name: 'Mac', txt: { id: 'mac-1' }, addresses: ['192.0.2.2'], port: 52000 });
  await new Promise(resolve => setTimeout(resolve, 20));
  assert.equal(sockets[0].destroyed, true);
  assert.equal(client.status, 'online');
  assert.equal(client.active.address, '192.0.2.2:52000');
  await client.subscribeChat('chat-1');
  assert.deepEqual(requests, ['snapshot', 'subscribeRecent']);
  assert.equal(client.error, null);
  client.disconnect();
});

test('a newly paired Mac reaches online after the snapshot', async () => {
  const client = new RemoteClient();
  await client.connect('192.0.2.2:52000');
  assert.equal(client.status, 'online');
  assert.equal(client.active.peer.id, 'mac-1');
  assert.equal(client.snapshot.pagedHistory, true);
  client.disconnect();
});

test('an unreachable local address falls back to the saved internet identity', async () => {
  const client = new RemoteClient();
  const known = { ...device, address: '', internetAddress: { endpointId: 'a'.repeat(64) } };
  await client.connect('', known);
  assert.equal(client.status, 'online');
  assert.equal(client.active.peer.id, device.peer.id);
  assert.equal(client.active.address, '');
  client.disconnect();
});
