import Foundation
import Testing
@testable import AbstractCore

@Suite struct PluginRegistryTests {
    private let approved = String(repeating: "a", count: 40)
    private let newer = String(repeating: "b", count: 40)
    private let unreviewed = String(repeating: "c", count: 40)

    private func json(commit: String? = nil, extra: String = "") -> Data {
        Data("""
        {"format":1,"plugins":[{"owner":"endeken-com","slug":"kanban","name":"Kanban",
        "description":"A board of your chats.","pluginId":"sh.abstract.kanban",
        "repository":"endeken-com/abstract-plugin-kanban","commit":"\(commit ?? approved)",
        "screenshots":["https://raw.githubusercontent.com/endeken-com/abstract-plugin-kanban/\(approved)/screenshot.png"],
        "reviewedAt":"2026-11-05T12:00:00Z"\(extra)}]}
        """.utf8)
    }

    @Test func readsListingsAndRefusesMalformedOnes() throws {
        let registry = try PluginRegistry.decode(json())
        let entry = try #require(registry.entry("endeken-com/kanban"))
        #expect(entry.id == "endeken-com/kanban" && entry.pluginId == "sh.abstract.kanban" && entry.path == nil)
        #expect(entry.source == PluginGitSource(owner: "endeken-com", repo: "abstract-plugin-kanban", commit: approved,
                                                listing: "endeken-com/kanban"))
        #expect(entry.screenshots.count == 1 && entry.reviewedAt != nil)
        #expect(registry.entry("Endeken-com/Kanban") == entry)

        let monorepo = try PluginRegistry.decode(json(extra: #","path":"plugins/kanban""#))
        #expect(monorepo.plugins[0].source.path == "plugins/kanban")

        let docs = try Data(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("../../docs/plugin-registry/registry.json").standardizedFileURL)
        #expect(throws: Never.self) { try PluginRegistry.decode(docs) }

        for bad in [json(commit: "main"), json(commit: "abc1234"), json(commit: approved.uppercased()),
                    json(extra: #","path":"../escape""#),
                    Data(String(decoding: json(), as: UTF8.self).replacingOccurrences(of: #""format":1"#, with: #""format":2"#).utf8),
                    Data(String(decoding: json(), as: UTF8.self).replacingOccurrences(of: "https://raw", with: "http://raw").utf8),
                    Data(String(decoding: json(), as: UTF8.self).replacingOccurrences(of: "endeken-com/abstract-plugin-kanban\",", with: "https://example.com/x.git\",").utf8),
                    Data("[]".utf8)] {
            #expect(throws: PluginRegistryError.invalid) { try PluginRegistry.decode(bad) }
        }
        let doubled = String(decoding: json(), as: UTF8.self)
        let entryText = doubled[doubled.range(of: "{\"owner\"")!.lowerBound..<doubled.range(of: "]}", options: .backwards)!.lowerBound]
        #expect(throws: PluginRegistryError.invalid) {
            try PluginRegistry.decode(Data(doubled.replacingOccurrences(of: "]}", with: ",\(entryText)]}").utf8))
        }
    }

    @Test func ownerSlugInstallsTheListingAndEverythingElseIsARepository() throws {
        let registry = try PluginRegistry.decode(json())
        #expect(try registry.source(for: "endeken-com/kanban").listing == "endeken-com/kanban")
        #expect(try registry.source(for: "endeken-com/kanban").commit == approved)
        // A ref, a folder or a prefix is a repository.
        #expect(try registry.source(for: "endeken-com/kanban@main").listing == nil)
        #expect(try registry.source(for: "endeken-com/kanban", ref: "main").listing == nil)
        #expect(try registry.source(for: "github:endeken-com/kanban").listing == nil)
        #expect(try registry.source(for: "endeken-com/kanban/plugins/x").listing == nil)
        #expect(try registry.source(for: "endeken-com/abstract-plugin-kanban")
                == PluginGitSource(owner: "endeken-com", repo: "abstract-plugin-kanban"))
    }

    @Test func reviewedMeansThisExactCommit() throws {
        let registry = try PluginRegistry.decode(json())
        var direct = PluginGitSource(owner: "endeken-com", repo: "abstract-plugin-kanban", commit: approved)
        #expect(registry.isReviewed(direct))
        direct.commit = unreviewed
        #expect(!registry.isReviewed(direct))
        direct.commit = approved; direct.path = "other"
        #expect(!registry.isReviewed(direct))
        // A listing's install stays reviewed when the listing moves on.
        #expect(PluginRegistry(plugins: []).isReviewed(registry.plugins[0].source))
    }

    @Test func galleryListsTheRegistryAsReviewedAndDirectInstallsAsNot() throws {
        let registry = try PluginRegistry.decode(json())
        let manifest = PluginManifest(id: "dev.example.other", name: "Other", version: "1.0", capabilities: [],
                                      views: [.init(id: "main", title: "Other")])
        let direct = InstalledPlugin(record: PluginRecord(id: manifest.id, name: manifest.name, version: "1.0",
                                                          source: .git(PluginGitSource(owner: "o", repo: "other", commit: unreviewed)),
                                                          enabled: true, packageHash: "h"),
                                     manifest: manifest, problem: nil, packageURL: URL(fileURLWithPath: "/tmp/x"))
        let items = PluginGalleryItem.items(installed: [direct], bundled: [], catalog: [], registry: registry)
        let listed = try #require(items.first { $0.id == "sh.abstract.kanban" })
        #expect(listed.state == .available && listed.name == "Kanban" && listed.summary == "A board of your chats.")
        #expect(listed.reviewText == "Reviewed" && listed.listing?.id == "endeken-com/kanban")
        #expect(items.first { $0.id == manifest.id }?.reviewText == "Not reviewed")
        #expect(PluginGalleryItem.filter(items, query: "not reviewed", view: .all, category: nil).map(\.id) == [manifest.id])
        // The app's own plugins aren't "reviewed" or not: they ship with it.
        #expect(PluginGalleryItem.items(installed: [], bundled: [manifest], catalog: [], registry: registry)
            .first { $0.id == manifest.id }?.reviewText == nil)
    }

    private func host() throws -> (PluginManager, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("plugin-registry-\(UUID().uuidString)")
        let manager = PluginManager(store: try Store.inMemory(), pluginsRoot: root.appendingPathComponent("Plugins"),
                                    dataRoot: root.appendingPathComponent("PluginData"))
        return (manager, root)
    }

    private func github(head: String) -> FakeGitHub {
        FakeGitHub(["endeken-com/abstract-plugin-kanban": .init(head: head, trees: [
            approved: ["manifest.json": FakeGitHub.manifest(id: "sh.abstract.kanban"), "index.html": "approved"],
            newer: ["manifest.json": FakeGitHub.manifest(id: "sh.abstract.kanban", version: "1.1.0"), "index.html": "newer"],
            unreviewed: ["manifest.json": FakeGitHub.manifest(id: "sh.abstract.kanban", version: "9.0.0",
                                                              capabilities: ["chats.read", "chats.create"]),
                         "index.html": "unreviewed"],
        ])])
    }

    @Test func aListingInstallsItsApprovedCommitNotTheBranch() async throws {
        let (manager, root) = try host()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = try PluginRegistry.decode(json())
        // The branch has moved past what was reviewed.
        let fake = github(head: unreviewed)
        let entry = registry.plugins[0]
        let candidate = try await manager.inspectListing(entry, fetcher: fake)
        defer { try? FileManager.default.removeItem(at: candidate.cleanup) }
        #expect(candidate.source.commit == approved && candidate.inspection.manifest.version == "1.0.0")
        let record = try manager.install(candidate)
        #expect(record.source.git?.listing == "endeken-com/kanban" && record.source.git?.commit == approved)
        manager.setEnabled(record.id, true)

        // Check for updates follows the registry, never the branch.
        #expect(await manager.checkGitUpdates(fetcher: fake, registry: registry).updates.isEmpty)
        #expect(await manager.checkGitUpdates(fetcher: fake, registry: nil).updates.isEmpty)
        let moved = try PluginRegistry.decode(json(commit: newer))
        let update = try #require(await manager.checkGitUpdates(fetcher: fake, registry: moved).updates.first)
        defer { try? FileManager.default.removeItem(at: update.candidate.cleanup) }
        #expect(update.candidate.source.commit == newer && update.candidate.source.listing == "endeken-com/kanban")
        #expect(!update.grants.asksForMore)
    }

    @Test func aListingWhosePinHoldsAnotherPluginIsRefused() async throws {
        let (manager, root) = try host()
        defer { try? FileManager.default.removeItem(at: root) }
        let other = try PluginRegistry.decode(Data(String(decoding: json(), as: UTF8.self)
            .replacingOccurrences(of: "sh.abstract.kanban", with: "sh.abstract.other").utf8))
        await #expect(throws: PluginRegistryError.notApproved("Kanban")) {
            try await manager.inspectListing(other.plugins[0], fetcher: github(head: approved))
        }
        await #expect(throws: PluginRegistryError.unavailable) {
            try await manager.inspect(other.plugins[0].source, registry: nil, fetcher: github(head: approved))
        }
        #expect(manager.records().isEmpty)
    }

    @Test func commandLineInstallsAListingAsReviewed() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("plugin-registry-cli-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let commands = Commands(store: try Store.inMemory(), storePath: root.appendingPathComponent("abstract.sqlite").path,
                                locks: root.appendingPathComponent("locks"), executable: "/bin/abstract")
        let registry = try PluginRegistry.decode(json())
        let fake = github(head: unreviewed)
        let listed = try await commands.addPlugin("endeken-com/kanban", ref: nil, fetcher: fake, registry: registry)
        #expect(listed.reviewed && listed.listing == "endeken-com/kanban" && listed.commit == approved && !listed.enabled)

        let direct = try await commands.addPlugin("endeken-com/abstract-plugin-kanban", ref: nil, fetcher: fake, registry: registry)
        #expect(!direct.reviewed && direct.listing == nil && direct.commit == unreviewed)
    }
}
