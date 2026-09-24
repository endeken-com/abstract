# Third-party notices

## Paseo

Parts of Abstract are adapted from [Paseo](https://github.com/getpaseo/paseo),
Copyright (c) 2025-present Mohamed Boudra, licensed under the Apache License,
Version 2.0 (full text in `Licenses/Paseo-LICENSE.txt`). The TypeScript
originals were rewritten in Swift; files carrying ported logic say so in a
comment:

- `Packages/AbstractCore/Sources/AbstractCore/Sessions/MarkdownBlocks.swift`: splitting replies into Markdown blocks.
- `Packages/AbstractCore/Sources/AbstractCore/Git/DiffCompare.swift`: review comparison modes, base resolution, discard.
- `Abstract/App/ChatFeed.swift`, `Abstract/Features/Chat/TranscriptList.swift`: head/tail stream and the virtualized transcript.
- `Abstract/Features/Chat/ConversationView.swift`, `ToolCallViews.swift`, `StreamReveal.swift`: row spacing, running shimmer, loader, reveal pacing.
- `Abstract/Features/Diff/DiffView.swift`, `DiffReview.swift`, `DiffFilePane.swift`, `ChangesTree.swift`, `WorktreeWatcher.swift`, `Abstract/Features/Review/LineComments.swift`: the review panel and review attachment format.
- `Packages/AbstractCore/Sources/AbstractCore/Layout/MainTabs.swift`, `Abstract/Features/Workspace/MainTabBar.swift`: main-pane tabs.
- `Packages/AbstractCore/Sources/AbstractCore/Git/GitActions.swift`, `Abstract/Features/Workspace/WorkspaceActions.swift`, `ExternalEditors.swift`: the git actions and open-in-editor buttons.
- `Abstract/Features/Editor/EditorDocument.swift`, `CodeTextView.swift`, `CodeEditorView.swift`: the file editor (autosave, conflicts on disk, its bar); One Dark / One Light syntax colours.

## Textual

`Packages/Textual` is [Textual](https://github.com/gonzalezreal/textual) 0.5.0,
Copyright (c) 2024 Guille Gonzalez, under the MIT License (`Packages/Textual/LICENSE`),
vendored with one change: `StructuredText` parses its markup while drawing
instead of after its first frame.

## Agent logos

The Ollama and LM Studio marks (`Abstract/Resources/Assets.xcassets/ProviderOllama`, `ProviderLMStudio`) are the
projects' own logos, used to name them where they appear as agents. The vector files come from
[Simple Icons](https://simpleicons.org) (Ollama, CC0-1.0) and [LobeHub Icons](https://github.com/lobehub/lobe-icons)
(LM Studio, MIT). The marks remain trademarks of their owners.

## Octicons

The pull-request marks and git action icons (`Abstract/Components/Octicon.swift`) and the GitHub issue
mark (`BrandGlyph.issue`) are [Primer Octicons](https://primer.style/octicons/) 19.38.0,
Copyright (c) GitHub Inc., under the MIT License (`Licenses/Octicons-LICENSE.txt`).
