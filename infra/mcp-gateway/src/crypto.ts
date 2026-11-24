const encoder = new TextEncoder();

/** `bytes` random bytes, base64url without padding. */
export function randomToken(bytes = 32): string {
  const data = crypto.getRandomValues(new Uint8Array(bytes));
  return base64url(data);
}

export function base64url(data: Uint8Array): string {
  let s = '';
  for (const b of data) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

/** HMAC-SHA-256 of `message` under `key`, hex. */
export async function hmac(key: string, message: string): Promise<string> {
  if (!key || key.length < 32) throw new Error('DEVICE_PEPPER is missing or shorter than 32 characters.');
  const k = await crypto.subtle.importKey('raw', encoder.encode(key), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const sig = new Uint8Array(await crypto.subtle.sign('HMAC', k, encoder.encode(message)));
  return [...sig].map((b) => b.toString(16).padStart(2, '0')).join('');
}

/** Equal-length strings compared without an early exit. */
export function constantTimeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

/** Letters and digits that can't be mistaken for each other (no 0/O, 1/I/L). */
const CODE_ALPHABET = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';

/** An 8-character connection code, shown as `XXXX-XXXX`: about 40 bits. */
export function connectionCode(): string {
  const out: string[] = [];
  while (out.length < 8) {
    const [byte] = crypto.getRandomValues(new Uint8Array(1));
    // Rejection sampling keeps every character equally likely.
    if (byte < 256 - (256 % CODE_ALPHABET.length)) out.push(CODE_ALPHABET[byte % CODE_ALPHABET.length]);
  }
  return `${out.slice(0, 4).join('')}-${out.slice(4).join('')}`;
}

/** A typed code, uppercased, without spaces or dashes; null unless it could be one. */
export function normalizeCode(typed: string): string | null {
  const code = typed.toUpperCase().replace(/[\s-]/g, '');
  if (code.length !== 8 || [...code].some((c) => !CODE_ALPHABET.includes(c))) return null;
  return `${code.slice(0, 4)}-${code.slice(4)}`;
}

export const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

/** A device credential is `<mac id>.<secret>`. */
export function parseDeviceCredential(header: string | null): { macId: string; secret: string } | null {
  const match = /^Device\s+([0-9a-f-]{36})\.([A-Za-z0-9_-]{43})$/.exec(header?.trim() ?? '');
  if (!match || !UUID.test(match[1])) return null;
  return { macId: match[1], secret: match[2] };
}

export function credentialHash(pepper: string, macId: string, secret: string): Promise<string> {
  return hmac(pepper, `device:${macId}.${secret}`);
}
