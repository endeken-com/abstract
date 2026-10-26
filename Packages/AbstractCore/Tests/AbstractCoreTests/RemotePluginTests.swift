import Foundation
import Testing
@testable import AbstractCore

struct RemotePluginTests {
    private func installed(enabled: Bool = true, problem: String? = nil) -> InstalledPlugin {
        let manifest = PluginManifest(id: "sh.example.widget", name: "Widget", version: "1.2.0",
                                      description: "A widget.", capabilities: ["usage.read", "transcripts.read"],
                                      views: [.init(id: "main", title: "Widget")],
                                      chatPanelTabs: [.init(id: "tab", title: "Widget tab")],
                                      chatMenuItems: [.init(id: "log", title: "Log chat")],
                                      homeWidgets: [.init(id: "card", title: "Widget card")])
        let record = PluginRecord(id: manifest.id, name: "Widget", version: "1.2.0", source: .user,
                                  enabled: enabled,
                                  grantedCapabilities: enabled ? [.usageRead, .transcriptsRead] : [],
                                  transcriptProjectKeys: ["mac1:p1"], packageHash: "abc")
        return InstalledPlugin(record: record, manifest: manifest, problem: problem,
                               packageURL: URL(fileURLWithPath: "/tmp/widget"))
    }

    @Test func remotePluginCarriesGrantsAndContributions() {
        let remote = RemotePlugin(installed())
        #expect(remote.usable)
        #expect(remote.requestedCapabilities == ["usage.read", "transcripts.read"])
        #expect(remote.grantedCapabilities == ["transcripts.read", "usage.read"])
        #expect(remote.transcriptProjectKeys == ["mac1:p1"])
        #expect(remote.viewId == "main")
        #expect(remote.contributions.map(\.place) == ["main", "chatPanel", "chatMenu", "home"])
        #expect(!remote.appearances.isEmpty)
    }

    @Test func offPluginStillNamesItsPlacesButIsNotUsable() {
        let remote = RemotePlugin(installed(enabled: false))
        #expect(!remote.usable)
        #expect(remote.grantedCapabilities.isEmpty)
        #expect(remote.contributions.map(\.place) == ["main", "chatPanel", "chatMenu", "home"])
    }

    @Test func pluginsRoundTripAndOlderSnapshotsDecode() throws {
        let snapshot = RemoteSnapshot(projects: [], sessions: [], providers: [], alive: [],
                                      plugins: [RemotePlugin(installed())],
                                      pluginProjects: [RemotePluginProject(key: "mac1:p1", name: "One")],
                                      pluginsSupported: true)
        let decoded = try JSONDecoder().decode(RemoteSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(decoded.plugins == snapshot.plugins)
        #expect(decoded.pluginProjects?.first?.name == "One")
        #expect(decoded.pluginsSupported == true)

        let old = try JSONDecoder().decode(RemoteSnapshot.self,
                                           from: Data(#"{"projects":[],"sessions":[],"providers":[],"alive":[]}"#.utf8))
        #expect(old.plugins == nil)
        #expect(old.pluginsSupported == nil)
    }

    @Test func pluginRequestsAndResponsesRoundTrip() throws {
        let requests: [RemoteMessage] = [
            .request(id: 1, .setPluginEnabled(pluginId: "p", enabled: true, transcriptProjectKeys: ["k"])),
            .request(id: 2, .setPluginEnabled(pluginId: "p", enabled: false, transcriptProjectKeys: nil)),
            .request(id: 3, .setPluginTranscriptProjects(pluginId: "p", keys: [])),
            .request(id: 4, .pluginPackage(pluginId: "p")),
            .request(id: 5, .pluginContext(pluginId: "p", place: "chatPanel", contributionId: "tab", chatId: "c1")),
            .request(id: 6, .pluginMessage(pluginId: "p", text: "{}", place: "main", contributionId: "main", chatId: nil)),
            .response(id: 7, .pluginPackage(RemotePluginPackage(entry: "index.html", files: ["index.html": Data("hi".utf8)]))),
            .response(id: 8, .pluginMessages(messages: ["{}"], openChatId: "c1")),
        ]
        for message in requests {
            let decoded = try JSONDecoder().decode(RemoteMessage.self, from: JSONEncoder().encode(message))
            #expect(String(describing: decoded) == String(describing: message))
        }
    }

    @Test func packageFilesCollectsAndRefusesOversized() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("plugin-pkg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("<html></html>".utf8).write(to: root.appendingPathComponent("index.html"))
        try Data("123456".utf8).write(to: root.appendingPathComponent("app.js"))

        let files = try PluginPackage.packageFiles(in: root, sizeLimit: 1024)
        #expect(files.keys.sorted() == ["app.js", "index.html"])
        #expect(files["app.js"] == Data("123456".utf8))
        #expect(throws: PluginValidationError.self) {
            try PluginPackage.packageFiles(in: root, sizeLimit: 4)
        }
    }
}
