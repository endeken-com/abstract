import { env } from 'cloudflare:test';
import { describe, expect, it, vi } from 'vitest';
import {
  FakeMac, RESOURCE, authorize, callList, connectedGrant, listTools, mcp, registerClient, registerMac, worker,
} from './helpers';

describe('discovery and the 401 challenge', () => {
  it('publishes protected-resource and authorization-server metadata', async () => {
    const resource = await (await worker('/.well-known/oauth-protected-resource')).json<any>();
    expect(resource.resource).toBe(RESOURCE);
    expect(resource.authorization_servers).toEqual(['http://localhost']);
    expect(resource.scopes_supported).toEqual(['chats:read']);
    const as = await (await worker('/.well-known/oauth-authorization-server')).json<any>();
    expect(as.code_challenge_methods_supported).toEqual(['S256']);
    expect(as.scopes_supported).toEqual(['chats:read']);
    expect(as.registration_endpoint).toBe('http://localhost/oauth/register');
    expect(as.client_id_metadata_document_supported).toBe(true);
  });

  it('answers /mcp without a token with 401 pointing at the metadata', async () => {
    const res = await mcp(null, listTools);
    expect(res.status).toBe(401);
    expect(res.headers.get('WWW-Authenticate')).toContain('resource_metadata="http://localhost/.well-known/oauth-protected-resource/mcp"');
    for (const token of ['nope', 'a:b:c', `${crypto.randomUUID()}:${crypto.randomUUID()}:x`]) {
      expect((await mcp(token, listTools)).status).toBe(401);
    }
  });

  it('health answers with no data', async () => {
    const res = await worker('/health');
    expect(res.status).toBe(204);
    expect(await res.text()).toBe('');
  });
});

describe('a Mac, end to end', () => {
  it('goes from discovery through PKCE and consent to a tools/call on its own Mac', async () => {
    const { mac, grantId, tokens } = await connectedGrant(['project-a']);
    expect(tokens.scope).toBe('chats:read');
    expect(tokens.expires_in).toBe(900);
    const consent = mac.received.find((m) => m.type === 'consent_request')!;
    expect(consent.client).toEqual({ name: 'Test Assistant', redirectHost: '127.0.0.1', loopback: true });
    expect(consent.scope).toEqual(['chats:read']);

    const res = await mcp(tokens.access_token, callList);
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ jsonrpc: '2.0', id: 2, result: { from: mac.macId, projects: ['project-a'] } });
    const call = mac.calls()[0];
    expect(call.grantId).toBe(grantId);
    expect(call.projects).toEqual(['project-a']);
    expect(JSON.parse(call.body)).toEqual(callList);
  });

  it('refresh tokens rotate', async () => {
    const { client, tokens } = await connectedGrant();
    const refresh = (token: string) => worker('/oauth/token', {
      method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({ grant_type: 'refresh_token', refresh_token: token, client_id: client.clientId }),
    });
    const first = await refresh(tokens.refresh_token);
    expect(first.status).toBe(200);
    const next = await first.json<any>();
    expect(next.refresh_token).not.toBe(tokens.refresh_token);
    expect((await mcp(next.access_token, listTools)).status).toBe(200);
    // Using the new one retires the old.
    expect((await refresh(next.refresh_token)).status).toBe(200);
    expect((await refresh(tokens.refresh_token)).status).toBe(400);
  });

  it('an expired access token gets 401', async () => {
    const { tokens } = await connectedGrant();
    expect((await mcp(tokens.access_token, listTools)).status).toBe(200);
    vi.useFakeTimers({ toFake: ['Date'] });
    try {
      vi.setSystemTime(Date.now() + 901_000);
      const res = await mcp(tokens.access_token, listTools);
      expect(res.status).toBe(401);
    } finally {
      vi.useRealTimers();
    }
  });

  it('refuses a token request for another audience', async () => {
    const client = await registerClient();
    const query = new URLSearchParams({ response_type: 'code', client_id: client.clientId, redirect_uri: 'http://127.0.0.1:33418/callback',
      scope: 'chats:read', state: 's', code_challenge: 'x'.repeat(43), code_challenge_method: 'S256', resource: 'https://elsewhere.example/mcp' });
    const res = await worker(`/authorize?${query}`);
    expect(res.status).toBe(302);
    expect(new URL(res.headers.get('Location')!).searchParams.get('error')).toBe('invalid_target');
  });
});

