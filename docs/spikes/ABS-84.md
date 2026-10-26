# ABS-84: a safe plugin boundary for Abstract views and data

**Question.** What is the smallest safe, versioned plugin contract that lets an installable
plugin add a screen to Abstract, read explicitly granted project/chat data, and open existing
chats — and how do the sample plugin (ABS-85) and Kanban (ABS-86) use that same contract?

**Method.** Read the current seams: `Destination`/`DetailView`
(`Abstract/App/AppModel.swift:8-17`, `Abstract/Features/Root/RootView.swift:98-141`), the
sidebar's fixed rows (`Abstract/Features/Sidebar/SidebarView.swift:56-60`), the settings tabs
(`Abstract/Features/Settings/SettingsView.swift:4-45`), `MainTabKind`
(`Packages/AbstractCore/Sources/AbstractCore/Layout/MainTabs.swift:5-18`), the joined
local + paired-Mac snapshot the sidebar already builds (`AppModel.sidebarChats()`,
`Abstract/App/AppModel+Sidebar.swift:8-33`, over `SidebarChats` in
`Packages/AbstractCore/Sources/AbstractCore/Sessions/SidebarChats.swift:69-129`), the store
(`~/Library/Application Support/Abstract/abstract.sqlite`, settings as JSON values,
`Store.swift:42-51,92-119`), signing (`project.yml`: the app is unsandboxed, hardened runtime
only when `scripts/sign-app.sh` signs a release), and the phone app (`mobile/`, a React Native
client of the Mac's encrypted remote protocol; agents and data stay on the Mac). Compared
against Apple's [ExtensionFoundation](https://developer.apple.com/documentation/extensionfoundation/adding-support-for-app-extensions-to-your-app)
(separate-process app extensions, XPC, extension points) and VS Code's
[contribution points](https://code.visualstudio.com/api/references/contribution-points)
(declarative manifest contributions, capability-gated APIs, webviews). No prototype code is kept.

## 1. Decision matrix

Abstract is unsandboxed and spawns agent CLIs and git in arbitrary repositories
(`Abstract/Resources/Abstract.entitlements`). Anything loaded into its process therefore has
the user's full authority — the database, every worktree, a shell. That rules out the classic
in-process bundle/dylib plugin outright: it cannot be made safe, and the hardened runtime would
need library validation switched off to load third-party code at all. The viable designs all
keep plugin code out of the app's process:

| | A. Web package in `WKWebView` (chosen) | B. Native app extension (ExtensionKit/XPC) | C. Helper process returning declarative UI |
|---|---|---|---|
| Package | Folder of HTML/JS/CSS + `manifest.json`; no native code | Signed `.appex` inside a containing app the user installs; discovered by extension point | Signed executable speaking JSON-RPC; host draws a described view tree |
| Isolation | WebKit content process; no file, network or native API unless the host bridges it | Own sandboxed process, system-enforced | Own process, sandboxed if the host launches it with a sandbox profile |
| What a bad plugin can still do | Mislead inside its own rectangle; keep granted snapshot data in its own storage. It cannot exfiltrate (no network), read files, or act on chats | Whatever its entitlements allow outside Abstract; inside, only the XPC contract | Same as B, and it cannot even draw freely |
| Install / remove by Abstract | Yes: copy a validated folder in, delete it out | No: the user installs/removes the containing app; Abstract can only enable/disable what it discovers — which breaks ABS-85's "install and remove it" | Yes, if the helper is a loose executable Abstract manages |
| Developer experience | Any web tooling, instant reload, no Apple account, no signing | Swift only, Xcode, Developer ID + notarisation per plugin, extension-point scaffolding | Any language, but every widget must exist in the host's vocabulary first |
| Look and feel | Host must hand over theme colours/fonts; close but not native | Native SwiftUI, hosted by `EXHostViewController` | Native, limited to the vocabulary |
| Kanban fit | A board is layout over a read-only snapshot — the easy case for web tech | Fine, but the packaging cost lands before the first card | Poor: columns, cards and filter menus mean inventing most of a UI toolkit before Kanban starts |
| Phone path | Same snapshot contract; the phone view itself is compiled in (§6) | No path: phone cannot run Mac extensions | Same contract idea, native renderer per platform |

**Decision: A, for API 1.** It is the only design where Abstract itself can install, enable,
disable and remove a plugin (ABS-85's acceptance), it runs no native third-party code, and the
Kanban use case needs nothing beyond a read-only snapshot, an "open chat" action and its own
saved filters. B stays the documented upgrade path if a future plugin genuinely needs native
UI; it would reuse this note's manifest fields, capabilities and snapshot shape, changing only
the transport. C is not worth building speculatively.

## 2. The package

- **Format.** A folder named `<name>.abstractplugin/` holding `manifest.json` at its root and
  static web assets below it. It may be picked as that folder or as a `.zip` of it. No
  executable files: install rejects entries that are executables, symlinks, or paths escaping
  the folder (`..`, absolute), and rejects a package over 25 MB.
- **Discovery.** Only two places, both scanned at launch for manifests only (no plugin code
  runs): plugins bundled inside `Abstract.app` (`Contents/Resources/Plugins/`) and
  `~/Library/Application Support/Abstract/Plugins/<plugin-id>/<version>/`. A repository,
  worktree or download can never install a plugin by being opened; installing is an explicit
  pick-a-file action in Settings.
- **Install.** Settings → Plugins → Install… validates the manifest, shows §5's review screen,
  then copies the package atomically into the user plugins folder and records a SHA-256 hash
  of the manifest and file list. Bundled plugins install through the same button and loader
  (copied out of the app bundle), so there is one code path. Installed is not enabled: nothing
  runs and no data flows until the person enables it.
- **Signing.** Bundled plugins are covered by the app's existing Developer ID signing and
  notarisation. A third-party package contains no native code, so Gatekeeper has nothing to
  check; API 1 accepts it unsigned *because* §4 leaves it no network, files or actions beyond
  what was granted, and the review screen says in plain words that it is not signed and exactly
  what it can see. If the installed files change after install (hash mismatch), the host
  disables the plugin and asks for a fresh review. Signed third-party distribution (a detached
  signature over the package, a publisher identity) is a follow-up (§8) and a precondition for
  ever downloading plugins from inside the app.

## 3. Manifest and API version

```json
{
  "api": 1,
  "id": "sh.abstract.kanban",
  "name": "Kanban",
  "version": "1.0.0",
  "description": "Shows your chats as a board, by what they need from you.",
  "entry": "index.html",
  "capabilities": ["projects.read", "chats.read", "chats.open", "storage.own"],
  "contributes": {
    "views": [{ "id": "board", "title": "Kanban", "symbol": "rectangle.split.3x1", "location": "main" }]
  }
}
```

- `api` is an integer major version. The first host supports exactly `1` and refuses anything
  else with a plain error. New *fields* may appear inside API 1 (plugins must ignore fields
  they don't know; the host ignores manifest keys it doesn't know); removing or renaming a
  field, or changing a capability's meaning, needs a new major. When API 2 exists, the host
  keeps an API 1 adapter for at least one release cycle, then old plugins show as unsupported
  rather than failing silently.
- `id` is reverse-DNS and permanent; `version` is semver. One installed version per plugin in
  API 1: installing a newer version replaces the older after validation (§5).
- Exactly one view, at the one contribution point API 1 has: a top-level screen (`main`).
  `title` is its sidebar and window name (max 40 characters); `symbol` is an SF Symbol name,
  falling back to `puzzlepiece.extension` when missing or unknown. Palette commands, settings
  sections, chat panes and tabs are not contribution points in API 1 — `MainTabKind` stays
  chat-only, because its tabs belong to a chat and a plugin screen does not.
- Unknown capability strings fail the install (fail closed), so a plugin built for a newer
  host can never be half-granted.

## 4. Trust boundary, capabilities and data

```text
AppModel / Store / agents / git            Abstract host                Plugin (WKWebView)
  projects, sessions, PRs, branches  →   snapshot builder (allowlist)  →   JSON snapshot
  AppModel.open(chatId)              ←   validates every message       ←   { type: "openChat" }
  plugin record + plugin storage     ←→  bridge, capability checks     ←→  storage get/set (own only)
```

The plugin never sees `AppModel`, `Store`, the file system or the network. The host serves the
package's files through a custom `abstract-plugin://<plugin-id>/…` scheme handler (package
files only), denies every `http(s)` navigation and subresource, injects a restrictive CSP
(`default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:`), uses a
non-persistent web data store, and puts the bridge shim in its own content world. All data
crosses as JSON over that bridge, gated by the closed capability list:

| Capability | Grants | Plain words shown at review |
|---|---|---|
| `projects.read` | Project snapshots | "See your projects' names" |
| `chats.read` | Chat snapshots | "See your chats' titles, agents and progress" |
| `chats.open` | The `openChat` action | "Open a chat when you click it" |
| `storage.own` | Its own saved settings | "Remember its own settings on this Mac" |

There is no capability in API 1 for network, files, the clipboard, notifications, running
commands, sending agent messages, or reading transcripts — a plugin that wants one is a new
ticket, not a new string. Theme, locale and the plugin's own id/version are environment, sent
to every plugin without a grant.

**Snapshot fields (the whole allowlist).** Built from the same facts `AppModel.sidebarChats()`
already joins, so local and paired-Mac chats arrive in one list and the host — not each
plugin — derives progress with `SidebarChats.status(of:)`:

- `macs[]`: `id`, `name`, `isThisMac`, `reachable` (a paired Mac appears with
  `reachable: false` and no chats, so "that Mac is offline" is sayable).
- `projects[]` (`projects.read`): `key` (opaque, stable per Mac + project, so same-named
  projects on two Macs stay distinguishable; `null` project means Standalone), `name`,
  `macId`, `archived`.
- `chats[]` (`chats.read`): `id` (the id `openChat` takes, paired-Mac mirror ids included),
  `title`, `projectKey` (or `null`), `agentId`, `branch`, `status` (the session status),
  `progress` (`needsYou | working | readyToReview | done`, host-derived), `pinned`,
  `archived`, `createdAt`, `lastActivityAt`, `hasChanges` (`true | false | null` = not read
  yet), `backgroundTasks` (count), `pullRequest` (`number`, `state`, `isDraft`,
  `checks: passed | failing | running | null`, `changesRequested`) or `null`, `macId`.

Deliberately excluded, even though `Project`/`Session` carry them: folder and worktree paths,
the home directory, prompts and transcript content, provider session ids, permission policies,
models/effort, setup/teardown/run scripts, naming instructions, automations and usage. A new
field needs a reason and (sensitive or not) a capability decision before it joins the list.

**Bridge.** Every message is `{ "api": 1, "type": …, "id": …, "payload": … }`. Host → plugin:
`context` (theme name + palette/font tokens from `ThemePalette`, locale, granted capabilities),
`snapshot` (`revision`, `generatedAt`, and the sections above that were granted), and
`themeChanged`. Plugin → host, each answered or refused by `id`: `getSnapshot`, `openChat
{chatId}`, `storage.get {key}`, `storage.set {key, value}` (JSON values, 512 KB total per
plugin). The host validates every inbound message — known type, capability granted, payload
within size limits, chat id present in the last snapshot — and drops and counts anything else;
a bad message can never throw into `AppModel`. Updates are whole snapshots with a monotonic
`revision`, coalesced by the host (at most a few per second) and sent only while the plugin is
enabled and its view is open; reopening always starts from a fresh snapshot. Whole snapshots
are fine at chat-list scale; deltas are a follow-up if a profile ever says otherwise.

## 5. Settings, permission flow and lifecycle

- **Navigation.** `Destination` gains `.plugin(pluginId, viewId)`. Each enabled plugin adds one
  sidebar row (its `title` + `symbol`) under the built-in rows in `SidebarView`, and
  `DetailView` shows the host view, or the plugin's error/empty state (§7). Disabling or
  removing the plugin removes the row; if its screen was showing, Abstract goes home.
- **Settings.** A new **Plugins** tab lists every installed plugin: name, version, where it
  came from ("With Abstract" or "Installed by you"), enabled switch, its granted capabilities
  in the plain words of §4, and Remove. This is the only new word the user learns — "Plugins" —
  and each screen is known by its own name (Kanban), not as plugin machinery.
- **Grant flow.** Installing or first enabling shows one review: name, version, source,
  signed or not, and the capability list, with **Enable** / **Cancel**. Grants are
  all-or-nothing in API 1 (four read-mostly capabilities do not justify per-item toggles) and
  are never asked for mid-session: a plugin cannot prompt for more from inside its view.
- **Persistence.** The host keeps one settings record (`plugins.v1` in the store's JSON
  settings): per plugin — id, version, source, enabled, granted capabilities, package hash,
  installed date. Plugin storage lives apart from project/session tables, one JSON file per
  plugin under `~/Library/Application Support/Abstract/PluginData/<plugin-id>.json`, written
  only through the bridge. Disable keeps storage; Remove deletes package, record and storage
  after a confirm that names what will be deleted.
- **Updates.** Installing over an installed plugin validates first, then swaps atomically. If
  the new version asks for more capabilities or a newer `api`, it lands **disabled** pending a
  fresh review; otherwise the existing grant carries over. Plugin storage is the plugin's own
  to migrate (it keeps its own schema version inside it); the host never rewrites it. Plugins
  are per-Mac: they are not synced to, or run on, paired Macs — a plugin here sees paired
  Macs' chats only as snapshot rows. There is no in-app download or auto-update in API 1.

## 6. Mac and phone

Plugins run on the Mac only. The phone never downloads, installs or executes a plugin package —
which also keeps it clear of store rules about downloaded code. A first-party plugin can still
have a phone counterpart, as *compiled-in* code: the mobile app may ship a screen registered
under the plugin's id (e.g. `sh.abstract.kanban`), reviewed and released with the app itself.
It needs no plugin machinery on the phone, because the phone is already a trusted, paired
client receiving projects and chats in `RemoteSnapshot` (`RemoteProtocol.swift:161-211`); the
screen projects the same §4 fields (adding the host-derived `progress`, `hasChanges` and
pull-request facts the snapshot increasingly carries) and opens chats through the phone's
existing navigation. Third-party plugins simply have no phone screen, and Mac Settings says
so: "Plugins run on this Mac. They don't run on your phone." Enabling a plugin on the Mac does
not change what the phone can see.

## 7. Failure behaviour

No plugin failure may stop Abstract opening, lose a chat, or leave a blank screen unexplained.
Launch never waits on a plugin: discovery reads manifests only, and a broken one is listed in
Settings with its error while the rest of the app starts.

| Failure | What the person sees | Host behaviour |
|---|---|---|
| Bad JSON, missing `entry`, oversize, escaping paths | "This plugin isn't a valid Abstract plugin." at install | Nothing copied in |
| `api` newer/older than supported, unknown capability | "Kanban 2.0 needs a newer version of Abstract." | Installed record kept, plugin stays disabled |
| Package files changed since install (hash mismatch) | "Kanban changed since you installed it, so it's off." + Review | Disabled until re-reviewed |
| Package or storage file missing/corrupt at launch | Listed in Settings with the problem; its row is gone from the sidebar | Treated as disabled; storage reset only on explicit Remove/reinstall |
| Web content process exits, page throws, bridge floods or sends oversize/unknown messages | Its screen shows "Kanban stopped working." with **Reload** and **Turn Off** | Web view torn down; one manual reload path, no retry loop; other plugins and chats unaffected |
| `openChat` for an unknown or deleted chat | Nothing (the click is refused and the next snapshot corrects the board) | Refused by validation, counted in the plugin's settings row ("last error") |
| Snapshot cannot be built | The same "stopped working" screen | Logged as a host error, not blamed on the plugin |

## 8. The sample and Kanban on this contract — and what is *not* in the first host

**Sample (ABS-85).** A bundled "Chat count" plugin: capabilities `chats.read`, `chats.open`,
`storage.own`; shows counts per `progress` group and a title list in both themes, opens a chat
on click, and remembers one toggle. It proves install → review → enable → open → disable →
remove, persistence across relaunch, and every §7 row, without Kanban's board logic in the way.

**Kanban (ABS-86).** Needs nothing beyond the sample's contract plus `projects.read`:

| Kanban need | Contract source |
|---|---|
| Four columns (Needs you / Working / Ready to review / Done) | Host-derived `progress`; pinned stays in its column via `pinned`, archived hidden via `archived` |
| Card: title, project, agent, last activity, PR number + checks/review | `title`, project `name` by `projectKey`, `agentId`, `lastActivityAt`, `pullRequest.*` |
| Project multi-select, Standalone, same-named projects on different Macs | `projects[]` `key` (per-Mac) + `macId`; `projectKey: null` = Standalone |
| Agent and Mac filters, title/branch/PR search | `agentId`, `macId`, `title`, `branch`, `pullRequest.number` — all client-side over the snapshot |
| Filters remembered apart from the sidebar, across relaunch | `storage.own` |
| Click a card → the right chat, local or paired | `openChat` with the snapshot `id`, landing in `AppModel.open` |
| Live moves between columns; offline paired Mac | Pushed `snapshot` revisions; `macs[].reachable` |

Kanban imports neither `AppModel` nor `Store`; its board projection and filters are pure
functions over the snapshot, testable outside the app.

**Follow-ups, to file in Triage (not in ABS-85):** signed third-party packages and a publisher
identity (precondition for any in-app downloading); a `network` capability with a host-checked
domain allowlist; further contribution points (palette commands, a chat side pane); snapshot
deltas if profiling needs them; the compiled-in phone Kanban screen (§6); a native
ExtensionKit tier reusing this contract if a plugin ever needs native UI.

**Acceptance examples for the host ticket (ABS-85).** (1) Install the sample from Settings,
read its three capabilities in plain words, enable it, see its sidebar row, open it, click a
chat and land in that chat. (2) Relaunch: still installed, still enabled, its saved toggle
kept. (3) Disable: row gone, no snapshots sent; remove: package and storage gone. (4) A
package with `"api": 99`, an unknown capability, and a missing `entry` are each refused with a
sentence, and Abstract opens normally with each left in the plugins folder. (5) A plugin whose
script throws, floods the bridge, and asks to open a made-up chat id shows "stopped working"
and nothing else in the app changes. (6) Editing an installed plugin's files turns it off
until re-reviewed. (7) A plugin granted only `chats.read` receives no projects section and its
`openChat` is refused. (8) No field outside §4's allowlist appears in any snapshot (asserted
by a contract test over the builder). (9) The sample renders in Graphite, Paper and Ink from
the `context` tokens. (10) The phone is unchanged: plugins neither appear nor run there.

## Go or no-go

**Go** — with design A. API 1 is a versioned `manifest.json` + static web package, installed
and removed by Abstract itself, contributing one top-level screen, running in a locked-down
`WKWebView` with no network or file access, fed only the §4 allowlisted snapshot under
explicit grants, and able to act only by opening chats. ABS-85 can build the host and sample
against §§2–7 as written, ABS-86 needs no contract change, and the phone path (§6) keeps
downloaded code off iOS/Android entirely. **No-go** for in-process native plugins at any
point, and no-go for building the ExtensionKit tier now: it cannot be installed or removed by
Abstract, which is the first host's whole point.
