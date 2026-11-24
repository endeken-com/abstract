import {
  AuthorizationError, CimdFetchError, authorizationErrorRedirect, type AuthRequest,
} from '@cloudflare/workers-oauth-provider';
import { credentialHash, hmac, normalizeCode, parseDeviceCredential, randomToken } from './crypto';
import { SCOPE, type Env } from './env';
import { log } from './log';
import { codePage, messagePage, pageHeaders } from './pages';
import { allowed } from './throttle';

/**
 * Everything but `/mcp` and the OAuth library's own endpoints: the authorize
 * page, Mac registration, the Mac's socket, and health.
 */
export const defaultHandler: ExportedHandler<Env> = {
  async fetch(request, env) {
    const url = new URL(request.url);
    try {
      switch (url.pathname) {
        case '/health':
          return request.method === 'GET' ? new Response(null, { status: 204 }) : new Response(null, { status: 405 });
        case '/authorize':
          if (request.method === 'GET') return await showAuthorize(request, env);
          if (request.method === 'POST') return await submitAuthorize(request, env);
          return new Response(null, { status: 405, headers: { Allow: 'GET, POST' } });
        case '/register':
          if (request.headers.get('Origin') !== null) return new Response(null, { status: 403 });
          if (request.method === 'POST') return await register(request, env);
          if (request.method === 'DELETE') return await unregister(request, env);
          return new Response(null, { status: 405, headers: { Allow: 'POST, DELETE' } });
        case '/connect':
          return await connect(request, env);
        default:
          return new Response(null, { status: 404 });
      }
    } catch (error) {
      if (error instanceof AuthorizationError && error.redirectTo) return Response.redirect(error.redirectTo, 302);
      if (error instanceof AuthorizationError) return messagePage('This sign-in link is no longer valid', error.description);
      if (error instanceof CimdFetchError) return messagePage('This app could not be verified', 'Its metadata document could not be fetched.');
      throw error;
    }
  },
};

// MARK: Mac registration and its socket

async function register(request: Request, env: Env): Promise<Response> {
  if (!(await allowed(env, 'register', request))) return new Response(null, { status: 429, headers: { 'Retry-After': '3600' } });
  const macId = crypto.randomUUID();
  const secret = randomToken(32);
  const tunnel = env.MAC_TUNNEL.get(env.MAC_TUNNEL.idFromName(macId));
  if (!(await tunnel.register(macId, await credentialHash(env.DEVICE_PEPPER, macId, secret)))) {
    return new Response(null, { status: 409 });
  }
  log({ event: 'register', mac: macId, status: 201 });
  return Response.json({ macId, credential: `${macId}.${secret}` }, { status: 201, headers: { 'Cache-Control': 'no-store' } });
}

async function unregister(request: Request, env: Env): Promise<Response> {
  const credential = parseDeviceCredential(request.headers.get('Authorization'));
  if (!credential) {
    await allowed(env, 'connect', request);
    return new Response(null, { status: 401 });
  }
  const tunnel = env.MAC_TUNNEL.get(env.MAC_TUNNEL.idFromName(credential.macId));
  const ok = await tunnel.unregister(credential.macId, await credentialHash(env.DEVICE_PEPPER, credential.macId, credential.secret));
  log({ event: 'unregister', mac: ok ? credential.macId : undefined, status: ok ? 204 : 401 });
  if (!ok && !(await allowed(env, 'connect', request))) return new Response(null, { status: 429, headers: { 'Retry-After': '600' } });
  return new Response(null, { status: ok ? 204 : 401 });
}

async function connect(request: Request, env: Env): Promise<Response> {
  if (request.method !== 'GET') return new Response(null, { status: 405 });
  if (request.headers.get('Upgrade')?.toLowerCase() !== 'websocket') return new Response(null, { status: 426 });
  const credential = parseDeviceCredential(request.headers.get('Authorization'));
  if (!credential) {
    await allowed(env, 'connect', request);
    return new Response(null, { status: 401 });
  }
  // The credential names its Mac, and only that Mac's object is asked; it checks the id and the HMAC itself.
  const tunnel = env.MAC_TUNNEL.get(env.MAC_TUNNEL.idFromName(credential.macId));
  const headers = new Headers({ Upgrade: 'websocket' });
  headers.set('X-Abstract-Mac-Id', credential.macId);
  headers.set('X-Abstract-Credential-Hash', await credentialHash(env.DEVICE_PEPPER, credential.macId, credential.secret));
  const response = await tunnel.fetch(new Request('https://mac-tunnel/connect', { headers }));
  if (response.status === 401 && !(await allowed(env, 'connect', request))) {
    return new Response(null, { status: 429, headers: { 'Retry-After': '600' } });
  }
  log({ event: 'connect', mac: response.status === 101 ? credential.macId : undefined, status: response.status });
  return response;
}

