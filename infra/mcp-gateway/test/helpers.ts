import { SELF } from 'cloudflare:test';
import { expect } from 'vitest';

export const ORIGIN = 'http://localhost';
export const RESOURCE = `${ORIGIN}/mcp`;
export const REDIRECT = 'http://127.0.0.1:33418/callback';

export function worker(path: string, init?: RequestInit): Promise<Response> {
  return SELF.fetch(`${ORIGIN}${path}`, { redirect: 'manual', ...init });
}

export interface Registered { macId: string; credential: string }

/** A fresh documentation-range address, so each test has its own throttles. */
export function randomIp(): string {
  const [a, b] = crypto.getRandomValues(new Uint16Array(2));
  return `2001:db8:${a.toString(16)}:${b.toString(16)}::1`;
}

export async function registerMac(ip = randomIp()): Promise<Registered> {
  const res = await worker('/register', { method: 'POST', headers: { 'CF-Connecting-IP': ip } });
  expect(res.status).toBe(201);
  return res.json();
}

type Envelope = { v: 1; type: string; id: string; [key: string]: any };

/**
 * A stand-in for the Mac app: it keeps the socket, answers calls with
 * `answer`, consent requests with `consent`, and records what it was sent.
 */
export class FakeMac {
  received: Envelope[] = [];
  closed: { code: number; reason: string } | null = null;
  answer: (call: Envelope) => { status: number; body: string } | null = (call) => ({
    status: 200,
    body: JSON.stringify({ jsonrpc: '2.0', id: JSON.parse(call.body).id ?? null, result: { from: this.macId, projects: call.projects } }),
  });
  consent: (request: Envelope) => object | null = () => ({ approve: true, grantId: crypto.randomUUID(), projects: '*', phi: false });
  private waiting: Array<{ type: string; resolve: (e: Envelope) => void }> = [];

  private constructor(readonly macId: string, readonly ws: WebSocket) {
    ws.addEventListener('message', (event) => {
      if (event.data === 'pong') return;
      const message = JSON.parse(event.data as string) as Envelope;
      this.received.push(message);
      const i = this.waiting.findIndex((w) => w.type === message.type);
      if (i >= 0) this.waiting.splice(i, 1)[0].resolve(message);
      if (message.type === 'call') {
        const reply = this.answer(message);
        if (reply) this.send({ type: 'result', id: message.id, ...reply });
      }
      if (message.type === 'consent_request') {
        const reply = this.consent(message);
        if (reply) this.send({ type: 'consent_response', id: message.id, ...reply });
      }
    });
    ws.addEventListener('close', (event) => { this.closed = { code: event.code, reason: event.reason }; });
  }

  static async connect(mac: Registered, credential = mac.credential): Promise<FakeMac> {
    const res = await worker('/connect', { headers: { Upgrade: 'websocket', Authorization: `Device ${credential}` } });
    expect(res.status).toBe(101);
    const ws = res.webSocket!;
    ws.accept();
    const fake = new FakeMac(mac.macId, ws);
    await fake.next('hello');
    return fake;
  }

  send(message: object): void {
    this.ws.send(JSON.stringify({ v: 1, ...message }));
  }

  next(type: string): Promise<Envelope> {
    const seen = this.received.find((m) => m.type === type && !(m as any).__taken);
    if (seen) { (seen as any).__taken = true; return Promise.resolve(seen); }
    return new Promise((resolve) => this.waiting.push({ type, resolve: (m) => { (m as any).__taken = true; resolve(m); } }));
  }

  async connectionCode(): Promise<string> {
    const id = crypto.randomUUID();
    this.send({ type: 'connect_code_request', id });
    const message = await this.next('connect_code');
    expect(message.id).toBe(id);
    return message.code;
  }

  calls(): Envelope[] {
    return this.received.filter((m) => m.type === 'call');
  }
}

// MARK: OAuth client

export interface Client { clientId: string }

export async function registerClient(name = 'Test Assistant', redirect = REDIRECT): Promise<Client> {
  const res = await worker('/oauth/register', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ client_name: name, redirect_uris: [redirect], token_endpoint_auth_method: 'none',
      grant_types: ['authorization_code', 'refresh_token'], response_types: ['code'] }),
  });
  expect(res.status).toBe(201);
  const body = await res.json<{ client_id: string }>();
  return { clientId: body.client_id };
}

