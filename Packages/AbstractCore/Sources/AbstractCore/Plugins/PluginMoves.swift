import Foundation

/// The first-party plugins that left the app for their own repositories
/// (ABS-190): `abstract-ade/abstract-plugin-<slug>`, each listed in the
/// registry as `abstract-ade/<slug>`. The app no longer ships them; an
/// existing install keeps working as a git source pinned to the commit its
/// files were extracted at.
public enum MovedPlugins {
    public struct Move: Sendable, Hashable {
        public var pluginId: String
        public var slug: String
        /// The commit the registry first approved: the extracted plugin, with
        /// its README pointing at the abstract-ade organization.
        public var commit: String
        /// The package's hash at that commit: the bundled copy's, unchanged.
        public var packageHash: String

        public init(pluginId: String, slug: String, commit: String, packageHash: String) {
            self.pluginId = pluginId; self.slug = slug; self.commit = commit; self.packageHash = packageHash
        }

        public var listing: String { "\(MovedPlugins.owner)/\(slug)" }

        /// Where it lives now, pinned to the extracted commit.
        public var source: PluginGitSource {
            PluginGitSource(owner: MovedPlugins.owner, repo: "abstract-plugin-\(slug)", commit: commit, listing: listing)
        }

        /// A source under the organization these repositories started in.
        func isLegacy(_ source: PluginGitSource) -> Bool {
            source.owner == MovedPlugins.legacyOwner && source.repo == "abstract-plugin-\(slug)"
        }
    }

    /// The GitHub organization the repositories and the registry live in.
    public static let owner = "abstract-ade"
    /// Where they were first published, before moving to `owner`: builds
    /// from that week recorded installs under it.
    public static let legacyOwner = "endeken-com"

    public static let all: [Move] = [
        .init(pluginId: "sh.abstract.approvals", slug: "approvals", commit: "e57b51a904f9e0af0208a470c3bf32b41fd5d48c",
              packageHash: "983038735aa69fd19dfede8c17c6b37f50035ae86beac8d7b5f62ad0c8445bb2"),
        .init(pluginId: "sh.abstract.bitbucket", slug: "bitbucket", commit: "b263c3d524b1db74ba2e8f640d5d790fcd375f95",
              packageHash: "e91445390deab2117ad784f953029358bb916b634fb7762d9eabfd06b0ea7dee"),
        .init(pluginId: "sh.abstract.chat-count", slug: "chat-count", commit: "bbb17ab098f8c9a331816b6275619686d5c41abc",
              packageHash: "50d083d84ca3b8f6615d54b32ccc851ea097f2455c0d5c1e13834a70a8ca1dc8"),
        .init(pluginId: "sh.abstract.chat-panel", slug: "chat-panel", commit: "531d9e28bf13baf155e1dcf4e3cdcb10f875d170",
              packageHash: "e130f3cfe0d4ec3acfcb57cc4da6be241a6a55b1a5fdf715c8dec7cac7461e6c"),
        .init(pluginId: "sh.abstract.dashboard", slug: "dashboard", commit: "773278075be2c7d615373d23e746dd47851ae5ce",
              packageHash: "8b1026f6d5e47121244b23e982a216acfb2ff4c3a11ba86a2bf8e15574f8e463"),
        .init(pluginId: "sh.abstract.delegation", slug: "delegation", commit: "e9deb5744b9a4cf3d31eca74711225a959d34170",
              packageHash: "575fadcefb56495498162d1b7d1f2603ab63802693eed415dfff8303f0e18d37"),
        .init(pluginId: "sh.abstract.follow-pr", slug: "follow-pr", commit: "bc551fe8d9d526ee160c791eae70ae67bd830694",
              packageHash: "2f11d72bec95ae927be19b13edc029d818931b0bba06365290ade84e510bf7d3"),
        .init(pluginId: "sh.abstract.jira", slug: "jira", commit: "f78ec32249008239dd21e15d9893d35fba16d229",
              packageHash: "bd0b9e0fbf06381ed34d59bac51e50b3c969094fa65cd606c964a280b2601eda"),
        .init(pluginId: "sh.abstract.kanban", slug: "kanban", commit: "c8448fe0509e2e41e3b7e4e0f756f1be4aaa608c",
              packageHash: "8e4e49e7e8f51af2deed409274c907bfc657d533fe0599513cf23cf93ec4fd6c"),
        .init(pluginId: "sh.abstract.lessons", slug: "lessons", commit: "eaeb6056a2848db58b800e500a3df7378976daeb",
              packageHash: "6ac24dea1213d2b3fd030220208c5d553133c1601862864d3c2f667cbaba6d9e"),
        .init(pluginId: "sh.abstract.linear", slug: "linear", commit: "e00753bf07439afd8b1f69aba8b5bf0673471e7e",
              packageHash: "06c42e6bdebb5eb8eeb3c6abd22b62bb4c387a215b93114d2ad8f6726e6bf058"),
        .init(pluginId: "sh.abstract.link-status", slug: "link-status", commit: "dca3a9b05868139ba06a59581b83318ebebb8aa3",
              packageHash: "299c5f6a621d232eb67a5b5c747d2a3d0cb2218a23356d28fbcc9072e8f7bc0b"),
        .init(pluginId: "sh.abstract.second-opinion", slug: "second-opinion", commit: "5accd260e3f2e9b1a76ecacdc791d38ccb845859",
              packageHash: "bf95649c9f42d8fb4329529c4d02b799565f3c25126c3abbe173bfbfee15c96c"),
    ]

    public static func move(_ pluginId: String) -> Move? {
        all.first { $0.pluginId == pluginId }
    }

    public static let bitbucket = "sh.abstract.bitbucket"
}

extension PluginManager {
    /// Turns each install of a moved plugin, from the app or its catalog,
    /// or recorded under the repositories' first organization, into its
    /// git source (ABS-190). Its files, storage, secrets, grants
    /// and on/off state are left exactly as they are, so nothing is
    /// reviewed again. Files identical to the extracted ones are pinned to
    /// that commit; an older copy gets no commit, so Check for updates
    /// offers the approved one. Returns whether anything changed.
    @discardableResult
    public func migrateMovedPlugins(_ moves: [MovedPlugins.Move] = MovedPlugins.all) -> Bool {
        var records = records()
        var changed = false
        for index in records.indices {
            guard let move = moves.first(where: { $0.pluginId == records[index].id }) else { continue }
            let source = records[index].source
            guard source == .bundled || source == .catalog || source.git.map(move.isLegacy) == true else { continue }
            var moved = move.source
            if records[index].packageHash != move.packageHash { moved.commit = nil }
            records[index].source = .git(moved)
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
