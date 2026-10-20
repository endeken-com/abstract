import Foundation
import JavaScriptCore
import Testing
@testable import AbstractCore

/// ABS-96: plugins appear in more places than their one sidebar screen.
@Suite struct PluginContributionTests {
    let fm = FileManager.default

    func manifestJSON(contributes: [String: Any], capabilities: [String] = ["chats.read"]) throws -> PluginManifest {
        let object: [String: Any] = [
            "api": 1, "id": "sh.abstract.chat-panel", "name": "Chat panel", "version": "1.0.0",
            "entry": "index.html", "capabilities": capabilities, "contributes": contributes,
        ]
        return try PluginManifest.decode(JSONSerialization.data(withJSONObject: object))
    }

    var fullContributes: [String: Any] {
        [
            "views": [["id": "main", "title": "Chat panel", "symbol": "rectangle.righthalf.inset.filled", "location": "main"]],
            "chatPanelTabs": [["id": "chat", "title": "Chat panel"]],
            "chatMenuItems": [["id": "log-chat", "title": "Log this chat"]],
            "paletteCommands": [["id": "open", "title": "Open Chat panel"]],
            "settingsPage": ["id": "settings", "title": "Chat panel settings"],
            "homeWidgets": [["id": "widget", "title": "Chat panel"]],
        ]
    }

    func expectInvalid(_ manifest: PluginManifest) {
        #expect(throws: PluginValidationError.self) { try manifest.validate() }
    }

    // MARK: Manifest

    @Test func everyPlaceDecodesAndValidates() throws {
        let manifest = try manifestJSON(contributes: fullContributes)
        try manifest.validate()
        #expect(manifest.contributes.chatPanelTabs.map(\.id) == ["chat"])
        #expect(manifest.contributes.chatMenuItems.map(\.id) == ["log-chat"])
        #expect(manifest.contributes.paletteCommands.map(\.id) == ["open"])
        #expect(manifest.contributes.settingsPage?.id == "settings")
        #expect(manifest.contributes.homeWidgets.map(\.id) == ["widget"])
    }

    @Test func anOldManifestWithoutTheNewPlacesStillReads() throws {
        let manifest = try manifestJSON(contributes: [
            "views": [["id": "main", "title": "Chat panel", "location": "main"]],
        ])
        try manifest.validate()
        #expect(manifest.contributes.chatPanelTabs.isEmpty)
        #expect(manifest.contributes.settingsPage == nil)
    }

    @Test func aPluginWithOnlyAChatPanelTabIsValid() throws {
        let manifest = try manifestJSON(contributes: [
            "chatPanelTabs": [["id": "chat", "title": "Chat panel"]],
        ])
        try manifest.validate()
        #expect(manifest.view == nil)
    }

    @Test func badContributionsAreRefused() throws {
        // Nothing contributed at all.
        expectInvalid(try manifestJSON(contributes: [:]))
        // Two sidebar screens.
        expectInvalid(try manifestJSON(contributes: [
            "views": [["id": "a", "title": "A", "location": "main"], ["id": "b", "title": "B", "location": "main"]],
        ]))
        // Duplicate ids in one place.
        expectInvalid(try manifestJSON(contributes: [
            "chatPanelTabs": [["id": "chat", "title": "One"], ["id": "chat", "title": "Two"]],
        ]))
        // Empty and over-long titles, empty id.
        expectInvalid(try manifestJSON(contributes: ["chatMenuItems": [["id": "x", "title": ""]]]))
        expectInvalid(try manifestJSON(contributes: [
            "paletteCommands": [["id": "x", "title": String(repeating: "x", count: 41)]],
        ]))
        expectInvalid(try manifestJSON(contributes: ["homeWidgets": [["id": "", "title": "Widget"]]]))
        expectInvalid(try manifestJSON(contributes: ["settingsPage": ["id": "s", "title": ""]]))
    }

    @Test func theReviewNamesEveryPlacePluginAppears() throws {
        let manifest = try manifestJSON(contributes: fullContributes)
        let sentences = manifest.appearanceSentences.joined(separator: "\n")
        #expect(sentences.contains("side panel"))
        #expect(sentences.contains("More menu"))
        #expect(sentences.contains("⌘K"))
        #expect(sentences.contains("Settings"))
        #expect(sentences.contains("Home"))
        #expect(sentences.contains("Log this chat"))
    }

