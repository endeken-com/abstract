import Foundation
import JavaScriptCore
import Testing
@testable import AbstractCore

/// The bundled Lessons plugin (ABS-102): a chat menu item that has the
/// chat's own agent write what it learned into the project's instructions
/// or a skill, as an edit you review. Its logic is plain JavaScript, so
/// these tests run the shipped script.
@Suite struct LessonsPluginTests {
    let fm = FileManager.default

    var pluginFolder: URL {
        let here = URL(fileURLWithPath: #filePath)
        let repo = here.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return repo.appendingPathComponent("Abstract/Resources/Plugins/lessons.abstractplugin")
    }

    /// Runs `Lessons.<call>` and returns its result as JSON.
    func evaluate(_ call: String) throws -> JSONValue {
        let source = try String(contentsOf: pluginFolder.appendingPathComponent("lessons.js"), encoding: .utf8)
        let context = try #require(JSContext())
        context.evaluateScript(source)
        let result = context.evaluateScript("JSON.stringify(Lessons.\(call))")
        if let exception = context.exception {
            Issue.record("Lessons.\(call) threw: \(exception.toString() ?? "?")")
            return .null
        }
        let text = try #require(result?.toString())
        if text == "undefined" { return .null }
        return JSONValue(any: try JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed))
    }

    func request(_ target: String, skill: String = "") throws -> String {
        try #require(try evaluate("request('\(target)', '\(skill)')").string)
    }

    // MARK: The package