async function pkce(): Promise<{ verifier: string; challenge: string }> {
  const verifier = btoa(String.fromCharCode(...crypto.getRandomValues(new Uint8Array(32))))
    .replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  const digest = new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(verifier)));
  const challenge = btoa(String.fromCharCode(...digest)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  return { verifier, challenge };
}

function cookiesFrom(res: Response): string {
  return res.headers.getAll?.('Set-Cookie').map((c) => c.split(';')[0]).join('; ')
    ?? (res.headers.get('Set-Cookie') ?? '').split(/,(?=\s*__Host-)/).map((c) => c.split(';')[0].trim()).join('; ');
}

export interface Tokens { access_token: string; refresh_token: string; expires_in: number; scope: string; token_type: string }

export interface AuthorizeOutcome { status: number; location: string | null; html: string; tokens?: Tokens }

/**
 * The browser and client side of the flow: the authorize page, typing the
 * Mac's code, the Mac's consent, and the code-for-token exchange.
 */
export async function authorize(client: Client, code: (() => Promise<string>) | string, options: { resource?: string; ip?: string } = {}):
    Promise<AuthorizeOutcome> {
  const { verifier, challenge } = await pkce();
  const query = new URLSearchParams({
    response_type: 'code', client_id: client.clientId, redirect_uri: REDIRECT, scope: 'chats:read',
    state: 'state-123', code_challenge: challenge, code_challenge_method: 'S256', resource: options.resource ?? RESOURCE,
  });
  const page = await worker(`/authorize?${query}`);
  expect(page.status).toBe(200);
  const html = await page.text();
  const handle = /name="handle" value="([^"]+)"/.exec(html)![1];
  const typed = typeof code === 'string' ? code : await code();
  const form = new URLSearchParams({ handle, code: typed, decision: 'continue' });
  const submitted = await worker(`/authorize`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded', Cookie: cookiesFrom(page), 'CF-Connecting-IP': options.ip ?? randomIp() },
    body: form,
  });
  const location = submitted.headers.get('Location');
  const outcome: AuthorizeOutcome = { status: submitted.status, location, html: submitted.status === 302 ? '' : await submitted.text() };
  if (submitted.status !== 302 || !location) return outcome;
  const back = new URL(location);
  const authCode = back.searchParams.get('code');
  if (!authCode) return outcome;
  expect(back.searchParams.get('state')).toBe('state-123');
  const token = await worker('/oauth/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ grant_type: 'authorization_code', code: authCode, redirect_uri: REDIRECT,
      client_id: client.clientId, code_verifier: verifier, resource: RESOURCE }),
  });
  expect(token.status).toBe(200);
  outcome.tokens = await token.json<Tokens>();
  return outcome;
}

export function mcp(token: string | null, body: object | string, headers: Record<string, string> = {}): Promise<Response> {
  return worker('/mcp', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json', Accept: 'application/json, text/event-stream',
      ...(token ? { Authorization: `Bearer ${token}` } : {}), ...headers,
    },
    body: typeof body === 'string' ? body : JSON.stringify(body),
  });
}

export const listTools = { jsonrpc: '2.0', id: 1, method: 'tools/list' };
export const callList = { jsonrpc: '2.0', id: 2, method: 'tools/call', params: { name: 'listar_chats_abertos', arguments: { projeto: 'planted-argument' } } };

/** A Mac registered, connected and approved for a client: its token reaches it. */
export async function connectedGrant(projects: '*' | string[] = '*', ip?: string) {
  const reg = await registerMac(ip);
  const mac = await FakeMac.connect(reg);
  const grantId = crypto.randomUUID();
  mac.consent = () => ({ approve: true, grantId, projects, phi: false });
  const client = await registerClient();
  const outcome = await authorize(client, () => mac.connectionCode());
  expect(outcome.tokens).toBeDefined();
  return { reg, mac, grantId, client, tokens: outcome.tokens! };
}
