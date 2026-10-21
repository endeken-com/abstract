import Foundation
import GRDB
import Testing
@testable import AbstractCore

/// ABS-141: issue trackers are plugins. A plugin declares the tracker it
/// answers for; the composer's search asks every one that's on and groups
/// what they find, and the line the agent reads stays Abstract's.
@Suite struct IssueTrackerTests {
    func manifest(_ tracker: [String: Any]?, id: String = "sh.example.tracker",
                  background: String? = "background.js") throws -> PluginManifest {
        var object: [String: Any] = [
            "api": 2, "id": id, "name": "Tracker", "version": "1.0.0", "entry": "index.html",
            "capabilities": ["network"], "network": ["hosts": ["api.example.com"]],
            "contributes": tracker.map { ["issueTracker": $0] } ?? [:],
        ]
        if let background { object["background"] = background }
        return try PluginManifest.decode(JSONSerialization.data(withJSONObject: object))
    }

    func json(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    nonisolated(unsafe) static let tracker: [String: Any] = ["title": "Example", "icon": "icon.svg", "keyExample": "EX-1",
                                         "keyPattern": "[A-Za-z]+-[0-9]+"]

    func installed(_ manifest: PluginManifest, enabled: Bool = true, background: Bool = true) -> InstalledPlugin {
        let record = PluginRecord(id: manifest.id, name: manifest.name, version: manifest.version, source: .user,
                                  enabled: enabled, grantedCapabilities: manifest.grantedCapabilities,
                                  grantedNetworkHosts: manifest.networkHosts, grantedBackground: background, packageHash: "h")
        return InstalledPlugin(record: record, manifest: manifest, problem: nil, packageURL: URL(fileURLWithPath: "/tmp"))
    }

    func resolved(_ id: String, title: String) -> ResolvedIssueTracker {
        ResolvedIssueTracker(pluginId: id, declaration: PluginIssueTrackerDeclaration(
            title: title, keyExample: "EX-1", keyPattern: "[A-Za-z]+-[0-9]+"))
    }

    // MARK: The manifest

    @Test func aTrackerIsDeclaredWithATitleAndKeysAndTheReviewNamesIt() throws {
        let manifest = try manifest(Self.tracker)
        try manifest.validate()
        #expect(manifest.contributes.issueTracker?.title == "Example")
        #expect(manifest.appearanceSentences.contains(
            "Example issues — found by the composer's issue search, to attach to your messages."))
        let declaration = try #require(manifest.contributes.issueTracker)
        #expect(declaration.isKey("EX-12"))
        #expect(declaration.isKey("ex-12"))
        #expect(!declaration.isKey("fix EX-12"))
        // A long query is never matched against the plugin's pattern.
        #expect(!declaration.isKey(String(repeating: "A", count: 60) + "-1"))
    }

    @Test func aTrackerNeedsABackgroundScriptAndSoundFields() throws {
        #expect(throws: PluginValidationError.self) { try manifest(Self.tracker, background: nil).validate() }
        for bad: [String: Any] in [
            ["title": "", "keyExample": "EX-1"],
            ["title": String(repeating: "x", count: 31), "keyExample": "EX-1"],
            ["title": "Example", "keyExample": ""],
            ["title": "Example", "keyExample": "EX-1", "icon": "../icon.svg"],
            ["title": "Example", "keyExample": "EX-1", "icon": "icon.js"],
            ["title": "Example", "keyExample": "EX-1", "keyPattern": "(unclosed"],
        ] {
            #expect(throws: PluginValidationError.self, "\(bad)") { try manifest(bad).validate() }
        }
        // A tracker is enough for a plugin to add something.
        try manifest(["title": "Example", "keyExample": "EX-1"]).validate()
    }

    @Test func onlyPluginsThatCanRunTheirScriptAreAsked() throws {
        let on = installed(try manifest(Self.tracker, id: "sh.example.b"))
        let off = installed(try manifest(Self.tracker, id: "sh.example.c"), enabled: false)
        let unreviewed = installed(try manifest(Self.tracker, id: "sh.example.d"), background: false)
        let other = installed(try manifest(nil, id: "sh.example.e"))
        #expect(PluginIssueTrackers.resolve([on, off, unreviewed, other]).map(\.pluginId) == ["sh.example.b"])
    }

    // MARK: Asking

    @Test func aKeyOrALinkIsAskedForAsOneIssueAndWordsAreSearched() {
        let tracker = resolved("sh.example.b", title: "Example").declaration
        #expect(PluginIssueTrackers.request(for: " EX-12 ", tracker: tracker) == .issue("EX-12"))
        #expect(PluginIssueTrackers.request(for: "https://example.com/issue/EX-12", tracker: tracker)
                == .issue("https://example.com/issue/EX-12"))
        #expect(PluginIssueTrackers.request(for: "login fails", tracker: tracker) == .searchIssues(query: "login fails", project: nil))
        #expect(PluginIssueTrackers.request(for: "", tracker: tracker) == .searchIssues(query: "", project: nil))
        #expect(TrackerRequest.searchIssues(query: "x", project: "team:1").input
                == .object(["query": .string("x"), "project": .string("team:1")]))
    }

    @Test func answersAreReadForWhatWasAskedAndBadIssuesAreDropped() throws {
        let issues = try json("""
            {"result":{"issues":[
              {"key":"EX-1","title":"Fix login","state":"Todo","assignee":"Ada","url":"https://example.com/EX-1","excerpt":"Steps"},
              {"key":"EX-2","title":"No link"},
              {"key":"EX 3","title":"Spaced key","url":"https://example.com/EX-3"},
              {"key":"EX-4","title":"Plain web","url":"http://example.com/EX-4"}
            ]}}
            """)
        let search = TrackerAnswer.parse(.searchIssues(query: "", project: nil), issues)
        #expect(search == .issues([TrackerIssue(key: "EX-1", title: "Fix login", state: "Todo", assignee: "Ada",
                                                url: "https://example.com/EX-1", excerpt: "Steps")]))
        #expect(TrackerAnswer.parse(.issue("EX-9"), try json(#"{"result":{"issue":null}}"#)) == .issue(nil))
        #expect(TrackerAnswer.parse(.access, try json(#"{"result":{"ready":false,"problem":"Enter a key."}}"#))
                == .access(TrackerAccess(ready: false, problem: "Enter a key.")))
        #expect(TrackerAnswer.parse(.listProjects, try json("""
            {"result":{"projects":[{"id":"team:1","name":"Engineering","kind":"team","key":"ENG"},{"id":"x","name":"Odd","kind":"epic"}]}}
            """)) == .projects([TrackerProject(id: "team:1", name: "Engineering", kind: .team, key: "ENG")]))
        // The wrong shape fails instead of showing half of it.
        #expect(TrackerAnswer.parse(.searchIssues(query: "", project: nil), try json(#"{"result":{"issue":null}}"#))
                == .failed("The tracker's answer couldn't be read."))
        #expect(TrackerAnswer.parse(.access, try json(#"{"error":"Linear said no"}"#)) == .failed("Linear said no"))
    }

    @Test func everyTrackerIsAskedAndTheirResultsAreGroupedInOrder() async {
        let fast = resolved("sh.example.a", title: "Alpha")
        let slow = resolved("sh.example.b", title: "Beta")
        let signedOut = resolved("sh.example.c", title: "Gamma")
        let groups = await PluginIssueTrackers.search("login", trackers: [fast, slow, signedOut]) { tracker, request in
            // A fake plugin per tracker.
            switch (tracker.pluginId, request) {
            case ("sh.example.c", .access): return .access(TrackerAccess(ready: false, problem: "Sign in to Gamma."))
            case (_, .access): return .access(TrackerAccess(ready: true, account: "Ada"))
            case ("sh.example.b", .searchIssues(let query, _)):
                try? await Task.sleep(for: .milliseconds(50))
                return .issues([TrackerIssue(key: "B-1", title: "Beta \(query)", url: "https://b.example.com/B-1")])
            case (_, .searchIssues(let query, _)):
                return .issues([TrackerIssue(key: "A-1", title: "Alpha \(query)", url: "https://a.example.com/A-1")])
            default: return .failed("unexpected \(request)")
            }
        }
        #expect(groups.map(\.tracker.title) == ["Alpha", "Beta", "Gamma"])
        #expect(groups[0].issues.map(\.title) == ["Alpha login"])
        #expect(groups[1].issues.map(\.title) == ["Beta login"])
        #expect(groups[2].issues.isEmpty)
        #expect(groups[2].problem == "Sign in to Gamma.")
    }

    @Test func aTrackerThatFailsSaysWhyWithoutHidingTheOthers() async {
        let groups = await PluginIssueTrackers.search("EX-1", trackers: [resolved("sh.example.a", title: "Alpha"),
                                                                        resolved("sh.example.b", title: "Beta")]) { tracker, request in
            if case .access = request { return .access(TrackerAccess(ready: true)) }
            #expect(request == .issue("EX-1"))
            return tracker.pluginId == "sh.example.a"
                ? .issue(TrackerIssue(key: "EX-1", title: "Found", url: "https://a.example.com/EX-1"))
                : .failed("Beta didn't answer within 20 seconds.")
        }
        #expect(groups[0].issues.map(\.key) == ["EX-1"])
        #expect(groups[1].problem == "Beta didn't answer within 20 seconds.")
    }

    // MARK: The bridge

    @Test func onlyABackgroundScriptAnswersForItsTracker() {
        let storage = PluginStorage(directory: FileManager.default.temporaryDirectory, pluginId: "sh.example.tracker")
        let message = #"{"api":2,"type":"tracker.result","payload":{"callId":"c1","result":{"ready":true}}}"#
        var screen = PluginBridge(capabilities: [])
        guard case .refused = screen.handle(message, storage: storage) else {
            Issue.record("a screen answered for a tracker"); return
        }
        var background = PluginBridge(capabilities: [])
        background.isBackground = true
        guard case .trackerResult("c1", let payload) = background.handle(message, storage: storage) else {
            Issue.record("the answer wasn't taken"); return
        }
        #expect(TrackerAnswer.parse(.access, payload) == .access(TrackerAccess(ready: true)))
        guard case .refused = background.handle(#"{"api":2,"type":"tracker.result","payload":{"result":{}}}"#, storage: storage) else {
            Issue.record("an answer without its call was taken"); return
        }
        // Search results with descriptions pass the usual message limit.
        let excerpt = String(repeating: "x", count: 10_000)
        let issues = (1...10).map { #"{"key":"EX-\#($0)","title":"T","url":"https://example.com/\#($0)","excerpt":"\#(excerpt)"}"# }
        let big = #"{"api":2,"type":"tracker.result","payload":{"callId":"c2","result":{"issues":[\#(issues.joined(separator: ","))]}}}"#
        #expect(big.utf8.count > PluginBridge.messageByteLimit)
        guard case .trackerResult("c2", let bigPayload) = background.handle(big, storage: storage) else {
            Issue.record("a large answer was refused"); return
        }
        #expect(TrackerAnswer.parse(.searchIssues(query: "", project: nil), bigPayload).issues.count == 10)
    }

    @Test func aCallEndsWithItsAnswerItsTimeLimitOrTheScriptStopping() async {
        let calls = PluginTrackerCalls(pluginName: "Example", timeout: 0.2)
        let answered = await calls.call(.access) { id in
            Task { await calls.finish(id, payload: .object(["result": .object(["ready": .bool(true), "account": .string("Ada")])])) }
            return true
        }
        #expect(answered == .access(TrackerAccess(ready: true, account: "Ada")))
        #expect(await calls.call(.listProjects) { _ in true } == .failed("Example didn't answer within 0 seconds."))
        #expect(await calls.call(.listProjects) { _ in false } == .failed("Example isn't running."))
        async let stopped = calls.call(.access) { _ in true }
        try? await Task.sleep(for: .milliseconds(50))
        await calls.failAll()
        #expect(await stopped == .failed("Example stopped before it answered."))
        #expect(await calls.pending == 0)
    }

    // MARK: What the agent reads

    @Test func anAttachedIssueSendsTheTrackersLine() {
        let issue = TrackerIssue(key: "ENG-123", title: "Fix login", state: "In Progress", url: "https://linear.app/acme/issue/ENG-123",
                                 excerpt: "Steps to reproduce")
        let attachment = issue.attachment(trackerId: "sh.abstract.linear", trackerName: "Linear")
        #expect(attachment.promptText
                == "Linear Issue ENG-123: Fix login\nhttps://linear.app/acme/issue/ENG-123\nState: In Progress\n\nSteps to reproduce")
        #expect(attachment.label == "ENG-123 Fix login")
        let message = PromptAttachments.message("look", [attachment])
        #expect(message.contains(#"<attachment kind="trackerIssue" tracker="sh.abstract.linear" label="ENG-123 Fix login""#))
        let chips = PromptAttachments.split(message).chips
        #expect(chips == [PromptAttachments.Chip(kind: .trackerIssue, label: "ENG-123 Fix login",
                                                  target: "https://linear.app/acme/issue/ENG-123", tracker: "sh.abstract.linear")])
    }

    // MARK: Upgrading

    /// A message as builds before ABS-141 sent it.
    static let legacyMessage = """
        fix this

        <attachment kind="linearIssue" label="ENG-9 Fix login" target="https://linear.app/acme/issue/ENG-9">
        Linear Issue ENG-9: Fix login
        https://linear.app/acme/issue/ENG-9
        </attachment>
        """

    @Test func oldLinearChipsStillShowAsTheLinearPluginsIssues() {
        let (text, chips) = PromptAttachments.split(Self.legacyMessage)
        #expect(text == "fix this")
        #expect(chips == [PromptAttachments.Chip(kind: .trackerIssue, label: "ENG-9 Fix login",
                                                  target: "https://linear.app/acme/issue/ENG-9", tracker: "sh.abstract.linear")])
    }

    @Test func savedLinearAttachmentsDecodeAsTrackerIssues() throws {
        let saved = #"{"id":"a1","kind":"linearIssue","title":"Fix login","reference":"ENG-9","url":"https://linear.app/acme/issue/ENG-9","details":["State: Todo"]}"#
        let attachment = try JSONDecoder().decode(PromptAttachment.self, from: Data(saved.utf8))
        #expect(attachment.kind == .trackerIssue)
        #expect(attachment.tracker == "sh.abstract.linear")
        #expect(attachment.promptText == "Linear Issue ENG-9: Fix login\nhttps://linear.app/acme/issue/ENG-9\nState: Todo")
        // And round-trip as tracker issues.
        let again = try JSONDecoder().decode(PromptAttachment.self, from: JSONEncoder().encode(attachment))
        #expect(again == attachment)
        // Files saved before trackers carry no tracker fields.
        let file = try JSONDecoder().decode(PromptAttachment.self, from: Data(#"{"id":"f","kind":"file","title":"a.txt","details":[]}"#.utf8))
        #expect(file.kind == .file && file.tracker == nil)
    }

    @Test func theStoreRewritesOldChatsFirstMessages() throws {
        let prompt = Self.legacyMessage.replacingOccurrences(of: "'", with: "''")
        let store = try Store.inMemory(migratedTo: "v21-workflows", thenRunning: """
            INSERT INTO sessions (id, name, provider_id, created_at, prompt)
            VALUES ('s1', 'Chat', 'claude', '2026-10-01 12:00:00.000', '\(prompt)');
            INSERT INTO sessions (id, name, provider_id, created_at, prompt)
            VALUES ('s2', 'Other', 'claude', '2026-10-01 12:00:00.000', 'no attachments');
            """)
        let migrated = try #require(try store.session("s1")?.prompt)
        #expect(migrated.contains(#"<attachment kind="trackerIssue" tracker="sh.abstract.linear" label="ENG-9 Fix login""#))
        #expect(!migrated.contains("linearIssue"))
        #expect(PromptAttachments.split(migrated).chips.first?.tracker == "sh.abstract.linear")
        #expect(try store.session("s2")?.prompt == "no attachments")
    }
}
