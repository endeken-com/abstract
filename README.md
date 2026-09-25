# Abstract

A native macOS app for running several CLI coding agents in parallel, each in
its own git worktree, then reviewing and merging what they changed.

Abstract drives agents you already pay for as **subscription CLIs**
(`claude`, `codex`), never metered API calls. It never sees your keys and never
talks to a model itself.

## Build and run

Requires macOS 15+, Xcode 26, and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`).

```bash
xcodegen generate
open Abstract.xcodeproj
```

Or from the command line:

```bash
xcodebuild -project Abstract.xcodeproj -scheme Abstract -configuration Debug -derivedDataPath build/dd build
open build/dd/Build/Products/Debug/Abstract.app
```

Core tests (fast, no Xcode project needed):

```bash
cd Packages/AbstractCore && swift test
```

Opt-in test against the real `claude` CLI (needs a signed-in subscription):

```bash
cd Packages/AbstractCore && ABSTRACT_E2E=1 swift test --filter RealAgent
```

### Releases

Download the latest signed build from
[Releases](https://github.com/endeken-com/abstract/releases/latest). Abstract updates
itself from then on: Settings → General → Updates, where you can also switch to nightly
builds. Coming from 0.8.x or earlier? Download 0.9.0 once by hand; those builds had no updater.

Releases are cut on purpose rather than on every merge; [AGENTS.md](AGENTS.md) explains
cutting and patching them. `scripts/package-dmg.sh` builds a DMG locally (a dev build,
version 0.0.0, signed ad hoc).

### Command line

`abstract` creates and drives chats from scripts and automations, with the app open
or closed; they show in Abstract like any other chat. It ships inside the app:
Settings → General → Command line → Install links `/usr/local/bin/abstract` to it.

```bash
abstract session list --project <id|path|name> [--include-archived]
abstract session create --project <p> --name <n> --branch <b> --agent claude --prompt-file <path|->
abstract agent find --session <id>
abstract agent send --session <id> --agent <agent id> --text-file <path|->
abstract agent respawn --session <id> --agent claude --prompt-file <path|->
```

Every command prints one JSON value on stdout; a failure prints `{"code","message"}` and
exits non-zero. `session create` fetches the project's base branch from `origin` first and
runs the project's setup script before the agent starts, as the app does. A chat open in the app is locked to `abstract`, and a chat `abstract`
drives is read-only in the app until its agent stops. See `CommandLineTool.swift`.

### Demo mode

`Abstract.app/Contents/MacOS/Abstract --demo` seeds throwaway repositories
and runs a scripted stand-in agent that speaks Claude's real stream format and
edits real files, so every screen can be exercised without spending tokens.
Add `--snapshot <dir>` to capture every screen in both themes and quit.

## Layout

```
project.yml                 XcodeGen spec (the .xcodeproj is generated)
Abstract/                   SwiftUI app
  App/                      AppModel (state + actions), scheduler, notifications, menus
  Theme/                    Graphite (dark gray) and Paper (white) palettes, type scale
  Components/               buttons, status, provider logos, surfaces
  Features/                 sidebar, home, chat, diff, worktrees, automations, settings, palette
  Demo/                     demo mode and screenshot capture
Packages/AbstractCore/      everything that isn't UI, with its own tests
  Providers/                claude + codex definitions and stream parsers
  Process/                  Executor protocol + LocalExecutor (posix_spawn, login-shell PATH)
  Git/                      worktrees, unified diff parsing, partial patches
  Sessions/                 SessionEngine (spawn, stream, log, replay), Timeline, Workspace
  Store/                    SQLite via GRDB
  Automations/              RRULE evaluation
legacy/tauri/               the earlier Tauri build, kept for reference
```

**Adding an agent** is one type conforming to `ProviderDefinition` plus one
line in `ProviderRegistry`. Nothing else names a provider.

**Accepting changes** applies the selected hunks to the project's main working
tree with `git apply --3way`, unstaged. Rejecting reverse-applies them inside
the agent's worktree.

**Automations** follow superset.sh's model. The scheduler runs inside the app,
so closing the window keeps Abstract running; a fire missed while it was quit
is skipped unless "catch up on launch" is on.
