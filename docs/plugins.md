# Plugins: theme and design kit

How a plugin's screen looks like part of Abstract. The plugin boundary itself (package,
manifest, capabilities, bridge) is in [spikes/ABS-84.md](spikes/ABS-84.md).

## Theme

A plugin draws in the theme picked in Abstract (Settings › Appearance): **Graphite**,
**Paper** or **Ink**, or whichever of them **Match System** resolves to. A named theme
holds whatever the Mac is set to, so Graphite stays dark on a Mac set to Light.

The host gives the page its colours before any of the page's own CSS loads, in a script
that runs at document start, so the first frame is already in the theme. It sets, on
`<html>`:

| What | Example |
|---|---|
| `--abstract-<role>` for every palette role (`canvas`, `surface`, `surfaceRaised`, `inset`, `hover`, `selection`, `field`, `fieldBorder`, `fieldBorderFocused`, `border`, `borderStrong`, `text`, `prose`, `textSecondary`, `textTertiary`, `accent`, `onAccent`, `added`, `removed`, `attention`, `addedWash`, `removedWash`, the `pullRequest*` colours, and more) | `--abstract-canvas: #1e1e21` |
| `--abstract-font` | the system UI font |
| `color-scheme` | `dark` or `light`, so scrollbars and form controls match |
| `background-color` | the canvas, so nothing white shows behind the page |
| `data-abstract-theme` | `graphite`, `paper` or `ink` |

When the theme changes, the same values are set again (no reload), and the plugin hears
`themeChanged` with the new `context`. The `context` message carries `theme`,
`colorScheme` and `tokens` too.

## The kit

Every plugin can use Abstract's own components. Link them from the host's scheme; the
`/_abstract/` path is reserved, and a package can't replace it:

```html
<link rel="stylesheet" href="/_abstract/abstract-ui.css">
<script src="/_abstract/abstract-ui.js"></script>
```

`abstract-ui.css` names the host's colours for components (`--ab-canvas`, `--ab-text`,
`--ab-text-2`, `--ab-text-3`, `--ab-border`, `--ab-hover`, `--ab-selection`, …) and adds
Abstract's type scale (`--ab-text-xs` 11px to `--ab-text-xl` 20px, 13px for UI), spacing
(`--ab-space-xxs` 2px to `--ab-space-xxl` 32px), radii and motion. Use those names and
no colours of your own: then your plugin is right in every theme. Motion stops when the
Mac asks for reduced motion.

`abstract-ui.js` is `window.AbstractUI`: `h(tag, props, …children)` to build elements,
`tabs({ tabs, selected, style, onSelect })` for a tab strip with arrow keys,
`empty(title, message, action)`, `skeleton(rows)`, `popover(anchor, build)`,
`flip(container, render)` to slide items to their new place after a redraw,
`isTyping(event)` and `reveal(element)`.

Each component below is drawn in Graphite, Paper and Ink.

### Page and header

`.ab-page` is a full-height column; `.ab-header` a 48px bar with a hairline below
(`.ab-header-title` for the title and a quiet count, `.ab-spacer` to push the rest right);
`.ab-toolbar` a row of filters under it; `.ab-content` the padded body;
`.ab-section-title` a small heading. The bundled plugins show these in use.

### Buttons

`.ab-button`, with `.ab-primary` (one per view), `.ab-ghost`, `.ab-danger`, `.ab-small`
and `.ab-picked`. `.ab-buttons` lays several out. `.ab-kbd` shows a key.

![Buttons](images/plugin-kit/buttons.png)

### Inputs and search

`.ab-input` for text, `.ab-field` for a label above it, and `.ab-search` wrapping an
`<input type="search">` (with an optional `.ab-kbd` hint that hides while typing).

![Inputs and search](images/plugin-kit/inputs.png)

### Tabs and segmented controls

`.ab-tabs` holds `.ab-tab` buttons with `role="tab"` and `aria-selected`. Add
`.ab-segmented` for a compact switch in a header, or `.ab-underline` for a page's own
views. An `.ab-count` inside a tab shows a number. `AbstractUI.tabs()` builds either and
wires the arrow keys.

![Tabs](images/plugin-kit/tabs.png)

### Lists and rows

