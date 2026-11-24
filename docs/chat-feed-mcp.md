# Chat feed (MCP)

The chat feed lets another assistant, such as Grok, follow what you're working on in
Abstract. It is a read-only [MCP](https://modelcontextprotocol.io/specification) server
inside the app: the assistant can list your open chats, read them and search them, and
nothing else. It can't send a message, run anything, or touch files, branches, pull
requests or GitHub.

- **Open chats only.** Archived and deleted chats never appear, not even by id. Chats
  mirrored from another Mac are left out.
- **Messages only.** What you typed and the agent's written replies. Never tool calls,
  command output, diffs, file contents, attachments or images.
- **Redacted first.** Every text goes through one filter before it leaves, in this order:
  1. fenced code blocks become `[bloco de código: <language>, <n> linhas]` (on by default);
  2. secrets become `[REDACTED]`: provider keys, GitHub and Slack tokens, AWS key ids,
     private keys, JWTs, Bearer credentials, `.env`-style `KEY=value` lines,
     `user:password@` in connection strings, `password`/`senha`/`token`/`secret`/`api_key`
     values, and long random-looking strings (always on);
  3. health data becomes `[REDACTED]` (off by default): CPF and CNS numbers, dates next to
     "nascimento", "DN" or "DOB", numbers next to "prontuário", "MRN" or "registro", and
     names after "Paciente", "pac.", "Sr." or "Sra.". **This is best effort.** It lowers the
     risk but can't guarantee that no patient data gets through.
- **On this Mac only.** It listens on `127.0.0.1`, never on your network. To reach it from
  the internet, run a tunnel on the same Mac (below).
- **Token required.** Every request needs `Authorization: Bearer <token>`. Without a valid
  one, the answer is `401` with no body, and no method or tool runs.
- **Rate limited.** 60 requests a minute; the 61st gets `429` with `Retry-After`.
  Responses are capped at 1 MB.
- **Logged without content.** Each call adds one line to
  `~/Library/Application Support/Abstract/logs/chat-feed.log`: the time, the tool, the
  chat id, the HTTP status and how long it took. Never a query, a message, a title or the
  token. The log rotates at 5 MB.

## Turning it on and off

**Settings → Devices → Chat feed (MCP) → Let other assistants read your open chats.**
It's off until you turn it on, and it needs a token before it answers anything. Turning
it off closes the port.

The same section has the port (4319 by default), the two filter toggles, the allowed web
origins, and **Last calls**, read from the log.

## The token

Choose **Generate token**. Abstract copies it to the clipboard once and keeps it in the
Keychain; it never shows it again, so paste it where the assistant needs it right away.

**Rotate token** makes a new one and replaces the old at once: the next request with the
old token gets `401`. **Revoke** forgets the token and turns the feed off.

## The endpoint

```
http://127.0.0.1:4319/mcp
```

It speaks MCP's Streamable HTTP transport, answering each `POST` with a single JSON
response (no event stream, no sessions). `GET` and `DELETE` answer `405`. One JSON-RPC
message per request; batches are refused. A request whose `Origin` header isn't in the
allowed list gets `403`, which keeps web pages in your browser from reaching it (DNS
rebinding). Assistants calling from a server send no `Origin` and need nothing listed.

## Exposing it with Cloudflare Tunnel

The feed never listens beyond `127.0.0.1`. A tunnel on the same Mac carries it out over
HTTPS. Install `cloudflared` (`brew install cloudflared`).

**To try it**, a quick tunnel gives you a random `trycloudflare.com` address until you stop
it:

```bash
cloudflared tunnel --url http://127.0.0.1:4319
```

The feed is at `https://<random>.trycloudflare.com/mcp`. Quick tunnels are for testing:
the address changes every time.

**To keep it**, use a named tunnel on a domain you have in Cloudflare:

```bash
cloudflared tunnel login
cloudflared tunnel create abstract-feed
cloudflared tunnel route dns abstract-feed feed.example.com
```

Then `~/.cloudflared/config.yml`:

```yaml
tunnel: abstract-feed
credentials-file: /Users/<you>/.cloudflared/<tunnel id>.json
ingress:
  - hostname: feed.example.com
    service: http://127.0.0.1:4319
  - service: http_status:404
```

and `cloudflared tunnel run abstract-feed`. The feed is at `https://feed.example.com/mcp`.

**Optionally, put Cloudflare Access in front.** In Zero Trust → Access → Applications, add
a self-hosted application for `feed.example.com` with a *Service Auth* policy, and create a
service token. Requests must then also carry its two headers,
`CF-Access-Client-Id` and `CF-Access-Client-Secret`, before they reach your Mac at all;
the feed's own Bearer token is still checked behind it.

## Revoking access

Any one of these cuts an assistant off; do all three when you're done for good:

1. **Rotate token** (or **Revoke**) in Settings: the old token stops working on the next
   request.
2. Stop the tunnel (`Ctrl-C`, or `cloudflared tunnel delete abstract-feed` for a named one),
   or remove its Access service token.
3. Turn the feed off: the port closes.

## Connecting Grok

xAI's API connects Grok to remote MCP servers over Streamable HTTP
([Remote MCP Tools](https://docs.x.ai/docs/guides/tools/remote-mcp-tools)). Give it the
tunnel's HTTPS address and the token. With the Responses API:

```bash
curl https://api.x.ai/v1/responses \
  -H "Authorization: Bearer $XAI_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "grok-4.7",
    "input": [{"role": "user", "content": "What have I been working on today in Abstract?"}],
    "tools": [{
      "type": "mcp",
      "server_url": "https://feed.example.com/mcp",
      "server_label": "abstract",
      "server_description": "Read-only view of my open Abstract chats",
      "allowed_tools": ["listar_chats_abertos", "ler_chat", "buscar_nos_chats", "atividade_recente"],
      "headers": {"Authorization": "Bearer <chat feed token>"}
    }]
  }'
```

With the xAI Python SDK:

```python
from xai_sdk.tools import mcp

chat = client.chat.create(model="grok-4.7", tools=[
    mcp(server_url="https://feed.example.com/mcp", server_label="abstract",
        extra_headers={"Authorization": "Bearer <chat feed token>"}),
])
```

xAI also documents an `authorization` field that it sets as the `Authorization` header;
its docs don't say whether it adds the `Bearer ` prefix, so the examples pass the whole
header in `headers` / `extra_headers`. If you use Cloudflare Access, add
`CF-Access-Client-Id` and `CF-Access-Client-Secret` there too. xAI recommends HTTPS for
remote servers: use the tunnel's address, not the `127.0.0.1` one.

## The tools

All four are read-only (`readOnlyHint: true`). Times are ISO 8601 in UTC.

| Tool | Arguments | Returns |
|---|---|---|
| `listar_chats_abertos` | `projeto?` (project name), `atualizado_desde?` | `chats`: `chat_id`, `titulo`, `projeto`, `criado_em`, `atualizado_em`, `quantidade_mensagens`, `status` (`ativo` while its agent works, otherwise `ocioso`) |
| `ler_chat` | `chat_id`, `limite?` (50, up to 200), `cursor?`, `desde?` | `mensagens` oldest first, each `autor` (`usuario` or `agente`), `timestamp`, `texto`; and `proximo_cursor` (null at the end) |
| `buscar_nos_chats` | `consulta`, `limite?` (20, up to 50) | `resultados`, newest first: `chat_id`, `titulo`, `timestamp`, `trecho` |
| `atividade_recente` | `desde?` (default: the last 24 hours) | `chats` with messages since then: `chat_id`, `titulo`, `ultima_mensagem_em`, `ultimas_mensagens` (the last three, shortened) |

Search runs on the filtered text, so it can't find what the filter hides. `ler_chat`
answers "Chat não encontrado." for an archived, deleted or unknown chat alike.

## Example calls

Set the token and address first (here, straight to the Mac):

```bash
TOKEN='<chat feed token>'
URL=http://127.0.0.1:4319/mcp
mcp() {
  curl -s "$URL" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' -d "$1"
}
```

```bash
mcp '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"curl","version":"1"}}}'
mcp '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'

mcp '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"listar_chats_abertos","arguments":{}}}'
mcp '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"listar_chats_abertos","arguments":{"projeto":"payments-api","atualizado_desde":"2026-11-23T00:00:00Z"}}}'
mcp '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"ler_chat","arguments":{"chat_id":"<chat_id>","limite":50}}}'
mcp '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"buscar_nos_chats","arguments":{"consulta":"webhook","limite":10}}}'
mcp '{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"atividade_recente","arguments":{"desde":"2026-11-23T09:00:00Z"}}}'
```

A tool's answer comes as JSON text in `content` and the same object in
`structuredContent`. For example, `ler_chat`:

```json
{"jsonrpc":"2.0","id":5,"result":{"isError":false,"structuredContent":{
  "chat_id":"<chat_id>",
  "mensagens":[
    {"autor":"usuario","timestamp":"2026-11-23T10:02:11Z","texto":"Move the app to the new database. The old one is postgres://[REDACTED]@db.example.test:5432/app"},
    {"autor":"agente","timestamp":"2026-11-23T10:04:40Z","texto":"Done.\n\n[bloco de código: sql, 2 linhas]"}
  ],
  "proximo_cursor":null},
  "content":[{"type":"text","text":"…the same, as text…"}]}}
```
