# ABS-88: structured Muse Code tool events for detailed chat rows

**Question.** Which supported Muse Code surface supplies stable, real-time tool name,
arguments, output, status and file-change information for Abstract: an enriched
`muse exec --json` stream, a retained export, or the `muse serve` session protocol?

**Method.** Muse Code 1.4.10, signed in, model `muse-wonder-1.0`, in a clean
`/tmp` workspace holding only `hello.txt`. Three surfaces were driven with the same
kinds of work (read, file search, shell, edit, create, a read that must fail, web
search, web fetch, resume):

- `muse exec --json` (what Abstract uses today, ABS-87);
- `muse serve` over stdio, driven as a raw JSON-RPC (MSP) client:
  `initialize` → `session/start` → `turn/start`, then a second process doing
  `session/resume` on the same session;
- `muse export --session <id>` on the serve session afterwards.

The MSP shapes below were checked against this binary's own exported schema
(`muse schema generate-json-schema`, fingerprint matches the `initialize` reply),
not only against the [online
cookbook](https://meta-models.github.io/muse-code-sdk/next/cookbook/cancel-a-running-turn/).
Abstract-side names are `MuseProvider.swift`, `ProviderContract.swift` (`AgentEvent`,
`EditPreview`), Mac `Abstract/Features/Chat/ToolCallViews.swift` (`ToolKind`,
`ToolPresentation`) and phone `mobile/src/toolPresentation.ts`. No home directory,
account, plugin or skill appears below; paths are the clean workspace's.

## 1. `muse exec --json` cannot be enriched: the arguments are not there

The journal stream Abstract parses today has no tool arguments anywhere. In the
probe (read `hello.txt`, run `echo`), no payload of any `payload_type` contained a
`path`, `args` or `command` key. The file name appears only in the echoed prompt
(`turn.input.user`) and inside result prose (`tool.result.text`,
`task.lifecycle.output.event.chunk`). Per tool call the stream carries only:

| Record | Tool fields present |
|---|---|
| `task.lifecycle.proposed` | `event.task_kind`: `tool.read_file` |
| `task.lifecycle.scheduled` | `event.idempotency_key`: `tool:<call_id>` |
| `task.lifecycle.side_effect_intent` | `event.operation`: `tool:read_file`, `policy_decision` |
| `tool.result` | `call_id`, `text`, `correlation_facts: {tool_name, outcome}` |

`muse exec --help` (1.4.10) has no flag that adds arguments or detail to this
stream. So `MuseParser`'s `input: .object([:])` is not a parser shortcut; it is all
the stream offers. Any file name shown from this surface would be guessed out of
`tool.result.text` prose, which ABS-89 forbids. **This surface is a dead end for
detailed rows** (it stays fine for the naming one-off, which only reads the final
text).

## 2. `muse export` is the same journal, after the fact

`muse export` writes the session's durable journal records verbatim (export schema
version 1): 471 events, about 1 MB for the two probe turns, including encrypted
reasoning. It is an offline, whole-session file: nothing arrives while a turn runs,
and the tool records are the same argument-free envelopes as `exec`. It cannot back
live rows, and replaying it would duplicate the chat log Abstract already keeps.
**No.**

## 3. `muse serve` carries everything, live

`muse serve` is a per-process MSP host on stdio (one client, which owns stdin and
stdout). After `session/start` and `turn/start`, the host pushes a view stream of
transcript **items**: `item/started`, `item/delta`, `item/updated`, `item/completed`,
each with `sessionId`, a monotonic `viewCursor`, and the full item at a `revision`
(apply rule: replace if higher). A `toolCall` item carries, per the exported schema
(all confirmed live below): `tool`, `callId`, `args` (the model's argument JSON as a
**verbatim string** — clients parse it; it can be almost-JSON), `status`
(`inProgress`/`completed`/`failed`/`cancelled`/`rejected`/`timedOut`),
`visibleOutput` (bounded result text; streams mid-call via `item/delta` on field
`output`), `truncated`, `outputRef`, `displayLabel` (the tool's own
active/done/neutral one-liners), `failureKind`/`failureReason`, `approvalId`, and for
edit-family tools `patchSummary` plus `patchRef`.

### Event matrix (sanitized, from the two live serve turns)

