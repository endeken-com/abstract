# ABS-90: prove ten more coding agents can show complete chat activity

**Question.** Which ten or more independently installed coding CLIs can Abstract
run through each CLI's own sign-in and a supported event surface, with enough
structured data for Claude Code-level chat detail — and what is honestly
missing for each?

**Method, and its limits.** Two evidence kinds, labelled everywhere below:

- **Local (live).** `gemini` 0.37.1 and `cursor-agent` 2026.01.23 are installed
  on this Mac; the other eight candidates are not. Both installed CLIs were
  driven in a clean `/tmp` workspace. Neither could run a turn: Gemini refuses
  the signed-in account (`IneligibleTierError: This client is no longer
  supported for Gemini Code Assist for individuals… migrate to the Antigravity
  suite`), and Cursor Agent is not signed in (`Authentication required. Please
  run 'agent login' first`). So **no candidate was live-proved end to end in
  this spike.** Flag and mode facts for those two come from their own
  `--help` output on this Mac.
- **Documented (upstream).** Event shapes, launch/resume commands and limits
  are taken from each vendor's published headless/streaming reference (linked
  per agent), including their worked sample streams. "Sample streams" below
  are those upstream examples, trimmed; paths in them are the vendors' own
  placeholders, not this machine's.

The consequence shapes the verdict: this spike can prove *a supported
structured surface exists and maps onto `AgentEvent`*, per agent. It cannot
prove the stream a signed-in binary actually emits today. Every child ticket
therefore starts with the ABS-88 step — a signed-in probe in a clean
workspace (read, search, shell, edit, create, failing read, web
search/fetch, resume) whose sanitized stream becomes the parser fixture. If
that probe contradicts this note, the probe wins and the child ticket stops.

## The bar (from the current code)

"Claude Code-level detail" means the parser can emit, from the logged lines
alone (live, replay after relaunch, phone, paired Mac all refold the same
lines):

- `.sessionId` / `.system(model:)` — a resume id Abstract can persist;
- `.text`/`.thinking` with partial deltas where the CLI streams them;
- `.toolUse(id:name:input:edit:)` with a **stable tool id** and the model's
  actual argument object — `ToolPresentation` (Mac
  `Abstract/Features/Chat/ToolCallViews.swift`, phone
  `mobile/src/toolPresentation.ts`) reads `path`/`file_path`, `command`,
  `pattern`/`query`/`url` from it; a target is never guessed from prose;
- `.toolResult(toolUseId:output:isError:edit:)` correlated by that id, with
  running → completed/failed derivable (a started event, or first-seen =
  running until its result lands);
- `EditPreview` for edits — from a structured patch/diff if the CLI sends
  one, from old/new text fields if it sends those, otherwise the row shows
  the path and counts only, and says so;
- `.turnEnd`/`.usage` where reported; `.error` on failure; unknown tools and
  lines stay name + input + output, or `.raw`;
- launch surface: `ProviderDefinition.buildLaunch/buildResume` from
  `LaunchContext` (cwd, prompt, resumeId, `PermissionPolicy`
  ask/autoEdits/bypass, model, effort, `OutputStyle`, image file paths,
  readableDirs), follow-ups via `FollowUpMode.stdin` or `.respawn`,
  `.permissionRequest` only where the CLI can actually be answered —
  otherwise the policy maps to launch flags and `permissionDetail` says what
  it really means (the ABS-87 Muse precedent).

Cross-surface cost of any one agent is then fixed and small: one
`ProviderDefinition` + one `ProviderRegistry` line (Mac, `abstract` CLI and
paired-Mac execution all resolve through the registry; the paired Mac must
have the binary installed and signed in — `detectArgs` already gates that),
tool-name entries in the two presentation maps, and parser fixtures. No new
user concept anywhere in this spike: a new agent is a new entry in the
existing agent picker.

`OutputStyle` note: Abstract injects style *instructions* for agents without
built-in styles (`ProviderContract.OutputStyle.instructions`), so "no native
output style" is never a blocker — it only decides flag vs. prompt text.

## Matrix

Transport = the surface the child ticket should build on. "Probe" = what
this spike could not verify and the child ticket must.