// MARK: Authorize

async function showAuthorize(request: Request, env: Env): Promise<Response> {
  const oauth = env.OAUTH_PROVIDER;
  const authRequest = await oauth.parseAuthRequest(request);
  const details = await oauth.describeConsent(authRequest);
  const consent = await oauth.beginConsent(authRequest);
  return new Response(codePage(details, consent.handle), { headers: pageHeaders(consent.headers) });
}

/** The page again, with a fresh handle, after a wrong code or a Mac that didn't answer. */
async function again(env: Env, authRequest: AuthRequest, carried: Headers, error: string): Promise<Response> {
  const oauth = env.OAUTH_PROVIDER;
  const details = await oauth.describeConsent(authRequest);
  const consent = await oauth.beginConsent(authRequest);
  const headers = pageHeaders(consent.headers);
  carried.forEach((value, name) => { if (name.toLowerCase() === 'set-cookie') headers.append(name, value); });
  return new Response(codePage(details, consent.handle, error), { status: 400, headers });
}

async function submitAuthorize(request: Request, env: Env): Promise<Response> {
  const oauth = env.OAUTH_PROVIDER;
  const form = await request.formData();
  const handle = String(form.get('handle') ?? '');
  if (form.get('decision') === 'deny') {
    const denied = await oauth.denyConsent(request, handle);
    return new Response(null, { status: 302, headers: denied.headers });
  }
  // The handle is used up here; every way back to the page below starts a new one.
  const approved = await oauth.approveConsent(request, handle, { scope: [SCOPE] });
  const authRequest = approved.request;

  if (!(await allowed(env, 'code', request))) {
    return again(env, authRequest, approved.headers, 'Too many codes tried. Wait ten minutes, then try again.');
  }
  const code = normalizeCode(String(form.get('code') ?? ''));
  const macId = code
    ? await env.CONNECT_CODE.get(env.CONNECT_CODE.idFromName(await hmac(env.DEVICE_PEPPER, `code:${code}`))).take()
    : null;
  if (!macId) {
    log({ event: 'authorize', outcome: 'bad_code', status: 400 });
    return again(env, authRequest, approved.headers, 'That code is wrong or has expired. Make a new one on your Mac.');
  }

  const details = await oauth.describeConsent(authRequest);
  const tunnel = env.MAC_TUNNEL.get(env.MAC_TUNNEL.idFromName(macId));
  const decision = await tunnel.consent(
    { name: details.clientName, ...(details.clientDomain ? { domain: details.clientDomain } : {}),
      redirectHost: details.redirectHost, loopback: details.redirectIsLoopback },
    authRequest.clientId, `${authRequest.clientId} ${authRequest.redirectUri}`, [SCOPE]);
  log({ event: 'authorize', mac: macId, outcome: decision.kind, grant: decision.kind === 'approved' ? decision.grantId : undefined });

  switch (decision.kind) {
    case 'offline':
      return again(env, authRequest, approved.headers, "Your Mac isn't connected. Open Abstract, check Remote access is on, and make a new code.");
    case 'timeout':
      return again(env, authRequest, approved.headers, "Your Mac didn't answer in time. Make a new code and try again.");
    case 'denied': {
      const headers = new Headers(approved.headers);
      headers.set('Location', authorizationErrorRedirect(authRequest, 'access_denied'));
      return new Response(null, { status: 302, headers });
    }
    case 'approved': {
      const { redirectTo } = await oauth.completeAuthorization({
        request: authRequest,
        userId: macId,
        metadata: { grantId: decision.grantId },
        scope: [SCOPE],
        props: { macId, grantId: decision.grantId },
      });
      const headers = new Headers(approved.headers);
      headers.set('Location', redirectTo);
      return new Response(null, { status: 302, headers });
    }
  }
}