describe('the Mac decides', () => {
  it('a denial goes back to the client as access_denied', async () => {
    const reg = await registerMac();
    const mac = await FakeMac.connect(reg);
    mac.consent = () => ({ approve: false });
    const outcome = await authorize(await registerClient(), () => mac.connectionCode());
    expect(outcome.status).toBe(302);
    expect(new URL(outcome.location!).searchParams.get('error')).toBe('access_denied');
  });

  it('a wrong, reused or expired code shows the page again', async () => {
    const reg = await registerMac();
    const mac = await FakeMac.connect(reg);
    const client = await registerClient();
    const wrong = await authorize(client, 'ABCD-EFGH');
    expect(wrong.status).toBe(400);
    expect(wrong.html).toContain('That code is wrong or has expired');
    const code = await mac.connectionCode();
    expect((await authorize(client, code)).tokens).toBeDefined();
    const reused = await authorize(client, code);
    expect(reused.status).toBe(400);
    expect(mac.received.filter((m) => m.type === 'consent_request')).toHaveLength(1);
  });

  it('an offline Mac and a silent one are said so on the page', async () => {
    const reg = await registerMac();
    const mac = await FakeMac.connect(reg);
    const code = await mac.connectionCode();
    mac.ws.close(1000, 'bye');
    await vi.waitFor(() => expect(mac.closed).not.toBeNull());
    const offline = await authorize(await registerClient(), code);
    expect(offline.status).toBe(400);
    expect(offline.html).toContain("Your Mac isn&#39;t connected");

    const silent = await FakeMac.connect(reg);
    silent.consent = () => null;
    const timeout = await authorize(await registerClient(), () => silent.connectionCode());
    expect(timeout.status).toBe(400);
    expect(timeout.html).toContain('didn&#39;t answer in time');
  });
});

