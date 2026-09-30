import { Buffer } from 'buffer';
import TcpSocket from 'react-native-tcp-socket';
import Zeroconf from 'react-native-zeroconf';
import AsyncStorage from '@react-native-async-storage/async-storage';
import { PermissionsAndroid, Platform } from 'react-native';
import { beginHandshake, Cipher, identity } from './secure';
import { FrameDecoder } from './framing';
import { InternetSocket, parseInvitation, validInternetAddress, type FramedConnection } from './internet';
import type { Device, Nearby, Peer, RemoteLine, Snapshot } from './types';

type Listener = (state: RemoteClient) => void;
type Reply = Record<string, any>;

function endpoint(address: string) {
  const match = address.trim().match(/^\[([^\]]+)\]:(\d+)$|^([^:]+):(\d+)$/);
  if (!match) throw Error('Use an address such as mac.local:52000 or 192.168.1.20:52000.');
  const port = Number(match[2] || match[4]);
  if (port < 1 || port > 65535) throw Error('Invalid port.');
  return { host: match[1] || match[3], port };
}

class FramedSocket {
  private decoder = new FrameDecoder();
  private frames: Buffer[] = [];
  private readers: Array<{ resolve: (data: Buffer) => void; reject: (error: Error) => void }> = [];
  private closed = false;
  onClose?: (error: Error) => void;
  constructor(private socket: ReturnType<typeof TcpSocket.createConnection>) {
    socket.on('data', chunk => {
      let frames: Buffer[];
      try { frames = this.decoder.push(Buffer.from(chunk)); }
      catch (error) { this.close(error as Error); return; }
      for (const frame of frames) {
        const reader = this.readers.shift();
        if (reader) reader.resolve(frame); else this.frames.push(frame);
      }
    });
    socket.on('error', error => this.close(error));
    socket.on('close', () => this.close(Error('Mac disconnected.')));
  }
  read(): Promise<Buffer> {
    if (this.frames.length) return Promise.resolve(this.frames.shift()!);
    if (this.closed) return Promise.reject(Error('Mac disconnected.'));
    return new Promise((resolve, reject) => this.readers.push({ resolve, reject }));
  }
  write(data: Uint8Array) {
    if (this.closed) throw Error('Mac disconnected.');
    const header = Buffer.alloc(4);
    header.writeUInt32BE(data.length, 0);
    this.socket.write(Buffer.concat([header, Buffer.from(data)]));
  }
  close(error = Error('Mac disconnected.')) {
    if (this.closed) return;
    this.closed = true;
    this.socket.destroy();
    this.readers.splice(0).forEach(reader => reader.reject(error));
    this.onClose?.(error);
  }
}

export class RemoteClient {
  devices: Device[] = [];
  nearby: Nearby[] = [];
  active: Device | null = null;
  snapshot: Snapshot | null = null;
  status = 'offline';
  pairingCode: string | null = null;
  error: string | null = null;
  lines: Record<string, RemoteLine[]> = {};
  historyBefore: Record<string, number | null> = {};
  loadingHistory = new Set<string>();
  terminals: Record<number, string> = {};
  private listeners = new Set<Listener>();
  private socket: FramedConnection | null = null;
  private cipher: Cipher | null = null;
  private nextId = 1;
  private pending = new Map<number, { resolve: (value: Reply) => void; reject: (error: Error) => void; timer: ReturnType<typeof setTimeout> }>();
  private browser: Zeroconf | null = null;
  private reconnect: ReturnType<typeof setTimeout> | null = null;
  private connectionEpoch = 0;
  private connectingAddress: string | null = null;
  private connectingPeerId: string | null = null;
  private connectingTask: Promise<void> | null = null;
  private abortDial: (() => void) | null = null;
  private lineNotification: ReturnType<typeof setTimeout> | null = null;
  private watched = new Set<string>();
  private subscribing = new Map<string, Promise<void>>();
  private replayBuffers = new Map<string, RemoteLine[]>();
  private snapshotHostId: string | null = null;