| Muse tool | `args` (verbatim string, shown parsed) | Result and status on the item | Abstract target |
|---|---|---|---|
| `read_file` | `{"path":"hello.txt"}` | `visibleOutput`: `Read text file…` + numbered lines; `status: completed` | `path` → file name + icon |
| `search` | `{"pattern":"needle"}` | `visibleOutput`: `hello.txt:2:second line needle` | `pattern` → search target |
| `bash` | `{"command":"echo spike-shell-ok","description":"Echo spike shell ok"}` | `visibleOutput`: a JSON receipt text incl. `exit_code: 0` and output — readable, but noisier than Claude's plain output | `command` → command target |
| `edit_file` | `{"path":"hello.txt","find":"second line","replace":"changed line"}` | `patchSummary {files:1, added:1, removed:1}`, `patchRef`; `visibleOutput` holds a small `---/+++` diff of the changed lines only | `path` + edit preview (see §5) |
| `write_file` | `{"path":"made.txt","content":"made"}` | `patchSummary {files:1, added:1, removed:0}`, `patchRef` | `path` + edit preview |
| `read_file` (missing file) | `{"path":"missing-nope.txt"}` | `status: failed`, `failureReason`: `No such file or directory (os error 2); …` (contains the resolved absolute candidate path), `visibleOutput` starts `tool failed: …` | Failed row, target still known |
| `web_search` | `{"query":"current Swift version"}` | `visibleOutput`: JSON with `results[{url,title,…}]` | `query` → search target |
| `web_fetch` | `{"url":"https://example.com"}` | `visibleOutput`: page text | `url` → page target |

Notes on the matrix:

- Web tools arrived as ordinary `toolCall` items named `web_search`/`web_fetch`.
  The schema also defines a separate `webSearch` item kind; the parser must accept
  both and not assume either.
- Turns also produce `userMessage`, `agentMessage` (the reply, delta-streamed),
  `hookRun` and `reminderChild` items. Unknown kinds must render generically (the
  schema says so; items may carry `fallbackText`). `item/completed` can arrive for
  an item never seen in `item/started` — the fold must not require the start.
- The argument **keys** are already the ones Abstract reads: `path`, `pattern`,
  `query`, `url`, `command`. `ToolPresentation.path` reads `path` for non-command
  calls and `target` falls back through `pattern`/`query`/`url`. What is missing is
  only the tool **names**: `ToolKind` (and the phone map) know `read`/`grep`/`glob`
  but not `read_file`, `search`, `edit_file`, `write_file` or `web_fetch`
  (`web_search` and `bash` are already recognized).

### Mapping into `AgentEvent`

| Serve item | `AgentEvent` |
|---|---|
| `toolCall` first seen (started or completed) | `.toolUse(id: callId, name: tool, input: parse(args) ?? .object([:]), edit: nil)` — unparsable `args` keeps the call honest: name + output, no invented target |
| `item/delta` on `output` | append to the pending result text for that `callId` (do not emit per delta) |
| `toolCall` terminal (`item/completed`) | `.toolResult(toolUseId: callId, output: visibleOutput, isError: status != completed, edit: …)` |
| `patchRef` body (when fetched, §5) | `EditPreview` on the result: the stored document is `{"files":[{"path", "hunks":[{"oldStart","oldLines","newStart","newLines","lines":[" ","-","+"]}]}]}`, which maps field-for-field onto `EditPreview.Line(origin, oldLine, newLine)`; multi-file patches fit `.toolFileChanges` |
| `agentMessage` deltas/completion | `.text(…, partial:)` as today, keyed by item id |
| `turn/completed` | `.turnEnd` + `.status(.finished)`; a failed item alone does not fail the turn |
| `session/started`-equivalent result | `.sessionId`, `.system(model:)` from the start/resume results |

## 4. Lifecycle: what serving changes, and what it preserves

Abstract already speaks to `muse serve` once: `MuseModelDiscovery` spawns it to list
models. Driving chats the same way fits the existing contract with two changes and
one open seam:

- **Start and resume.** Every request id the host needs is client-minted: the
  `commandId`s (UUIDv7; `turnId` derives from the turn's) and even the
  `sessionId` (`session/start.sessionId` takes an exact new id). So one
  precomputed `stdinInitial` batch — `initialize`, `initialized`,
  `session/start` (or `session/resume`), `turn/start` — works without waiting for
  replies, exactly like Claude's `stdinInitial` user message. (Observed trap for
  ABS-89's tests: `initialize.clientInfo.name` must match `^[a-z0-9_]+$`.)
- **Follow-ups.** `followUpMode` becomes `.stdin` with the host kept alive between
  turns (`keepStdinOpen: true`, as Claude). But `buildUserMessage(_:)` receives
  only the text — no session id — and `turn/start` needs `sessionId` plus a fresh
  `commandId` per turn. **Minimum contract change:** let a stdin provider's parser
  (which already saw the session id) be the thing that supplies follow-up lines, or
  pass the session id into `buildUserMessage`. This is the one place ABS-89 must
  touch the shared contract; size it as Muse-only state if possible.
  Alternative that avoids it: one serve process per turn (keep `.respawn`), batch as
  above, end the process at `turn/completed` (SIGTERM flushed the session log
  cleanly in the probe), and `session/resume` next turn with `excludeItems: true`.
  Simpler, matches today's Muse lifecycle, and spends a host spawn per turn.
- **No duplicates, nothing lost.** `session/resume` returns history items inline
  with the **same `callId`s** as the live stream (verified: all five first-turn
  calls came back identical, patch summary included). The parser must therefore
  either resume with `excludeItems: true` (metadata only, page history separately)
  or dedupe on `callId`. Abstract's own log stays the transcript of record: the
  raw serve lines are logged and re-folded by the same parser after a relaunch and
  on a paired Mac (the `LineEnricher` contract: live, replay and other Macs read
  the same lines). The fold is deterministic and offline — started/updated/completed
  by `revision`, keyed by `callId` — so replay needs no host. `view/subscribe`
  with `after:` also exists for gapless re-attach if the live-host route is chosen.
- **Stop.** Today Stop terminates the Muse process (`TurnStop` → `.terminate`).
  Serve offers `turn/cancel` (and `turn/interrupt`); `buildInterrupt` is the existing
  seam. Keeping terminate-on-stop also remains correct with the per-turn route.
- **Permissions.** This is where serve differs most. The host's sandbox posture is
  fixed at launch by process flags (`--disable-sandbox`, `--disable-write`,
  `--disable-shell`, `--trust-workspace`); **approval mode is chosen on the wire**
  per session (`approvalMode`: `allowAll`, `promptUnmatched`, `onRequest`,
  `denyUnmatched`; changeable with `session/setApprovalMode`) instead of the exec
  flags `.ask/.autoEdits/.bypass` map to today. There is no `--yolo` on serve:
  bypass ≈ `allowAll` + `--disable-sandbox`. A held call arrives as an
  `approval/request` carrying `approvalId` (also the item's `approvalId`) and is
  answered with `approval/decide` (`approvalId`, `choiceId`,
  `currentRequirementId` as a race guard, `commandId`). That means serve *can* fix
  ABS-87's known limitation — ".ask is read-only because Abstract cannot answer an
  approval" — by having the parser emit `.permissionRequest` and
  `buildPermissionResponse` write the decision. That is new user-visible behaviour,
  not needed for detailed rows; ABS-89 should either include it deliberately or
  keep the current mapping (read-only `.ask` via launch flags + `denyUnmatched`)
  and say so. Do not let it slip in unnoticed.
- **Images, model, effort.** `turn/start.input` takes text and image parts;
  `modelId`/`reasoningEffort` are per-session/per-turn on the wire
  (`session/start.modelId`, `turn/start.reasoningEffort`), replacing the exec
  `--model`/`--reasoning-effort`/`--image` flags. Model discovery and the naming
  one-off stay exactly as they are.

## 5. The one gap: full output and full diffs sit behind a request

`visibleOutput` is budgeted: long results arrive `truncated: true` with an
`outputRef`, and the complete bytes — likewise the structured patch body behind
`patchRef` — are fetched with `item/readOutput` (byte-ranged, works on loaded and
unloaded sessions). A passive `OutputParser` cannot ask. Three honest options for
ABS-89, in the order this spike recommends trying them:

1. **Fetch after the fact with a short-lived serve probe**, the pattern
   `MuseModelDiscovery` already uses: at turn end, for each `patchRef` (and any
   truncated `outputRef` the UI expands), spawn `muse serve`, `item/readOutput`,
   and enrich. Because enrichment must happen before a line is logged if replay is
   to show the same preview (relaunch, paired Mac), prefer writing the fetched patch
   into Abstract's log via a `LineEnricher`-shaped step, or accept previews only
   while the session is loaded. Decide this first; it shapes the ticket.
2. **Use what the item already carries**: `patchSummary` gives files/added/removed
   counts inline, and `edit_file`'s `visibleOutput` already includes a small
   changed-lines diff. That covers ABS-89's "changed file and an inline change
   preview" for single edits, but `write_file`'s output is just
   `wrote N bytes to <path>` — no preview without the fetch (its `args.content`
   could synthesize one, but that is deriving a diff, not reporting one; say so if
   used).
3. **Give the parser a request channel** (a small driver protocol beside
   `OutputParser`). Most general, biggest contract change; only if options 1–2
   prove unworkable.

Other gaps that remain even on serve:

- `args` is a verbatim string, not an object: parse defensively, and an
  unparsable value means the row shows the tool name and output with no target.
  Unknown tools keep name + any recognized keys + output; nothing is inferred from
  prose. That satisfies ABS-89's "honestly labeled" clause.
- `bash` and `web_search` results are JSON-shaped text, so the result body reads
  noisier than Claude's until the presentation trims it. No structured
  exit-code field on `toolCall` (that exists on `userShell` items, a different
  kind); failure is `status`/`failureReason`, which is enough for the Failed row.
- `failureReason` can contain absolute paths (the resolved candidate). Fine in the
  app's own chat; fixtures must be sanitized, as usual.
- Subagent/workflow calls appear as their own item kinds (`subagent`, `workflow`)
  with child session ids; mapping them onto Abstract's `.subagent`/`.task` events
  is possible but beyond ABS-89's acceptance cases — render generically first.

## 6. Minimum plan for ABS-89

1. **Transport**: Muse provider launches `muse serve` (flags from the permission
   policy as in §4), `stdinInitial` = initialize + session start/resume + first
   `turn/start`, client-minted session and command ids persisted as the resume id.
   Choose per-turn respawn vs long-lived host (§4) — respawn is the smaller delta.
2. **Parser**: replace the journal fold for chats with an item fold keyed by
   `callId`/item id with revision replace-if-higher; emit `.toolUse` with parsed
   `args`, `.toolResult` from `visibleOutput` (delta-accumulated), `isError` from
   terminal `status`; keep unknown lines `.raw`. The exec parser stays for naming.
3. **Names**: add `read_file`, `search` → explore (and `web_fetch`), `edit_file`,
   `write_file` → edit in Mac `ToolKind` and phone `toolPresentation.ts`, so the
   existing targets, icons and explore-grouping light up from the argument keys
   that already match. No new UI concept; `displayLabel` may seed the row verb.
4. **Diffs**: `patchSummary` inline now; full `EditPreview` from `patchRef` via
   option 1 or 2 in §5, decided up front.
5. **Permissions**: keep ABS-87's mapping and wording unless ABS-89 deliberately
   adopts `approval/decide` (§4). Either way, pin the mapping in tests.
6. **Tests**: sanitized serve-stream fixtures per row of the matrix (read, search,
   shell, edit, create, failed read, web search/fetch, resume returning the same
   callIds), parser fold tests (completed-without-started, revision replacement,
   unparsable `args`, delta accumulation), Mac + phone presentation tests, and a
   replay test proving the logged lines refold to the same events offline.

Against ABS-89's acceptance cases: file read (name + icon) ✓ from `args.path`;
edit (changed file + preview) ✓ via `patchSummary`/`patchRef` or the inline diff;
shell (command + result) ✓; local search (query + matches) ✓ from `args.pattern`;
web search/fetch (query/URL) ✓; running/completed/failed ✓ from item `status`;
grouped exploration ✓ once names are mapped; reopen/phone ✓ because the same
logged lines refold everywhere; unexposed arguments stay honestly labeled ✓
(unparsable `args` path); no duplicate or lost calls ✓ if resume dedupes by
`callId` or uses `excludeItems`.

## Go or no-go

**Go — on `muse serve`.** It is the only surface that carries the model's actual
arguments, status and patch data in real time, and every ABS-89 acceptance case maps
to a field verified live in this spike, with no target ever guessed from output
prose. The follow-up's real work is the transport and fold (§6.1–2), the
`readOutput` fetch decision (§5), and a deliberate call on approvals (§4) — not
discovering where the data lives.

**No-go** for enriching `muse exec --json` or mining `muse export`: the journal
stream contains no arguments to parse (verified by scanning every payload of a live
run), and the export is the same journal, offline. ABS-89 should not spend time on
either.
