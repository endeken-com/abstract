import { Buffer } from 'buffer';
import { ed25519, x25519 } from '@noble/curves/ed25519';
import { sha256 } from '@noble/hashes/sha256';
import { hkdf } from '@noble/hashes/hkdf';
import { chacha20poly1305 } from '@noble/ciphers/chacha';
import type { Peer } from './types';

const utf8 = (text: string) => new Uint8Array(Buffer.from(text, 'utf8'));
const bytes = (base64: string) => new Uint8Array(Buffer.from(base64, 'base64'));
const base64 = (value: Uint8Array) => Buffer.from(value).toString('base64');
const concat = (...parts: Uint8Array[]) => new Uint8Array(Buffer.concat(parts.map(p => Buffer.from(p))));
const sorted = (value: unknown): unknown => Array.isArray(value) ? value.map(sorted) :
  value && typeof value === 'object' ? Object.fromEntries(Object.entries(value).sort(([a], [b]) => a.localeCompare(b, 'en')).map(([k, v]) => [k, sorted(v)])) : value;
// Swift JSONEncoder's default escapes slashes, including those in base64 keys.
const encode = (value: unknown) => utf8(JSON.stringify(sorted(value)).replace(/\//g, '\\/'));
export function uuid() {
  const data = new Uint8Array(16);
  global.crypto.getRandomValues(data);
  data[6] = (data[6] & 15) | 64;
  data[8] = (data[8] & 63) | 128;
  const hex = Buffer.from(data).toString('hex');
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

export type Identity = { peer: Peer; privateKey: Uint8Array };
export async function identity(): Promise<Identity> {
  const SecureStore = await import('expo-secure-store');
  let id = await SecureStore.getItemAsync('remote-device-id');
  let key = await SecureStore.getItemAsync('remote-signing-key');
  if (!id || !key) {
    id = uuid();
    const seed = ed25519.utils.randomPrivateKey();
    key = base64(seed);
    await SecureStore.setItemAsync('remote-device-id', id);
    await SecureStore.setItemAsync('remote-signing-key', key);
  }
  const privateKey = bytes(key);
  return { peer: { id, name: 'Abstract Mobile', publicKey: base64(ed25519.getPublicKey(privateKey)) }, privateKey };
}

export class Cipher {
  private sent = 0;
  private received = 0;
  constructor(private sendKey: Uint8Array, private receiveKey: Uint8Array) {}
  private nonce(counter: number) {
    const n = new Uint8Array(12);
    for (let i = 11; i >= 4; i--) { n[i] = counter % 256; counter = Math.floor(counter / 256); }
    return n;
  }
  seal(plain: Uint8Array): Uint8Array {
    const nonce = this.nonce(this.sent++);
    return concat(nonce, chacha20poly1305(this.sendKey, nonce).encrypt(plain));
  }
  open(frame: Uint8Array): Uint8Array {
    const expected = this.nonce(this.received++);
    if (frame.length < 28 || !expected.every((b, i) => b === frame[i])) throw Error('Remote frame was altered.');
    return chacha20poly1305(this.receiveKey, expected).decrypt(frame.slice(12));
  }
}

export function beginHandshake(who: Identity, pairing: boolean) {
  const secretKey = x25519.utils.randomPrivateKey();
  const hello = encode({ v: 1, peer: who.peer, ephemeral: base64(x25519.getPublicKey(secretKey)), pairing });
  return {
    hello,
    finish(replyBytes: Uint8Array, pinned?: Peer) {
      const reply = JSON.parse(Buffer.from(replyBytes).toString('utf8')) as { v: number; peer: Peer; ephemeral: string; signature: string };
      if (reply.v !== 1 || !reply.signature || !reply.peer?.publicKey) throw Error('Incompatible Mac remote protocol.');
      if (!pairing && (!pinned || pinned.id !== reply.peer.id || pinned.publicKey !== reply.peer.publicKey)) throw Error('The Mac identity changed or is not paired.');
      const transcript = sha256(concat(utf8('abstract-remote-v1'), hello,
        encode({ v: reply.v, peer: reply.peer, ephemeral: reply.ephemeral })));
      if (!ed25519.verify(bytes(reply.signature), concat(utf8('responder'), transcript), bytes(reply.peer.publicKey))) throw Error('Mac identity signature failed.');
      const shared = x25519.getSharedSecret(secretKey, bytes(reply.ephemeral));
      const codeBytes = hkdf(sha256, shared, transcript, utf8('abstract pairing code'), 8);
      const number = codeBytes.reduce((value, byte) => (value * 256 + byte) % 1_000_000, 0);
      const digits = String(number).padStart(6, '0');
      return {
        peer: reply.peer, code: `${digits.slice(0, 3)} ${digits.slice(3)}`,
        finish: encode({ signature: base64(ed25519.sign(concat(utf8('initiator'), transcript), who.privateKey)) }),
        cipher: new Cipher(hkdf(sha256, shared, transcript, utf8('abstract i2r'), 32),
          hkdf(sha256, shared, transcript, utf8('abstract r2i'), 32))
      };
    }
  };
}
