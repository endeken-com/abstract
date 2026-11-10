import Foundation
import Testing
@testable import AbstractCore

/// ABS-190: the non-essential first-party plugins moved to their own
/// repositories, and installs from before keep working.
@Suite struct PluginMoveTests {
    let fm = FileManager.default
    let commit = String(repeating: "e", count: 40)

    @Test func onlyBundledAndApprovedMovedSourcesKeepBrandTrust() {
        let official = PluginGitSource(owner: "abstract-ade", repo: "abstract-plugin-jira", commit: commit,
                                       listing: "abstract-ade/jira")
        let lookalike = PluginGitSource(owner: "someone-else", repo: "abstract-plugin-jira", commit: commit,
                                        listing: "someone-else/jira")
        #expect(MovedPlugins.trustsBrand(pluginId: "sh.abstract.jira", source: .bundled))
        #expect(MovedPlugins.trustsBrand(pluginId: "sh.abstract.jira", source: .git(official)))
        #expect(!MovedPlugins.trustsBrand(pluginId: "sh.abstract.jira", source: .git(lookalike)))
        #expect(!MovedPlugins.trustsBrand(pluginId: "sh.example.jira", source: .git(official)))
        #expect(!MovedPlugins.trustsBrand(pluginId: "sh.abstract.jira", source: .user))
    }

    var repo: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func host() throws -> (PluginManager, URL) {
        let root = fm.temporaryDirectory.appendingPathComponent("plugin-move-\(UUID().uuidString)")
        let manager = PluginManager(store: try Store.inMemory(), pluginsRoot: root.appendingPathComponent("Plugins"),
                                    dataRoot: root.appendingPathComponent("PluginData"))
        return (manager, root)
    }

