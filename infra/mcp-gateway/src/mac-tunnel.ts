import { DurableObject } from 'cloudflare:workers';
import { getOAuthApi } from '@cloudflare/workers-oauth-provider';
import { connectionCode, constantTimeEqual, hmac } from './crypto';
import { number, type Env } from './env';
import { providerOptions } from './oauth';
import {
  PROTOCOL_VERSION, parseFromMac, rpcError,
  type ConsentResponse, type FromMac, type GrantSummary, type Projects, type Result,
} from './protocol';

import { CALLS_PER_MINUTE, CODE_TTL_MS, MAX_BODY, MAX_RESPONSE } from './limits';

/** What a forwarded call came to: the HTTP status and body for the MCP client. */
export interface CallOutcome {
  status: number;
  body: string;
  headers?: Record<string, string>;
  /** For the log only. */
  outcome: 'ok' | 'revoked' | 'rate_limited' | 'too_large' | 'offline' | 'timeout' | 'response_too_large';
}

export interface ConsentClient { name: string; domain?: string; redirectHost: string; loopback: boolean }

export type ConsentOutcome =
  | { kind: 'approved'; grantId: string }
  | { kind: 'denied' }
  | { kind: 'offline' }
  | { kind: 'timeout' };

interface Waiter { resolve: (message: FromMac | null) => void; timer: ReturnType<typeof setTimeout> }

/**
 * One registered Mac (ABS-218): its device credential (as an HMAC), its grants
 * and a rate-limit counter. Never chat content. The Mac keeps an outbound
 * WebSocket here (hibernatable: an idle socket costs no duration), and each
 * MCP call is sent over it as an envelope and answered with the same id.
 */
