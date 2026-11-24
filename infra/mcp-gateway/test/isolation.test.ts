import { env } from 'cloudflare:test';
import { describe, expect, it } from 'vitest';
import { credentialHash } from '../src/crypto';
import { connectedGrant, listTools, mcp, worker } from './helpers';

/**
 * Cross-tenant attempts (ABS-218): every one of these must fail. Two Macs, A
 * and B, each with its own grant, token, projects and socket.
 */
describe('isolation between Macs', () => {
  async function twoMacs() {
    const a = await connectedGrant(['project-of-a']);
    const b = await connectedGrant(['project-of-b']);
    return { a, b };
  }

  it("A's token only ever reaches A, whatever the request names", async () => {
    const { a, b } = await twoMacs();
    const attempts: Array<[string, RequestInit]> = [
      ['/mcp', {}],
      [`/mcp?mac=${b.reg.macId}`, {}],
      [`/mcp/${b.reg.macId}`, {}],
      ['/mcp', { headers: { 'X-Abstract-Mac-Id': b.reg.macId, 'X-Abstract-Grant-Id': b.grantId } }],
    ];
    for (const [path, init] of attempts) {
      const res = await worker(path, {
        method: 'POST', body: JSON.stringify(listTools),
        headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${a.tokens.access_token}`, ...(init.headers ?? {}) },
      });
      expect(res.status).toBe(200);
      expect((await res.json<any>()).result.from).toBe(a.reg.macId);
    }
    expect(a.mac.calls()).toHaveLength(attempts.length);
    expect(b.mac.calls()).toHaveLength(0);
    expect(a.mac.calls().every((c) => c.grantId === a.grantId && JSON.stringify(c.projects) === '["project-of-a"]')).toBe(true);
  });

  it("A's grant is unknown to B's Mac object, so B's projects can't be reached through it", async () => {
    const { a, b } = await twoMacs();
    const tunnelB = env.MAC_TUNNEL.get(env.MAC_TUNNEL.idFromName(b.reg.macId));
    const out = await tunnelB.call(a.grantId, JSON.stringify(listTools));
    expect(out.status).toBe(401);
    expect(b.mac.calls()).toHaveLength(0);
    // And B's grant, even named, isn't reachable from A's object.
    const tunnelA = env.MAC_TUNNEL.get(env.MAC_TUNNEL.idFromName(a.reg.macId));
    expect((await tunnelA.call(b.grantId, JSON.stringify(listTools))).status).toBe(401);
  });

  it("A's device credential can't open B's object", async () => {
    const { a, b } = await twoMacs();
    const secretA = a.reg.credential.split('.')[1];
    // A's secret under B's id.
    const mixed = await worker('/connect', { headers: { Upgrade: 'websocket', Authorization: `Device ${b.reg.macId}.${secretA}` } });
    expect(mixed.status).toBe(401);
    // A's full credential sent straight to B's object, as a misrouted request would.
    const tunnelB = env.MAC_TUNNEL.get(env.MAC_TUNNEL.idFromName(b.reg.macId));
    const asA = await tunnelB.fetch(new Request('https://mac-tunnel/connect', { headers: {
      Upgrade: 'websocket', 'X-Abstract-Mac-Id': a.reg.macId,
      'X-Abstract-Credential-Hash': await credentialHash(env.DEVICE_PEPPER, a.reg.macId, secretA),
    } }));
    expect(asA.status).toBe(401);
    // B's id with A's secret's HMAC.
    const half = await tunnelB.fetch(new Request('https://mac-tunnel/connect', { headers: {
      Upgrade: 'websocket', 'X-Abstract-Mac-Id': b.reg.macId,
      'X-Abstract-Credential-Hash': await credentialHash(env.DEVICE_PEPPER, b.reg.macId, secretA),
    } }));
    expect(half.status).toBe(401);
    // Nor unregister B.
    const unregister = await worker('/register', { method: 'DELETE', headers: { Authorization: `Device ${b.reg.macId}.${secretA}` } });
    expect(unregister.status).toBe(401);
    // B is still connected and served.
    expect(b.mac.closed).toBeNull();
    expect((await mcp(b.tokens.access_token, listTools)).status).toBe(200);
  });

  it("A revoking B's grant id over A's socket changes nothing for B", async () => {
    const { a, b } = await twoMacs();
    a.mac.send({ type: 'revoke', id: 'x1', grantId: b.grantId });
    await a.mac.next('ack');
    a.mac.send({ type: 'grant_update', id: 'x2', grantId: b.grantId, projects: '*', phi: false });
    expect((await a.mac.next('error')).message).toBe('No such grant.');
    expect((await mcp(b.tokens.access_token, listTools)).status).toBe(200);
    expect(b.mac.calls().at(-1)?.projects).toEqual(['project-of-b']);
  });

  it("A using up its rate limit doesn't slow B", async () => {
    const { a, b } = await twoMacs();
    for (let i = 0; i < 60; i++) await mcp(a.tokens.access_token, listTools);
    expect((await mcp(a.tokens.access_token, listTools)).status).toBe(429);
    expect((await mcp(b.tokens.access_token, listTools)).status).toBe(200);
  });

  it('a Mac answering for a call id it was never sent changes nothing', async () => {
    const { a, b } = await twoMacs();
    b.mac.answer = () => null; // B stays silent…
    const pending = mcp(b.tokens.access_token, listTools);
    // …and A can't answer B's call: it never sees B's correlation id, and its socket goes to its own object.
    a.mac.send({ type: 'result', id: 'guessed-id', status: 200, body: '{"forged":true}' });
    const res = await pending;
    expect(res.status).toBe(503);
  });
});