    /// A Jira as the app used to ship it.
    private func bundledJira(in root: URL, version: String = "1.1.0") throws -> URL {
        let folder = root.appendingPathComponent("bundled-jira-\(version)")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try FakeGitHub.manifest(id: "sh.abstract.jira", version: version, capabilities: ["chats.read", "storage.own"])
            .write(to: folder.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try "<html></html>".write(to: folder.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        return folder
    }

    private func move(hash: String) -> MovedPlugins.Move {
        .init(pluginId: "sh.abstract.jira", slug: "jira", commit: commit, packageHash: hash)
    }

    @Test func anInstalledJiraKeepsWorkingWithItsSettingsAfterTheMove() throws {
        let (manager, root) = try host()
        defer { try? fm.removeItem(at: root) }
        let folder = try bundledJira(in: root)
        let installed = try manager.install(from: folder, sourceKind: .bundled)
        manager.setEnabled(installed.id, true)
        manager.setAlwaysAllowed(installed.id, .chatsRead, true)
        try manager.storage(for: installed.id).set(.string("PROJ"), forKey: "project:p")
        let before = try #require(manager.records().first)

        #expect(manager.migrateMovedPlugins([move(hash: installed.packageHash)]))
        let after = try #require(manager.records().first)
        #expect(after.source == .git(PluginGitSource(owner: "abstract-ade", repo: "abstract-plugin-jira", commit: commit,
                                                     listing: "abstract-ade/jira")))
        // Everything but where it comes from is as it was.
        var same = after
        same.source = before.source
        #expect(same == before)
        #expect(after.enabled && after.grantedCapabilities == [.chatsRead, .storageOwn])
        #expect(try manager.storage(for: installed.id).values()["project:p"] == .string("PROJ"))
        let plugin = try #require(manager.installed().first)
        #expect(plugin.problem == nil && plugin.isUsable)
        // A listing's install counts as reviewed, and isn't moved twice.
        #expect(PluginRegistry(plugins: []).isReviewed(try #require(after.source.git)))
        #expect(!manager.migrateMovedPlugins([move(hash: installed.packageHash)]))
    }

    /// Builds from the week the repositories sat in endeken-com recorded
    /// installs there; they follow the repositories to abstract-ade.
    @Test func installsRecordedUnderTheFirstOrganizationFollowTheMove() throws {
        let (manager, root) = try host()
        defer { try? fm.removeItem(at: root) }
        let installed = try manager.install(from: try bundledJira(in: root), sourceKind: .bundled)
        manager.setEnabled(installed.id, true)
        var records = manager.records()
        records[0].source = .git(PluginGitSource(owner: "endeken-com", repo: "abstract-plugin-jira",
                                                 commit: String(repeating: "1", count: 40), listing: "endeken-com/jira"))
        try manager.store.setSetting(PluginManager.settingsKey, records)

        #expect(manager.migrateMovedPlugins([move(hash: installed.packageHash)]))
        let after = try #require(manager.records().first)
        #expect(after.source.git?.owner == "abstract-ade" && after.source.git?.listing == "abstract-ade/jira")
        #expect(after.source.git?.commit == commit && after.enabled)
        // Someone else's repository of the same name stays theirs.
        records[0].source = .git(PluginGitSource(owner: "someone", repo: "abstract-plugin-jira", commit: commit))
        try manager.store.setSetting(PluginManager.settingsKey, records)
        #expect(!manager.migrateMovedPlugins([move(hash: installed.packageHash)]))
    }

    @Test func onlyTheAppsAndTheCatalogsCopiesMove() throws {
        let (manager, root) = try host()
        defer { try? fm.removeItem(at: root) }
        let mine = try manager.install(from: try bundledJira(in: root), sourceKind: .user)
        #expect(!manager.migrateMovedPlugins([move(hash: mine.packageHash)]))
        #expect(manager.records().first?.source == .user)

        let catalog = try manager.install(from: try bundledJira(in: root), sourceKind: .bundled)
        var records = manager.records()
        records[0].source = .catalog
        try manager.store.setSetting(PluginManager.settingsKey, records)
        #expect(manager.migrateMovedPlugins([move(hash: catalog.packageHash)]))
        #expect(manager.records().first?.source.git?.commit == commit)
    }

    @Test func anOlderCopyFromTheAppIsOfferedTheApprovedCommit() async throws {
        let (manager, root) = try host()
        defer { try? fm.removeItem(at: root) }
        let old = try manager.install(from: try bundledJira(in: root, version: "1.0.0"), sourceKind: .bundled)
        manager.setEnabled(old.id, true)
        #expect(manager.migrateMovedPlugins([move(hash: String(repeating: "0", count: 64))]))
        let migrated = try #require(manager.records().first?.source.git)
        #expect(migrated.commit == nil && migrated.listing == "abstract-ade/jira")
        #expect(try #require(manager.installed().first).isUsable)

        let github = FakeGitHub(["abstract-ade/abstract-plugin-jira": .init(head: commit, trees: [
            commit: ["manifest.json": FakeGitHub.manifest(id: "sh.abstract.jira", version: "1.1.0",
                                                          capabilities: ["chats.read", "storage.own"]),
                     "index.html": "<html></html>"],
        ])])
        let registry = PluginRegistry(plugins: [.init(owner: "abstract-ade", slug: "jira", name: "Jira", description: "Jira.",
                                                      pluginId: "sh.abstract.jira", repository: "abstract-ade/abstract-plugin-jira",
                                                      commit: commit)])
        let update = try #require(await manager.checkGitUpdates(fetcher: github, registry: registry).updates.first)
        defer { try? fm.removeItem(at: update.candidate.cleanup) }
        #expect(update.fromCommit == nil && update.changes == nil && !update.grants.asksForMore)
        #expect(update.summary == "The copy from the app → eeeeeee: no new access.")
        let updated = try manager.install(update.candidate)
        #expect(updated.enabled && updated.version == "1.1.0" && updated.source.git?.commit == commit)
    }

    @Test func aPluginTurnedOnByItselfComesFromItsListingOnce() async throws {
        let (manager, root) = try host()
        defer { try? fm.removeItem(at: root) }
        let github = FakeGitHub(["abstract-ade/abstract-plugin-bitbucket": .init(head: commit, trees: [
            commit: ["manifest.json": FakeGitHub.manifest(id: "sh.abstract.bitbucket"), "index.html": "x"],
        ])])
        let entry = PluginRegistry.Entry(owner: "abstract-ade", slug: "bitbucket", name: "Bitbucket", description: "Bitbucket.",
                                         pluginId: "sh.abstract.bitbucket",
                                         repository: "abstract-ade/abstract-plugin-bitbucket", commit: commit)
        #expect(try await manager.installOffered(entry, fetcher: github))
        let record = try #require(manager.records().first)
        #expect(record.enabled && record.source.git?.listing == "abstract-ade/bitbucket")
        // Removing it sticks.
        manager.remove(record.id)
        #expect(try await !manager.installOffered(entry, fetcher: github))
        #expect(manager.records().isEmpty)
    }

    @Test func theMovedPluginsLeftTheAppAndAreListedAtTheirCommits() throws {
        let bundled = try fm.contentsOfDirectory(atPath: repo.appendingPathComponent("Abstract/Resources/Plugins").path)
        #expect(MovedPlugins.all.count == 13)
        for move in MovedPlugins.all {
            #expect(!bundled.contains("\(move.slug).abstractplugin"), "\(move.slug) is still bundled")
            #expect(!PluginManager.defaultPluginIds.contains(move.pluginId))
            // Listed in abstract-ade/abstract-plugins, whose CI checks each pin.
            #expect(move.listing == "abstract-ade/\(move.slug)")
            #expect(move.source == PluginGitSource(owner: "abstract-ade", repo: "abstract-plugin-\(move.slug)",
                                                   commit: move.commit, listing: move.listing))
            #expect(PluginGitSource.isCommit(move.commit) && move.packageHash.count == 64)
        }
        // What stays: the agents, the themes and GitHub.
        #expect(Set(bundled.filter { $0.hasSuffix(".abstractplugin") }) == [
            "agent-claude.abstractplugin", "agent-codex.abstractplugin", "agent-muse.abstractplugin",
            "agent-opencode.abstractplugin", "agent-gemini.abstractplugin", "theme-graphite.abstractplugin", "theme-ink.abstractplugin",
            "theme-paper.abstractplugin", "github.abstractplugin",
        ])
    }
}