  subscribe(listener: Listener) { this.listeners.add(listener); listener(this); return () => { this.listeners.delete(listener); }; }
  private changed() { this.listeners.forEach(listener => listener(this)); }
  private linesChanged() {
    if (this.lineNotification) return;
    this.lineNotification = setTimeout(() => {
      this.lineNotification = null;
      this.changed();
    }, 80);
  }
  async load() {
    try { this.devices = JSON.parse(await AsyncStorage.getItem('paired-macs') || '[]'); } catch { this.devices = []; }
    this.changed();
    this.discover().catch(() => {});
    if (this.devices[0]) this.connect(this.devices[0].address, this.devices[0]).catch(() => {});
  }
  async discover() {
    if (this.browser) return;
    try {
      if (Platform.OS === 'android' && Number(Platform.Version) >= 33) {
        const permission = await PermissionsAndroid.request(PermissionsAndroid.PERMISSIONS.NEARBY_WIFI_DEVICES);
        if (permission !== PermissionsAndroid.RESULTS.GRANTED) throw Error('Nearby Wi-Fi permission is needed to discover Macs.');
      }
      const browser = new Zeroconf();
      this.browser = browser;
      browser.on('resolved', (service: any) => {
        const id = service.txt?.id || service.txtRecord?.id || service.name;
        const host = service.addresses?.find((x: string) => /^\d+\.\d+\.\d+\.\d+$/.test(x)) || service.host;
        if (!host || !service.port) return;
        this.nearby = [...this.nearby.filter(x => x.id !== id), { id, name: service.name, address: `${host}:${service.port}` }];
        this.changed();
        const paired = this.devices.find(x => x.peer.id === id || x.peer.name === service.name);
        const address = `${host}:${service.port}`;
        if (paired && (!this.active || this.active.peer.id === paired.peer.id) && this.status !== 'online' && (this.connectingAddress !== address || this.connectingPeerId !== paired.peer.id)) {
          this.connect(address, paired).catch(() => {});
        }
      });
      browser.on('remove', (name: string) => { this.nearby = this.nearby.filter(x => x.name !== name); this.changed(); });
      browser.scan('abstract', 'tcp', 'local.');
    } catch (error) { if (!this.active && !this.devices.length) { this.error = String(error); this.changed(); } }
  }
  private async persist() { await AsyncStorage.setItem('paired-macs', JSON.stringify(this.devices)); }
  async forget(id: string) {
    if (this.active?.peer.id === id) this.disconnect(true);
    this.devices = this.devices.filter(x => x.peer.id !== id);
    await this.persist(); this.changed();
  }
  disconnect(clearSnapshot = false) {
    this.connectionEpoch++;
    this.abortDial?.(); this.abortDial = null;
    this.connectingAddress = null; this.connectingPeerId = null; this.connectingTask = null;
    if (this.lineNotification) { clearTimeout(this.lineNotification); this.lineNotification = null; }
    if (this.reconnect) clearTimeout(this.reconnect);
    this.reconnect = null; this.pairingCode = null;
    for (const waiter of this.pending.values()) { clearTimeout(waiter.timer); waiter.reject(Error('Mac disconnected.')); }
    this.pending.clear();
    this.subscribing.clear();
    this.replayBuffers.clear();
    this.loadingHistory.clear();
    this.active = null; if (clearSnapshot) { this.snapshot = null; this.snapshotHostId = null; this.lines = {}; this.historyBefore = {}; this.watched.clear(); } this.status = 'offline'; this.error = null;
    this.terminals = {};
    const socket = this.socket; this.socket = null; socket?.close(); this.cipher = null; this.changed();
  }
  private scheduleReconnect() {
    if (!this.active || this.reconnect) return;
    this.reconnect = setTimeout(() => {
      this.reconnect = null;
      if (this.active) {
        const nearby = this.nearby.find(x => x.id === this.active?.peer.id);
        this.connect(nearby?.address || this.active.address, this.active).catch(() => {});
      }
    }, 1500);
  }
  async resume() {
    const active = this.active;
    if (!active || this.status === 'pairing' || this.status === 'connecting') return;
    if (this.status === 'online') {
      try { await this.request('snapshot', {}, 5000); return; }
      catch { this.disconnect(); }
    }
    await this.connect(this.nearby.find(x => x.id === active.peer.id)?.address || active.address, active);
  }
  connect(address: string, paired?: Device): Promise<void> {
    if (this.status === 'online' && this.active?.peer.id === paired?.peer.id && this.active?.address === address) return Promise.resolve();
    if (this.status === 'connecting' && this.connectingAddress === address && this.connectingPeerId === (paired?.peer.id || null) && this.connectingTask) return this.connectingTask;
    this.disconnect(!paired || paired.peer.id !== this.snapshotHostId); this.active = paired || null; this.error = null; this.status = 'connecting'; this.changed();
    const epoch = this.connectionEpoch;
    this.connectingAddress = address; this.connectingPeerId = paired?.peer.id || null;
    const task = this.connectAttempt(address, paired, epoch);
    this.connectingTask = task;
    task.finally(() => { if (this.connectingTask === task) { this.connectingTask = null; this.connectingAddress = null; this.connectingPeerId = null; } }).catch(() => {});
    return task;
  }
  private async connectAttempt(address: string, paired: Device | undefined, epoch: number): Promise<void> {
    let socket: FramedConnection | null = null;
    try {
      const invite = address.trim().startsWith('abstract://') ? parseInvitation(address) : undefined;
      const internetAddress = invite?.address || (address.startsWith('iroh:') ? { endpointId: address.slice(5) } : undefined);
      const who = await identity();
      if (epoch !== this.connectionEpoch) return;
      const handshake = beginHandshake(who, !paired);
      if (internetAddress) {
        if (!validInternetAddress(internetAddress)) throw Error('Invalid internet address.');
        const remote = new InternetSocket();
        socket = remote; this.socket = remote;
        const abort = () => remote.close(Error('Connection replaced.'));
        this.abortDial = abort;
        try { await remote.connect(who, internetAddress, invite?.token); }
        finally { if (this.abortDial === abort) this.abortDial = null; }
      } else {
      const { host, port } = endpoint(address);
      const raw = await new Promise<ReturnType<typeof TcpSocket.createConnection>>((resolve, reject) => {
        let settled = false;
        const rawSocket = TcpSocket.createConnection({ host, port }, () => finish());
        const finish = (error?: Error) => {
          if (settled) return;
          settled = true;
          clearTimeout(timer);
          rawSocket.removeListener('connect', connected);
          rawSocket.removeListener('error', failed);
          rawSocket.removeListener('close', closed);
          if (this.abortDial === abort) this.abortDial = null;
          if (error) { rawSocket.destroy(); reject(error); } else resolve(rawSocket);
        };
        const connected = () => finish();
        const failed = (error: Error) => finish(error);
        const closed = () => finish(Error('Connection closed.'));
        const abort = () => finish(Error('Connection replaced.'));
        const timer = setTimeout(() => finish(Error('Connection timed out.')), 5000);
        this.abortDial = abort;
        rawSocket.once('connect', connected);
        rawSocket.once('error', failed);
        rawSocket.once('close', closed);
      });
      if (epoch !== this.connectionEpoch) { raw.destroy(); return; }
      socket = new FramedSocket(raw); this.socket = socket;
      }
      if (epoch !== this.connectionEpoch) { socket.close(); return; }
      socket.write(handshake.hello);
      let handshakeTimer: ReturnType<typeof setTimeout> | undefined;
      const reply = await Promise.race([
        socket.read(),
        new Promise<never>((_, reject) => { handshakeTimer = setTimeout(() => reject(Error('Mac did not complete the connection.')), 5000); }),
      ]).finally(() => clearTimeout(handshakeTimer));
      const outcome = handshake.finish(reply, paired?.peer);
      if (invite && (outcome.peer.id !== invite.peer.id || outcome.peer.publicKey !== invite.peer.publicKey)) throw Error('The host does not match this invitation.');
      socket.write(outcome.finish);
      this.cipher = outcome.cipher;
      if (!paired) {
        this.pairingCode = outcome.code; this.status = 'pairing'; this.changed();
        const pairingTimeout = setTimeout(() => socket?.close(Error('Pairing timed out.')), 60000);
        const answer = this.decode(await socket.read().finally(() => clearTimeout(pairingTimeout)));
        if (epoch !== this.connectionEpoch) { socket.close(); return; }
        if (answer.event?._0?.paired?._0 !== true) throw Error('Pairing was declined on the Mac.');
        paired = { peer: outcome.peer, address: internetAddress ? '' : address, internetAddress, pairedAt: Date.now() };
        this.devices = [...this.devices.filter(x => x.peer.id !== paired!.peer.id), paired];
        await this.persist();
      } else if (!internetAddress && paired.address !== address) {
        paired.address = address; await this.persist();
      }
      if (epoch !== this.connectionEpoch) { socket.close(); return; }
      this.active = paired; this.connectingPeerId = paired?.peer.id || null;
      this.status = 'connecting'; this.pairingCode = null; this.changed();
      socket.onClose = error => {
        if (this.socket !== socket) return;
        this.socket = null; this.cipher = null;
        this.status = 'offline'; this.error = null; this.changed();
        for (const waiter of this.pending.values()) { clearTimeout(waiter.timer); waiter.reject(error); }
        this.pending.clear();
        this.scheduleReconnect();
      };
      this.receive(socket);
      await this.request('snapshot');
      if (epoch !== this.connectionEpoch) return;
      this.status = 'online'; this.pairingCode = null; this.changed();
      await Promise.all([...this.watched].map(sessionId => this.subscribeChat(sessionId)));
    } catch (error) {
      socket?.close();
      if (epoch !== this.connectionEpoch) return;
      this.socket = null; this.cipher = null;
      // A stale local address should not prevent reaching the same pinned host online.
      if (paired?.internetAddress && !address.startsWith('iroh:') && !address.startsWith('abstract://')) {
        return this.connectAttempt('iroh:' + paired.internetAddress.endpointId, paired, epoch);
      }
      this.error = String(error); this.status = 'offline'; this.pairingCode = null; this.changed();
      if (paired) this.scheduleReconnect();
      throw error;
    }
  }
  private decode(frame: Buffer) {
    if (!this.cipher) throw Error('Connection is not secure.');
    return JSON.parse(Buffer.from(this.cipher.open(frame)).toString('utf8'));
  }
  private mergeLines(sessionId: string, incoming: RemoteLine[]): boolean {
    const known = this.lines[sessionId] || [];
    const last = known.at(-1)?.seq || 0;
    const fresh = incoming.filter(line => line.seq > last);
    if (fresh.length === incoming.length && fresh.every((line, i) => i === 0 || line.seq > fresh[i - 1].seq)) {
      if (!fresh.length) return false;
      this.lines[sessionId] = known.concat(fresh);
      return true;
    }
    // Replay can overtake a live event after subscribing. Preserve both.
    const bySequence = new Map(known.map(line => [line.seq, line]));
    for (const line of incoming) bySequence.set(line.seq, line);
    if (bySequence.size === known.length) return false;
    this.lines[sessionId] = [...bySequence.values()].sort((a, b) => a.seq - b.seq);
    return true;
  }
  private async receive(socket: FramedConnection) {
    try {
      while (this.socket === socket) {
        const message = this.decode(await socket.read());
        if (message.response) {
          const { id, _1: response } = message.response;
          const waiter = this.pending.get(id);
          if (waiter) { this.pending.delete(id); clearTimeout(waiter.timer); response.failed !== undefined ? waiter.reject(Error(response.failed._0)) : waiter.resolve(response); }
        } else if (message.event?._0) {
          const event = message.event._0;
          if (event.snapshot) {
            this.snapshot = event.snapshot._0; this.snapshotHostId = this.active?.peer.id || null;
            if (this.active) {
              const address = validInternetAddress(this.snapshot?.internetAddress) ? this.snapshot.internetAddress : undefined;
              if (this.active.internetAddress?.endpointId !== address?.endpointId) {
                this.active.internetAddress = address;
                this.persist().catch(() => {});
              }
            }
          }
          let receivedLines = false;
          if (event.lines) {
            const { sessionId, _1: incoming } = event.lines;
            const buffer = this.replayBuffers.get(sessionId);
            if (buffer) for (const line of incoming as RemoteLine[]) buffer.push(line);
            else receivedLines = this.mergeLines(sessionId, incoming as RemoteLine[]);
          }
          if (event.terminalOutput) {
            const { id, _1: data } = event.terminalOutput;
            const chunk = Buffer.from(data, 'base64').toString('utf8');
            this.terminals[id] = (this.terminals[id] || '') + chunk;
          }
          if (event.terminalExit) {
            const { id, code } = event.terminalExit;
            this.terminals[id] = (this.terminals[id] || '') + `\n[Terminal exited: ${code ?? ''}]`;
          }
          // A replay can be thousands of events. Publish it once, after the
          // subscribe response, so React does not relayout the whole chat for
          // every network batch.
          if (event.lines && this.replayBuffers.has(event.lines.sessionId)) continue;
          if ((receivedLines || event.terminalOutput) && !event.snapshot && !event.terminalExit) this.linesChanged();
          else this.changed();
        }
      }
    } catch (error) { socket.close(error as Error); }
  }
  async request(name: string, args: Record<string, unknown> = {}, timeoutMs = 30000): Promise<Reply> {
    if (!this.socket || !this.cipher || (this.status !== 'online' && !(this.status === 'connecting' && name === 'snapshot'))) throw Error('Connect to a Mac first.');
    const id = this.nextId++;
    const body = Buffer.from(JSON.stringify({ request: { id, _1: { [name]: args } } }), 'utf8');
    const result = new Promise<Reply>((resolve, reject) => {
      const timer = setTimeout(() => { if (this.pending.has(id)) { this.pending.delete(id); reject(Error('Mac did not respond.')); } }, timeoutMs);
      this.pending.set(id, { resolve, reject, timer });
    });
    try { this.socket.write(this.cipher.seal(body)); }
    catch (error) {
      const waiter = this.pending.get(id);
      if (waiter) { this.pending.delete(id); clearTimeout(waiter.timer); waiter.reject(error as Error); }
    }
    return result;
  }
  async subscribeChat(sessionId: string) {
    this.watched.add(sessionId);
    const existing = this.subscribing.get(sessionId);
    if (existing) return existing;
    const afterSeq = this.lines[sessionId]?.at(-1)?.seq || 0;
    // Reopening after a long absence must also stay bounded. The newest page
    // merges with any lines already in memory; older gaps remain fetchable.
    const recent = this.snapshot?.pagedHistory === true;
    const replay = [] as RemoteLine[];
    this.replayBuffers.set(sessionId, replay);
    const task = this.request(recent ? 'subscribeRecent' : 'subscribe', recent ? { sessionId, limit: 160 } : { sessionId, afterSeq }, 300000).then(response => {
      if (recent) {
        const page = response.historyPage;
        if (!page || (page.hasMore && typeof page.beforeSeq !== 'number')) throw Error('Mac did not return a history page.');
        this.historyBefore[sessionId] = page?.hasMore ? page.beforeSeq : null;
      }
    });
    this.subscribing.set(sessionId, task);
    let complete = false;
    try { await task; complete = true; } finally {
      if (this.subscribing.get(sessionId) === task) {
        this.subscribing.delete(sessionId);
        if (this.replayBuffers.get(sessionId) === replay) this.replayBuffers.delete(sessionId);
        if (complete) {
          const previousLast = this.lines[sessionId]?.at(-1)?.seq || 0;
          const firstReceived = replay.reduce((minimum, line) => Math.min(minimum, line.seq), Infinity);
          // A long offline period can leave a hole between cached output and
          // the newest page. Keep the displayed transcript contiguous.
          const gap = recent && previousLast > 0 && Number.isFinite(firstReceived) && firstReceived > previousLast + 1;
          if (gap) this.lines[sessionId] = [];
          this.mergeLines(sessionId, replay);
          if (recent && !gap && typeof this.historyBefore[sessionId] === 'number') {
            const earliest = this.lines[sessionId]?.[0]?.seq;
            if (earliest && earliest < this.historyBefore[sessionId]!) this.historyBefore[sessionId] = earliest > 1 ? earliest : null;
          }
        }
        this.changed();
      }
    }
  }
  hasOlder(sessionId: string) { return typeof this.historyBefore[sessionId] === 'number'; }
  async loadOlder(sessionId: string) {
    const beforeSeq = this.historyBefore[sessionId];
    if (typeof beforeSeq !== 'number' || this.loadingHistory.has(sessionId) || this.subscribing.has(sessionId) || this.status !== 'online') return;
    const replay: RemoteLine[] = [];
    this.loadingHistory.add(sessionId);
    this.replayBuffers.set(sessionId, replay);
    this.changed();
    try {
      const response = await this.request('history', { sessionId, beforeSeq, limit: 160 }, 300000);
      const page = response.historyPage;
      if (!page || (page.hasMore && typeof page.beforeSeq !== 'number')) throw Error('Mac did not return a history page.');
      this.historyBefore[sessionId] = page.hasMore ? page.beforeSeq : null;
      this.mergeLines(sessionId, replay);
    } finally {
      if (this.replayBuffers.get(sessionId) === replay) this.replayBuffers.delete(sessionId);
      this.loadingHistory.delete(sessionId);
      this.changed();
    }
  }
  async unsubscribeChat(sessionId: string) {
    this.watched.delete(sessionId);
    if (this.status === 'online') await this.request('unsubscribe', { sessionId });
  }
  async refresh() {
    if (this.status !== 'online') return;
    await this.request('snapshot');
    for (const sessionId of this.watched) await this.subscribeChat(sessionId);
  }
  async exec(cwd: string, args: string[]) {
    const response = await this.request('exec', { command: 'git', args, cwd });
    return response.exec?._0 as { code: number; stdout: string; stderr: string };
  }
  async readFile(path: string) {
    const response = await this.request('readFile', { path });
    return Buffer.from(response.data?._0 || '', 'base64').toString('utf8');
  }
  async writeFile(path: string, content: string) {
    await this.request('writeFile', { path, data: Buffer.from(content, 'utf8').toString('base64') });
  }
  async openTerminal(cwd: string) {
    const id = this.nextId++;
    this.terminals[id] = '';
    await this.request('openTerminal', { id, cwd, cols: 80, rows: 24 });
    return id;
  }
  async terminalInput(id: number, text: string) {
    await this.request('terminalInput', { id, data: Buffer.from(text, 'utf8').toString('base64') });
  }
}

export const remote = new RemoteClient();