describe('calls', () => {
  it('answers 503 / -32000 at once when the Mac is offline', async () => {
    const { mac, tokens } = await connectedGrant();
    mac.ws.close(1000, 'bye');
    await vi.waitFor(() => expect(mac.closed).not.toBeNull());
    const started = Date.now();
    const res = await mcp(tokens.access_token, callList);
    expect(res.status).toBe(503);
    expect(Date.now() - started).toBeLessThan(300);
    expect(await res.json()).toEqual({ jsonrpc: '2.0', id: 2, error: { code: -32000, message: 'Mac unavailable' } });
  });

  it('answers the same after the timeout when the Mac is silent', async () => {
    const { mac, tokens } = await connectedGrant();
    mac.answer = () => null;
    const res = await mcp(tokens.access_token, callList);
    expect(res.status).toBe(503);
    expect((await res.json<any>()).error.code).toBe(-32000);
  });

  it('the 61st call in a minute gets 429 with a JSON-RPC error', async () => {
    const { tokens } = await connectedGrant();
    for (let i = 0; i < 60; i++) expect((await mcp(tokens.access_token, { ...listTools, id: i })).status).toBe(200);
    const limited = await mcp(tokens.access_token, { ...listTools, id: 61 });
    expect(limited.status).toBe(429);
    expect(Number(limited.headers.get('Retry-After'))).toBeGreaterThan(0);
    expect((await limited.json<any>()).error).toMatchObject({ code: -32000 });
  });

  it('caps the request at 64 KB and the answer at 1 MB', async () => {
    const { mac, tokens } = await connectedGrant();
    const big = JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'ping', params: { pad: 'x'.repeat(65 * 1024) } });
    expect((await mcp(tokens.access_token, big)).status).toBe(413);
    mac.answer = () => ({ status: 200, body: JSON.stringify({ pad: 'y'.repeat(1024 * 1024 + 10) }) });
    const res = await mcp(tokens.access_token, listTools);
    expect(res.status).toBe(502);
    expect((await res.json<any>()).error.message).toBe('Response over 1 MB.');
  });

  it('refuses browsers and other verbs', async () => {
    const { tokens } = await connectedGrant();
    expect((await mcp(tokens.access_token, listTools, { Origin: 'https://evil.example' })).status).toBe(403);
    const get = await worker('/mcp', { headers: { Authorization: `Bearer ${tokens.access_token}` } });
    expect(get.status).toBe(405);
    const del = await worker('/mcp', { method: 'DELETE', headers: { Authorization: `Bearer ${tokens.access_token}` } });
    expect(del.status).toBe(405);
  });

  it('passes notifications through as 202', async () => {
    const { mac, tokens } = await connectedGrant();
    mac.answer = () => ({ status: 202, body: '' });
    const res = await mcp(tokens.access_token, { jsonrpc: '2.0', method: 'notifications/initialized' });
    expect(res.status).toBe(202);
    expect(await res.text()).toBe('');
  });

  it('logs metadata only: no arguments, content, codes, credentials or tokens', async () => {
    const lines: string[] = [];
    const spy = vi.spyOn(console, 'log').mockImplementation((line: string) => { lines.push(line); });
    try {
      const { reg, mac, tokens } = await connectedGrant(['project-secret-name']);
      mac.answer = (call) => ({ status: 200, body: JSON.stringify({ jsonrpc: '2.0', id: 2, result: { text: 'planted chat content' } }) });
      await mcp(tokens.access_token, callList);
      const all = lines.join('\n');
      for (const planted of [tokens.access_token, tokens.refresh_token, reg.credential.split('.')[1], 'planted-argument',
        'planted chat content', 'project-secret-name', 'Test Assistant']) {
        expect(all).not.toContain(planted);
      }
      const call = lines.map((l) => JSON.parse(l)).find((l) => l.event === 'mcp');
      expect(call).toMatchObject({ mac: reg.macId, method: 'tools/call', tool: 'listar_chats_abertos', status: 200, outcome: 'ok' });
      expect(Object.keys(call).sort()).toEqual(['bytes', 'event', 'grant', 'mac', 'method', 'ms', 'outcome', 'status', 'tool']);
    } finally {
      spy.mockRestore();
    }
  });
});

describe('the Mac socket', () => {
  it('a new connection replaces the old one', async () => {
    const reg = await registerMac();
    const first = await FakeMac.connect(reg);
    const second = await FakeMac.connect(reg);
    await vi.waitFor(() => expect(first.closed?.code).toBe(4000));
    expect(second.closed).toBeNull();
  });

  it('refuses a missing, malformed or wrong credential', async () => {
    const reg = await registerMac();
    const wrongSecret = `${reg.macId}.${'A'.repeat(43)}`;
    for (const auth of [null, 'Bearer abs_x', `Device ${reg.macId}`, `Device ${wrongSecret}`]) {
      const res = await worker('/connect', { headers: { Upgrade: 'websocket', ...(auth ? { Authorization: auth } : {}) } });
      expect(res.status).toBe(401);
    }
  });

  it('answers heartbeats', async () => {
    const reg = await registerMac();
    const mac = await FakeMac.connect(reg);
    const pong = new Promise<string>((resolve) => mac.ws.addEventListener('message', (e) => { if (e.data === 'pong') resolve(e.data); }));
    mac.ws.send('ping');
    expect(await pong).toBe('pong');
  });
});