`.ab-list` of `.ab-row`: add `.ab-interactive` for a hover wash, `.ab-selected` (or
`aria-selected="true"`) for the selected one. `.ab-row-title` truncates; `.ab-row-meta`
sits quietly on the right. `.ab-group-header` is a sticky header for a group of rows.
Keyboard focus shows a ring everywhere (`:focus-visible`).

![Rows: default, hovered, selected, focused](images/plugin-kit/rows.png)

### Chips (filters)

`.ab-chip` is a dashed filter chip; `.ab-active` or `aria-pressed="true"` when it filters,
with `.ab-chip-value` for what it's set to.

![Chips](images/plugin-kit/chips.png)

### Status and badges

`.ab-status` is the sidebar's diamond, with `.ab-needsYou`, `.ab-working` (it breathes),
`.ab-readyToReview` and `.ab-done`. `.ab-badge` is a small label: `.ab-pr-open`,
`.ab-pr-draft`, `.ab-pr-merged`, `.ab-pr-closed` for pull requests; `.ab-passed`,
`.ab-failing`, `.ab-running` for checks (with an `.ab-glyph` dot); `.ab-outline` for a
plain one.

![Status and badges](images/plugin-kit/badges.png)

### Cards

`.ab-card`, with `.ab-interactive` and `.ab-selected` as for rows.

![Cards](images/plugin-kit/cards.png)

### Choices

`.ab-choice` is a radio or checkbox drawn as a card, with `.ab-choice-text` for its title
and a line below.

![Choices](images/plugin-kit/choices.png)

### Menus

`.ab-popover` (opened with `AbstractUI.popover()`) holds `.ab-menu-item`s; a
`role="menuitemcheckbox"` item with an `.ab-check` shows a tick when `aria-checked="true"`.

![Menu](images/plugin-kit/menu.png)

### Notices

`.ab-notice`, and `.ab-error` for something that went wrong.

![Notices](images/plugin-kit/notices.png)

### Empty states

`AbstractUI.empty(title, message)`: say what will appear here, and how.

![Empty state](images/plugin-kit/empty.png)

### Loading

`AbstractUI.skeleton(rows)` until the first snapshot or reply arrives.

![Skeleton](images/plugin-kit/skeleton.png)

## The bundled plugins

Each in Graphite, Paper and Ink, from the demo (`--demo --snapshot`), with the Mac set to
Light.

**Kanban** — Board, List and Mine (what needs your answer or your review), remembered.
J/K or the arrows move, H/L cross columns or groups, Enter opens, / searches, 1–3 switch tabs.

![Kanban: Board](images/plugins/kanban-board.png)
![Kanban: List](images/plugins/kanban-list.png)
![Kanban: Mine](images/plugins/kanban-mine.png)

**Approvals** — Waiting and Answered.

![Approvals](images/plugins/approvals.png)

**Chat count** and **Chat panel**, the samples.

![Chat count](images/plugins/chat-count.png)
![Chat panel](images/plugins/chat-panel.png)

Tabs beside a chat, from the side panel's + menu: **Follow PR** (Following and History),
**Second opinion**, **Lessons** and **Chat panel**.

![Follow PR](images/plugins/panel-follow-pr.png)
![Second opinion](images/plugins/panel-second-opinion.png)
![Lessons](images/plugins/panel-lessons.png)
![Chat panel](images/plugins/panel-chat-panel.png)

## Statuses after links

A plugin can put a short status after links in chats (ABS-126). It lists
`linkDecorators` in `contributes`, each with the links it knows as `patterns`, and
needs a background script to answer:

```json
"linkDecorators": [
  { "id": "github", "title": "GitHub", "patterns": ["https://github.com/*/*/pull/*"] }
]
```

A pattern is `https://`, an exact host, then path segments, where `*` is any one
segment. A link matches when its path starts with those segments. The script is handed
the link alone, cut to the pattern's segments, with no query or fragment, and never the
chat or the message. The review screen names the sites the patterns cover.

```js
AbstractPlugin.links.decorate("github", async (url) => ({ label: "Merged", tone: "merged" }));
```

Return `{ label, tone }` or `null` for nothing to show. The label is one line of up to
40 characters; the tone is `open`, `draft`, `merged`, `closed`, `failing` or `neutral`,
and Abstract picks the colour. A link is asked about once its message has finished
arriving and while it's on screen, and again when its status is more than four and a
half minutes old, so a change shows within five minutes. A failed lookup keeps the last
status. Clicking the status opens the link.

