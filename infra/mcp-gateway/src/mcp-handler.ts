import { WorkerEntrypoint } from 'cloudflare:workers';
import { insufficientScope, type OAuthResourceAuth } from '@cloudflare/workers-oauth-provider';
import { SCOPE, type Env } from './env';
import { describeCall, log } from './log';
import { MAX_BODY } from './limits';
import type { GrantProps } from './oauth';

/**
 * `POST /mcp`, reached only with a valid access token for this resource. The
 * token alone picks the Mac: its grant's Mac id names the Durable Object.
 * Nothing the client sends can name another Mac.
 */
export class McpHandler extends WorkerEntrypoint<Env, GrantProps> {
  async fetch(request: Request): Promise<Response> {
    const started = Date.now();
    const props = this.ctx.props;
    const auth = (this.ctx as unknown as { auth: OAuthResourceAuth }).auth;
    // No browser may call it: any Origin is refused (MCP's DNS-rebinding rule), and there's no CORS.
    if (request.headers.get('Origin') !== null) return new Response(null, { status: 403 });
    if (request.method !== 'POST') return new Response(null, { status: 405, headers: { Allow: 'POST' } });
    if (!auth.scope.includes(SCOPE)) return insufficientScope(auth, [SCOPE]);
    const declared = Number(request.headers.get('Content-Length') ?? '0');
    if (declared > MAX_BODY) return json(413, '{"jsonrpc":"2.0","id":null,"error":{"code":-32600,"message":"Request body over 64 KB."}}');
    const raw = await request.arrayBuffer();
    if (raw.byteLength > MAX_BODY) return json(413, '{"jsonrpc":"2.0","id":null,"error":{"code":-32600,"message":"Request body over 64 KB."}}');
    const body = new TextDecoder().decode(raw);
    const tunnel = this.env.MAC_TUNNEL.get(this.env.MAC_TUNNEL.idFromName(props.macId));
    const out = await tunnel.call(props.grantId, body);
    const { method, tool } = describeCall(body);
    log({ event: 'mcp', mac: props.macId, grant: props.grantId, method, tool, status: out.status, outcome: out.outcome,
      ms: Date.now() - started, bytes: out.body.length });
    if (out.status === 401) {
      // The grant was revoked on the Mac: the token is no good any more.
      return new Response(null, {
        status: 401,
        headers: { 'WWW-Authenticate': `Bearer error="invalid_token", resource_metadata="${this.env.PUBLIC_ORIGIN}/.well-known/oauth-protected-resource/mcp", scope="${SCOPE}"` },
      });
    }
    return json(out.status, out.body, out.headers);
  }
}

function json(status: number, body: string, headers: Record<string, string> = {}): Response {
  return new Response(body.length ? body : null, {
    status,
    headers: { ...(body.length ? { 'Content-Type': 'application/json' } : {}), 'Cache-Control': 'no-store', ...headers },
  });
}

