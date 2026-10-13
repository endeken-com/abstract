# ABS-60: can every agent take a code history tool from Abstract, and does it help

**Question.** Can Claude, Codex and OpenCode each be given a `code_history(path, lines)` tool by Abstract,
for one chat only, in the way Abstract already runs them? And does reading history change what they do
enough to be worth it?

**Method.** A throwaway stdio MCP server (about 100 lines of Python, standing in for `abstract mcp`)
answered `code_history` from six hand-made records about this repository. Four carry a real decision
(ABS-11, ABS-45, ABS-52, ABS-53), written from the tickets and pull requests; their "you corrected" and
"review" lines are paraphrased, not quoted. Two are unrelated records on the same files. Each agent was
run exactly as Abstract runs it, plus the flags below. That meant `claude -p` with stream-json and
`acceptEdits`, Sonnet, and `codex exec --json` with `workspace-write`, gpt-5.5 at medium effort. Runs
used the normal profile (its plugins, settings and global instructions), in a fresh worktree at
`5390495`. Each prompt ended "don't build, don't run tests, and don't commit". claude 2.1.283, codex-cli
0.156.1, opencode 1.18.18, 2026-10-13. 49 runs, plus the delivery checks.

## 1. Delivery for each agent

| Agent | Result | How |
|---|---|---|
| Claude | **Works, with two flags** | `--mcp-config '<json>'` and `--allowedTools mcp__abstract__code_history` |
| Codex | **Works, if the tool says it's read-only** | `-c mcp_servers.abstract.command=…` / `.args=…` / `.env=…` |
| OpenCode | **Works with a caveat: set up and connected, but no turn was run** | `OPENCODE_CONFIG_CONTENT='{"mcp":{"abstract":{"type":"local",…}}}'` |

**Claude.**
- `--mcp-config` takes inline JSON, and the server shows up as `source: "dynamic"` beside the user's own
  servers, which stay untouched. Don't pass `--strict-mcp-config`: it would drop the user's own servers.
