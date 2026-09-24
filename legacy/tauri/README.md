# Abstract

An agentic development environment: run several CLI coding agents in parallel,
each isolated in its own git worktree, then review and merge what they changed.

Abstract drives agents you already pay for as **subscription CLIs** (`claude`,
`codex`), not metered API calls. It never sees your API keys and never talks to
a model itself.

## Status

First slice. Local execution works end to end: projects, chats, live agent
output, diff review with hunk-level accept/reject, worktree management,
settings, and scheduled automations. SSH execution and LAN device pairing are
scaffolded at the interface level but not implemented yet.

## Running it

Requires [bun](https://bun.sh), Rust (via rustup), and `git`.

```bash
bun install
bun tauri dev
```

> On this machine Homebrew's `rustc` (1.86) shadows the rustup toolchain, which
> is too old for Tauri's dependencies. The `tauri` and `rust:test` package
> scripts prepend `~/.cargo/bin` to `PATH` so builds pick up rustup's toolchain.
> Putting `~/.cargo/bin` before `/opt/homebrew/bin` in your shell profile makes
> that workaround unnecessary.

Checks:

```bash
bun run check      # tsc, vitest, cargo test
```

## Architecture

```
src-tauri/          Rust core — "dumb plumbing", knows nothing about any agent
  executor/         trait Executor: spawn a process, stream its lines, run a command
  git/              worktree add/list/remove, unified diff parsing, patch building
  sessions/         process lifecycle, line streaming, JSONL replay
  automations/      RRULE scheduler, run bookkeeping
  commands.rs       the Tauri command surface (also the future remote RPC surface)
src/                React frontend
  providers/        everything agent-specific lives here
  features/         projects, sessions, output, diff, worktrees, automations, settings
```

**The split that matters:** the Rust side receives a `LaunchSpec` (command,
args, cwd, stdin) and hands back raw output lines. All knowledge of what
`claude` or `codex` print lives in a `ProviderDefinition` on the TypeScript
side. Adding a provider is one file in `src/providers/` plus one line in
`registry.ts` — no core changes.

### Agents run headless, not in a terminal

Agents are launched in their JSON streaming modes
(`claude -p --output-format stream-json`, `codex exec --json`) and the output is
parsed into typed events. That is what lets the UI render agent work as a
readable document — prose as markdown, tool calls as one collapsible line,
edits as inline mini-diffs — instead of a scrolling wall of terminal output.

The parsers are tested against JSONL recorded from real runs of both CLIs, in
`src/providers/__fixtures__/`.

### Worktrees

Each chat gets `git worktree add -b <prefix><slug> <path> <base-ref>`, with the
path and branch prefix set by templates in Settings. Worktrees live outside the
repository by default (`~/.abstract/worktrees/<repo>-<hash>/<slug>`).

Nested repositories are detected when a project is added, excluded from diffs,
and — because one nested repo makes a whole-tree `git add -N` fail and would
otherwise hide every new file from review — untracked files are marked
individually when that happens.

### Accepting changes

Review is per file and per hunk. Accepting builds a patch from the selected
hunks and applies it to the project's main working tree with
`git apply --3way`, unstaged, so you commit it however you like. Rejecting
reverse-applies the same patch inside the worktree. Patches, rather than branch
merges, because hunk-level granularity is the point and the same code path will
work over SSH.

### Automations

Scheduled agent runs, modelled on superset.sh's automations: a title, a prompt,
a project (or none), an RRULE schedule with a timezone, an agent, and a
workspace mode. A run is `created` once its workspace exists; whether the
agent's work succeeded is the session's own status.

Two differences from a cloud orchestrator, by necessity: the scheduler runs
inside the app, so closing the window hides Abstract to the tray instead of
quitting, and a fire missed while the app was closed is skipped unless "catch up
on launch" is on. In exchange, firing is exactly-once rather than at-least-once.

## Non-goals

No built-in editor, no cloud sync, no model training. Abstract orchestrates
agents that already exist.
