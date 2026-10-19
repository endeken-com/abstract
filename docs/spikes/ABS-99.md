# ABS-99: how one chat hands sub-tasks to other chats, waits for them and hears back

**Question.** Can Paperclip-style delegation (a parent chat splits work into sub-tasks for
other chats, waits, and gets their results back) live in a plugin on the planned capabilities
— `chats.create`/`chats.message` (ABS-92), events (ABS-93), agent tools over MCP (ABS-97) —
with Abstract core only storing a chat's parent? ROADMAP.md lists "a workflow or pipeline
builder that chains agents" under **Not planned**, so if delegation needs a core engine, the
answer is no.

**Method.** Read the current seams: the `abstract` CLI
(`Packages/AbstractCore/Sources/AbstractCore/CLI/CommandLineTool.swift:212`),
the MCP server every chat already gets
(`Packages/AbstractCore/Sources/AbstractCore/CLI/HistoryMCPServer.swift:7`),
plugin API 1
(`Packages/AbstractCore/Sources/AbstractCore/Plugins/PluginManifest.swift:6`,
`Packages/AbstractCore/Sources/AbstractCore/Plugins/PluginBridge.swift:7`),
the chat record and store
(`Packages/AbstractCore/Sources/AbstractCore/Models/Records.swift:138`,
`Packages/AbstractCore/Sources/AbstractCore/Store/Store.swift:415`),
worktree provisioning
(`Packages/AbstractCore/Sources/AbstractCore/Sessions/Workspace.swift:30`),
turn summaries (`Packages/AbstractCore/Sources/AbstractCore/Sessions/Turns.swift:15`)
and stall detection
(`Packages/AbstractCore/Sources/AbstractCore/Sessions/StallWatch.swift:9`).
Then ran a throwaway prototype (§6) against an isolated data directory
(`ABSTRACT_DATA_DIR`), plus a scratch-repo test of the branch/merge model (§5). No prototype code is kept
in the repository; its worktrees, branches and isolated data were removed afterwards.

## 1. Plugin or core: plugin, with four small core additions

Delegation is a first-party **Delegation plugin**. Everything that is policy — the tree,
limits, who may delegate to whom, when the parent is woken, what a report contains — is the
plugin's, held in its own storage (`storage.own`, 512 KB of JSON; a tree of chat ids and
states fits easily). Core never learns "sub-task", never schedules anything, and gains no
screen of its own beyond showing the parent link it stores. That keeps Abstract on the right
side of "runs agents; it does not choreograph them": uninstall the plugin and delegation is
gone, children remain ordinary chats.

Core/host must add exactly four things, none of them a new concept for the user:

