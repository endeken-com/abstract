# abstract-mcp-gateway

The Cloudflare Worker at `https://mcp.useabstract.app/mcp` (ABS-218). Remote MCP
clients (Grok, Claude, ChatGPT, Cursor) connect there, sign in with OAuth 2.1,
and each token reaches only the Mac that approved it, through that Mac's
`MacTunnel` Durable Object and its outbound WebSocket. The Mac answers from its
read-only chat feed. See [PROTOCOL.md](PROTOCOL.md) for the socket, and
`docs/remote-mcp-gateway.md` (ABS-221) for the flow, DNS and the runbook.

| Path | What |
|---|---|
| `POST /mcp` | MCP Streamable HTTP, JSON only, with a Bearer token |
| `GET /.well-known/oauth-protected-resource[/mcp]` | RFC 9728 metadata |
| `GET /.well-known/oauth-authorization-server` | RFC 8414 metadata |
| `GET/POST /authorize` | The page that asks for your Mac's connection code |
| `POST /oauth/token`, `POST /oauth/register` | Tokens (PKCE, rotating refresh), dynamic registration; CIMD clients need none |
| `POST/DELETE /register` | A Mac turning remote access on or off |
| `GET /connect` | The Mac's WebSocket |
| `GET /health` | `204`, no data |

## Develop and test

Node 22 or later.

```sh
npm ci
npx tsc --noEmit
npx vitest run            # in workerd: OAuth, the tunnel, limits, cross-tenant isolation
npx wrangler deploy --dry-run --outdir dist
```

For `wrangler dev`, put a placeholder pepper and the local origin in `.dev.vars`
(git-ignored). `--local-upstream` keeps requests on `localhost` instead of the
production route's host:

```sh
printf 'DEVICE_PEPPER=%s\nPUBLIC_ORIGIN=http://localhost:8787\n' "$(openssl rand -base64 48)" > .dev.vars
npx wrangler dev --local-upstream localhost:8787
```

## Deploy (the owner)

1. `npx wrangler kv namespace create OAUTH_KV`, and put its id in `wrangler.toml`.
2. `npx wrangler secret put DEVICE_PEPPER` with 48+ random bytes
   (`openssl rand -base64 48`). Changing it later signs out every Mac and voids
   live connection codes.
3. Check that the deployed Worker's first migration tag is `v1` and created
   `MacTunnel` (Dashboard → Workers → abstract-mcp-gateway → Durable Objects). If
   the skeleton used another tag, rename `v1` here to match before deploying. `v2`
   adds `ConnectCode` and `Throttle`.
4. `npx wrangler deploy`.

Nothing here stores chat content: the Durable Objects hold the credential's
HMAC, grants (client, project ids, times) and counters, and logs carry only
the Mac, grant, method, tool, status, latency and size.