| Agent | Transport (launch → resume) | Tool detail in stream | Permissions | Model / effort | Images in | Usage | Probe must confirm |
|---|---|---|---|---|---|---|---|
| Cursor Agent | `cursor-agent -p --output-format stream-json` → `--resume <chatId>` | `tool_call started/completed`, stable `call_id`, typed args per tool | `--force` allows; `plan`/`ask` read-only; no answerable ask in print mode | `--model`, `--list-models`; no effort flag | Not in print-mode docs | Durations only, no tokens | Signed-in stream; shell/search/edit tool shapes; image route |
| Amp | `amp --execute --stream-json [--stream-json-input]` → `amp threads continue` | Claude-shaped: `tool_use` blocks `id/name/input`, `tool_result tool_use_id/is_error` | Execute mode runs tools; no per-call approval documented | Mode-based, no `--model` documented | Yes, image blocks in stream-json input | Per-message token usage | Local `amp login` session works from a spawned (non-TTY) process; edit diff fields |
| Qwen Code | `qwen -p --output-format stream-json` → `--resume <sessionId>` | Claude-shaped messages; partials via `--include-partial-messages` | `--approval-mode plan/default/auto-edit/auto/yolo` | `--model`; `--output-style` names match Abstract's; effort not documented | Not in headless docs | `result` usage + per-model stats | Tool block shapes; image route; stream-json *input* is "under construction" → respawn follow-ups |
| Pi | `pi --mode rpc` (long-lived) or `--mode json` (one-shot) → session file | `tool_execution_start/update/end` with `toolCallId`, `args`, `result`, `isError` | No approval surface documented; tools run | `--provider/--model`; thinking levels | Via RPC prompt content (probe) | Per-message usage incl. cost | Edit tool's result (diff in `details`?); RPC approval story; no built-in web tools |
| Factory Droid | `droid exec --input-format stream-jsonrpc --output-format stream-jsonrpc` → `-s <session-id>` | JSON-RPC session protocol (shapes unpublished in fetched docs) | `--auto low/medium/high`, read-only spec default, `--skip-permissions-unsafe` | `-m`, `-r` reasoning effort | Not in fetched docs | Not in fetched docs | The JSON-RPC event shapes themselves |
| GitHub Copilot CLI | `copilot -p --output-format json` (JSONL) → `--resume/--continue/--session-id` | JSONL events documented as parseable; full schema not in the programmatic reference | Launch-time `--allow-tool/--deny-tool/--allow-all`; no prompts in `-p` | `--model`; effort via config `effortLevel`, no per-run flag found | `--attachment <path>` (non-interactive) | Final-record fields documented for workflow runs; `-p` probe needed | JSONL tool event ids/args; token usage presence |
| Kimi Code | `kimi -p --output-format stream-json` → `--session <id>` / `--continue` | Assistant message with `tool_calls`, then Tool message (no started event; progress on stderr) | `-p` is auto-permission only; `--yolo/--auto/--plan` rejected with `-p` | `-m` model alias; no effort flag found | Not in fetched docs | Not in fetched docs | `tool_calls` ids/args; whether ACP (`kimi acp`) gives started events + approvals |
| Mistral Vibe | `vibe --prompt … --output streaming` → `--resume <id>` / `--continue` | Streaming output exists; event schema not in fetched page | `--agent plan/accept-edits/smart-approve/auto-approve`; programmatic defaults to auto-approve | `/model` in-session; launch flag to confirm | Not in fetched docs | Not in fetched docs | Streaming event shapes; model flag; usage |
| Cline CLI | `cline --json "…"` (NDJSON) → **no `--resume` flag in README** | NDJSON `agent_event` stream (jq examples show `.type/.event.text`) | `--auto-approve false`: non-TTY approvals are *denied*; desktop file-IPC approval exists | `-m`, `--thinking none…xhigh` | Not in fetched docs | `-v` stats: tokens, estimated cost | Resume/follow-up route (hub? history? ACP?); tool event shapes |
| Gemini CLI | `gemini -p --output-format stream-json` → `--resume latest\|<index>` | `init/message/tool_use/tool_result/error/result` JSONL | `--approval-mode default/auto_edit/yolo/plan` maps 1:1 | `-m`; no effort flag | Not in headless docs | `result` per-model token stats | **Which Google CLI is supported for individuals now** (see §3); stream shapes |

