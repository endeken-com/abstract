import Foundation
import Testing
@testable import AbstractCore

/// Plugin API 2 actions (ABS-92): a plugin may act on chats only under a
/// granted action capability, each kind asks first until always allowed,
/// and flooding actions pauses the plugin.
@Suite struct PluginActionTests {
    let fm = FileManager.default

    func tempRoot() throws -> URL {
        let url = fm.temporaryDirectory.appendingPathComponent("abstract-plugin-action-tests-\(UUID().uuidString)")
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func storage(root: URL) throws -> PluginStorage {
        let dir = root.appendingPathComponent("PluginData")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return PluginStorage(directory: dir, pluginId: "sh.abstract.kanban")
    }

    func makeBridge(_ capabilities: Set<PluginCapability>, always: Set<PluginCapability> = []) -> PluginBridge {
        var bridge = PluginBridge(capabilities: capabilities, alwaysAllowedActions: always)
        bridge.knownChatIds = ["chat-1"]
        bridge.knownProjectKeys = ["mac-1:project-1"]
        return bridge
    }

    // MARK: Manifest

    @Test func api2ManifestsMayAskForActionsAndApi1MayNot() throws {
        let actions = PluginManifest(id: "sh.abstract.kanban", name: "Kanban", version: "2.0.0",
                                       capabilities: ["chats.read", "chats.message", "automations.run"],
                                       views: [.init(id: "board", title: "Kanban")])
        #expect(actions.api == 2)
        try actions.validate()
        #expect(actions.grantedCapabilities.contains(.chatsMessage))
        #expect(PluginCapability.chatsMessage.isAction)
        #expect(!PluginCapability.chatsRead.isAction)
        #expect(Set(PluginCapability.actionCases) == [.chatsCreate, .chatsMessage, .chatsControl,
                                                       .permissionsAnswer, .automationsRun])

        var old = actions
        old.api = 1
        #expect(throws: PluginValidationError.self) { try old.validate() }

        var future = actions
        future.api = 3
        #expect(throws: PluginValidationError.self) { try future.validate() }

