import Foundation
import JavaScriptCore
import Testing
@testable import AbstractCore

/// The bundled Approvals plugin (ABS-111): one queue for every permission
/// request and question waiting across your chats. The host side (what's
/// waiting, `permission.resolved`, batch Allow, the badge) is Swift; the
/// queue's rules are plain JavaScript, so these tests run the shipped file
/// over recorded `permission.requested` events.
@Suite struct ApprovalsPluginTests {
    var pluginFolder: URL {
        let here = URL(fileURLWithPath: #filePath)
        let repo = here.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return repo.appendingPathComponent("Abstract/Resources/Plugins/approvals.abstractplugin")
    }

    /// The shipped queue.js, with `__args[n]` bound from JSON values.
    final class Queue {
        let context: JSContext
        init(folder: URL) throws {
            let source = try String(contentsOf: folder.appendingPathComponent("queue.js"), encoding: .utf8)
            context = try #require(JSContext())
            context.evaluateScript(source)
            context.evaluateScript("var state = ApprovalsQueue.emptyState();")
        }

        @discardableResult
        func run(_ code: String, _ args: [JSONValue] = []) -> JSONValue {
            context.setObject(args.map { $0.compact() }, forKeyedSubscript: "__argTexts" as NSString)
            context.evaluateScript("var __args = __argTexts.map(function (t) { return JSON.parse(t); });")
            let result = context.evaluateScript("JSON.stringify(\(code))")
            if let exception = context.exception {
                Issue.record("\(code) threw: \(exception.toString() ?? "?")")
                context.exception = nil
                return .null
            }
            guard let text = result?.toString(), text != "undefined",
                  let object = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed) else {
                return .null
            }
            return JSONValue(any: object)
        }

        /// An event, exactly as the host cuts it down for this plugin.
        func hear(_ event: PluginEvent, at now: String = "2026-10-20T10:00:00Z") {
            let payload = event.payload(capabilities: ApprovalsPluginTests.grants) ?? .null
            run("(state = ApprovalsQueue.applyEvent(state, __args[0], __args[1])) && null", [payload, .string(now)])
        }

        /// Sends a pull; returns its number.
        func sendPull() -> Int {
            let asked = run("(function () { var a = ApprovalsQueue.nextPull(state); state = a.state; return a.seq; })()")
            return asked.int ?? 0
        }

        func reply(_ seq: Int, _ requests: [PluginPendingRequest]) {
            run("(state = ApprovalsQueue.applyPull(state, __args[0], __args[1])) && null",
                [.number(Double(seq)), PluginPermissions.list(requests)])
        }

        var count: Int { run("ApprovalsQueue.count(state)").int ?? -1 }

        func built(_ snapshot: JSONValue = .object([:])) -> JSONValue {
            run("ApprovalsQueue.build(state, __args[0])", [snapshot])
        }
    }

    static let grants: Set<PluginCapability> = [.projectsRead, .chatsRead, .chatsOpen, .permissionsAnswer]
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    // Recorded from Claude's stream: what each request carries.
    func bash(_ chatId: String, _ requestId: String, _ command: String, description: String = "Run the tests",
              after seconds: TimeInterval = 0) -> PluginPendingRequest {
        PluginPendingRequest(chatId: chatId, requestId: requestId, toolName: "Bash",
                             input: .object(["command": .string(command), "description": .string(description)]),
                             requestedAt: t0.addingTimeInterval(seconds), root: "/work/\(chatId)")
    }

    func edit(_ chatId: String, _ requestId: String, after seconds: TimeInterval = 0) -> PluginPendingRequest {
        PluginPendingRequest(chatId: chatId, requestId: requestId, toolName: "Edit",
                             input: .object(["file_path": .string("/work/\(chatId)/Sources/Cart.swift"),
                                             "old_string": .string("let a = 1\nlet b = 2"),
                                             "new_string": .string("let a = 3")]),
                             requestedAt: t0.addingTimeInterval(seconds), root: "/work/\(chatId)")
    }

    func question(_ chatId: String, _ requestId: String, after seconds: TimeInterval = 0) -> PluginPendingRequest {
        let input = JSONValue.object(["questions": .array([.object([
            "question": .string("Which database?"), "header": .string("Storage"), "multiSelect": .bool(false),
            "options": .array([.object(["label": .string("SQLite"), "description": .string("One file")]),
                               .object(["label": .string("Postgres")])]),
        ])])])
        return PluginPendingRequest(chatId: chatId, requestId: requestId, toolName: AgentQuestion.toolName,
                                    input: input, requestedAt: t0.addingTimeInterval(seconds))
    }