- Without `--allowedTools` the call is refused under `acceptEdits` ("requested permissions … you
  haven't granted it yet"). With Abstract's `--permission-prompt-tool stdio` it arrives as a
  `can_use_tool` approval request, which the user would have to answer. `readOnlyHint` doesn't change
  that.
- In the stream it's an ordinary `tool_use` named `mcp__abstract__code_history`, then a `tool_result`.
- With many MCP tools installed, Claude Code defers them, so the agent first calls `ToolSearch`
  (`select:mcp__abstract__code_history`). It did that by itself every time; it costs one extra step.
- **Resume:** both flags must be passed again on every `--resume`. Without them the tool is gone, and
  the agent says it "disconnected".

**Codex.**
- `-c` overrides work on both `exec` and `exec resume` and never touch `~/.codex/config.toml`.
- `exec` runs with the approval policy "never". So a plain MCP tool fails: `"MCP tool call requires
  approval, but approval policy is never"`. If the tool declares `annotations: {readOnlyHint: true}`,
  it runs with no approval. Abstract's tool must be read-only anyway.
- The stream shape is now confirmed, where `CodexParser` marks it "unverified": `item.started` and then
  `item.completed`, with `type: "mcp_tool_call"`, `server`, `tool`, `arguments`, `result.content[]` or
  `error.message`, and `status`.
- If the user has their own `mcp_servers.abstract`, the overrides merge into it, so ABS-61 should pick a
  name nobody else uses.

**OpenCode.**
- With `OPENCODE_CONFIG_CONTENT`, `opencode mcp list` shows the server as connected.
- `opencode debug config` shows the env config *merged* with the user's and project's config: their own
  MCP servers and `instructions` are kept, and ours are added.
- The default `build` agent's rules allow every tool (`"*": "allow"`), so `run` without `--auto` would
  call it. A user rule of `"abstract_*": "ask"` would make `run` decline it, and the chat should say so.
- Each turn is a new process, so passing the same env on `--session` covers resume.
- **Not verified:** a real turn. No model is reachable from this Mac, the same limit as ABS-53. So the
  `tool_use` part's shape (`tool: "abstract_code_history"`) is unconfirmed, and so is whether OpenCode
  calls the tool.
- Abstract already sets `OPENCODE_CONFIG_CONTENT` for naming, so a chat launch has to build one JSON
  object holding both.

**Fallback** (`abstract history` plus one instruction): no agent needed it. Keep it as the command-line
feature ABS-61 already plans, not as a delivery path.

## 2. The instruction

| Agent | Where it goes | Note |
|---|---|---|
| Claude | `--append-system-prompt` | passed again on every resume |
| Codex | `-c developer_instructions=<TOML string>` | Abstract already uses this for output styles: join the two |
| OpenCode | `instructions: ["<file>"]` in `OPENCODE_CONFIG_CONTENT` | merged after the user's own (verified with `debug config`) |

**Without an instruction, no agent called the tool:** 0 calls in 8 runs (4 Claude, 4 Codex), even
though the tool's description says "call it before changing existing code".

**The wording matters.** The first draft said: "Follow those decisions unless the person's request
explicitly overrides one; if the request conflicts with one, say so." Both agents read the history and
then did what was asked: a request that named a command counted as "explicitly overriding". This text
made every agent stop on every conflict, and still let a harmless edit go through:

> Before you change existing code, call the code_history tool for each file you're about to change, with
> the lines when you know them. It returns what earlier chats in this project were asked, what the person
> corrected, and what was decided and why. Follow those decisions. If what you've been asked to do goes
> against one, don't make that change yet: quote the decision, say how the request conflicts with it, and
> ask whether to go ahead.

## 3. The format

Newest first within a relevance order: records about these lines, then this file, then its folder. Each
record has a heading line (date, chat title, ticket and PR) and then fields in this order: **Decided**,
You asked, You corrected, Agent's summary, Review, From the chat. The size limit drops fields before it
drops records.

| Limit | Returned | Holds | Result on the two conflict tasks (Claude) |
|---|---|---|---|
| about 500 tokens | 350–570 | heading + Decided, every matching record | flagged both |
| about 1,500 | 300–2,600 (summed over 1–6 calls) | + asked, corrected, summary | flagged the branch task; the index task in 1 of 3 runs |
| about 3,000 | 880–1,800 | + review, excerpt | flagged both |

The "Decided" line did the work: every flag quoted it, and only one also quoted a correction. **Use about 500
tokens by default**, and let `chat_excerpt` (ABS-61) give the rest when asked. That also needs ABS-62 to
record a decision for each turn, not only what was asked and done.

A real answer at the 500 limit, for `code_history("…/Git/Diff.swift", "225-235")` (354 tokens; the
third record is trimmed here):

```
## 2026-09-24 · Agent git commands fail on index.lock in Abstract worktrees · ABS-11
Decided: Background reads of an agent's worktree must never write its git index or take its index.lock:
the agent runs git there at the same moment, and its commands fail with 'index.lock: File exists'. Read
with `git --no-optional-locks`; never add `add -N`, `update-index`, `status` without --no-optional-locks,
or anything else that writes the index on a refresh path. […]

## 2026-10-11 · The Review tab refreshes only when the changes did · ABS-51 (PR #36)
Decided: The Review tab compares a fingerprint of the changes before replacing what's shown, so a refresh
that finds nothing new doesn't redraw or move your place.

## 2026-10-01 · Abstract's background git runs within a hard process budget · ABS-45 (PR #26)
Decided: Every background git read goes through the app-wide GitBudget […]
```

## 4. Does it help?

Each task is a request someone could plausibly make that runs into an earlier decision without naming it:

- **ABS-11:** "fix timestamp-only changes in `Diff.collect` with `git update-index -q --refresh`".
  It writes the agent's index.
- **ABS-45:** "show the stash count in each sidebar row, refreshed every 10 seconds". It's a new git
  poll.
- **ABS-52:** "when I rename a chat, rename its branch too". ABS-52 decided a title rename doesn't rename
  the branch, and set the safety checks for renaming one.
- **ABS-53:** "make Codex name chats with `gpt-5.5-mini`". ABS-53 said not to hard-code a Codex model,
  and to keep naming inside the agent's provider.

"Respected" means the agent followed the decision or stopped and named it. "Draft" is the first
instruction and "final" the one in section 2. Results with a count show how many runs out of how many.

| Decision | Claude, no tool | Claude, tool + draft | Claude, tool + final | Codex, no tool | Codex, tool + draft | Codex, tool + final |
|---|---|---|---|---|---|---|
| ABS-11 index lock | 0/3 (added it) | 3/5 flagged¹ | **3/3** stopped | 0/3 | 0/3 (read it, added it anyway) | **3/3** stopped |
| ABS-45 git budget | partly² | **yes**, stopped | — | partly² | partly² | **yes**, stopped |
| ABS-52 branch rename | partly³ | **3/3** flagged | — | partly³ | built it with every check⁴ | **yes**, stopped |
| ABS-53 naming | no (hard-coded) | **yes**, stopped | — | no (added a Codex switch outside its provider) | no (hard-coded) | **yes**, stopped |
| Control: rename a variable | done | — | done, no false alarm | done | — | done, no false alarm |

¹ At 1,500 tokens 1 of 3 runs flagged it, and its fix (`--no-optional-locks update-index`) still writes
the index. At 500 and 3,000 tokens both runs stopped and asked.
² Used the budgeted `reader(for:)`, which is visible in the code, but added a new 10-second git poll.
³ Proposed or built safety checks (Claude reused `AutomationRunNaming.renameBranch`), but neither
mentioned that a title rename isn't meant to rename the branch. Codex with the tool but no instruction
(it never called it) renamed with no upstream or pull request check.
⁴ Added the lock checks and "if GitHub can't be asked, assume a PR" from the history, which the version
without the tool lacked, but didn't mention the decision.

**Cost.**
- History adds 1 to 6 calls and 300 to 2,600 tokens to a turn.
- With the final instruction, the T1 runs took 37 s (Claude) and 23 s (Codex), against 45 s and 46 s
  without the tool. Stopping to ask is faster than building.
- On the control task the tool added 3 s (Claude) and 8 s (Codex).
- A run's total tokens varied two- to tenfold between runs of the same task for reasons that had
  nothing to do with the tool (cache reads, how far the agent explored), so these runs can't measure
  the total cost more precisely.

**What it shows.**
- With history and the final instruction, both agents caught every conflict (9 of 9) and let the
  harmless edit through.
- Without history, neither caught any: the decisions that only live in conversations (no new polls, no
  hard-coded model, a title rename keeps the branch) are invisible in the code.
- Decisions the code already shows (`reader(for:)`, the provider holding naming) were mostly followed
  either way.
- Runs were single for most cells, with the records written by hand and accurate. ABS-62's real records
  will be noisier.

## 5. Limits

Never passed to an agent:
- **Another project's chats.** Abstract starts `abstract mcp` for one chat. The server looks up that
  chat's project itself, and the agent can't name another one. Paths that leave the repository (absolute,
  `..`) are refused.
- **Deleted chats.** Deleting a chat (`AppModel.delete` → `Store.deleteSession`, `engine.deleteLog`) must
  delete its turn records in the same transaction (ABS-62), so they can't be returned afterwards. Archived
  chats still count: archiving tidies the list, it doesn't take back decisions.
- **Secrets pasted into prompts.** Records keep the request, corrections, summary and review, never tool
  output, file contents or attachments. Known key shapes (`sk-…`, `ghp_…`, `AKIA…`, `-----BEGIN … KEY`,
  `NAME=value` lines from env files, long high-entropy tokens) are masked when the record is written and
  again when it's returned.
- **The chat's own turns.** The agent already has them.

The project setting ABS-61 plans ("Give agents the history of the code they change") turns all of this
off: no server, no instruction. A chat on a paired Mac runs its server on that Mac, against that Mac's
own records.

## Go or no-go

**Go for ABS-61**, with these changes to it:

1. The instruction is the final text from section 2, not the one-line draft. The draft let Codex read a
   decision and then go against it, 3 times out of 3.
2. Claude also gets `--allowedTools mcp__abstract__code_history`, and both flags on every resume. The
   tool declares `readOnlyHint: true` for Codex. OpenCode's config is merged into the
   `OPENCODE_CONFIG_CONTENT` Abstract already builds.
3. The default limit is about 500 tokens of "Decided" lines, with `chat_excerpt` for more. ABS-62 records
   a one-line decision for each turn.
4. OpenCode's part is done when a real `opencode run` turn calls the tool: record the fixture with a
   working model. Until then, its delivery is built but unproven.
5. "Done when" keeps the `Diff.collect` check. Each agent stops and quotes the index-lock decision, which
   both Claude and Codex did here with the final instruction.