        let unknown = PluginManifest(id: "sh.abstract.kanban", name: "Kanban", version: "2.0.0",
                                       capabilities: ["chats.delete"],
                                       views: [.init(id: "board", title: "Kanban")])
        do {
            try unknown.validate()
            Issue.record("an unknown capability installed")
        } catch let error as PluginValidationError {
            if case .unknownCapability("chats.delete") = error {} else {
                Issue.record("unexpected refusal: \(error.detail)")
            }
        }
    }

    @Test func actionCapabilitiesReadInPlainWords() {
        #expect(PluginCapability.chatsCreate.plainWords == "Start chats in your projects")
        #expect(PluginCapability.chatsMessage.plainWords == "Send messages to your chats")
        #expect(PluginCapability.chatsControl.plainWords == "Stop and resume your agents")
        #expect(PluginCapability.permissionsAnswer.plainWords == "Answer your agents' questions and permission requests")
        #expect(PluginCapability.automationsRun.plainWords == "Run your automations")
    }

    // MARK: Bridge gating

    @Test func sendMessageAsksFirstThenAlwaysAllowSkipsTheAsk() throws {
        let root = try tempRoot()
        let store = try storage(root: root)
        let message = #"{"api":2,"type":"sendMessage","id":"1","payload":{"chatId":"chat-1","text":"Please rebase."}}"#

        var asking = makeBridge([.chatsMessage])
        let asked = asking.handle(message, storage: store)
        guard case .askAction(let id, let action) = asked else {
            Issue.record("a first action didn't ask: \(asked)"); return
        }
        #expect(id == "1")
        #expect(action.capability == .chatsMessage)
        #expect(action.chatId == "chat-1")
        #expect(action.text == "Please rebase.")

        var allowed = makeBridge([.chatsMessage], always: [.chatsMessage])
        let done = allowed.handle(message, storage: store)
        guard case .action(_, let same) = done else {
            Issue.record("an always-allowed action didn't go through: \(done)"); return
        }
        #expect(same == action)
    }

    @Test func withoutTheGrantNothingReachesTheAgent() throws {
        let root = try tempRoot()
        let store = try storage(root: root)
        var bridge = makeBridge([.chatsRead])
        let refused = bridge.handle(
            #"{"api":2,"type":"sendMessage","id":"1","payload":{"chatId":"chat-1","text":"hi"}}"#, storage: store)
        guard case .refused = refused else { Issue.record("an ungranted action wasn't refused: \(refused)"); return }

        // Revoked after being granted: the next call is refused too.
        var revoked = makeBridge([.chatsMessage], always: [.chatsMessage])
        revoked.capabilities.remove(.chatsMessage)
        let afterRevoke = revoked.handle(
            #"{"api":2,"type":"sendMessage","id":"2","payload":{"chatId":"chat-1","text":"hi"}}"#, storage: store)
        guard case .refused = afterRevoke else { Issue.record("a revoked action wasn't refused: \(afterRevoke)"); return }
    }

    @Test func everyActionKindNeedsItsOwnCapability() throws {
        let root = try tempRoot()
        let store = try storage(root: root)
        let cases: [(String, PluginCapability)] = [
            (#"{"api":2,"type":"createChat","id":"1","payload":{"projectKey":"mac-1:project-1","prompt":"Fix it","agentId":"claude","policy":"ask"}}"#, .chatsCreate),
            (#"{"api":2,"type":"controlChat","id":"2","payload":{"chatId":"chat-1","control":"stop"}}"#, .chatsControl),
            (#"{"api":2,"type":"answerPermission","id":"3","payload":{"chatId":"chat-1","requestId":"r1","allow":true}}"#, .permissionsAnswer),
            (#"{"api":2,"type":"answerQuestion","id":"4","payload":{"chatId":"chat-1","requestId":"r1","answers":{"Which?":"That one"}}}"#, .permissionsAnswer),
            (#"{"api":2,"type":"runAutomation","id":"5","payload":{"automationId":"a1"}}"#, .automationsRun),
        ]
        for (message, capability) in cases {
            var granted = makeBridge([capability], always: [capability])
            let outcome = granted.handle(message, storage: store)
            guard case .action(_, let action) = outcome else {
                Issue.record("\(capability.rawValue) didn't act when granted: \(outcome)"); continue
            }
            #expect(action.capability == capability)

            var ungranted = makeBridge([.chatsRead])
            let refused = ungranted.handle(message, storage: store)
            guard case .refused = refused else {
                Issue.record("\(capability.rawValue) acted without its grant: \(refused)"); continue
            }
        }
    }

    @Test func actionPayloadsAreCheckedBeforeAnythingActs() throws {
        let root = try tempRoot()
        let store = try storage(root: root)
        var bridge = makeBridge(Set(PluginCapability.actionCases), always: Set(PluginCapability.actionCases))
        let bad = [
            // A chat the plugin was never shown.
            #"{"api":2,"type":"sendMessage","id":"1","payload":{"chatId":"made-up","text":"hi"}}"#,
            // Empty text.
            #"{"api":2,"type":"sendMessage","id":"2","payload":{"chatId":"chat-1","text":"  "}}"#,
            // A project the plugin was never shown.
            #"{"api":2,"type":"createChat","id":"3","payload":{"projectKey":"mac-9:nope","prompt":"Fix it"}}"#,
            // A policy outside the autonomy levels.
            #"{"api":2,"type":"createChat","id":"4","payload":{"prompt":"Fix it","policy":"yolo"}}"#,
            // An unknown control.
            #"{"api":2,"type":"controlChat","id":"5","payload":{"chatId":"chat-1","control":"delete"}}"#,
            // No request to answer.
            #"{"api":2,"type":"answerPermission","id":"6","payload":{"chatId":"chat-1","allow":true}}"#,
            // No automation named.
            #"{"api":2,"type":"runAutomation","id":"7","payload":{}}"#,
        ]
        for message in bad {
            let outcome = bridge.handle(message, storage: store)
            guard case .refused = outcome else {
                Issue.record("a bad action wasn't refused: \(message) -> \(outcome)"); continue
            }
        }
    }

    @Test func theAskNamesThePluginAndWhatItWillDo() throws {
        let root = try tempRoot()
        let store = try storage(root: root)
        var bridge = makeBridge([.chatsMessage])
        let outcome = bridge.handle(
            #"{"api":2,"type":"sendMessage","id":"1","payload":{"chatId":"chat-1","text":"Please rebase."}}"#,
            storage: store)
        guard case .askAction(_, let action) = outcome else { Issue.record("didn't ask: \(outcome)"); return }
        #expect(action.describe(pluginName: "Kanban", chatTitle: "Fix login")
            == "Kanban wants to send a message to “Fix login”.")
        #expect(action.detail == "Please rebase.")
    }

    // MARK: Rate limit

    @Test func floodingActionsPausesThePlugin() throws {
        let root = try tempRoot()
        let store = try storage(root: root)
        var bridge = makeBridge([.chatsMessage], always: [.chatsMessage])
        let now = Date(timeIntervalSince1970: 10_000)
        let message = #"{"api":2,"type":"sendMessage","id":"1","payload":{"chatId":"chat-1","text":"hi"}}"#
        for _ in 0..<PluginBridge.actionLimit {
            let outcome = bridge.handle(message, storage: store, now: now)
            guard case .action = outcome else { Issue.record("an action inside the limit stopped: \(outcome)"); return }
        }
        let flooded = bridge.handle(message, storage: store, now: now.addingTimeInterval(30))
        #expect(flooded == .actionRateLimited(id: "1"))

        // After the minute, actions go through again.
        let later = bridge.handle(message, storage: store, now: now.addingTimeInterval(61))
        guard case .action = later else { Issue.record("an action after the window didn't go through: \(later)"); return }
    }

    // MARK: Grants, revocation, upgrades

    func package(in root: URL, version: String, capabilities: [String]) throws -> URL {
        let folder = root.appendingPathComponent("pkg-\(UUID().uuidString)")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let manifest: [String: Any] = [
            "api": 2, "id": "sh.abstract.kanban", "name": "Kanban", "version": version,
            "entry": "index.html", "capabilities": capabilities,
            "contributes": ["views": [["id": "board", "title": "Kanban", "location": "main"]]],
        ]
        try JSONSerialization.data(withJSONObject: manifest)
            .write(to: folder.appendingPathComponent("manifest.json"))
        try "<html>hi</html>".write(to: folder.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        return folder
    }

    @Test func alwaysAllowAndRevokeSurviveRelaunch() throws {
        let root = try tempRoot()
        let host = PluginManager(store: try Store.inMemory(),
                                 pluginsRoot: root.appendingPathComponent("Plugins"),
                                 dataRoot: root.appendingPathComponent("PluginData"))
        let record = try host.install(from: package(in: root, version: "2.0.0",
                                                    capabilities: ["chats.read", "chats.message"]), sourceKind: .user)
        host.setEnabled(record.id, true)
        host.setAlwaysAllowed(record.id, .chatsMessage, true)

        let second = PluginManager(store: host.store, pluginsRoot: host.pluginsRoot, dataRoot: host.dataRoot)
        #expect(second.records().first?.alwaysAllowedActions == [.chatsMessage])

        // Revoking the grant takes the always-allow with it.
        second.revokeCapability(record.id, .chatsMessage)
        let revoked = try #require(second.records().first)
        #expect(!revoked.grantedCapabilities.contains(.chatsMessage))
        #expect(revoked.alwaysAllowedActions.isEmpty)
        #expect(revoked.grantedCapabilities.contains(.chatsRead))

        // Back to asking first is its own, smaller step.
        second.setEnabled(record.id, true)
        #expect(second.records().first?.grantedCapabilities.contains(.chatsMessage) == true)
        second.setAlwaysAllowed(record.id, .chatsMessage, true)
        second.setAlwaysAllowed(record.id, .chatsMessage, false)
        #expect(second.records().first?.alwaysAllowedActions.isEmpty == true)
        #expect(second.records().first?.grantedCapabilities.contains(.chatsMessage) == true)
    }

    @Test func anUpdateAskingForActionsWaitsForApproval() throws {
        let root = try tempRoot()
        let host = PluginManager(store: try Store.inMemory(),
                                 pluginsRoot: root.appendingPathComponent("Plugins"),
                                 dataRoot: root.appendingPathComponent("PluginData"))
        let record = try host.install(from: package(in: root, version: "2.0.0",
                                                    capabilities: ["chats.read"]), sourceKind: .user)
        host.setEnabled(record.id, true)

        let updated = try host.install(from: package(in: root, version: "2.1.0",
                                                     capabilities: ["chats.read", "chats.message"]), sourceKind: .user)
        #expect(updated.enabled == false)
        #expect(updated.grantedCapabilities.isEmpty)
        #expect(updated.alwaysAllowedActions.isEmpty)

        // An update asking for no more keeps the grant and the always-allow.
        host.setEnabled(record.id, true)
        host.setAlwaysAllowed(record.id, .chatsMessage, true)
        let same = try host.install(from: package(in: root, version: "2.2.0",
                                                  capabilities: ["chats.read", "chats.message"]), sourceKind: .user)
        #expect(same.enabled == true)
        #expect(same.alwaysAllowedActions == [.chatsMessage])
    }
}
