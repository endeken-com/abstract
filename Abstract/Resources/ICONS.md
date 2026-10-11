# App icon

`Assets.xcassets/AppIcon.appiconset` is an empty placeholder. Drop Abstract's
own icon PNGs into it (16–512 pt at 1x and 2x), or replace the whole set from
the provided 1024px PNG in Xcode.

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

The other git marks (pull request, merge, commit, pull, push) are Octicons too,
in `Components/Octicon.swift`, from Primer Octicons (MIT).