    @Test func theBundledPackageInstallsAsAChatMenuItemThatNeedsReadingAndMessaging() throws {
        let manifest = try PluginPackage.inspect(folder: pluginFolder).manifest
        #expect(manifest.id == "sh.abstract.lessons")
        #expect(manifest.grantedCapabilities == [.chatsRead, .chatsOpen, .chatsMessage])
        #expect(manifest.view == nil)
        let save = try #require(manifest.contributes.chatMenuItems.first)
        #expect(save.title == "Save What We Learned…")
        #expect(Set(save.needs ?? []) == [.chatsRead, .chatsMessage])
        // And beside a chat, as a side-panel tab that works on that chat (ABS-134).
        let tab = try #require(manifest.contributes.chatPanelTabs.first)
        #expect(Set(tab.needs ?? []) == [.chatsRead, .chatsMessage])
        #expect(manifest.appearanceSentences == [
            "Lessons — a tab in a chat's side panel, next to Review, Files and Terminal.",
            "Save What We Learned… — an item in a chat's More menu.",
        ])
    }

    // MARK: The request, per target

    @Test func everyTargetAsksForAMinimalUncommittedEditOfTheChatsLessons() throws {
        for target in ["instructions", "newSkill", "existingSkill"] {
            let text = try request(target)
            #expect(text.contains("what we learned"), "\(target)")
            #expect(text.contains("minimal edit"), "\(target)")
            #expect(text.contains("change nothing else"), "\(target)")
            #expect(text.contains("Don't commit"), "\(target)")
            #expect(text.contains("home directories, accounts or secrets"), "\(target)")
        }
    }

    @Test func projectInstructionsGoToAgentsMdOrClaudeMdAtTheRoot() throws {
        let text = try request("instructions")
        #expect(text.contains("AGENTS.md or CLAUDE.md at the root of this repository"))
        #expect(text.contains("if CLAUDE.md only points to AGENTS.md"))
        #expect(text.contains("If neither exists, create AGENTS.md"))
        #expect(!text.contains("SKILL.md"))
    }

    @Test func aNewSkillIsNamedByYouOrByTheAgentInsideTheRepository() throws {
        let named = try request("newSkill", skill: "Release Checklist!")
        #expect(named.contains("a new skill named “release-checklist”"))
        #expect(named.contains("inside this repository"))
        #expect(named.contains(".claude/skills/<name>/SKILL.md"))
        #expect(named.contains("If a skill like it already exists, tell me"))

        let unnamed = try request("newSkill")
        #expect(unnamed.contains("with a short, lowercase, hyphenated name"))
        #expect(!unnamed.contains("named “"))
    }

    @Test func anExistingSkillIsTheOneYouNameOrTheOneTheyFitBest() throws {
        let named = try request("existingSkill", skill: "build")
        #expect(named.contains("Add them to this project's skill “build”"))
        #expect(named.contains("If there's no such skill inside this repository, tell me and change nothing"))

        let unnamed = try request("existingSkill")
        #expect(unnamed.contains("the skill in this project they fit best"))
        #expect(unnamed.contains("If no skill inside this repository fits"))
    }

    @Test func anUnknownTargetHasNoRequest() throws {
        #expect(try evaluate("request('somewhere')") == .null)
    }

    @Test func skillNamesBecomeFolderNames() throws {
        #expect(try evaluate("skillName('  Run the UI Tests  ')") == .string("run-the-ui-tests"))
        #expect(try evaluate("skillName('../../etc')") == .string("etc"))
        #expect(try evaluate("skillName('!!!')") == .string(""))
        #expect(try evaluate("skillName('\(String(repeating: "a-", count: 50))')").string?.count == 63)
    }

    @Test func theScreenFindsTheChatItWasChosenOn() throws {
        let snapshot = #"{"chats":[{"id":"a","title":"Fix the build"},{"id":"b","title":"Other"}]}"#
        #expect(try evaluate("chatOf(\(snapshot), 'a').title") == .string("Fix the build"))
        #expect(try evaluate("chatOf(\(snapshot), 'zzz')") == .null)
        #expect(try evaluate("chatOf(null, 'a')") == .null)
    }

    /// Exactly what the screen sends, through the host's own checks: it
    /// asks first until you always allow messages from it.
    @Test func theRequestIsSentToTheChatThroughTheBridge() throws {
        let text = try request("instructions")
        var bridge = PluginBridge(capabilities: [.chatsRead, .chatsOpen, .chatsMessage])
        bridge.knownChatIds = ["chat-1"]
        let message = JSONValue.object(["api": .number(2), "type": .string("sendMessage"), "id": .string("1"),
                                        "payload": .object(["chatId": .string("chat-1"), "text": .string(text)])]).compact()
        let storage = PluginStorage(directory: fm.temporaryDirectory, pluginId: "sh.abstract.lessons")
        let outcome = bridge.handle(message, storage: storage)
        #expect(outcome == .askAction(id: "1", PluginAction(capability: .chatsMessage, chatId: "chat-1", text: text)))
    }

    // MARK: The menu item shows only with the right grants

    @Test func theMenuItemShowsOnlyWhileReadingAndMessagingAreGranted() throws {
        let root = fm.temporaryDirectory.appendingPathComponent("abstract-lessons-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let manager = PluginManager(store: try Store.inMemory(),
                                     pluginsRoot: root.appendingPathComponent("Plugins"),
                                     dataRoot: root.appendingPathComponent("PluginData"))
        let record = try manager.install(from: pluginFolder, sourceKind: .bundled)
        func menu() -> [String] {
            PluginContributions.resolve(manager.installed(), place: .chatMenu).map(\.contribution.title)
        }
        #expect(menu().isEmpty)

        manager.setEnabled(record.id, true)
        #expect(menu() == ["Save What We Learned…"])

        // Opening the chat afterwards is a nicety; the item still works.
        manager.revokeCapability(record.id, .chatsOpen)
        #expect(menu() == ["Save What We Learned…"])

        manager.revokeCapability(record.id, .chatsMessage)
        #expect(menu().isEmpty)

        // Turning it off and on reviews the whole list again.
        manager.setEnabled(record.id, false)
        manager.setEnabled(record.id, true)
        #expect(menu() == ["Save What We Learned…"])

        manager.revokeCapability(record.id, .chatsRead)
        #expect(menu().isEmpty)
    }

    @Test func anItemCanOnlyNeedWhatItsPluginAsksFor() throws {
        func manifest(capabilities: [String], needs: [String]) throws -> PluginManifest {
            let object: [String: Any] = [
                "api": 2, "id": "sh.example.lessons", "name": "Lessons", "version": "1.0.0",
                "entry": "index.html", "capabilities": capabilities,
                "contributes": ["chatMenuItems": [["id": "save", "title": "Save", "needs": needs]]],
            ]
            return try PluginManifest.decode(JSONSerialization.data(withJSONObject: object))
        }
        try manifest(capabilities: ["chats.read", "chats.message"], needs: ["chats.message"]).validate()
        #expect(throws: PluginValidationError.self) {
            try manifest(capabilities: ["chats.read"], needs: ["chats.message"]).validate()
        }
        #expect(throws: PluginValidationError.self) {
            try manifest(capabilities: ["chats.read"], needs: ["chats.everything"])
        }
    }
}
