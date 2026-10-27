# App icon

Abstract's icon is a folded white ribbon — a hexagonal loop — on black. The same
art serves both appearances, in `Brand/` at full size:

| File | Version | Shown |
|---|---|---|
| `Brand/horizonte-dark.png` | Folded white ribbon on black | Dark appearance; Android |
| `Brand/horizonte-light.png` | Same art | Light appearance |

Everything else is made from those two by `scripts/make-icons.sh`. Change the art in
`Brand/`, run the script, and commit what it writes. `scripts/make-icons.sh --check`,
which CI runs, fails if an icon is missing or the wrong size.

- **Mac:** `AppIcon.icon`, an Icon Composer document holding the 1024 px masters for
  both appearances (the same art). macOS 26 shapes and sizes it. For older macOS, and
  for the `AppIcon.icns` the DMG wears, Xcode flattens the default appearance.
- **iPhone:** `mobile/assets/icon-light.png` and `icon-dark.png`, named in
  `mobile/app.config.js`. The checked-in iOS project carries the same two images
  (`mobile/ios/Abstract/Images.xcassets/AppIcon.appiconset`).
- **Android:** an adaptive icon with the art as its background layer and an empty
  foreground (`icon-clear.png`), and `icon-arc.png`, the bright part alone, for themed icons.

Provider logos (`ProviderClaude`, `ProviderOpenAI`, `ProviderCodex`) come from
the MIT-licensed `@lobehub/icons-static-svg` package. The marks themselves
belong to Anthropic and OpenAI and are used only to label their agents.

# Branches and worktrees

A chat has both a git branch and a worktree folder, usually with different
names, so each idea keeps one icon:

| Idea | Icon | Where |
|---|---|---|
| Branch | GitHub's `git-branch` Octicon (`Octicon.gitBranch`) | the branch line above the reply box, the Branch row in the sidebar's hover card, anywhere else a branch name is shown |
| Worktree | SF Symbol `arrow.triangle.branch` | the sidebar's Worktrees item, Settings, the ⌘K palette, the "No worktree yet" screens, abandoned worktrees in the Worktrees list |

The phone follows the same rule. A branch draws the same Octicon path
(`BranchIcon` in `mobile/src/PullRequestIcon.tsx`): the pill above the reply
box when the chat has a branch, the project's chat rows, and the pull request
screen. A worktree uses `arrow.triangle.branch` on iOS and `account_tree` on
Android, both on that pill when there's no branch and on the sidebar's
Worktrees entry.

The other git marks (pull request, merge, commit, pull, push) are Octicons too,
in `Components/Octicon.swift`, from Primer Octicons (MIT).