    // MARK: Host context per place

    func chatRow() -> PluginSnapshot.Chat {
        PluginSnapshot.Chat(id: "chat-1", title: "Fix the thing", projectKey: nil, agentId: "claude",
                            branch: nil, status: "working", progress: .working, pinned: false, archived: false,
                            createdAt: "2026-01-01T00:00:00Z", lastActivityAt: "2026-01-01T00:00:00Z",
                            hasChanges: nil, backgroundTasks: 0, pullRequest: nil, macId: "mac-1")
    }

    func context(capabilities: Set<PluginCapability>, placement: PluginPlacement?) -> JSONValue {
        PluginContext.jsonValue(theme: .graphite, locale: "en_US", pluginId: "sh.abstract.chat-panel",
                                pluginVersion: "1.0.0", capabilities: capabilities,
                                placement: placement, chat: placement?.chatId != nil ? chatRow() : nil)
    }

    @Test func aChatPanelTabGetsTheChatIdAndItsSnapshotOnlyWithTheGrant() {
        let placement = PluginPlacement(place: .chatPanel, contributionId: "chat", chatId: "chat-1")
        let granted = context(capabilities: [.chatsRead], placement: placement)
        #expect(granted["place"] == .string("chatPanel"))
        #expect(granted["contributionId"] == .string("chat"))
        #expect(granted["chatId"] == .string("chat-1"))
        #expect(granted["chat"]?["title"] == .string("Fix the thing"))

        let ungranted = context(capabilities: [], placement: placement)
        #expect(ungranted["chatId"] == .string("chat-1"))
        #expect(ungranted["chat"] == nil)
        #expect(!ungranted.compact().contains("Fix the thing"))
    }

    @Test func placesWithoutAChatGetNoChat() {
        let palette = context(capabilities: [.chatsRead],
                              placement: PluginPlacement(place: .palette, contributionId: "open"))
        #expect(palette["place"] == .string("palette"))
        #expect(palette["chatId"] == nil)
        #expect(palette["chat"] == nil)

        let main = context(capabilities: [.chatsRead], placement: nil)
        #expect(main["place"] == nil)
        #expect(main["chat"] == nil)
    }

    @Test func anInvocationCarriesItsPlaceItemAndChat() {
        let value = PluginInvocation(place: .chatMenu, contributionId: "log-chat", chatId: "chat-1").jsonValue()
        #expect(value["place"] == .string("chatMenu"))
        #expect(value["contributionId"] == .string("log-chat"))
        #expect(value["chatId"] == .string("chat-1"))
        #expect(PluginInvocation(place: .palette, contributionId: "open").jsonValue()["chatId"] == nil)
    }

    // MARK: Resolution: enabling adds them, disabling removes them

    @Test func disablingRemovesEveryContribution() throws {
        let root = fm.temporaryDirectory.appendingPathComponent("abstract-plugin-places-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let folder = root.appendingPathComponent("pkg")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let object: [String: Any] = [
            "api": 1, "id": "sh.abstract.chat-panel", "name": "Chat panel", "version": "1.0.0",
            "entry": "index.html", "capabilities": ["chats.read"], "contributes": fullContributes,
        ]
        try JSONSerialization.data(withJSONObject: object).write(to: folder.appendingPathComponent("manifest.json"))
        try "<html>hi</html>".write(to: folder.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)

        let manager = PluginManager(store: try Store.inMemory(),
                                     pluginsRoot: root.appendingPathComponent("Plugins"),
                                     dataRoot: root.appendingPathComponent("PluginData"))
        let record = try manager.install(from: folder, sourceKind: .user)
        #expect(PluginContributions.resolve(manager.installed()).isEmpty)

        manager.setEnabled(record.id, true)
        let resolved = PluginContributions.resolve(manager.installed())
        #expect(Set(resolved.map(\.place)) == [.main, .chatPanel, .chatMenu, .palette, .settings, .home])
        #expect(PluginContributions.resolve(manager.installed(), place: .chatPanel).map(\.contribution.title) == ["Chat panel"])

        manager.setEnabled(record.id, false)
        #expect(PluginContributions.resolve(manager.installed()).isEmpty)
    }

    // MARK: The side-panel tab

