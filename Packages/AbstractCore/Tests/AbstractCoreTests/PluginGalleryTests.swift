import Foundation
import Testing
@testable import AbstractCore

@Suite struct PluginGalleryTests {
    private func manifest(_ id: String, _ name: String, description: String = "A useful plugin",
                          reviews: Bool = false) -> PluginManifest {
        PluginManifest(id: id, name: name, version: "1.0", description: description,
                       capabilities: [], views: [.init(id: "main", title: name)],
                       reviewActions: reviews ? [.init(id: "review", title: "Review")]: [])
    }

    private func installed(_ manifest: PluginManifest, enabled: Bool = true,
                           source: PluginSource = .user, problem: String? = nil) -> InstalledPlugin {
        InstalledPlugin(record: PluginRecord(id: manifest.id, name: manifest.name,
                                            version: manifest.version, source: source,
                                            enabled: enabled, packageHash: String(repeating: "a", count: 64)),
                        manifest: manifest, problem: problem,
                        packageURL: URL(fileURLWithPath: "/tmp/example-plugin"))
    }

    private func catalog(_ id: String, name: String = "Catalog plugin", version: String = "2.0") -> PluginCatalog.Entry {
        let hash = String(repeating: "b", count: 64)
        let json = """
        {"plugins":[{"id":"\(id)","name":"\(name)","version":"\(version)",
        "url":"https://github.com/endeken-com/abstract/releases/download/test/plugin.zip",
        "hash":"\(hash)","archiveHash":"\(hash)","archiveSignature":"\(Data(repeating: 0, count: 64).base64EncodedString())"}]}
        """
        return try! PluginCatalog.decode(Data(json.utf8)).plugins[0]
    }

    @Test func mergesSourcesAndFiltersTogether() {
        let local = manifest("sh.abstract.local", "Local notes", description: "Notes in chats")
        let bundled = manifest("sh.abstract.review", "Review helper", reviews: true)
        let items = PluginGalleryItem.items(installed: [installed(local, enabled: false)],
                                            bundled: [bundled], catalog: [catalog("sh.abstract.remote")])
        #expect(items.count == 3)
        #expect(items.first { $0.id == local.id }?.state == .disabled)
        #expect(items.first { $0.id == bundled.id }?.category == .reviews)
        #expect(items.first { $0.id == bundled.id }?.source == .bundled)
        #expect(items.first { $0.id == "sh.abstract.remote" }?.source == .catalog)
        #expect(PluginGalleryItem.filter(items, query: "notes", view: .installed, category: nil).map(\.id) == [local.id])
        #expect(PluginGalleryItem.filter(items, query: "review", view: .all, category: .reviews).map(\.id) == [bundled.id])
        #expect(PluginGalleryItem.filter(items, query: "review", view: .installed, category: nil).isEmpty)
    }

    @Test func updatesAndOfflineInstalledManagement() {
        let manifest = manifest("sh.abstract.local", "Local notes")
        let plugin = installed(manifest, source: .catalog)
        let online = PluginGalleryItem.items(installed: [plugin], bundled: [],
                                             catalog: [catalog(manifest.id)])
        #expect(online[0].state == .updateAvailable)
        #expect(PluginGalleryItem.filter(online, query: "", view: .updates, category: nil).count == 1)

        let offline = PluginGalleryItem.items(installed: [plugin], bundled: [], catalog: [])
        #expect(offline[0].state == .installed)
        #expect(offline[0].installed?.id == plugin.id)
        #expect(PluginGalleryItem.filter(offline, query: "", view: .installed, category: nil).count == 1)
        #expect(PluginGalleryItem.items(installed: [installed(manifest, problem: "Changed")],
                                        bundled: [], catalog: [])[0].state == .needsReview)
    }
}