    func requested(_ request: PluginPendingRequest) -> PluginEvent {
        .permissionRequested(chatId: request.chatId, requestId: request.requestId, kind: request.kind,
                             toolName: request.toolName,
                             questions: AgentQuestion.parse(request.input).map(\.question))
    }

    func storage() -> PluginStorage {
        PluginStorage(directory: FileManager.default.temporaryDirectory, pluginId: "sh.abstract.approvals")
    }

    func message(_ type: String, _ payload: JSONValue) -> String {
        JSONValue.object(["api": .number(2), "type": .string(type), "id": .string("1"), "payload": payload]).compact()
    }

    // MARK: The package

    @Test func theBundledPackageIsAScreenWithABackgroundScript() throws {
        let manifest = try PluginPackage.inspect(folder: pluginFolder).manifest
        #expect(manifest.id == "sh.abstract.approvals")
        #expect(manifest.name == "Approvals")
        #expect(manifest.background == "background.js")
        #expect(manifest.view?.title == "Approvals")
        #expect(manifest.grantedCapabilities == Self.grants)
    }

    // MARK: What's waiting

    @Test func theListIsOldestFirstWithWhatEachAsks() throws {
        let list = PluginPermissions.list([
            question("c", "q1", after: 30),
            bash("a", "p1", #"/bin/zsh -lc "npm test""#, after: 10),
            edit("b", "p2", after: 20),
        ])
        let items = try #require(list["requests"]?.array)
        #expect(items.map { $0["requestId"]?.string } == ["p1", "p2", "q1"])
        #expect(items[0]["kind"] == .string("permission"))
        #expect(items[0]["command"] == .string("npm test"))
        #expect(items[0]["description"] == .string("Run the tests"))
        #expect(items[1]["path"] == .string("Sources/Cart.swift"))
        #expect(items[1]["added"] == .number(1))
        #expect(items[1]["removed"] == .number(2))
        #expect(items[2]["kind"] == .string("question"))
        let q = try #require(items[2]["questions"]?.array?.first)
        #expect(q["question"] == .string("Which database?"))
        #expect(q["options"]?.array?.compactMap { $0["label"]?.string } == ["SQLite", "Postgres"])
        #expect(list["total"] == .number(3))
    }

    @Test func onlyAPluginThatMayAnswerSeesWhatsWaiting() {
        var reader = PluginBridge(capabilities: [.chatsRead])
        guard case .refused = reader.handle(message("getPermissions", .object([:])), storage: storage()) else {
            Issue.record("a plugin that can't answer saw the requests"); return
        }
        var answerer = PluginBridge(capabilities: Self.grants)
        #expect(answerer.handle(message("getPermissions", .object([:])), storage: storage()) == .getPermissions(id: "1"))

        // The same in events: a resolved request's id is only for answerers.
        let resolved = PluginEvent.permissionResolved(chatId: "a", requestId: "p1")
        #expect(resolved.payload(capabilities: [.chatsRead])?["requestId"] == nil)
        #expect(resolved.payload(capabilities: Self.grants)?["requestId"] == .string("p1"))
    }

    @Test func aRequestThatStopsWaitingIsAnnouncedOnce() {
        var detector = PluginEventDetector()
        let a = PluginAction.Target(chatId: "a", requestId: "p1")
        let b = PluginAction.Target(chatId: "b", requestId: "p2")
        #expect(detector.resolved(pending: [a, b]).isEmpty)  // baseline
        #expect(detector.resolved(pending: [b]) == [.permissionResolved(chatId: "a", requestId: "p1")])
        #expect(detector.resolved(pending: [b]).isEmpty)
        #expect(detector.resolved(pending: []) == [.permissionResolved(chatId: "b", requestId: "p2")])
    }

    // MARK: Done when

    /// Three chats waiting — two permissions and a question — show as three
    /// rows; answering each through the host's own checks, and the
    /// requests leaving, brings the count to zero.
    @Test func threeWaitingShowAndAnsweringEmptiesTheQueue() throws {
        let queue = try Queue(folder: pluginFolder)
        let waiting = [bash("a", "p1", "npm test"), edit("b", "p2", after: 5), question("c", "q1", after: 10)]
        for request in waiting { queue.hear(requested(request)) }
        #expect(queue.count == 3)
        queue.reply(queue.sendPull(), waiting)

        let snapshot = JSONValue.object([
            "chats": .array([
                .object(["id": .string("a"), "title": .string("Fix the cart"), "agentId": .string("claude"),
                         "projectKey": .string("mac:p")]),
                .object(["id": .string("b"), "title": .string("Tidy"), "agentId": .string("claude")]),
                .object(["id": .string("c"), "title": .string("Pick a store"), "agentId": .string("claude")]),
            ]),
            "projects": .array([.object(["key": .string("mac:p"), "name": .string("Shop")])]),
        ])
        let rows = try #require(queue.built(snapshot)["rows"]?.array)
        #expect(rows.map { $0["requestId"]?.string } == ["p1", "p2", "q1"])
        #expect(rows[0]["summary"] == .string("Run npm test"))
        #expect(rows[0]["chatTitle"] == .string("Fix the cart"))
        #expect(rows[0]["projectName"] == .string("Shop"))
        #expect(rows[0]["agentName"] == .string("Claude Code"))
        #expect(rows[1]["summary"] == .string("Edit Sources/Cart.swift (+1 −2)"))
        #expect(rows[2]["summary"] == .string("A question for you"))

        // Allow and the question's option, as the screen sends them.
        var bridge = PluginBridge(capabilities: Self.grants, alwaysAllowedActions: [.permissionsAnswer])
        bridge.knownChatIds = ["a", "b", "c"]
        let allow = bridge.handle(message("answerPermission", .object([
            "chatId": .string("a"), "requestId": .string("p1"), "allow": .bool(true)])), storage: storage())
        #expect(allow == .action(id: "1", PluginAction(capability: .permissionsAnswer, chatId: "a", requestId: "p1", allow: true)))
        let answers = try #require(queue.run("ApprovalsQueue.questionAnswers(__args[0], __args[1])",
                                             [rows[2]["questions"] ?? .null,
                                              .object(["Which database?": .array([.string("SQLite")])])]).object)
        let reply = bridge.handle(message("answerQuestion", .object([
            "chatId": .string("c"), "requestId": .string("q1"), "answers": .object(answers)])), storage: storage())
        #expect(reply == .action(id: "1", PluginAction(capability: .permissionsAnswer, chatId: "c", requestId: "q1",
                                                       answers: ["Which database?": "SQLite"])))

        queue.run("(state = ApprovalsQueue.markAnswered(state, __args[0], 'Answered from Approvals')) && null",
                  [.array([.object(["chatId": .string("a"), "requestId": .string("p1")]),
                           .object(["chatId": .string("c"), "requestId": .string("q1")])])])
        #expect(queue.count == 1)
        let answered = try #require(queue.built(snapshot)["answered"]?.array)
        #expect(answered.map { $0["note"]?.string } == ["Answered from Approvals", "Answered from Approvals"])

        // The third is answered in its chat: the host says so.
        queue.hear(.permissionResolved(chatId: "b", requestId: "p2"))
        #expect(queue.count == 0)
        queue.reply(queue.sendPull(), [])
        #expect(queue.count == 0)
    }

    // MARK: Out of order

    @Test func aResolvedRequestNeverComesBack() throws {
        let queue = try Queue(folder: pluginFolder)
        let request = bash("a", "p1", "npm test")
        // Resolved heard first, its request after: it isn't waiting.
        queue.hear(.permissionResolved(chatId: "a", requestId: "p1"))
        queue.hear(requested(request))
        #expect(queue.count == 0)
        // A pull sent before it was answered still lists it: ignored too.
        queue.reply(queue.sendPull(), [request])
        #expect(queue.count == 0)
    }

    @Test func aLateReplyToAnOlderPullIsIgnored() throws {
        let queue = try Queue(folder: pluginFolder)
        let first = queue.sendPull()
        let second = queue.sendPull()
        queue.reply(second, [bash("a", "p1", "npm test")])
        queue.reply(first, [bash("a", "p1", "npm test"), bash("b", "p2", "make")])
        #expect(queue.count == 1)
    }

    @Test func aPullSentBeforeARequestDoesNotDropIt() throws {
        let queue = try Queue(folder: pluginFolder)
        let seq = queue.sendPull()
        queue.hear(requested(bash("a", "p1", "npm test")))
        queue.reply(seq, [])
        #expect(queue.count == 1)
        // The next pull is the truth.
        queue.reply(queue.sendPull(), [])
        #expect(queue.count == 0)
    }

    @Test func aRequestAnsweredHereStaysAnsweredWhenItsEventArrivesLate() throws {
        let queue = try Queue(folder: pluginFolder)
        let request = bash("a", "p1", "npm test")
        queue.reply(queue.sendPull(), [request])
        queue.run("(state = ApprovalsQueue.markAnswered(state, [{chatId: 'a', requestId: 'p1'}], 'Answered from Approvals')) && null")
        queue.hear(requested(request))
        #expect(queue.count == 0)
        #expect(queue.built()["answered"]?.array?.count == 1)
    }

    @Test func aRepeatedRequestedEventIsOneRow() throws {
        let queue = try Queue(folder: pluginFolder)
        let request = edit("a", "p1")
        queue.hear(requested(request))
        queue.hear(requested(request))
        #expect(queue.count == 1)
    }

    // MARK: Allow several at once

    @Test func allowAllIsOfferedOnlyForExactlyTheSameCommand() throws {
        let queue = try Queue(folder: pluginFolder)
        queue.reply(queue.sendPull(), [
            bash("a", "p1", "npm test", description: "Run the tests"),
            bash("b", "p2", #"/bin/zsh -lc "npm test""#, description: "Tests again", after: 1),
            bash("c", "p3", "npm test -- --watch", after: 2),
            edit("d", "p4", after: 3),
            edit("e", "p5", after: 4),
        ])
        let rows = try #require(queue.built()["rows"]?.array)
        let same = rows.map { $0["sameCommand"]?.array?.count ?? 0 }
        #expect(same == [2, 2, 0, 0, 0])
        #expect(rows[0]["sameCommand"]?.array?.compactMap { $0["requestId"]?.string } == ["p1", "p2"])
    }

    @Test func theHostAllowsABatchOnlyForExactlyTheSameCommandStillWaiting() throws {
        let pending = [bash("a", "p1", "npm test"), bash("b", "p2", #"/bin/zsh -lc "npm test""#),
                       bash("c", "p3", "rm -rf build"), edit("d", "p4"), edit("e", "p5")]
        func targets(_ pairs: [(String, String)]) -> [PluginAction.Target] {
            pairs.map { PluginAction.Target(chatId: $0.0, requestId: $0.1) }
        }
        let allowed = try PluginPermissions.batch(targets([("a", "p1"), ("b", "p2")]), pending: pending)
        #expect(allowed.map(\.requestId) == ["p1", "p2"])
        #expect(throws: AbstractError.self) {
            try PluginPermissions.batch(targets([("a", "p1"), ("c", "p3")]), pending: pending)
        }
        // Edits aren't commands, even when they're the same edit.
        #expect(throws: AbstractError.self) {
            try PluginPermissions.batch(targets([("d", "p4"), ("e", "p5")]), pending: pending)
        }
        #expect(throws: AbstractError.self) {
            try PluginPermissions.batch(targets([("a", "p1"), ("b", "gone")]), pending: pending)
        }
        #expect(throws: AbstractError.self) {
            try PluginPermissions.batch(targets([("a", "p1")]), pending: pending)
        }
    }

    @Test func theBridgeTakesABatchAsOneAllowForChatsItKnows() {
        var bridge = PluginBridge(capabilities: Self.grants)
        bridge.knownChatIds = ["a", "b"]
        let requests = JSONValue.array([.object(["chatId": .string("a"), "requestId": .string("p1")]),
                                        .object(["chatId": .string("b"), "requestId": .string("p2")])])
        let outcome = bridge.handle(message("answerPermissions", .object(["requests": requests, "allow": .bool(true)])),
                                    storage: storage())
        let action = PluginAction(capability: .permissionsAnswer, allow: true,
                                  batch: [.init(chatId: "a", requestId: "p1"), .init(chatId: "b", requestId: "p2")])
        #expect(outcome == .askAction(id: "1", action))
        #expect(action.describe(pluginName: "Approvals") == "Approvals wants to allow the same command 2 times, in 2 chats.")

        for payload: JSONValue in [
            .object(["requests": requests, "allow": .bool(false)]),
            .object(["requests": .array([requests.array![0]]), "allow": .bool(true)]),
            .object(["requests": .array([requests.array![0], requests.array![0]]), "allow": .bool(true)]),
            .object(["requests": .array([requests.array![0], .object(["chatId": .string("x"), "requestId": .string("p9")])]),
                     "allow": .bool(true)]),
        ] {
            guard case .refused = bridge.handle(message("answerPermissions", payload), storage: storage()) else {
                Issue.record("accepted \(payload.compact())"); continue
            }
        }
    }

    // MARK: The badge

    @Test func theBadgeIsACountOnItsOwnRow() {
        var bridge = PluginBridge(capabilities: [])
        #expect(bridge.handle(message("setBadge", .object(["count": .number(3)])), storage: storage()) == .badge(id: "1", count: 3))
        #expect(bridge.handle(message("setBadge", .object(["count": .number(0)])), storage: storage()) == .badge(id: "1", count: 0))
        for bad: JSONValue in [.number(-1), .number(10_000), .string("3")] {
            guard case .refused = bridge.handle(message("setBadge", .object(["count": bad])), storage: storage()) else {
                Issue.record("accepted badge \(bad.compact())"); continue
            }
        }
    }
}