    @Test func aPluginTabOpensOnceInTheSidePanelAndLeavesWithItsPlugin() {
        var layout = PanelLayout.standard()
        let first = PluginContributions.paneItemId(pluginId: "sh.abstract.chat-panel", contributionId: "chat")
        let second = PluginContributions.paneItemId(pluginId: "sh.example.other", contributionId: "tab")
        #expect(PluginContributions.parsePaneItemId(first)?.pluginId == "sh.abstract.chat-panel")
        #expect(PluginContributions.parsePaneItemId(first)?.contributionId == "chat")
        #expect(PluginContributions.parsePaneItemId("plain-uuid") == nil)

        layout.showPluginTab(paneItemId: first)
        layout.showPluginTab(paneItemId: first)
        layout.showPluginTab(paneItemId: second)
        #expect(layout.items(of: .plugin).count == 2)
        #expect(layout.side.tabs.contains { $0.id == first })
        #expect(layout.side.active?.id == second)

        layout.removePluginTabs(pluginId: "sh.abstract.chat-panel")
        #expect(layout.items(of: .plugin).map(\.id) == [second])
        #expect(layout.items(of: .changes).count == 1)
    }

    // MARK: The bundled sample (Done when)

    var sampleFolder: URL {
        let here = URL(fileURLWithPath: #filePath)
        let repo = here.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return repo.appendingPathComponent("Abstract/Resources/Plugins/chat-panel.abstractplugin")
    }

    @Test func theBundledChatPanelSampleShowsTheChatAndLogsInvocations() throws {
        let inspection = try PluginPackage.inspect(folder: sampleFolder)
        #expect(inspection.manifest.contributes.chatPanelTabs.map(\.id) == ["chat"])
        #expect(inspection.manifest.contributes.chatMenuItems.map(\.id) == ["log-chat"])
        #expect(inspection.manifest.contributes.paletteCommands.map(\.id) == ["open"])

        let source = try String(contentsOf: sampleFolder.appendingPathComponent("panel.js"), encoding: .utf8)
        let context = try #require(JSContext())
        context.evaluateScript(source)
        #expect(context.exception == nil)

        // The tab shows its chat's title from the host context…
        let granted = self.context(capabilities: [.chatsRead],
                                   placement: PluginPlacement(place: .chatPanel, contributionId: "chat", chatId: "chat-1"))
        context.setObject([granted.compact()], forKeyedSubscript: "__texts" as NSString)
        let title = context.evaluateScript("ChatPanel.chatTitle(JSON.parse(__texts[0]), null)")?.toString()
        #expect(title == "Fix the thing")

        // …and nothing of the chat without the grant.
        let ungranted = self.context(capabilities: [],
                                     placement: PluginPlacement(place: .chatPanel, contributionId: "chat", chatId: "chat-1"))
        context.setObject([ungranted.compact()], forKeyedSubscript: "__texts" as NSString)
        let hidden = context.evaluateScript("ChatPanel.chatTitle(JSON.parse(__texts[0]), null)")
        #expect(hidden?.isNull == true)

        // The menu item logs the chat's id; the ⌘K command logs itself.
        let menu = PluginInvocation(place: .chatMenu, contributionId: "log-chat", chatId: "chat-1").jsonValue().compact()
        context.setObject([menu], forKeyedSubscript: "__texts" as NSString)
        let line = context.evaluateScript("ChatPanel.logLine(JSON.parse(__texts[0]))")?.toString() ?? ""
        #expect(line.contains("chat-1"))
        let palette = PluginInvocation(place: .palette, contributionId: "open").jsonValue().compact()
        context.setObject([palette], forKeyedSubscript: "__texts" as NSString)
        #expect(context.evaluateScript("ChatPanel.logLine(JSON.parse(__texts[0]))")?.toString()?.contains("⌘K") == true)
    }

    @Test func oldSavedLayoutsStillDecode() throws {
        let json = #"{"side":{"tabs":[{"id":"a","kind":"changes"}],"activeId":"a","isOpen":true,"size":460},"bottom":{"tabs":[],"activeId":null,"isOpen":false,"size":240}}"#
        let layout = try JSONDecoder().decode(PanelLayout.self, from: Data(json.utf8))
        #expect(layout.side.active?.kind == .changes)
    }
}