**Link status**, bundled, does this for GitHub pull requests (open, draft, merged or
closed, with checks) and issues, and Linear issues (state and assignee). Private
repositories need a GitHub token and Linear needs a Linear API key, entered under
Settings › Plugins.

![Link status](images/plugins/link-status.png)

## Command-line tools

A plugin can run one command-line tool with the `cli` capability (ABS-139). Its
manifest names the binary, how to install it, and the exact subcommands it may run, each
marked `read` or `write`. It needs `"api": 2` and a background script to call it from:

```json
"capabilities": ["cli", "projects.read", "chats.read"],
"cli": {
  "binary": "gh",
  "install": "brew install gh",
  "commands": [
    { "args": ["auth", "status"], "access": "read" },
    { "args": ["pr", "list"], "access": "read" },
    { "args": ["pr", "merge"], "access": "write" }
  ]
}
```

`binary` is a plain program name found on the login shell's PATH; shells, interpreters,
`git` and the like are refused. `commands` lists up to 32 subcommands of up to four
lowercase words each, with no flags. A run's arguments must start with one of them;
what follows is the plugin's own (flags, values, a pull request body). Abstract runs the
binary directly, never through a shell.

```js
const out = await AbstractPlugin.cli.run(["pr", "list", "--json", "number,title"], { projectKey });
// out = { code, ok, stdout, stderr, truncated }
```

