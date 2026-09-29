# Roadmap

Abstract runs several CLI coding agents in parallel, each in its own git worktree,
and helps you review, finish and ship what they changed. This file is the plan for
what ships next, one week at a time. It is written so that an automated agent can
pick an item, build it, and open a pull request whose title becomes the line in that
week's release notes.

Last planned: 2026-09-28. Current stable: v0.9.0. Next cut: v0.10.0.

## How the weekly release works

- A **minor release is cut every Friday** from `main` (Actions → *Cut release* → `minor`).
  Everything merged since the previous tag ships in it. Nothing is cut on merge.
- **Release notes are generated from PR titles.** The cut workflow calls GitHub's
  `generate-notes`, which lists every merged PR since the last tag, and puts the optional
  hand-written `notes` input above that list. So the PR title *is* the release note line.
- **The week's headline** (below, per release) is what goes into the `notes` input when
  the release is cut. Keep it to two sentences a user would want to read.
- **Fixes after the cut** go to `main` first, then get cherry-picked onto `vX.Y.x` and
  released with *Patch release* (see AGENTS.md). Nothing in this file needs a patch.
- **Freeze on Thursday.** A PR that isn't green and reviewed by Thursday evening moves
  to the next week; its item keeps its ID.

## How an agent works an item

1. Pick the topmost `planned` item in the current week whose blockers are shipped.
   Set it to `in progress (#PR)` in the same PR you open for it.
2. Branch from `main`. One item is one PR. Never change `project.yml`'s version
   (CI sets it from tags).
3. **Use the PR title written in the item, verbatim.** It is the release-note line.
   Write it the way the rest of the notes read: what changed for the user, present
   tense, no ticket numbers. Label the PR as the item says (`feature`, `fix`, `agents`,
   `internal`). Labels place the line under the right heading once R-1001 ships.
4. Do what *Do* says, stop when *Done when* is true, and add the tests under *Tests*.
   `cd Packages/AbstractCore && swift test` must pass; the app must build.
   Recorded agent streams must not carry a real home directory, account, plugin or
   skill list (AGENTS.md).
5. Follow the product rules below. If an item turns out to need a new concept the user
   has to learn, stop and say so in the PR instead of adding it.
6. When the PR merges, set the item to `shipped vX.Y.0` in a follow-up commit on `main`
   (or in the same PR if you know the version).

Sizes: **S** fits in a day for one agent, **M** two to three days, **L** a week, and an
L item always has a spike (a `spike` item) the week before.

## Product rules

These come from how Abstract has been built so far and decisions already taken.

- **Correctness before orchestration.** Make the concepts Abstract already has
  (Chats, Changes, Commit, Push, PR, Automations, Devices) behave correctly in more
  cases before adding new concepts or encoding one team's workflow. Ask: does this add
  an idea the user must learn, or make an existing one right?
- **Agents are equals.** Anything Claude can do in the app, Codex and OpenCode should do
  too, as far as their CLIs allow. When a CLI can't, say so in the UI instead of failing
  quietly.
- **Subscription CLIs only.** Abstract never calls a model API and never holds a model
  key. It also never knows which model server an agent uses (Ollama, LM Studio); that
  is the agent's business.
- **Public repository.** No personal paths, accounts or fixtures from a real profile.
- **One type per agent.** Adding an agent is one `ProviderDefinition` plus one line in
  `ProviderRegistry`. Keep it that way.
- **Plain language in the UI and in notes.** Sentences, not labels. No jargon a
  newcomer to the app wouldn't know.

## Themes