All ten clear the first gate — a vendor-supported machine-readable surface
that is not final prose. They differ in how much of the bar is documented
versus probe-debt, which sets the build order in §4.

## 1. The four with documented tool-level streams

### Cursor Agent — build first

[Output format reference](https://cursor.com/docs/cli/reference/output-format.md);
flags confirmed against local `--help` (2026.01.23).

```sh
cursor-agent -p --output-format stream-json --stream-partial-output [--force] [--model <m>] "<prompt>"
cursor-agent -p --output-format stream-json --resume <chatId> "<follow-up>"   # respawn follow-ups
cursor-agent create-chat   # mints a chat id up front; `models` / --list-models for discovery
```

Documented sample (upstream, trimmed — the shape the fixture must match):

```json
{"type":"system","subtype":"init","apiKeySource":"login","cwd":"<cwd>","session_id":"<uuid>","model":"Claude 4 Sonnet","permissionMode":"default"}
{"type":"tool_call","subtype":"started","call_id":"toolu_…","tool_call":{"readToolCall":{"args":{"path":"README.md"}}},"session_id":"<uuid>"}
{"type":"tool_call","subtype":"completed","call_id":"toolu_…","tool_call":{"readToolCall":{"args":{"path":"README.md"},"result":{"success":{"content":"…","totalLines":54}}}},"session_id":"<uuid>"}
{"type":"result","subtype":"success","duration_ms":5234,"is_error":false,"result":"…","session_id":"<uuid>"}
```

Mapping: `system/init` → `.sessionId` + `.system(model:)`; started → `.toolUse`
(name from the wrapper key — `readToolCall` → `read`, `writeToolCall` →
`write` — input = its `args`); completed → `.toolResult` (`result.success`
content, `isError` from a failure variant the probe must capture);
`result` → `.turnEnd(durationMs:)`. Honest gaps: print mode suppresses
`thinking` events entirely; no token usage in the documented `result`;
writes carry the full `fileText`, so an edit preview would be *derived*
against the file on disk, not reported — same call as ABS-88 §5, to be made
deliberately in the child ticket; `--stream-partial-output` emits duplicate
flushes that must be filtered by the documented `timestamp_ms`/`model_call_id`
rule. Permissions: print mode cannot be answered, so ask → no `--force`
(words in `permissionDetail` must say commands are refused, not asked),
autoEdits → default, bypass → `--force`. Local blocker today: not signed in
on this Mac (`cursor-agent login`, the CLI's own OAuth; `CURSOR_API_KEY` is
the CLI's alternative and stays the user's, never Abstract's).

### Amp — the Claude-shaped stream

[Streaming JSON](https://ampcode.com/docs/cli/streaming-json),
[execute mode](https://ampcode.com/docs/cli/execute-mode).

```sh
amp --execute "<prompt>" --stream-json                 # one turn per process
amp threads continue --execute "<follow-up>" --stream-json
amp --execute --stream-json --stream-json-input        # stdin follow-ups, image blocks supported
```

The stream is Claude Code's format: `system/init` with `session_id`
(thread id `T-…`) and tool list, assistant messages whose content holds
`tool_use {id, name, input}` blocks, user messages with
`tool_result {tool_use_id, content, is_error}`, per-message `usage`
(input/cache/output tokens), final `result`. Tool names in the documented
tool list (`Read`, `Grep`, `glob`, `Bash`, `edit_file`, `create_file`,
`web_search`, `read_web_page`) mostly hit existing `ToolKind` entries once
lowercased, plus `create_file`/`finder`/`read_web_page` additions. This is
the closest fold to `ClaudeProvider`'s parser of any candidate. Gaps:
execute-mode docs say non-interactive *environments* should set
`AMP_API_KEY` because the `amp login` session token expires within an hour —
Abstract spawns on the user's own Mac under their login, so the probe must
prove a spawned non-TTY process rides the login session (if it cannot, this
agent needs the user to have set the token themselves, and detection must
say so plainly); no per-call approval in execute mode (ask collapses, say
so); model choice is mode-based (`--fast`), not a catalogue — `fallbackModels`
may legitimately be just "the CLI's choice".

### Qwen Code — Claude-shaped, with Abstract's own style names

[Headless mode](https://github.com/QwenLM/qwen-code/blob/main/docs/users/features/headless.md).

```sh
qwen -p "<prompt>" --output-format stream-json --include-partial-messages [--model <m>] [--approval-mode <mode>] [--output-style <Style>]
qwen --resume <sessionId> -p "<follow-up>" --output-format stream-json    # respawn; stream-json input is "under construction"
```

`system/session_start` → session + model; assistant messages carry the
content blocks (probe confirms tool block fields); `result` carries usage;
textual tool results are bounded to 64 KB head/tail previews by the CLI
itself — the row shows what the CLI kept, nothing invented. Standout fit:
`--approval-mode plan|default|auto-edit|auto|yolo` covers ask/autoEdits/
bypass at launch, and `--output-style` takes `Concise`/`Proactive`/
`Explanatory`/`Learning` — Abstract's `OutputStyle` titles verbatim
(`Learning` is skipped headless upstream; fall back to injected
instructions there). Auth is the CLI's own (Qwen OAuth or a key the user
configures in Qwen); Abstract holds nothing.

### Pi — the strongest documented protocol, the smallest toolset

[JSON event stream](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/json.md),
[RPC mode](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/rpc.md).

```sh
pi --mode rpc [--provider <p>] [--model <m>]   # long-lived; stdin {"type":"prompt","message":"…"}
pi --mode json "<prompt>"                       # one-shot variant of the same event shapes
```

Events carry everything the bar asks for: session header with id,
`message_update` deltas (text/thinking/toolcall, by `contentIndex`),
`tool_execution_start/update/end` with `toolCallId`, full `args`, `result`,
`isError`, `durationMs`, cumulative `usage` including cost, and
`agent_settled` as the true turn end (not `agent_end`). RPC mode fits
`FollowUpMode.stdin`; the fold is deterministic from logged lines, and RPC
command *responses* must be treated as live-only (the `InputDrivingParser`
contract already states events must not depend on writes). Gaps: Pi's
built-in tools are deliberately minimal (read/write/edit/bash family;
search and web arrive via extensions the user installs — rows still render
generically when present, absent when not, which the UI must state as the
CLI's configuration, not Abstract's failure); no documented approval
surface (ask collapses); whether the edit tool's `result.details` carries a
diff is probe work. Sign-in is Pi's `/login` (subscription or key — Pi's
business, per the product rules).

## 2. Feasible, with a named unknown the probe must close

### Factory Droid

[Droid Exec](https://docs.factory.com/droid-exec/overview). Two transports:
one-shot `droid exec -o json` (structured artifacts) and multi-turn
`--input-format stream-jsonrpc --output-format stream-jsonrpc` driving
`droid.initialize_session` / `droid.load_session` over JSON-RPC — the
`muse serve` pattern Abstract already speaks. Launch surface is the richest
of the ten: `-s/--session-id`, `--fork`, `-m`, `-r` reasoning effort,
`--auto low|medium|high` over a read-only-by-default spec mode (a natural
ask/autoEdits/bypass ladder), `--cwd`, `--list-tools`. The unknown is the
JSON-RPC *event* shapes: the fetched docs show requests, not notifications.
Child ticket gates on capturing them signed-in. (Mission mode — Droid
spawning its own workers — is the CLI's feature; Abstract would run plain
`droid exec` sessions and must not build choreography on it.)

### GitHub Copilot CLI

[Programmatic reference](https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-programmatic-reference).

```sh
copilot -p "<prompt>" --output-format json [--model <m>] [--attachment <img>] [--add-dir <dir>] \
  [--allow-tool 'shell,write' | --deny-tool … | --allow-all]
```

JSONL output is documented for scripting, images attach in non-interactive
mode, resume flags exist (`--resume`, `--continue`, `--session-id` appear in
the `--trust-folder` constraints), and permissions are a launch-time
allow/deny list over `shell(...)`/`write(...)`/`url(...)`/MCP tools — ask
cannot be answered in `-p`, so it maps to a restrictive allowlist and
`permissionDetail` says so; `--allow-tool` granularity could even make
autoEdits honest (`write` allowed, `shell` not). Effort is a config-file
`effortLevel`, not a per-run flag in the reference, so the effort picker
would be absent unless the probe finds otherwise. Unknown: the JSONL tool
event schema (ids, args, results, usage) is not published on that page.

### Kimi Code

[`kimi` command reference](https://www.kimi.com/code/docs/en/kimi-code-cli/reference/kimi-command).

```sh
kimi -p "<prompt>" --output-format stream-json [-m <alias>]
kimi --session <id> -p "<follow-up>" --output-format stream-json   # or --continue
```

Stream-json emits OpenAI-shaped messages: an Assistant message carrying
`tool_calls`, then the matching Tool message. That yields tool id + args +
result, but no started event (progress goes to stderr in `-p` mode), so a
row can only appear when its call is already dispatched — running state is
"call seen, result pending" between the two messages, which is honest but
coarser than Claude's. Thinking is excluded from the JSONL. `-p` cannot
combine with `--yolo/--auto/--plan`: non-interactive runs are
auto-permission, so all three Abstract policies collapse to one behaviour
(static deny rules still apply) — the weakest permission story of the ten,
and the picker wording must say so. The alternative transport, `kimi acp`
(Agent Client Protocol over JSON-RPC), may restore lifecycle events and
approvals; see §3.

### Mistral Vibe

[Work with the CLI](https://docs.mistral.ai/vibe/code/cli/work-with-cli).

```sh
vibe --prompt "<prompt>" --output streaming [--agent plan|accept-edits|smart-approve|auto-approve] [--max-turns N]
vibe --resume <sessionId> …   # partial ids accepted; --continue for latest
```

The `--agent` ladder maps cleanly onto ask/autoEdits/bypass (with
`smart-approve` unused or as autoEdits' wording), sessions resume by id,
and programmatic mode is a supported, documented surface. Everything else
is probe-debt: the streaming event schema, a `--model` launch flag (only
in-session `/model` is documented), usage fields, image input. Feasible on
the strength of the supported programmatic mode; ranked by its unknowns.

### Cline CLI

[CLI README](https://github.com/cline/cline/blob/main/apps/cli/README.md).

```sh
cline --json "<prompt>" [-m <model>] [--thinking <level>] [--yolo | --auto-approve false] [-c <cwd>]
```

NDJSON output is a supported headless mode (`agent_event` records; the
README's own jq example selects `.event.text`), thinking levels map to
effort, and sign-in can be Cline's OAuth or a ChatGPT subscription
(`openai-codex`) — all CLI-held. Two named risks. **Resume:** the README's
options table has no `--resume`/session-id flag; sessions exist (`cline
history`, a hub daemon, `--team-name` persistence), but whether a later
process can continue *this* chat is undocumented — without it, follow-ups
would lose context, which fails the bar; the child ticket gates on finding
the supported route (hub session, ACP, or an undocumented flag), not on
inventing one. **Approvals:** with `--auto-approve false` and no TTY,
required approvals are denied outright (ask = tools refuse); the desktop
approval mode (`CLINE_TOOL_APPROVAL_MODE=desktop`, request/decision JSON
files) is a real, supported seam a later ticket could wire to
`.permissionRequest`, but it is file IPC, not stream — do not let it slip
into the first Cline ticket unscoped.

## 3. Two cross-cutting findings

**Gemini CLI's sign-in moved.** The documented surface is ideal
(`init/message/tool_use/tool_result/error/result`, `--approval-mode`
default/auto_edit/yolo/plan, per-model token stats in `result`,
`--resume latest|<index>` — index-based resume is awkward beside a persisted
id; `--list-sessions` exists). But the live binary on this Mac (0.37.1)
refuses the individual tier and directs users to Google's Antigravity
suite. Building `GeminiProvider` against a CLI its vendor is retiring for
individuals would ship a picker entry most users cannot sign into. The
Gemini child ticket therefore starts by identifying the supported Google
CLI and *its* stream (Antigravity's CLI, if it exposes one), and targets
that; if neither offers the documented stream-json to individual accounts,
that child ticket reports no-go and the replacement candidate below keeps
the count at ten.

**Replacement bench** (in case any child probe fails): agents with
documented structured surfaces not in the ten — Aider (`--json` history is
weaker: message log, not tool events — likely fails the bar), Crush and
Goose (headless/JSON output to verify), Muse via the existing
OpenCode-style servers. Each replacement needs the same signed-in probe;
none is pre-approved by this note. A failure swaps one child ticket, it
does not lower the bar.

**ACP is a shared second transport, not a shortcut.** Gemini (`--acp`),
Kimi (`kimi acp`), Cline (`--acp`) and Qwen (ACP sessions in its docs) all
expose the Agent Client Protocol. One ACP driver beside `OutputParser`
could in principle serve several agents — and would be the first
non-line-fold protocol besides Muse's, so it must still log lines that
refold offline. But ACP standardizes the envelope, not each agent's tool
payloads, diff detail or approval support; per-agent probes remain. This
spike recommends native streams first (they are the vendors' documented
automation surfaces) and treating ACP as the fallback investigated inside
the Kimi or Cline child ticket if their native streams fail the bar.

## 4. Child tickets, in build order

One ticket per agent, each: signed-in probe fixture first (sanitized — no
home directory, account, plugin or skill list), provider + parser,
tool-name entries in both presentation maps, `permissionDetail` wording
that matches reality, parser/replay tests, naming one-off only if the
CLI supports a tool-free call. Suggested order (documented certainty ×
distance from an existing parser):

1. **Cursor Agent runs in Abstract with detailed chat activity** — most
   completely documented tool stream; respawn follow-ups; no-usage and
   no-thinking gaps stated in the ticket.
2. **Amp runs in Abstract with detailed chat activity** — Claude-shaped
   fold; gates on the login-session question.
3. **Qwen Code runs in Abstract with detailed chat activity** —
   Claude-shaped; approval modes and output styles map directly.
4. **Pi runs in Abstract with detailed chat activity** — RPC transport;
   smallest surface, richest events.
5. **Factory Droid runs in Abstract with detailed chat activity** —
   stream-jsonrpc; gates on capturing its notification shapes.
6. **GitHub Copilot CLI runs in Abstract with detailed chat activity** —
   gates on the unpublished JSONL tool schema.
7. **Kimi Code runs in Abstract with detailed chat activity** — native
   stream first; ACP fallback decision inside the ticket.
8. **Mistral Vibe runs in Abstract with detailed chat activity** — gates
   on the streaming schema and model selection.
9. **Cline CLI runs in Abstract with detailed chat activity** — gates on
   a supported resume route.
10. **Google's coding CLI runs in Abstract with detailed chat activity**
    — first settles Gemini CLI vs. Antigravity; targets whichever CLI an
    individual can sign into with the documented stream.

ABS-91 ("at least ten more") is done when these ten (or a probed
replacement for any that fails) have shipped; it should track them as its
children rather than being built as one change.

Version checks for every child: `detectArgs` already runs the binary
(`--version`-style) before offering the agent; each provider should also
treat an unrecognized stream version/field set defensively (unknown lines
fold to `.raw`, unknown tools keep name + input + output) so a CLI upgrade
degrades a chat's detail, never breaks it. Minimum versions belong in each
child ticket once its probe pins the stream it tested.

## Go or no-go

**Go — as ten probe-gated child tickets in the order above.** All ten
candidates expose a vendor-supported structured surface (never final
prose, never a model API key held by Abstract), and for the four in §1 the
documented streams demonstrably carry stable tool ids, argument objects,
correlated results and session ids — everything `AgentEvent` and the
current tool presentation need, with the gaps named per agent rather than
papered over. The existing four agents do not count toward the ten; these
ten are all additional.

**No-go for building any single one from documentation alone.** This spike
live-proved none of them: on this Mac the two installed candidates cannot
run a turn (Gemini's individual tier is retired in favour of Antigravity;
Cursor Agent is not signed in) and the other eight are not installed. Each
child ticket's first step is therefore the signed-in ABS-88-style probe,
and a candidate whose real stream lacks tool ids, arguments or a resume
route (Cline's resume and Google's CLI identity are the two flagged risks)
stops there and is replaced — it does not ship as a launch-only picker
entry.
