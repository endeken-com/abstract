import type { OAuthProviderOptions } from '@cloudflare/workers-oauth-provider';
import { defaultHandler } from './default-handler';
import { number, resource, SCOPE, type Env } from './env';
import { log } from './log';
import { McpHandler } from './mcp-handler';

/** What a token resolves to: the Mac it reaches and the grant it was issued under. */
export interface GrantProps {
  macId: string;
  grantId: string;
}

/**
 * The authorization server (ABS-218): authorization code with PKCE, Client ID
 * Metadata Documents and dynamic registration, one scope (`chats:read`), and
 * short access tokens bound to `<origin>/mcp`. Refresh tokens rotate on use.
 * The "user" of every grant is the Mac that approved it.
 */
export function providerOptions(env: Env): OAuthProviderOptions<Env> {
  return {
    apiRoute: '/mcp',
    apiHandler: McpHandler,
    defaultHandler,
    authorizeEndpoint: '/authorize',
    tokenEndpoint: '/oauth/token',
    clientRegistrationEndpoint: '/oauth/register',
    scopesSupported: [SCOPE],
    requiredScopes: [SCOPE],
    resourceMetadata: {
      resource: resource(env),
      authorization_servers: [env.PUBLIC_ORIGIN],
      resource_name: 'Abstract chat feed',
    },
    clientIdMetadataDocumentEnabled: true,
    accessTokenTTL: number(env.ACCESS_TOKEN_TTL_SECONDS, 900),
    refreshTokenTTL: 30 * 24 * 60 * 60,
    onError: ({ code, status }) => {
      // The library's default logs descriptions; these hold no secrets, but keep to codes.
      log({ event: 'oauth_error', code, status });
    },
  };
}