| Theme | What it means | Why now |
|---|---|---|
| **Finish** | Reviewing, committing, pushing and merging work correctly, including submodules | Submodule support is half-shipped (PR #10) |
| **Parity** | Codex and OpenCode catch up with Claude: approvals, commands, usage, drafting | Users who chose those agents get a worse app today |
| **Trust** | Tests around the app layer, screenshots in CI, release notes that read well | Automated agents will ship most of this roadmap; they need a net |
| **Reach** | The command line, paired Macs and the menu bar make Abstract usable when its window isn't in front | The app already runs headless and on other Macs; the UI lags |
| **Speed** | The palette, shortcuts and navigation | Once the basics are right, this is where daily use gets faster |

## Status legend

`planned` · `spike` (answer only, no code kept) · `in progress (#PR)` · `shipped vX.Y.0` · `moved → vX.Y` · `dropped (why)`

---

## v0.10.0 — week of 2026-09-28 (cut Friday 2026-10-02)

**Headline:** Submodules are reviewed and shipped safely, one repository at a time.
Release notes are now grouped, and a project's default agent, policy and base branch
can be changed after it's added.

### R-1000 · Submodules: review each repository on its own, and ship them safely
- Status: in progress (#10) · Size: L · Label: feature · Theme: Finish
- Why: a project with submodules showed the wrong diff and could push a parent that
  pointed at an unpushed submodule commit.
- Do: finish review of PR #10 and merge it. It already contains the per-repository
  selector, innermost-first commit and push, and the push guard.
- Done when: PR #10 is merged and the core tests pass on `main`.
- Tests: already in the PR (502 core tests).

### R-1001 · Group release notes into features, fixes, agents and internals
- Status: planned · Size: S · Label: internal · Theme: Trust
- Why: the notes are one flat list of PR titles today. Grouping makes the weekly note
  readable without hand-editing.
- Do: add `.github/release.yml` mapping labels `feature`, `fix`, `agents`, `internal` to
  sections "New", "Fixed", "Agents" and "Under the hood"; exclude `internal` from the
  main list if GitHub's schema allows it. Create the four labels. Add a short "Pull
  request titles and labels" section to AGENTS.md saying the title is the release line.
- Done when: a dry run of `gh api repos/:owner/:repo/releases/generate-notes` on a
  branch with labelled PRs shows the sections.
- Tests: none (config). Run `actionlint` as `test.yml` does.
- Touches: `.github/release.yml`, `AGENTS.md`.

### R-1002 · Change a project's default agent, permission policy and base branch in Project Settings
- Status: planned · Size: S · Label: fix · Theme: Finish
- Why: these three are set only when a project is added (`AppModel.addProject`, around
  `Abstract/App/AppModel.swift:515`) and can't be changed afterwards.
- Do: add the three controls to `Abstract/Features/ProjectSettings/ProjectSettingsView.swift`
  next to the naming section, saving through the same path the Add Project sheet uses.
  The Launcher must pre-fill from the saved values.
- Done when: changing them in settings changes what a new chat in that project defaults to.
- Tests: a `Store` round-trip test for the updated project record; a Launcher default
  test if one exists in `Tests/AbstractCoreTests`.

### R-1003 · Count OpenCode's tokens and cost in Usage
- Status: planned · Size: S · Label: agents · Theme: Parity
- Why: the Usage ledger reads Claude and Codex logs only; OpenCode chats show nothing
  under Settings → Usage even though its stream reports tokens and cost per step.
- Do: extend `Abstract/Features/Usage/UsageLedger.swift` (and the core `Usage/` types)
  to read OpenCode's per-step usage from session logs, keyed by workspace and day like
  the others.
- Done when: an OpenCode chat from the demo or a recorded fixture appears in Usage
  with tokens and cost.
- Tests: a ledger test over a recorded OpenCode stream fixture
  (`Tests/AbstractCoreTests/Fixtures/`).

### R-1004 · Don't block every push on a repository with no upstream and no base
- Status: planned · Size: S · Label: fix · Theme: Finish · Blocked by: R-1000
- Why: the push guard compares against the SHA-1 empty tree, so a SHA-256 repository
  with no upstream and no base branch blocks every push.
- Do: get the empty tree with `git hash-object -t tree /dev/null` in the repository
  instead of hard-coding the SHA-1 constant (`Git/Shipping.swift`, `unpublishedPointers`,
  both arriving with PR #10).
- Done when: a SHA-256 test repository with one commit and no remote can be pushed
  when a remote is added.
- Tests: extend the Shipping tests with a SHA-256 repository (`git init --object-format=sha256`).

---

## v0.11.0 — week of 2026-10-05 (cut Friday 2026-10-09)

**Headline:** Pull, update from base and merge locally now work across submodules.
Abstract lives in the menu bar when its window is closed.

### R-1100 · Pull, update from base and merge locally across submodules
- Status: planned · Size: M · Label: feature · Theme: Finish · Blocked by: R-1000
- Why: commit and push handle submodules innermost-first; the three remaining git
  actions still act on the parent only and leave submodules stale or detached.
- Do: run each action per repository, innermost-first, on the chat's branch in each
  submodule; show per-repository outcomes in the git action's tooltip. A conflict in any
  repository stops the sequence and names the repository.
- Done when: a project with one nested submodule can be updated from base and merged
  locally with both repositories ending on the expected commits.
- Tests: `GitActionsTests` with a fixture that has a submodule; one conflict case.

### R-1101 · Show Abstract in the menu bar while its window is closed
- Status: planned · Size: M · Label: feature · Theme: Reach
- Why: closing the window keeps the app (and its automations and agents) running with no
  visible sign of it. The earlier Tauri build had a tray icon; the Swift app lost it.
- Do: a menu bar item with: agents waiting for you (click opens that chat), running chats
  count, "Open Abstract", "Run automation ▸", "Quit". A setting under General to hide it.
  Use the existing notification model as the source for "waiting for you".
- Done when: with the window closed, an agent asking a question shows in the menu bar
  item and clicking it opens the chat.
- Tests: the model behind the menu (which chats count as waiting) in core tests; no UI test.
- Touches: `Abstract/App/`, `Abstract/Features/Settings`.

### R-1102 · Wait for the warning before letting you remove a worktree with unpushed submodule commits
- Status: planned · Size: S · Label: fix · Theme: Finish · Blocked by: R-1000
- Why: the remove sheet enables Remove before its "unpushed commits" check has finished.
- Do: disable Remove until the check returns; show a spinner in the sheet.
- Done when: the button can't be pressed before the check completes.
- Tests: a state test for the sheet's model.

### R-1103 · Ask GitHub once per host when a project has several GitHub submodules
- Status: planned · Size: S · Label: fix · Theme: Finish · Blocked by: R-1000
- Why: `AppModel.access(to:)` (added by PR #10) runs a `gh` lookup for every GitHub submodule on the first
  commit, concurrently and without retry once `gh` becomes ready.
- Do: cache lookups per remote host for the app's lifetime, coalesce concurrent calls,
  and retry once `gh auth status` succeeds.
- Done when: a project with three GitHub submodules makes one lookup per host.
- Tests: a test with a fake executor counting `gh` invocations.

### R-1104 · Repeat an automation on "the last Friday of the month" and similar rules
- Status: planned · Size: S · Label: feature · Theme: Reach
- Why: `Recurrence.swift` rejects numbered BYDAY (`-1FR`) and BYSETPOS, which the
  automation form can't express either.
- Do: implement numbered BYDAY and BYSETPOS for MONTHLY rules; add "first/last weekday
  of the month" choices to the automation form. YEARLY stays unsupported.
- Done when: a rule with `BYDAY=-1FR` fires on the right dates in `RecurrenceTests`.
- Tests: `RecurrenceTests` cases for first, second and last weekday; a leap-year month.

### R-1105 · Spike: how Codex can ask for approval inside Abstract
- Status: spike · Size: S · Label: internal · Theme: Parity
- Question: can Abstract receive Codex's approval requests (command, file change) and
  answer them, the way it does with Claude's permission tool? Candidate: run Codex through
  its app-server JSON-RPC over stdio instead of `codex exec`, and answer
  `applyPatchApproval` / `execCommandApproval`. Also check whether the same channel
  streams text deltas (which `exec` doesn't).
- Output: a one-page note in the PR (no code kept) with the protocol shape, what
  changes in `CodexProvider.swift`, and a go/no-go for R-1200.

### R-1106 · Submodules: update, pull, commit and push the repository you're working in
- Status: in progress (#13) · Size: M · Label: feature · Theme: Finish · Blocked by: R-1000
- Why: a feature often changes the parent and a submodule, and the git actions button
  only acted on the parent, so a submodule's branch couldn't be brought up to date with
  its own default branch from Abstract.
- Do: one current repository per chat, picked in the review's repository menu and shared
  with the git actions button. With a submodule current, Update from its own default
  branch, Pull, Commit and Push act on it and what's inside it, innermost first and
  guarded, and leave the parent's pointer for the parent.
- Done when: with a submodule current, Update from `<its default branch>` merges its
  `origin/<default>`, and Commit and Push leave the parent untouched.
- Tests: `SubmoduleGitActionsTests` (update, pull and shipping in a submodule).

### R-1107 · Submodules: see each repository's pull request, linked to the others
- Status: planned · Size: M · Label: feature · Theme: Finish · Blocked by: R-1106
- Why: a feature's parent and submodule pull requests live in different repositories, and
  Abstract only showed the parent's.
- Do: the Pull Request tab follows the current repository. The parent's lists its
  submodules' pull requests and a submodule's links back; merging the parent while a
  submodule's pull request is still open asks first.
- Done when: a chat with a parent and a submodule pull request shows both, each linking
  to the other.
- Tests: `PullRequestPick` rules; one `gh pr list` per distinct submodule repository.

---

## v0.12.0 — week of 2026-10-12 (cut Friday 2026-10-16)

**Headline:** Codex asks for permission in the app like Claude does. Codex and OpenCode
get their own `/` commands, and any of the three agents can draft an automation.

### R-1200 · Codex asks for permission in the app before running commands or editing files
- Status: planned · Size: L · Label: agents · Theme: Parity · Blocked by: R-1105 (go)
- Why: Codex today runs under a fixed sandbox mode and `buildPermissionResponse` returns
  nil; the user never sees or answers an approval, and "Ask first" policy is a no-op.
- Do: what the spike decided. Approval cards must reuse the Chat permission card. The
  three permission policies must mean the same thing for Codex as for Claude. Mid-run
  policy change should apply if the protocol allows; otherwise show it as "applies to
  the next turn".
- Done when: with "Ask first", Codex pauses on its first command and the chat shows a
  card that can allow or deny it.
- Tests: `CodexProviderTests` over a recorded approval exchange fixture; a
  `SessionEngine` test that a denied approval reaches the process.

### R-1201 · Show Codex's custom prompts and OpenCode's commands in the `/` menu
- Status: planned · Size: M · Label: agents · Theme: Parity
- Why: the `/` menu lists app commands plus the commands Claude reports; Codex and
  OpenCode report none, so their menus are half empty.
- Do: for Codex read `~/.codex/prompts/*.md`; for OpenCode read the project's
  `.opencode/command/` and the user's config. Feed them through the same
  `commands_changed` path the Chat uses. Send the chosen command the way each CLI expects.
- Done when: a Codex prompt file shows in the menu and sending it runs that prompt.
- Tests: `SlashCommandTests` for both discovery paths using temp directories.

### R-1202 · Draft an automation with OpenCode
- Status: planned · Size: S · Label: agents · Theme: Parity
- Why: `AutomationDrafting.swift` limits drafting to Claude and Codex.
- Do: allow OpenCode with the same prompt and JSON contract; fall back to a plain
  "we couldn't read the draft" error rather than a crash if the output isn't parseable.
- Done when: the drafting sheet offers OpenCode and returns a draft in demo mode.
- Tests: a drafting parse test with an OpenCode-shaped response.

### R-1203 · Say in the chat when an agent can't ask for permission
- Status: planned · Size: S · Label: agents · Theme: Parity
- Why: OpenCode's `run` can't prompt, so "Ask first" silently behaves as "Full autonomy"
  or fails. Users should see this, not discover it.
- Do: when a policy isn't supported by the chosen agent, show a one-line notice above the
  composer explaining what will happen instead, with the policy picker showing the
  effective value.
- Done when: starting an OpenCode chat with "Ask first" shows the notice.
- Tests: a capability table test per provider (`ProviderContract`).

---

## v0.13.0 — week of 2026-10-19 (cut Friday 2026-10-23)

**Headline:** A safety net for everything that follows: tests for the app's state
model, screenshots of every screen on every pull request, and coverage for the parts of
the core that had none.

### R-1300 · Add a test target for the app's state model
- Status: planned · Size: M · Label: internal · Theme: Trust
- Why: `project.yml`'s test scheme has no targets; `AppModel` (state and actions) is
  untested. Automated agents will keep changing it.
- Do: an `AbstractTests` unit test target (XCTest or Swift Testing, match the core) with
  `AppModel` driven by a fake executor from `AbstractCore`'s tests. Start with five tests:
  add project, start chat, pin chat, archive, settings round-trip. Add it to `test.yml`.
- Done when: `xcodebuild test -scheme Abstract` runs on CI and is required by
  `require-tested.sh`.
- Touches: `project.yml`, `.github/workflows/test.yml`, new `Tests/AbstractTests/`.

### R-1301 · Attach demo-mode screenshots of every screen to each pull request
- Status: planned · Size: M · Label: internal · Theme: Trust
- Why: `--demo --snapshot <dir>` already captures every screen in both themes, but only
  by hand. UI regressions from agents go unseen until someone opens the app.
- Do: a CI job on PRs that builds Debug, runs the snapshot, and uploads the folder as an
  artifact. Add a comment on the PR linking the artifact. Don't fail the build on pixel
  diffs yet.
- Done when: a PR shows a "Screenshots" artifact with both themes.
- Tests: none beyond the job running green.

### R-1302 · Cover agent start, accounts, CLI arguments and timed runs with tests
- Status: planned · Size: S · Label: internal · Theme: Trust
- Why: `AgentStart`, `AgentAccounts`, `CLIArguments` and `TimedRun` in AbstractCore have
  no tests of their own.
- Do: one test file each, covering the public API and the error paths.
- Done when: each file has a matching test file and the suite still runs under CI's time limit.

### R-1303 · Tell the user when a submodule is checked out somewhere else
- Status: planned · Size: S · Label: fix · Theme: Finish · Blocked by: R-1000
- Why: a detached submodule whose branch lives in another worktree shows no notice in the
  Changes pane; commits then land on a detached HEAD.
- Do: a notice row in Changes for that submodule with a "Check out here" action.
- Done when: the notice appears for a detached submodule and the action puts it on the
  chat's branch.
- Tests: `RepoReview` test with a detached submodule fixture.

---

## v0.14.0 — week of 2026-10-26 (cut Friday 2026-10-30)

**Headline:** The `abstract` command line can now list projects, wait for an agent to
finish, read its last reply, and archive chats, so scripts can drive Abstract end to end.

### R-1400 · `abstract project list` and `abstract session show`
- Status: planned · Size: S · Label: feature · Theme: Reach
- Do: `project list` prints id, name, path and base branch; `session show --session <id>`
  prints the session record, its agent, branch, worktree path and status. JSON like the
  other commands.
- Done when: both commands appear in README's command list and `CLITests` cover them.

### R-1401 · `abstract agent wait` blocks until the agent is idle and prints its last reply
- Status: planned · Size: M · Label: feature · Theme: Reach
- Why: scripts can `send` but have no way to know when the reply is ready without
  tailing logs.
- Do: `agent wait --session <id> [--timeout <s>]` returns `{status, lastMessage,
  waitingFor}` where `waitingFor` is set when the agent is blocked on a permission or a
  question. Works with the app open (through the handover channel) or closed.
- Done when: `create` → `wait` → `send` → `wait` runs in `CLITests` against the demo agent.

### R-1402 · `abstract session archive` and `abstract agent answer`
- Status: planned · Size: S · Label: feature · Theme: Reach · Blocked by: R-1401
- Do: `session archive --session <id>`; `agent answer --session <id> --allow|--deny`
  or `--choice <n>` for a pending permission or question.
- Done when: a permission raised by the demo agent can be answered from the CLI.

### R-1403 · The command line's errors use one set of codes
- Status: planned · Size: S · Label: fix · Theme: Reach
- Why: error `code` values were added command by command.
- Do: an enum of codes documented in README with exit statuses; every failure maps to one.
- Tests: `CLITests` asserts the code for the three common failures (not found, app is
  running the chat, agent missing).

---

## v0.15.0 — week of 2026-11-02 (cut Friday 2026-11-06)

**Headline:** Paired Macs everywhere: a project can default to another Mac, an automation
can run on one, and remote file checks tell the truth.

### R-1500 · Choose a default Mac for a project
- Status: planned · Size: M · Label: feature · Theme: Reach
- Why: Project Settings shows a Device menu locked to "This Mac"
  (`ProjectSettingsView.swift`, around line 259) although the Launcher already starts
  chats on a paired Mac.
- Do: unlock the menu; store the device id on the project (migration v9); the Launcher
  pre-selects it; a missing device falls back to This Mac with a notice.
- Tests: `Store` migration test; Launcher default test.

### R-1501 · Run an automation on a paired Mac
- Status: planned · Size: M · Label: feature · Theme: Reach · Blocked by: R-1500
- Why: automations always run locally; the earlier build had a disabled Device select
  for this and the Swift app never got one.
- Do: a Device picker in the automation form; the scheduler starts the chat through the
  remote channel; a run whose Mac is unreachable is recorded as failed with that reason.
- Tests: scheduler test with a fake remote channel; run history shows the reason.

### R-1502 · Remote file checks return real answers
- Status: planned · Size: S · Label: fix · Theme: Reach
- Why: the remote-Mac executor's `fileExists` always returns false
  (`Abstract/Features/Remote/RemoteWorktree.swift:56`), so every feature that checks a
  file before acting takes the wrong branch on a paired Mac.
- Do: add a `stat`-style request to `RemoteProtocol` and implement it in the executor.
- Tests: `RemoteTests` round trip.

---

## v0.16.0 — week of 2026-11-09 (cut Friday 2026-11-13)

**Headline:** ⌘K finds everything: chats across projects, automations, pull requests
and recent files. Keyboard shortcuts are listed in one place.

### R-1600 · Search chats, automations and pull requests from ⌘K
- Status: planned · Size: M · Label: feature · Theme: Speed
- Why: the palette (`Abstract/Features/Palette`) jumps between projects and starts chats;
  it doesn't know about archived chats, automations or PRs.
- Do: index chat titles across projects (including archived, marked), automations
  ("Run …"), open PRs ("Open PR #…"), and the current worktree's recent files. Keep the
  fuzzy scorer; rank by recency then score.
- Tests: `FuzzyScore` gets its own tests; a palette-index test over a seeded store.

### R-1601 · A keyboard shortcuts sheet
- Status: planned · Size: S · Label: feature · Theme: Speed
- Do: ⌘/ opens a sheet listing every shortcut the app defines, generated from the
  menu definitions so it can't drift. Add it to the Help menu.
- Tests: a test that every menu command with a key equivalent appears in the list.

### R-1602 · Spike: a fourth agent
- Status: spike · Size: S · Label: internal · Theme: Parity
- Question: which CLI is next, and what does its stream look like? Candidates in order:
  Gemini CLI, GitHub Copilot CLI, Amp. Pick the one with a stable JSON stream, resumable
  sessions and a subscription sign-in (never an API key). Record a clean fixture.
- Output: a note in the PR with the stream shape, capability table row (as in the
  Parity theme), and a go/no-go for R-1700.

---

## v0.17.0 — week of 2026-11-16 (cut Friday 2026-11-20)

**Headline:** A fourth agent joins Claude, Codex and OpenCode.

### R-1700 · Add <agent chosen in R-1602> as an agent
- Status: planned · Size: L · Label: agents · Theme: Parity · Blocked by: R-1602 (go)
- Do: one `ProviderDefinition` in `Packages/AbstractCore/Sources/AbstractCore/Providers/`,
  one line in `ProviderRegistry`, a stream parser with a recorded fixture, models
  discovery, per-agent defaults in Settings → Agents, and a row in the capability table
  under R-1203 so unsupported policies are announced.
- Done when: a chat with the new agent runs in the app, its tokens show in Usage, and
  `abstract session create --agent <name>` works.
- Tests: `<Agent>ProviderTests` over the fixture; `ProviderRegistryTests` updated.

### R-1701 · Codex cost estimate in Usage
- Status: planned · Size: S · Label: agents · Theme: Parity
- Why: Codex reports tokens but no cost, so the Usage meter mixes cost for Claude and
  OpenCode with tokens-only for Codex.
- Do: show Codex as tokens only, clearly labelled, rather than a guessed cost. Abstract
  does not carry a price list.
- Done when: the Usage view says "tokens (Codex reports no cost)" for Codex rows.

---

## Later (not scheduled)

Ordered by how likely they are to be pulled forward. Each needs a spike before it is
scheduled.

- **SSH executor.** `ExecutorContract.swift` says an SSH executor "slots in behind"
  `LocalExecutor`. It would let a project live on a Linux box. Large; depends on how
  much of the remote-Mac protocol can be reused.
- **Pull requests across submodules.** Deliberately deferred on 2026-09-25: show
  submodule PRs and warn when the parent's pointer isn't merged. Only a light version,
  and only if asked.
- **Comments on a PR from the Review pane.** Line comments go to the agent today; they
  could also post as review comments through `gh`.
- **Linear beyond attachments.** Create a chat from a Linear issue; move the issue when
  the PR merges.
- **OpenCode approvals.** Blocked on OpenCode's `run` being unable to prompt.
- **First-run guide.** A short walkthrough for a new user: add project, pick agent,
  start a chat, accept a change.

## Not planned

- Calling model APIs, holding model keys, or pricing tables.
- A workflow or pipeline builder that chains agents. Abstract runs agents; it does not
  choreograph them.
- Windows or Linux builds of the app itself (the SSH executor is the path to remote Linux).
- Merging a release branch back into `main`.

## Changing this file

- Add an item under the earliest week where it fits with a new ID (`R-<week><nn>`);
  never renumber.
- When a week is cut, add the version to each shipped item and move the unshipped ones
  down with `moved → vX.Y`.
- Re-plan on Mondays: read what merged since the last tag
  (`gh release view --json tagName`, then the merged PRs) and adjust the next two weeks
  only. Later weeks are direction, not commitment.
