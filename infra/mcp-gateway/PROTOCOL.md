# Mac ↔ gateway protocol, version 1

How the Abstract app on a Mac talks to `abstract-mcp-gateway` (ABS-218). The Mac
side is ABS-219; the consent sheet is ABS-220.

## Registering

`POST https://mcp.useabstract.app/register` with no body and no `Origin`.

```json
201 {"macId": "<uuid>", "credential": "<uuid>.<43 base64url characters>"}
```

Keep `credential` in the Keychain. It is the Mac's device credential, and it's
the only thing that opens this Mac's tunnel. It is never the local `abs_` token
and never an MCP client's token. The gateway stores only an HMAC of it. Registering
is limited to 10 an hour per IP (`429`).

`DELETE /register` with `Authorization: Device <credential>` turns remote access
off. It closes the socket (code `4001`), and deletes every grant and their
tokens and the credential itself. `204`, or `401`.

## The socket

```
GET wss://mcp.useabstract.app/connect
Authorization: Device <credential>
```

`401` for a wrong credential; repeated failures from one IP get `429`. One
connection per Mac: a new valid one closes the old with code `4000` (`replaced`).

Heartbeat: send the text frame `ping` every 30 s or so; the gateway answers
`pong` without waking the Durable Object. Reconnect with exponential backoff
(1 s doubling to 60 s, with jitter) whenever the socket closes, except after
`4001`.

Every other frame is one JSON object with `"v": 1` and a `type`. Ids are 1–64
characters of `[A-Za-z0-9_-]`; grant ids are lowercase UUIDs.

### Gateway → Mac

| `type` | Fields | Meaning |
|---|---|---|
| `hello` | `macId`, `grants[]` | First frame after connecting: every grant the gateway holds for this Mac (`id`, `clientName`, `clientDomain?`, `projects`, `phi`, `createdAt`, `revokedAt?`, `lastUsedAt?`, times in ms). |
| `call` | `id`, `grantId`, `projects`, `phi`, `body` | One MCP request. `body` is the JSON-RPC text as the client sent it. `projects` is `"*"` or the allowed project ids. Answer with `result` and the same `id`, within 15 s. |
| `consent_request` | `id`, `expiresAt`, `scope[]`, `client{name, domain?, redirectHost, loopback}` | Someone typed this Mac's connection code. Show the consent sheet; answer with `consent_response` before `expiresAt`. `domain` is set only for a client whose identity is a verified metadata URL; `loopback` means the tokens go to an app on that computer. |
| `connect_code` | `id`, `code`, `expiresAt` | The answer to `connect_code_request`: an 8-character code (`XXXX-XXXX`), valid 10 minutes, usable once. |
| `ack` | `id` | `revoke` or `grant_update` done. |
| `error` | `id?`, `message` | A frame the gateway didn't understand, or a grant it doesn't hold. |
| `grant_revoked` | `grantId` | The client connected again and its new grant replaced this one. |

### Mac → gateway

| `type` | Fields | Meaning |
|---|---|---|
| `result` | `id`, `status`, `body` | The answer to a `call`: the local feed's HTTP status (200, 202, 4xx) and body. At most 1 MB, or the client gets `502`. |
| `consent_response` | `id`, `approve`, and when approving `grantId`, `projects`, `phi` | The user's decision. The Mac makes the grant id (a new UUID) and remembers it: it answers only calls for grants it made. |
| `connect_code_request` | `id` | Make a connection code for "Connect an assistant". |
| `revoke` | `id`, `grantId` | Revoke a grant. Calls stop at once, and its access and refresh tokens are revoked. |
| `grant_update` | `id`, `grantId`, `projects`, `phi` | Change a grant's projects or health-data redaction. |

## What the Mac must check on every `call`

1. The `grantId` is one this Mac made and hasn't revoked; otherwise answer
   `result` with status `403`, without calling the feed.
2. Apply the grant's projects on the Mac (the Mac is the source of truth; the
   `projects` in the envelope are a second copy). `listar_chats_abertos`,
   `buscar_nos_chats` and `atividade_recente` return only those projects'
   chats, and `ler_chat` answers "not found" for any other.
3. Answer through the chat feed (`ChatFeedEndpoint`) with the local `abs_`
   token, so the same token check, redaction and limits apply. Code blocks and
   secrets stay redacted; health data is redacted when the grant's `phi` is set.

## What the MCP client sees

* `401` with `WWW-Authenticate` and `resource_metadata` when there's no valid
  token, or after the grant was revoked.
* `429` with `Retry-After` and a JSON-RPC error after 60 calls in a minute per
  Mac.
* `503` with `{"error":{"code":-32000,"message":"Mac unavailable"}}` when the
  Mac isn't connected (at once) or doesn't answer within the timeout.
* `413` over 64 KB; `502` when the Mac's answer is over 1 MB.
