import { Buffer } from 'buffer';
import { ed25519 } from '@noble/curves/ed25519';
import { sha256 } from '@noble/hashes/sha256';
import { uuid, type Identity } from './secure';
import type { InternetAddress, Peer } from './types';

type Invitation = { v: number; peer: Peer; address: InternetAddress; token: string; expires: number };
export const validInternetAddress = (address: any): address is InternetAddress =>
  typeof address?.endpointId === 'string' && /^[a-f0-9]{64}$/.test(address.endpointId);

export function parseInvitation(text: string): Invitation {
  const match = text.trim().match(/^abstract:\/\/connect\/([A-Za-z0-9_-]+)$/);
  if (!match || text.length > 4096) throw Error('Paste an Abstract invitation from your Mac.');
  const invitation = JSON.parse(Buffer.from(match[1].replace(/-/g, '+').replace(/_/g, '/'), 'base64').toString());
  const now = Date.now() / 1000;
  if (invitation.v !== 1 || !validInternetAddress(invitation.address) ||
      typeof invitation.peer?.id !== 'string' || typeof invitation.peer?.name !== 'string' ||
      typeof invitation.peer?.publicKey !== 'string' || Buffer.from(invitation.peer.publicKey, 'base64').length !== 32 ||
      typeof invitation.token !== 'string' || Buffer.from(invitation.token, 'base64').length !== 32 ||
      !Number.isSafeInteger(invitation.expires) || invitation.expires <= now || invitation.expires > now + 660) {
    throw Error('This invitation is invalid or expired. Copy a new one from your Mac.');
  }
  return invitation;
}

type NativeInternet = {
  connect(key: string, host: string, handle: string): Promise<string>;
  read(handle: string, count: number): Promise<string>;
  write(handle: string, bytes: string): Promise<void>;
  close(handle: string): Promise<void>;
};

export interface FramedConnection {
  read(): Promise<Buffer>;
  write(data: Uint8Array): void;
  close(error?: Error): void;
  onClose?: (error: Error) => void;
}

export class InternetSocket implements FramedConnection {
  onClose?: (error: Error) => void;
  private closed = false;
  private writes: Promise<void> = Promise.resolve();
  private readonly handle = uuid();
  private native: NativeInternet;
  constructor() {
    // Loaded only when needed: local networking also works in builds without a native bridge.
    this.native = require('expo-modules-core').requireNativeModule('AbstractInternet');
  }
  async connect(who: Identity, address: InternetAddress, invitation?: string) {
    const key = sha256(Buffer.concat([Buffer.from('abstract-internet-identity-v1'), Buffer.from(who.privateKey)]));
    const timer = setTimeout(() => this.close(Error('Internet connection timed out.')), 15000);
    try {
      const client = await this.native.connect(Buffer.from(key).toString('base64'), address.endpointId, this.handle);
      if (this.closed) { await this.native.close(this.handle); throw Error('Connection cancelled.'); }
      const timestamp = Math.floor(Date.now() / 1000);
      const proof = Buffer.from(`abstract-internet-v1\n${address.endpointId}\n${client}\n${timestamp}`);
      this.write(Buffer.from(JSON.stringify({ peer: who.peer, timestamp, invitation,
        signature: Buffer.from(ed25519.sign(proof, who.privateKey)).toString('base64') })));
    } finally { clearTimeout(timer); }
  }
  async read() {
    if (this.closed) throw Error('Mac disconnected.');
    const header = Buffer.from(await this.native.read(this.handle, 4), 'base64');
    if (header.length !== 4) throw Error('Invalid frame.');
    const length = header.readUInt32BE();
    if (length > 16 << 20) { this.close(); throw Error('Remote frame is too large.'); }
    return length ? Buffer.from(await this.native.read(this.handle, length), 'base64') : Buffer.alloc(0);
  }
  write(data: Uint8Array) {
    if (this.closed) throw Error('Mac disconnected.');
    const header = Buffer.alloc(4); header.writeUInt32BE(data.length);
    const frame = Buffer.concat([header, Buffer.from(data)]).toString('base64');
    this.writes = this.writes.then(() => {
      if (this.closed) throw Error('Mac disconnected.');
      return this.native.write(this.handle, frame);
    }).catch(error => this.close(error));
  }
  close(error = Error('Mac disconnected.')) {
    if (this.closed) return;
    this.closed = true;
    this.native.close(this.handle).catch(() => {});
    this.onClose?.(error);
  }
}