export class MacTunnel extends DurableObject<Env> {
  private waiters = new Map<string, Waiter>();
  private sql: SqlStorage;

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.sql = ctx.storage.sql;
    this.sql.exec(`
      CREATE TABLE IF NOT EXISTS mac (id TEXT PRIMARY KEY, credential_hash TEXT NOT NULL, created_at INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS grants (
        id TEXT PRIMARY KEY, client_id TEXT NOT NULL, client_key TEXT NOT NULL, client_name TEXT NOT NULL,
        client_domain TEXT, projects TEXT NOT NULL, phi INTEGER NOT NULL, created_at INTEGER NOT NULL,
        revoked_at INTEGER, last_used_at INTEGER);
      CREATE TABLE IF NOT EXISTS calls (at INTEGER NOT NULL);`);
    // Heartbeats are answered without waking the object.
    ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair('ping', 'pong'));
  }

  // MARK: Registration

  private macId(): string | null {
    const row = this.sql.exec<{ id: string }>('SELECT id FROM mac').toArray()[0];
    return row?.id ?? null;
  }

  /** Called once, by `/register`, for a fresh Mac id. */
  async register(macId: string, credentialHash: string): Promise<boolean> {
    if (this.macId() !== null) return false;
    this.sql.exec('INSERT INTO mac (id, credential_hash, created_at) VALUES (?, ?, ?)', macId, credentialHash, Date.now());
    return true;
  }

  /** The credential is this Mac's: its id is this object's and its HMAC matches. */
  private verify(macId: string, credentialHash: string): boolean {
    const row = this.sql.exec<{ id: string; credential_hash: string }>('SELECT id, credential_hash FROM mac').toArray()[0];
    if (!row) return false;
    return constantTimeEqual(row.id, macId) && constantTimeEqual(row.credential_hash, credentialHash);
  }

  /** Remote access turned off: the credential, every grant and its tokens are gone. */
  async unregister(macId: string, credentialHash: string): Promise<boolean> {
    if (!this.verify(macId, credentialHash)) return false;
    for (const ws of this.ctx.getWebSockets()) ws.close(4001, 'unregistered');
    await this.revokeLibraryGrants(macId, null);
    this.sql.exec('DELETE FROM grants');
    this.sql.exec('DELETE FROM calls');
    this.sql.exec('DELETE FROM mac');
    return true;
  }

  // MARK: The Mac's socket

  /** `/connect`, forwarded with the Mac id and credential HMAC the Worker computed. */
  async fetch(request: Request): Promise<Response> {
    if (request.headers.get('Upgrade')?.toLowerCase() !== 'websocket') return new Response(null, { status: 426 });
    const macId = request.headers.get('X-Abstract-Mac-Id') ?? '';
    const hash = request.headers.get('X-Abstract-Credential-Hash') ?? '';
    if (!this.verify(macId, hash)) return new Response(null, { status: 401 });
    // One connection per Mac: a new valid one replaces the old.
    for (const ws of this.ctx.getWebSockets()) ws.close(4000, 'replaced');
    const { 0: client, 1: server } = new WebSocketPair();
    this.ctx.acceptWebSocket(server);
    server.send(JSON.stringify({ v: PROTOCOL_VERSION, type: 'hello', macId, grants: this.grants() }));
    return new Response(null, { status: 101, webSocket: client });
  }

  private socket(): WebSocket | null {
    return this.ctx.getWebSockets().find((ws) => ws.readyState === WebSocket.OPEN) ?? null;
  }

  async webSocketMessage(ws: WebSocket, data: string | ArrayBuffer): Promise<void> {
    if (typeof data !== 'string' || data.length > MAX_RESPONSE + 64 * 1024) {
      ws.send(JSON.stringify({ v: PROTOCOL_VERSION, type: 'error', message: 'Frame not understood.' }));
      return;
    }
    const message = parseFromMac(data);
    if (!message) {
      ws.send(JSON.stringify({ v: PROTOCOL_VERSION, type: 'error', message: 'Frame not understood.' }));
      return;
    }
    switch (message.type) {
      case 'result':
      case 'consent_response': {
        const waiter = this.waiters.get(message.id);
        if (waiter) {
          this.waiters.delete(message.id);
          clearTimeout(waiter.timer);
          waiter.resolve(message);
        }
        return;
      }
      case 'connect_code_request': {
        const macId = this.macId();
        if (!macId) return;
        const code = connectionCode();
        const expiresAt = Date.now() + CODE_TTL_MS;
        const name = await hmac(this.env.DEVICE_PEPPER, `code:${code}`);
        await this.env.CONNECT_CODE.get(this.env.CONNECT_CODE.idFromName(name)).put(macId, expiresAt);
        ws.send(JSON.stringify({ v: PROTOCOL_VERSION, type: 'connect_code', id: message.id, code, expiresAt }));
        return;
      }
      case 'revoke': {
        await this.revoke(message.grantId);
        ws.send(JSON.stringify({ v: PROTOCOL_VERSION, type: 'ack', id: message.id }));
        return;
      }
      case 'grant_update': {
        const updated = this.sql.exec('UPDATE grants SET projects = ?, phi = ? WHERE id = ? AND revoked_at IS NULL',
          JSON.stringify(message.projects), message.phi ? 1 : 0, message.grantId).rowsWritten;
        ws.send(JSON.stringify(updated
          ? { v: PROTOCOL_VERSION, type: 'ack', id: message.id }
          : { v: PROTOCOL_VERSION, type: 'error', id: message.id, message: 'No such grant.' }));
        return;
      }
    }
  }

  async webSocketClose(ws: WebSocket, code: number): Promise<void> {
    // The runtime closes its side; nothing is queued for a Mac that's gone.
    try { ws.close(code === 1005 ? 1000 : code, 'closed'); } catch { /* already closed */ }
  }

  private send(message: object): boolean {
    const ws = this.socket();
    if (!ws) return false;
    try { ws.send(JSON.stringify(message)); return true; } catch { return false; }
  }

  private forget(id: string): void {
    const waiter = this.waiters.get(id);
    if (waiter) clearTimeout(waiter.timer);
    this.waiters.delete(id);
  }

  private waitFor(id: string, ms: number): Promise<FromMac | null> {
    return new Promise((resolve) => {
      const timer = setTimeout(() => { this.waiters.delete(id); resolve(null); }, ms);
      this.waiters.set(id, { resolve, timer });
    });
  }

  // MARK: Calls

  /** One MCP request from the Worker, for a grant the token resolved to. */
  async call(grantId: string, body: string): Promise<CallOutcome> {
    const grant = this.activeGrant(grantId);
    if (!grant) {
      return { status: 401, body: '', headers: {}, outcome: 'revoked' };
    }
    const now = Date.now();
    this.sql.exec('DELETE FROM calls WHERE at <= ?', now - 60_000);
    const counted = this.sql.exec<{ n: number; oldest: number | null }>('SELECT COUNT(*) AS n, MIN(at) AS oldest FROM calls').one();
    if (counted.n >= CALLS_PER_MINUTE) {
      const wait = Math.max(1, Math.ceil(((counted.oldest ?? now) + 60_000 - now) / 1000));
      return {
        status: 429, headers: { 'Retry-After': String(wait) }, outcome: 'rate_limited',
        body: rpcError(body, -32000, 'Too many requests: at most 60 a minute.', { retryAfter: wait }),
      };
    }
    this.sql.exec('INSERT INTO calls (at) VALUES (?)', now);
    if (new TextEncoder().encode(body).length > MAX_BODY) {
      return { status: 413, body: rpcError(null, -32600, 'Request body over 64 KB.'), outcome: 'too_large' };
    }
    const id = crypto.randomUUID();
    const waiting = this.waitFor(id, number(this.env.MAC_TIMEOUT_MS, 15_000));
    const sent = this.send({ v: PROTOCOL_VERSION, type: 'call', id, grantId, projects: grant.projects, phi: grant.phi, body });
    if (!sent) {
      this.forget(id);
      return { status: 503, body: rpcError(body, -32000, 'Mac unavailable'), outcome: 'offline' };
    }
    const reply = (await waiting) as Result | null;
    if (!reply) return { status: 503, body: rpcError(body, -32000, 'Mac unavailable'), outcome: 'timeout' };
    this.sql.exec('UPDATE grants SET last_used_at = ? WHERE id = ?', Date.now(), grantId);
    if (new TextEncoder().encode(reply.body).length > MAX_RESPONSE) {
      return { status: 502, body: rpcError(body, -32000, 'Response over 1 MB.'), outcome: 'response_too_large' };
    }
    return { status: reply.status, body: reply.body, outcome: 'ok' };
  }

  // MARK: Consent and grants

  /** Asks the Mac whether this client may read it; on Allow, records the grant the Mac named. */
  async consent(client: ConsentClient, clientId: string, clientKey: string, scope: string[]): Promise<ConsentOutcome> {
    const id = crypto.randomUUID();
    const timeout = number(this.env.CONSENT_TIMEOUT_MS, 120_000);
    const waiting = this.waitFor(id, timeout);
    const sent = this.send({ v: PROTOCOL_VERSION, type: 'consent_request', id, expiresAt: Date.now() + timeout, scope, client });
    if (!sent) {
      this.forget(id);
      return { kind: 'offline' };
    }
    const reply = (await waiting) as ConsentResponse | null;
    if (!reply) return { kind: 'timeout' };
    if (!reply.approve || !reply.grantId || !reply.projects) return { kind: 'denied' };
    const exists = this.sql.exec('SELECT 1 FROM grants WHERE id = ?', reply.grantId).toArray().length > 0;
    if (exists) return { kind: 'denied' };
    // Connecting the same client again replaces its earlier grant, as the OAuth library does for its tokens.
    const superseded = this.sql.exec<{ id: string }>('SELECT id FROM grants WHERE client_key = ? AND revoked_at IS NULL', clientKey).toArray();
    for (const old of superseded) {
      this.sql.exec('UPDATE grants SET revoked_at = ? WHERE id = ?', Date.now(), old.id);
      this.send({ v: PROTOCOL_VERSION, type: 'grant_revoked', grantId: old.id });
    }
    this.sql.exec(
      `INSERT INTO grants (id, client_id, client_key, client_name, client_domain, projects, phi, created_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
      reply.grantId, clientId, clientKey, client.name, client.domain ?? null, JSON.stringify(reply.projects),
      reply.phi ? 1 : 0, Date.now());
    return { kind: 'approved', grantId: reply.grantId };
  }

  private activeGrant(grantId: string): { projects: Projects; phi: boolean } | null {
    const row = this.sql.exec<{ projects: string; phi: number }>(
      'SELECT projects, phi FROM grants WHERE id = ? AND revoked_at IS NULL', grantId).toArray()[0];
    return row ? { projects: JSON.parse(row.projects) as Projects, phi: row.phi === 1 } : null;
  }

  grants(): GrantSummary[] {
    return this.sql.exec<any>('SELECT * FROM grants ORDER BY created_at').toArray().map((r) => ({
      id: r.id, clientName: r.client_name, ...(r.client_domain ? { clientDomain: r.client_domain } : {}),
      projects: JSON.parse(r.projects), phi: r.phi === 1, createdAt: r.created_at,
      ...(r.revoked_at ? { revokedAt: r.revoked_at } : {}), ...(r.last_used_at ? { lastUsedAt: r.last_used_at } : {}),
    }));
  }

  /** Revoked here at once (calls stop now), then its tokens in the OAuth store. */
  async revoke(grantId: string): Promise<void> {
    this.sql.exec('UPDATE grants SET revoked_at = ? WHERE id = ? AND revoked_at IS NULL', Date.now(), grantId);
    const macId = this.macId();
    if (macId) await this.revokeLibraryGrants(macId, grantId);
  }

  /** The OAuth library's grants for this Mac (its "user"): one, by our grant id, or all. */
  private async revokeLibraryGrants(macId: string, grantId: string | null): Promise<void> {
    const oauth = getOAuthApi(providerOptions(this.env), this.env);
    let cursor: string | undefined;
    do {
      const page = await oauth.listUserGrants(macId, { cursor });
      for (const grant of page.items) {
        if (grantId === null || grant.metadata?.grantId === grantId) await oauth.revokeGrant(grant.id, macId);
      }
      cursor = page.cursor;
    } while (cursor);
  }
}