describe('revocation', () => {
  it('revoking on the Mac stops calls at once and kills the refresh token', async () => {
    const { mac, grantId, client, tokens } = await connectedGrant();
    mac.send({ type: 'revoke', id: 'r1', grantId });
    await mac.next('ack');
    const res = await mcp(tokens.access_token, listTools);
    expect(res.status).toBe(401);
    expect(res.headers.get('WWW-Authenticate')).toContain('invalid_token');
    const refresh = await worker('/oauth/token', {
      method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({ grant_type: 'refresh_token', refresh_token: tokens.refresh_token, client_id: client.clientId }),
    });
    expect(refresh.status).toBe(400);
  });

  it('connecting the same client again replaces its earlier grant', async () => {
    const { mac, client, tokens, grantId } = await connectedGrant();
    const second = crypto.randomUUID();
    mac.consent = () => ({ approve: true, grantId: second, projects: '*', phi: false });
    const again = await authorize(client, () => mac.connectionCode());
    expect((await mac.next('grant_revoked')).grantId).toBe(grantId);
    expect((await mcp(tokens.access_token, listTools)).status).toBe(401);
    expect((await mcp(again.tokens!.access_token, listTools)).status).toBe(200);
  });

  it('turning remote access off unregisters the Mac, its grants and tokens', async () => {
    const { reg, mac, tokens } = await connectedGrant();
    const res = await worker('/register', { method: 'DELETE', headers: { Authorization: `Device ${reg.credential}` } });
    expect(res.status).toBe(204);
    await vi.waitFor(() => expect(mac.closed?.code).toBe(4001));
    expect((await mcp(tokens.access_token, listTools)).status).toBe(401);
    const reconnect = await worker('/connect', { headers: { Upgrade: 'websocket', Authorization: `Device ${reg.credential}` } });
    expect(reconnect.status).toBe(401);
  });

  it('grant updates change the projects a call carries', async () => {
    const { mac, grantId, tokens } = await connectedGrant(['one']);
    mac.send({ type: 'grant_update', id: 'u1', grantId, projects: ['two', 'three'], phi: true });
    await mac.next('ack');
    await mcp(tokens.access_token, listTools);
    expect(mac.calls().at(-1)).toMatchObject({ projects: ['two', 'three'], phi: true });
  });
});

describe('throttles', () => {
  it('count an IPv6 /64 as one client', async () => {
    const { clientIp } = await import('../src/throttle');
    const ip = (value: string) => clientIp(new Request('http://x', { headers: { 'CF-Connecting-IP': value } }));
    expect(ip('2001:db8:1:2:aaaa::1')).toBe(ip('2001:db8:1:2:bbbb:cccc:dddd:eeee'));
    expect(ip('2001:db8:1:2::1')).not.toBe(ip('2001:db8:1:3::1'));
    expect(ip('2001:db8::1')).toBe('2001:db8:0:0::/64');
    expect(ip('192.0.2.7')).toBe('192.0.2.7');
  });

  it('wrong connection codes are limited per client', async () => {
    const client = await registerClient();
    const ip = '2001:db8:77:77::5';
    for (let i = 0; i < 10; i++) expect((await authorize(client, 'ABCD-EFGH', { ip })).html).toContain('wrong or has expired');
    expect((await authorize(client, 'ABCD-EFGH', { ip })).html).toContain('Too many codes tried');
  });
});

describe('registration', () => {
  it('is throttled per IP', async () => {
    for (let i = 0; i < 10; i++) await registerMac('192.0.2.55');
    const res = await worker('/register', { method: 'POST', headers: { 'CF-Connecting-IP': '192.0.2.55' } });
    expect(res.status).toBe(429);
  });

  it('never needs or accepts a browser', async () => {
    const res = await worker('/register', { method: 'POST', headers: { Origin: 'https://evil.example' } });
    expect(res.status).toBe(403);
  });

  it('stores only an HMAC of the device credential', async () => {
    const reg = await registerMac();
    const { runInDurableObject } = await import('cloudflare:test');
    const stub = env.MAC_TUNNEL.get(env.MAC_TUNNEL.idFromName(reg.macId));
    await runInDurableObject(stub, async (_instance, state) => {
      const rows = state.storage.sql.exec<any>('SELECT * FROM mac').toArray();
      expect(rows).toHaveLength(1);
      expect(JSON.stringify(rows)).not.toContain(reg.credential.split('.')[1]);
    });
  });
});
