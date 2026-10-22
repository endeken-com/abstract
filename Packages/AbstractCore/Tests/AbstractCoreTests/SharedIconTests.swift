import Foundation
import Testing
@testable import AbstractCore

@Suite struct SharedIconTests {
    @Test func oldSymbolsSurviveMigrationAndNewChoicesRoundTrip() throws {
        let store = try Store.inMemory(migratedTo: "v22-tracker-attachments", thenRunning: """
            INSERT INTO profiles (id, name, icon_symbol, created_at)
            VALUES ('profile', 'Reviewer', 'magnifyingglass', '2026-10-01 12:00:00.000');
            INSERT INTO workflows (id, name, icon_symbol, created_at)
            VALUES ('workflow', 'Review', 'checkmark.seal', '2026-10-01 12:00:00.000');
            """)
        var profile = try #require(try store.profile("profile"))
        var workflow = try #require(try store.workflow("workflow"))
        #expect(profile.iconValue == IconValue(symbol: "magnifyingglass"))
        #expect(workflow.iconValue == IconValue(symbol: "checkmark.seal"))

        profile.iconValue = IconValue(symbol: "hammer", color: "sage", imagePath: "/managed/profile.png")
        workflow.iconValue = IconValue(color: "rose", imagePath: "/managed/workflow.png")
        try store.save(profile)
        try store.save(workflow)
        #expect(try store.profile("profile")?.iconValue == profile.iconValue)
        #expect(try store.workflow("workflow")?.iconValue == workflow.iconValue)
    }

    @Test func olderJSONUsesTheDefaultForMissingIconFields() throws {
        let profile = try JSONDecoder().decode(AgentProfile.self, from: Data(#"{"id":"p","name":"Reviewer","iconSymbol":"magnifyingglass"}"#.utf8))
        let workflow = try JSONDecoder().decode(Workflow.self, from: Data(#"{"id":"w","name":"Review","iconSymbol":"checkmark.seal"}"#.utf8))
        let running = try JSONDecoder().decode(WorkflowSnapshot.self, from: Data(#"{"id":"w","name":"Review","steps":[]}"#.utf8))
        #expect(profile.iconValue == IconValue(symbol: "magnifyingglass"))
        #expect(workflow.iconValue == IconValue(symbol: "checkmark.seal"))
        #expect(running.icon == nil)
    }

    @Test func pluginFieldsAreIsolatedAndBounded() throws {
        let store = try Store.inMemory()
        let value = IconValue(symbol: "hammer", color: "plum", imagePath: "/managed/image.png")
        try store.savePluginIcon(value, pluginId: "one", key: "my.icon")
        #expect(store.pluginIcon(pluginId: "one", key: "my.icon") == value)
        #expect(store.pluginIcon(pluginId: "two", key: "my.icon") == nil)
        #expect(throws: (any Error).self) { try store.savePluginIcon(value, pluginId: "one", key: "../private") }
        for index in 0..<(PluginIconFields.limit - 1) {
            try store.savePluginIcon(value, pluginId: "one", key: "field-\(index)")
        }
        #expect(throws: (any Error).self) { try store.savePluginIcon(value, pluginId: "one", key: "one-too-many") }
        #expect(try store.deletePluginIcons(pluginId: "one").count == PluginIconFields.limit)
        #expect(store.pluginIcon(pluginId: "one", key: "my.icon") == nil)
    }

    @Test func remoteImagesAreBoundedDataAndOptionalForOlderPeers() throws {
        let bytes = Data([0x89, 0x50, 0x4e, 0x47])
        let current = RemoteSnapshot(projects: [], sessions: [], providers: [], alive: [],
                                     profileIcons: ["profile": bytes], workflowIcons: ["workflow": bytes])
        let decoded = try JSONDecoder().decode(RemoteSnapshot.self, from: JSONEncoder().encode(current))
        #expect(decoded.profileIcons?["profile"] == bytes)
        #expect(decoded.workflowIcons?["workflow"] == bytes)
        let old = try JSONDecoder().decode(RemoteSnapshot.self, from: Data(#"{"projects":[],"sessions":[],"providers":[],"alive":[]}"#.utf8))
        #expect(old.profileIcons == nil && old.workflowIcons == nil)
    }

    @Test func onlyVisibleScreensCanRequestTheHostPicker() {
        let storage = PluginStorage(directory: FileManager.default.temporaryDirectory, pluginId: "test-icons")
        let get = #"{"api":2,"type":"icon.get","id":"1","payload":{"key":"avatar"}}"#
        let choose = #"{"api":2,"type":"icon.choose","id":"2","payload":{"key":"avatar","anchor":{"x":3,"y":4,"width":20,"height":20}}}"#
        var screen = PluginBridge(capabilities: [])
        #expect(screen.handle(get, storage: storage) == .iconGet(id: "1", key: "avatar"))
        #expect(screen.handle(choose, storage: storage) == .iconChoose(id: "2", key: "avatar", anchor: PluginIconAnchor(.object([
            "x": .number(3), "y": .number(4), "width": .number(20), "height": .number(20)
        ]))!))
        var background = PluginBridge(capabilities: [])
        background.isBackground = true
        if case .refused = background.handle(get, storage: storage) {} else { Issue.record("background icon request was accepted") }
        if case .refused = screen.handle(#"{"api":2,"type":"icon.get","payload":{"key":"../other"}}"#, storage: storage) {} else {
            Issue.record("invalid key was accepted")
        }
    }
}
