import type { OAuthHelpers } from '@cloudflare/workers-oauth-provider';
import type { ConnectCode } from './connect-code';
import type { MacTunnel } from './mac-tunnel';
import type { Throttle } from './throttle';

export interface Env {
  /** One Durable Object per registered Mac, named by its Mac id. */
  MAC_TUNNEL: DurableObjectNamespace<MacTunnel>;
  /** One per live connection code, named by the code's HMAC. */
  CONNECT_CODE: DurableObjectNamespace<ConnectCode>;
  /** Attempt counters (registrations, wrong codes, failed connects) by client IP. */
  THROTTLE: DurableObjectNamespace<Throttle>;
  /** workers-oauth-provider's clients, grants and tokens (hashed). */
  OAUTH_KV: KVNamespace;
  /** Set by OAuthProvider for the default handler. */
  OAUTH_PROVIDER: OAuthHelpers;

  /** `https://mcp.useabstract.app` in production; `http://localhost:8787` for `wrangler dev`. */
  PUBLIC_ORIGIN: string;
  /** How long a forwarded call waits for the Mac. */
  MAC_TIMEOUT_MS: string;
  /** How long the consent page waits for the Mac's answer. */
  CONSENT_TIMEOUT_MS: string;
  ACCESS_TOKEN_TTL_SECONDS: string;

  /** Worker Secret: keys the HMACs of device credentials and connection codes. Never in code or config. */
  DEVICE_PEPPER: string;
}

export const SCOPE = 'chats:read';

export function resource(env: Env): string {
  return `${env.PUBLIC_ORIGIN}/mcp`;
}

export function number(value: string | undefined, fallback: number): number {
  const n = Number(value);
  return Number.isFinite(n) && n > 0 ? n : fallback;
}