Name where it runs with `{ chatId }` (the chat's worktree) or `{ projectKey }` (the
project's folder), from the plugin's snapshot or from a code host call; with neither it
runs outside any folder on this Mac. A path is never accepted. The command runs on the
Mac the chat or project lives on, so paired Macs work. Reads go through the app-wide
git budget (at most four at a time, one per folder, 30 seconds each). Writes ask first,
showing the whole command, until the person picks Always Allow; they're stopped after
two minutes. `run` throws when the command can't run, with `error.missing` and
`error.install` set when the tool isn't installed. Output past 4 MB is cut, with
`truncated` set.

The review screen lists the binary and every command. An update that adds a command, or
makes a read a write, is reviewed again.

## Code hosts

A plugin can be the code host for projects whose `origin` is on its hosts (ABS-139).
Abstract keeps every pull request screen and asks the code host for what they show.
It declares `contributes.codeHost` and answers from its background script:

```json
"codeHost": {
  "title": "GitHub",
  "hosts": ["github.com"],
  "operations": ["access", "listPullRequests", "pullRequest", "create", "merge", "markReady",
                 "close", "reviewThreads", "rerunFailed", "updateBranch", "pushAccess",
                 "searchIssuesAndPullRequests"]
}
```

```js
AbstractPlugin.codeHost.handle("pullRequest", async (input, { projectKey, chatId, remote, callId }) => {
  const out = await AbstractPlugin.cli.run(["pr", "view", input.branch, "--json", "..."], { projectKey, callId });
  return { pullRequest: toAbstract(JSON.parse(out.stdout)) };
});
AbstractPlugin.codeHost.setHosts(["github.example.com"]); // Enterprise hosts it is signed in to
```

`access`, `listPullRequests` and `pullRequest` are required. Each answer is an object:

| Operation | Input | Answer |
|---|---|---|
| `access` | | `{ access: "ready" \| "missing" \| "signedOut", viewer?, install?, hint? }` |
| `listPullRequests` | `{ state: "all" \| "open", limit }` | `{ pullRequests: [PullRequest] }` |
| `pullRequest` | `{ number }` or `{ branch }` | `{ pullRequest: PullRequest \| null }` |
| `create` | `{ branch, base?, title, body, draft }` | `{ pullRequest }` |
| `merge` | `{ number, method: "squash" \| "merge" \| "rebase", deleteBranch }` | `{}` |
| `markReady`, `close`, `rerunFailed`, `updateBranch` | `{ number }` | `{}` |
| `reviewThreads` | `{ number }` | `{ threads: [ReviewThread] }` |
| `pushAccess` | `{ slug }` | `{ access: "push" \| "readOnly" \| "unknown" }` |
| `searchIssuesAndPullRequests` | `{ query, kind: "issue" \| "pullRequest", limit }` | `{ items: [Item] }` |

A `PullRequest` is `{ number, title, state: "open" | "closed" | "merged", isDraft, url,
head, base, author, reviewDecision: "approved" | "changesRequested" | "reviewRequired",
mergeable, mergeState, additions, deletions, changedFiles, createdAt, updatedAt, body,
mergeCommit, checks: [{ name, workflow, outcome: "pending" | "passed" | "failed" |
"skipped", url }], reviews: [{ author, verdict, body, submittedAt, association }],
comments: [{ author, body, createdAt, isBot, association }], threads }`. A
`ReviewThread` is `{ id, path, line, originalLine, isResolved, isOutdated, diffHunk,
commit, comments: [{ id, author, avatar, body, createdAt, url, association }] }`. An
`Item` is `{ number, title, url, state, body, isPullRequest, isDraft, base, head }`.
Dates are ISO 8601. Throw to fail an operation; its message is shown.

Core only asks for `create`, `merge`, `markReady`, `close`, `rerunFailed` and
`updateBranch` when the person clicked for them, so up to two write commands run with
that call's `callId` don't ask again. Reads have 45 seconds to answer, writes 150.
Core commits and pushes before `create`: plain git stays in Abstract.

**GitHub**, bundled, installed and on by default, is the code host for `github.com` and
the GitHub Enterprise hosts `gh` is signed in to. It answers every operation through the
GitHub CLI (`brew install gh`, then `gh auth login`) and keeps no token of its own. Its
page under Settings › Plugins says whether `gh` is installed and signed in. Turned off,
Abstract makes no `gh` calls, and the pull request screens say a code host plugin is
needed; turning it off or removing it sticks. Its logic is plain JavaScript in
`background.js` (`GitHubHost`), tested in `GitHubPluginTests` against recorded `gh` output.

## Issue trackers

A plugin can answer the composer's issue search for a tracker (ABS-141). It declares
`issueTracker` in `contributes` and answers in its background script:

```json
"issueTracker": {
  "title": "Linear",
  "icon": "icon.svg",
  "keyExample": "ENG-123",
  "keyPattern": "[A-Za-z][A-Za-z0-9]*-[0-9]+"
}
```

The icon is an SVG or PNG in the package, drawn in the text colour. A query that is
one key, whole, or an `https://` link is asked for as one issue; anything else is
searched for. Abstract asks every tracker that's on and groups what they find by
tracker.

```js
AbstractPlugin.issueTracker.handle(async (operation, input) => {
  switch (operation) {
    case "access": return { ready: true, account: "Ada" };    // or { ready: false, problem: "…" }
    case "searchIssues": return { issues: [] };                // input: { query, project? }
    case "issue": return { issue: null };                       // input: { reference }, a key or a link
    case "listProjects": return { projects: [] };               // { id, name, kind: "team" | "project", key? }
  }
});
```

An issue is `{ key, title, url, state?, assignee?, excerpt? }`, with an `https` link
and the start of its description as `excerpt`. The plugin is handed only what was typed
in the search. Abstract draws the results and the chip, and writes the line the agent
reads, `<Tracker> Issue KEY: title`, so every tracker reads the same.

**Linear**, bundled, does this one of two ways, picked on its settings page: a personal
Linear API key entered under Settings › Plugins and sent only to api.linear.app, or the
[Linear CLI](https://github.com/schpet/linear-cli) signed in on the Mac, through `cli`
with read commands only (`auth whoami`, `auth list`, `issue query`, `issue view`,
`team list`, `project list`) in the workspace picked there. Abstract never reads the
CLI's token. Both give the same results. It's turned on by itself when Abstract
finds a Linear key from before it was a plugin, or the CLI signed in.

## Previewing a plugin

`python3 docs/plugin-kit/preview.py` serves the bundled plugins, the kit and a stand-in
for the host at <http://localhost:8765/>, with made-up chats. Add `?theme=paper` or
`?theme=ink`; `?place=chatPanel&chat=c6` opens a page as a tab beside a chat. The kit's
gallery is at `/__preview/gallery.html`; the screenshots above are of it.
`docs/plugin-kit/tokens.js` holds the host's colours for each theme, and the core tests
check it against the palette.
