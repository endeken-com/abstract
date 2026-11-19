# Native buttons

Use the shared styles in `Abstract/Components/Buttons.swift` for actions in SwiftUI views. Their colors come from the semantic palette, so the same roles work in Graphite, Paper, Ink, and installed themes.

| Role | Use | Resting appearance |
| --- | --- | --- |
| `.btPrimary` | The main action in a view or decision | Solid accent fill |
| `.btSecondary` | A regular action, including menu triggers such as Merge | Raised fill with a hairline border |
| `.btGhost` | Quiet supporting actions | Text only |
| `.btDanger` | Destructive or closing actions | Removed-color text |
| `.icon` | Icon-only controls with a `.help(...)` label | Icon only; selection wash when active |

All roles use flat fills. Hover and press add a palette wash; disabled controls dim, and press motion respects Reduce Motion. The text styles have small (24 pt), regular (28 pt), and large (34 pt) heights. Use `.bt(.secondary, size: .small)` when a compact action sits beside other controls.

Use an existing Octicon for GitHub concepts. In particular, Merge uses `Octicon.gitMerge` in both the pull request menu and the other merge surfaces.