1. **`Session.parentSessionId`** (optional). One nullable column on `sessions` plus the
   `decodeIfPresent` pattern `Session` already uses for newer fields
   (`Packages/AbstractCore/Sources/AbstractCore/Models/Records.swift:209`),
   so older Macs and paired snapshots keep decoding. Shown as an indented child row in the
   sidebar with "2 of 3 sub-tasks done" on the parent (ABS-100's proposal). Core also refuses
   a create whose parent chain would cycle — it is the only writer of the link, so the check
   is authoritative and one ancestor walk.
2. **`chats.create` takes `parentId` and `baseBranch`** (in ABS-92). Worktree provisioning
   already accepts any base ref
   (`Packages/AbstractCore/Sources/AbstractCore/Sessions/Workspace.swift:46`);
   the child branches from the parent's branch (§5). The action returns as soon as the chat
   exists (`provisioning`), not after setup and agent start — a setup script alone can run
   for minutes, and ABS-97 caps a tool call at 30 seconds.
3. **`turn.finished` events carry the turn's summary** (in ABS-93), capped (see §2). Without
   it the plugin would need transcript access (ABS-95) just to report back, which is a much
   bigger grant than delegation needs. The host already derives this summary per turn
   (`Packages/AbstractCore/Sources/AbstractCore/Sessions/Turns.swift:95`).
4. **Wake-up messages are ordinary `chats.message` sends** (ABS-92), marked "Sent by
   Delegation" like every plugin action. No special wake channel.

What will **not** work is the shortcut the evidence suggested — an agent shelling out to the
`abstract` CLI today. The CLI refuses Codex and OpenCode outright
(`drivableProvider` only accepts stdin-follow-up agents,
`Packages/AbstractCore/Sources/AbstractCore/CLI/CommandLineTool.swift:427`;
Codex and OpenCode are `.respawn`), it cannot set a parent or a base branch (create always
bases on the project's default base,
`Packages/AbstractCore/Sources/AbstractCore/CLI/CommandLineTool.swift:237`),
`agent send` is refused while the app drives the chat, and headless approvals are denied.
The prototype hit the first of these live (§6). ABS-92's actions must therefore go through
the app's own session-start path, not the CLI's `AgentHost`.

## 2. The agent's side: two tools, both immediate

The parent's agent gets two MCP tools from the plugin (ABS-97), namespaced
`delegation.*`. There is no `report` tool: a child's final turn summary *is* its report, and
the child's first prompt tells it to end with one. A third tool would only duplicate what
the host already records, and a child that crashes could never call it.

| Tool | Takes | Returns (at once) |
|---|---|---|
| `delegate` | `title`, `prompt`, `agent`, `project` (default: the parent's) | the child chat id, or a refusal (§4) |
| `wait_for` | `children` (default: all unfinished children) | "Waiting. End your turn; you'll be sent their reports." |

Neither tool blocks. `delegate` returns the moment the child chat exists; `wait_for` only
records the pending wake in the plugin and instructs the agent to end its turn — a blocking
wait would die on ABS-97's 30-second tool limit, and a sleeping agent process is exactly
what Abstract's turn model avoids. When every waited-on child is finished, failed, or
stalled (§4), the plugin sends **one** `chats.message` to the parent and the parent's next
turn starts with it. This works for both follow-up modes: stdin agents are sitting idle,
respawn agents (Codex, OpenCode) resume with the message as their next prompt.

**Keeping the parent's context small.** The wake message carries, per child: its title and
agent, how it ended, its turn summary capped at the code-history budget
(`textBudget` = 2000 characters,
`Packages/AbstractCore/Sources/AbstractCore/History/CodeHistory.swift:99`),
its branch, and a changed-files count — never transcripts, diffs or tool output. In the
prototype, two children's full logs were 84 KB; the wake message built from their summaries
was 247 characters. A parent that wants more can open the child chat, like a person would.
Children that finish at different times are reported in the order they were delegated, and
nothing is sent until all of them have reached an end state (or one has failed — §4).

## 3. The org chart: not needed

Paperclip's tree ("every agent reports to exactly one manager") exists to answer "who may
assign work to whom, and who owns a stall". Abstract already has both answers without a new
concept:

- **Who may delegate, and to which agents:** ABS-97 already gives every plugin tool a
  per-project Allowed / Ask first / Off setting in Project Settings. The Delegation plugin
  adds one list to the same place — "Agents sub-tasks may use" — defaulting to every
  installed agent. A project that never opens it has nothing new to learn.
- **Who owns a stall:** the parent chat, because the parent link is the whole structure.
  Escalation is the wake message going up one level at a time (§4); there is no chart to
  walk because depth is capped at 2.

So: no org chart, no roles, no hiring. "Sub-task" is the only new word, and it names
something the user already sees — a chat indented under the chat that asked for it.

## 4. Guardrails

Enforced by the plugin at `delegate` time, each refusal returned to the agent as a tool
error it can act on, and shown in the parent chat as an ordinary tool row:

- **Ask first.** The `delegate` tool ships as Ask first (ABS-97's per-project setting). The
  permission card names the sub-task, agent and project, with Allow once / Always allow /
  Decline — Paperclip's hire approval, reused. Declined means no chat is created.
- **Fan-out and depth.** At most **5 children per chat** and **depth 2** (a child may
  delegate once; its children may not). Depth comes from the core parent chain, so a plugin
  bug can't mint a deeper tree than core can display.
- **Cycles.** Core refuses a parent link that would close a cycle (§1). The plugin also
  refuses to delegate a prompt identical to an ancestor's open sub-task in the same project,
  which is the practical shape a loop takes when ids are fresh each time.
- **Failure and stalls wake the parent.** A child that errors, or produces no output for
  the stall threshold Abstract already has (15 minutes by default,
  `Packages/AbstractCore/Sources/AbstractCore/Sessions/StallWatch.swift:9`;
  the plugin runs the timer with ABS-93's `jobs.schedule`), ends the wait early: the parent
  is woken with what finished, what failed and why, and can retry, reassign to another
  agent, or ask the person. The prototype exercised the reassign path live (§6).
- **Budget per tree: later, and already countable.** Usage is recorded per chat
  (`usage_events.session_id`), so a tree's tokens are a sum over descendants once the parent
  link exists. Enforcement belongs to ABS-116 (still in Triage, blocked on ABS-113); until
  then the fan-out/depth caps are the budget guardrail, and the plugin must not invent its
  own money limits. When ABS-116 lands, "pause at 100%" pausing a parent must pause its
  children too — noted on ABS-100.
- **Rate limits** come free from ABS-92 (10 actions a minute per plugin), which also bounds
  how fast children can be spawned even if a prompt loops.

## 5. Where children run, and how their work comes back

Each child runs in **its own worktree, branched from the parent chat's branch** at the
moment of delegation. One chat, one worktree is Abstract's existing rule; two agents in one
worktree would share a git index and working tree and corrupt each other's changes, and
Abstract has no per-file locking to offer instead. Branching from the parent's branch (not
the project's base) means the child sees the parent's committed work — the usual reason to
delegate "the tests for the API I just wrote". Uncommitted parent changes are not visible to
children; the child's prompt says so, and a parent that needs them shared must commit first.
Standalone (project-less) parents get standalone children in their own folders; there is no
merge step to offer there.

**Nothing auto-merges.** The child keeps its own branch and finishes like any chat: review,
commit, PR. The wake message names each child's branch, and the parent agent — which has a
shell and git, like any agent in Abstract — merges the branches it wants into its own
branch, in its own worktree, where the person reviews the result in Changes as usual. The
scratch-repo test confirmed the mechanics: two children branched from a parent branch with
an unpushed commit both saw that commit, disjoint changes merged back cleanly, and two
children editing the same line stopped the second merge with a conflict for the parent to
resolve — visible, not overwritten. A plugin that merged on the person's behalf would be
encoding a workflow; leaving the merge to the parent agent and the person's review keeps
delegation inside Abstract's existing Finish flow. Children created on a paired Mac are out
of scope for the first version: children start on the parent's Mac (plugins are per-Mac,
ABS-84 §5).

## 6. Prototype

ABS-92, ABS-93 and ABS-97 don't exist yet, so the prototype simulated the plugin's state
machine in a throwaway script driving today's `abstract` CLI against an isolated
`ABSTRACT_DATA_DIR` with this repository as its only project: the script was the parent,
polling stood in for events, and `session create` stood in for `delegate`. Two read-only
sub-tasks were delegated in parallel and the parent was "woken" once both reached `idle`:

| Step | Result |
|---|---|
| Delegate child 1 to **Claude** ("what does ROADMAP.md say Abstract is?") | Chat created in its own worktree/branch; finished in ~35 s with the correct one-sentence answer |
| Delegate child 2 to **Codex** ("what must PRs never change?") | **Refused by the CLI**: "“codex” isn't an agent abstract can drive. Use: claude, muse." — the failure came back at delegate time and the script reassigned the sub-task to **Muse**, which answered correctly ("Pull requests must never change the app's version."). This is the §1 finding and the §4 reassign path, exercised live |
| Delegate to a nonexistent agent | Refused the same way; nothing was created |
| Guardrails (simulated plugin state) | 6th child refused (fan-out), depth-3 delegation refused, ask-first decline refused |
| Wake message | One message with both reports, 247 characters, from 84 KB of combined child logs |
| Cleanup | Prototype hosts stopped, both worktrees and branches removed, the user's real database was never touched |

What the prototype does **not** prove: a live agent choosing to call `delegate`/`wait_for`
and a Codex or OpenCode child. Both need ABS-97 and ABS-92's app-side actions (§1) and are
the build ticket's acceptance tests, not this spike's. It does prove the load-bearing parts:
chats can be created for a parent by something other than the person, in parallel, on more
than one agent; their end states and summaries are observable from outside; a failure at
delegate time is recoverable by reassignment; and a capped wake message carries enough to
act on.

**Build ticket.** ABS-100 is updated with this split and these sizes: the core parent link,
sidebar indent and ABS-92/ABS-93 contract additions (§1) are **S** on top of those tickets;
the Delegation plugin (tools, guardrails, wake assembly, stall timer, plugin tests for
limits/cycle/wake/failure) is **M**. ABS-100 stays one ticket of size **L** in total only if
taken whole; splitting core (S) from plugin (M) is recommended, in that order, once ABS-92,
ABS-93 and ABS-97 land.

## Go or no-go

**Go** — for ABS-100 as a Delegation plugin on ABS-92, ABS-93 and ABS-97, with the four
core additions in §1 and the two-tool, non-blocking contract in §2. Delegation needs no org
chart (§3), its guardrails are enforceable at delegate time (§4), and children work in their
own worktrees branched from the parent's branch with no auto-merge (§5). **No-go** for a
core orchestration engine or visual pipeline (Not planned, and unnecessary), and no-go for
agents delegating through the `abstract` CLI from their shell: it cannot drive Codex or
OpenCode, cannot link or base a child correctly, and would bypass Ask first. One condition
on the go: ABS-92's `chats.create` must start chats through the app's session path (so every
agent works) and return before setup finishes, and ABS-93's `turn.finished` must carry the
capped turn summary — without those two, this spike should be re-read before ABS-100 starts.
