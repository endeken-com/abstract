import { OAuthProvider } from '@cloudflare/workers-oauth-provider';
import type { Env } from './env';
import { providerOptions } from './oauth';

export { ConnectCode } from './connect-code';
export { MacTunnel } from './mac-tunnel';
export { Throttle } from './throttle';
export { McpHandler } from './mcp-handler';

let provider: { origin: string; instance: OAuthProvider<Env> } | undefined;

/**
 * abstract-mcp-gateway (ABS-218): the one public endpoint for remote MCP
 * clients at mcp.useabstract.app. Each access token reaches only the Mac
 * that approved it, over that Mac's own Durable Object and socket.
 */
export default {
  fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    if (provider?.origin !== env.PUBLIC_ORIGIN) {
      provider = { origin: env.PUBLIC_ORIGIN, instance: new OAuthProvider<Env>(providerOptions(env)) };
    }
    // The library serves the path-aware metadata (RFC 9728 §3.1); clients that ask at the root get the same.
    const url = new URL(request.url);
    if (url.pathname === '/.well-known/oauth-protected-resource') {
      url.pathname = '/.well-known/oauth-protected-resource/mcp';
      return provider.instance.fetch(new Request(url, request), env, ctx);
    }
    return provider.instance.fetch(request, env, ctx);
  },
} satisfies ExportedHandler<Env>;
