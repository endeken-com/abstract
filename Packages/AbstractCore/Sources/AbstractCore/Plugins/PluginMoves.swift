import Foundation

/// The first-party plugins that left the app for their own repositories
/// (ABS-190): `endeken-com/abstract-plugin-<slug>`, each listed in the
/// registry as `endeken-com/<slug>`. The app no longer ships them; an
/// existing install keeps working as a git source pinned to the commit its
/// files were extracted at.
public enum MovedPlugins {
    public struct Move: Sendable, Hashable {
        public var pluginId: String
        public var slug: String
        /// The extracted repository's commit the registry first approved.
        public var commit: String
        /// The package's hash at that commit: the bundled copy's, unchanged.
        public var packageHash: String

        public init(pluginId: String, slug: String, commit: String, packageHash: String) {
            self.pluginId = pluginId; self.slug = slug; self.commit = commit; self.packageHash = packageHash
        }

        public var listing: String { "endeken-com/\(slug)" }

        /// Where it lives now, pinned to the extracted commit.
        public var source: PluginGitSource {
            PluginGitSource(owner: "endeken-com", repo: "abstract-plugin-\(slug)", commit: commit, listing: listing)
        }
    }

    public static let all: [Move] = [
        .init(pluginId: "sh.abstract.approvals", slug: "approvals", commit: "d8ea0151ca9cf9fc1f3a3e3a43766f532263b191",
              packageHash: "983038735aa69fd19dfede8c17c6b37f50035ae86beac8d7b5f62ad0c8445bb2"),
        .init(pluginId: "sh.abstract.bitbucket", slug: "bitbucket", commit: "5da7c96e8e41a189f9e2ce55af432afeaef1e45a",
              packageHash: "e91445390deab2117ad784f953029358bb916b634fb7762d9eabfd06b0ea7dee"),
        .init(pluginId: "sh.abstract.chat-count", slug: "chat-count", commit: "b0b60e20ce31ea4ccdff2e2efa3ce66307f2401c",
              packageHash: "50d083d84ca3b8f6615d54b32ccc851ea097f2455c0d5c1e13834a70a8ca1dc8"),
        .init(pluginId: "sh.abstract.chat-panel", slug: "chat-panel", commit: "c1a26478725b98d71cc8f20daac23ee6467486b8",
              packageHash: "e130f3cfe0d4ec3acfcb57cc4da6be241a6a55b1a5fdf715c8dec7cac7461e6c"),
        .init(pluginId: "sh.abstract.dashboard", slug: "dashboard", commit: "60744cbab556ac2dc2683712c8e6fd470d16eadf",
              packageHash: "8b1026f6d5e47121244b23e982a216acfb2ff4c3a11ba86a2bf8e15574f8e463"),
        .init(pluginId: "sh.abstract.delegation", slug: "delegation", commit: "7eb7e7c73aca8b441d85e04be36eeb634e3c9f92",
              packageHash: "575fadcefb56495498162d1b7d1f2603ab63802693eed415dfff8303f0e18d37"),
        .init(pluginId: "sh.abstract.follow-pr", slug: "follow-pr", commit: "ed769b9d7e3ac46ebced2e5838a9a3a22102ec4b",
              packageHash: "2f11d72bec95ae927be19b13edc029d818931b0bba06365290ade84e510bf7d3"),
        .init(pluginId: "sh.abstract.jira", slug: "jira", commit: "1c50de6c51a6d61837c662adadeb384dbe6fbad6",
              packageHash: "bd0b9e0fbf06381ed34d59bac51e50b3c969094fa65cd606c964a280b2601eda"),
        .init(pluginId: "sh.abstract.kanban", slug: "kanban", commit: "8cd6a46849301a96c85c94db08e26e3ea04c2507",
              packageHash: "8e4e49e7e8f51af2deed409274c907bfc657d533fe0599513cf23cf93ec4fd6c"),
        .init(pluginId: "sh.abstract.lessons", slug: "lessons", commit: "e54fc29eafe8f42c1d784900f43b566df5f9c162",
              packageHash: "6ac24dea1213d2b3fd030220208c5d553133c1601862864d3c2f667cbaba6d9e"),
        .init(pluginId: "sh.abstract.linear", slug: "linear", commit: "7660c51543d5608f0b9f0c72efc6d40b71242276",
              packageHash: "06c42e6bdebb5eb8eeb3c6abd22b62bb4c387a215b93114d2ad8f6726e6bf058"),
        .init(pluginId: "sh.abstract.link-status", slug: "link-status", commit: "38a796a38fc888f532786b31915dab6640255038",
              packageHash: "299c5f6a621d232eb67a5b5c747d2a3d0cb2218a23356d28fbcc9072e8f7bc0b"),
        .init(pluginId: "sh.abstract.second-opinion", slug: "second-opinion", commit: "d92acfe9bfb1919fd8b6c777e767530485c4f4a0",
              packageHash: "bf95649c9f42d8fb4329529c4d02b799565f3c25126c3abbe173bfbfee15c96c"),
    ]

    public static func move(_ pluginId: String) -> Move? {
        all.first { $0.pluginId == pluginId }
    }

    public static let bitbucket = "sh.abstract.bitbucket"
}

extension PluginManager {
    /// Turns each install of a moved plugin, from the app or its catalog,
    /// into its git source (ABS-190). Its files, storage, secrets, grants
    /// and on/off state are left exactly as they are, so nothing is
    /// reviewed again. Files identical to the extracted ones are pinned to
    /// that commit; an older copy gets no commit, so Check for updates
    /// offers the approved one. Returns whether anything changed.
    @discardableResult
    public func migrateMovedPlugins(_ moves: [MovedPlugins.Move] = MovedPlugins.all) -> Bool {
        var records = records()
        var changed = false
        for index in records.indices {
            guard records[index].source == .bundled || records[index].source == .catalog,
                  let move = moves.first(where: { $0.pluginId == records[index].id }) else { continue }
            var source = move.source
            if records[index].packageHash != move.packageHash { source.commit = nil }
            records[index].source = .git(source)
            changed = true
        }
        if changed { try? store.setSetting(Self.settingsKey, records) }
        return changed
    }

    /// A plugin Abstract turns on by itself the first time it's useful,
    /// like Bitbucket for a Bitbucket remote, installed from its reviewed
    /// listing now that the app doesn't carry it. Once: removing or turning
    /// it off afterwards sticks. Returns whether it was installed.
    @discardableResult
    public func installOffered(_ entry: PluginRegistry.Entry, fetcher: any PluginGitFetching,
                               fileManager fm: FileManager = .default) async throws -> Bool {
        var offered = offeredDefaults
        guard !offered.contains(entry.pluginId), !records().contains(where: { $0.id == entry.pluginId }) else { return false }
        let candidate = try await inspectListing(entry, fetcher: fetcher, fileManager: fm)
        defer { try? fm.removeItem(at: candidate.cleanup) }
        try install(candidate, fileManager: fm)
        setEnabled(entry.pluginId, true)
        offered.insert(entry.pluginId)
        try? store.setSetting(Self.defaultsKey, offered.sorted())
        return true
    }
}
