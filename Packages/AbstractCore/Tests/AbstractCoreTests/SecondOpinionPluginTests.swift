import Foundation
import JavaScriptCore
import Testing
@testable import AbstractCore

/// The bundled Second opinion plugin (ABS-112), and the host API it rides
/// on: a read-only reviewer chat, Review comments marked with their
/// author, a Review command per agent, and the round limit. The plugin's
/// logic is plain JavaScript, so these tests run the shipped script.
@Suite struct SecondOpinionPluginTests {
    var pluginFolder: URL {
        let here = URL(fileURLWithPath: #filePath)
        let repo = here.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return repo.appendingPathComponent("Abstract/Resources/Plugins/second-opinion.abstractplugin")
    }

    /// Runs `SecondOpinion.<call>` with `__args[n]` bound from JSON texts.
    func evaluate(_ call: String, args: [String] = []) throws -> JSONValue {
        let source = try String(contentsOf: pluginFolder.appendingPathComponent("background.js"), encoding: .utf8)
        let context = try #require(JSContext())
        context.evaluateScript(source)
        context.setObject(args, forKeyedSubscript: "__argTexts" as NSString)
        context.evaluateScript("const __args = __argTexts.map((text) => JSON.parse(text));")
        let result = context.evaluateScript("JSON.stringify(SecondOpinion.\(call))")
        if let exception = context.exception {
            Issue.record("SecondOpinion.\(call) threw: \(exception.toString() ?? "?")")
            return .null
        }
        let text = try #require(result?.toString())
        return JSONValue(any: try JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed))
    }

    func json(_ string: String) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: [string]), as: UTF8.self)
    }

    // MARK: The package

    @Test func theBundledPackageInstallsAsAReviewCommandWithABackgroundScript() throws {
        let manifest = try PluginPackage.inspect(folder: pluginFolder).manifest
        #expect(manifest.id == "sh.abstract.second-opinion")
        #expect(manifest.background == "background.js")
        #expect(manifest.grantedCapabilities.isSuperset(of: [.chatsCreate, .chatsMessage, .transcriptsRead, .reviewComment, .turnsRead]))
        let ask = try #require(manifest.contributes.reviewActions.first { $0.id == "ask" })
        #expect(ask.isPerAgent)
        #expect(ask.title(agentName: "Codex") == "Ask Codex to Review")
        #expect(manifest.appearanceSentences.contains("Ask another agent to Review — a command in a chat's Review."))
    }

    // MARK: Findings from recorded replies

    /// A Codex-style reply: prose, then findings with bullets, backticks,
    /// a range, a repeat, and lines Review can't place.
    static let codexReply = """
        I reviewed the uncommitted changes.

        - `Sources/App/Cart.swift:42` — the total ignores the discount when the cart is empty — return 0 before applying it
        - Sources/App/Cart.swift:58-61 — `remove` mutates the array while iterating it — iterate over a copy
        2. **Tests/CartTests.swift:10** -- the test never awaits the save -- add `await`
        - Sources/App/Cart.swift:42 — the total ignores the discount when the cart is empty — return 0 before applying it
        - /etc/passwd:1 — outside the worktree — ignore
        - ../elsewhere.swift:3 — outside the worktree — ignore
        - Sources/App/Cart.swift:0 — no such line — ignore

        Overall the change is close.
        """

    @Test func findingsAreParsedFromARecordedReply() throws {
        let findings = try evaluate("parseFindings(__args[0])", args: [json(Self.codexReply)])
        let items = try #require(findings.array)
        #expect(items.count == 3)
        #expect(items[0]["path"] == .string("Sources/App/Cart.swift"))
        #expect(items[0]["line"] == .number(42))
        #expect(items[0]["problem"] == .string("the total ignores the discount when the cart is empty"))
        #expect(items[0]["suggestion"] == .string("return 0 before applying it"))
        #expect(items[1]["line"] == .number(58))
        #expect(items[1]["problem"] == .string("`remove` mutates the array while iterating it"))
        #expect(items[2]["path"] == .string("Tests/CartTests.swift"))
        #expect(items[2]["suggestion"] == .string("add `await`"))
    }

    @Test func aReplyWithNothingToChangeHasNoFindings() throws {
        let findings = try evaluate("parseFindings(__args[0])", args: [json("I read the diff carefully.\n\nNo findings.")])
        #expect(findings.array?.isEmpty == true)
    }

    @Test func findingsBecomeLineCommentsTheBridgeAccepts() throws {
        let comments = try evaluate("toComments(SecondOpinion.parseFindings(__args[0]))", args: [json(Self.codexReply)])
        let items = try #require(comments.array)
        #expect(items.count == 3)
        #expect(items[0]["text"] == .string("the total ignores the discount when the cart is empty\nSuggestion: return 0 before applying it"))

        // Exactly what the plugin sends, through the host's own checks.
        var bridge = PluginBridge(capabilities: [.reviewComment])
        bridge.knownChatIds = ["chat-1"]
        let message = JSONValue.object(["api": .number(2), "type": .string("addReviewComments"), "id": .string("1"),
                                        "payload": .object(["chatId": .string("chat-1"), "author": .string("Codex"),
                                                            "comments": comments])]).compact()
        let storage = PluginStorage(directory: FileManager.default.temporaryDirectory, pluginId: "sh.abstract.second-opinion")
        guard case .addReviewComments(_, "chat-1", "Codex", let added) = bridge.handle(message, storage: storage) else {
            Issue.record("the comments were refused: \(bridge.lastRefusal ?? "?")"); return
        }
        #expect(added.map(\.path) == ["Sources/App/Cart.swift", "Sources/App/Cart.swift", "Tests/CartTests.swift"])
        #expect(added.map(\.line) == [42, 58, 10])
    }

    @Test func theLastReplyIsWhatTheReviewerSaidSinceItWasLastAsked() throws {
        let items = """
            [{"kind":"user","text":"Review it."},{"kind":"assistant","text":"old"},
             {"kind":"user","text":"Again."},{"kind":"tool","toolName":"Bash"},
             {"kind":"assistant","text":"a.swift:1 — x — y"},{"kind":"assistant","text":"Done."}]
            """
        #expect(try evaluate("lastReply(__args[0])", args: [items]) == .string("a.swift:1 — x — y\nDone."))
    }

    @Test func thePromptNamesWhatReviewCompares() throws {
        let uncommitted = try evaluate("reviewPrompt('uncommitted', 'Fix the cart')").string ?? ""
        #expect(uncommitted.contains("git diff HEAD"))
        #expect(uncommitted.contains("“Fix the cart”"))
        #expect(uncommitted.contains("Don't change any files"))
        #expect(try evaluate("describeScope('commit abc1234')").string?.contains("git show abc1234") == true)
        #expect(try evaluate("describeScope('committed')").string?.contains("commits on this branch") == true)
    }

    // MARK: Rounds

    func step(_ review: String, _ happening: String) throws -> JSONValue {
        try evaluate("step(__args[0], __args[1])", args: [review, happening])
    }

    @Test func sendingAfterFindingsLoopsBackToTheReviewer() throws {
        let asked = try step("null", #"{"kind":"ask","agentId":"codex","agentName":"Codex","scope":"uncommitted"}"#)
        #expect(asked["effect"]?["kind"] == .string("startReviewer"))
        #expect(asked["review"]?["round"] == .number(1))

        let review = #"{"agentId":"codex","agentName":"Codex","scope":"uncommitted","reviewerId":"r","round":1,"phase":"reviewing"}"#
        let found = try step(review, #"{"kind":"reviewerFinished","outcome":"done","found":2}"#)
        #expect(found["review"]?["phase"] == .string("waiting"))
        #expect(found["notice"]?.string?.contains("2 findings are in Review") == true)

        let waiting = review.replacingOccurrences(of: "reviewing", with: "waiting")
        let sent = try step(waiting, #"{"kind":"send"}"#)
        #expect(sent["effect"]?["kind"] == .string("sendReview"))
        #expect(sent["review"]?["phase"] == .string("fixing"))

        let fixing = review.replacingOccurrences(of: "reviewing", with: "fixing")
        let again = try step(fixing, #"{"kind":"authorFinished","outcome":"done"}"#)
        #expect(again["effect"]?["kind"] == .string("reReview"))
        #expect(again["review"]?["round"] == .number(2))
        #expect(again["review"]?["phase"] == .string("reviewing"))
    }

    @Test func roundThreeStopsAndHandsItBackToYou() throws {
        #expect(try evaluate("maxRounds") == .number(3))
        let third = #"{"agentId":"codex","agentName":"Codex","scope":"uncommitted","reviewerId":"r","round":3,"phase":"reviewing"}"#
        let found = try step(third, #"{"kind":"reviewerFinished","outcome":"done","found":1}"#)
        #expect(found["review"]?["phase"] == .string("done"))
        #expect(found["effect"] == nil)
        #expect(found["notice"]?.string?.contains("last round") == true)

        let done = third.replacingOccurrences(of: "reviewing", with: "done")
        let refused = try step(done, #"{"kind":"send"}"#)
        #expect(refused["effect"] == nil)
        #expect(refused["notice"]?.string?.contains("yourself") == true)
    }

    @Test func nothingFoundOrAStoppedTurnEndsTheReview() throws {
        let review = #"{"agentId":"codex","agentName":"Codex","scope":"uncommitted","reviewerId":"r","round":1,"phase":"reviewing"}"#
        let clean = try step(review, #"{"kind":"reviewerFinished","outcome":"done","found":0}"#)
        #expect(clean["review"]?["phase"] == .string("done"))
        #expect(clean["notice"] == .string("Codex found nothing to change."))
        let stopped = try step(review, #"{"kind":"reviewerFinished","outcome":"stopped","found":0}"#)
        #expect(stopped["review"]?["phase"] == .string("done"))
        // The author's own turns don't count until you send.
        #expect(try step(review, #"{"kind":"authorFinished","outcome":"done"}"#)["effect"] == nil)
        #expect(try step("null", #"{"kind":"send"}"#)["effect"] == nil)
    }
}

/// What the host lets a reviewing plugin do (ABS-112).
@Suite struct PluginReviewBridgeTests {
    let storage = PluginStorage(directory: FileManager.default.temporaryDirectory, pluginId: "sh.abstract.second-opinion")

    func bridge(_ capabilities: Set<PluginCapability>, always: Set<PluginCapability> = []) -> PluginBridge {
        var bridge = PluginBridge(capabilities: capabilities, alwaysAllowedActions: always)
        bridge.knownChatIds = ["chat-1"]
        bridge.knownProjectKeys = ["mac-1:project-1"]
        return bridge
    }

    @Test func aReviewerStartsReadOnlyInTheChatItReviews() {
        var b = bridge([.chatsCreate])
        let create = #"{"api":2,"type":"createChat","id":"1","payload":{"reviewOf":"chat-1","agentId":"codex","prompt":"Review it."}}"#
        guard case .askAction(_, let action) = b.handle(create, storage: storage) else {
            Issue.record("refused: \(b.lastRefusal ?? "?")"); return
        }
        #expect(action.reviewOf == "chat-1")
        #expect(action.policy == "read-only")
        #expect(action.describe(pluginName: "Second opinion", chatTitle: "Fix the cart")
                == "Second opinion wants Codex to review the changes in “Fix the cart”, without changing anything.")

        // Only a chat it was handed, only read-only, and only where that chat works.
        for payload in [#"{"reviewOf":"chat-9","prompt":"x"}"#, #"{"reviewOf":"chat-1","policy":"bypass","prompt":"x"}"#,
                        #"{"reviewOf":"chat-1","projectKey":"mac-1:project-1","prompt":"x"}"#] {
            let message = #"{"api":2,"type":"createChat","id":"2","payload":"# + payload + "}"
            guard case .refused = b.handle(message, storage: storage) else { Issue.record("allowed \(payload)"); continue }
        }
        b.know(chatId: "chat-9")
        let handed = #"{"api":2,"type":"createChat","id":"3","payload":{"reviewOf":"chat-9","prompt":"x"}}"#
        guard case .askAction = b.handle(handed, storage: storage) else { Issue.record("a handed chat was refused"); return }
    }

    @Test func anAskModeChatMayStartAnywhereButPlanMayNot() {
        var b = bridge([.chatsCreate], always: [.chatsCreate])
        let ask = #"{"api":2,"type":"createChat","id":"1","payload":{"prompt":"Look around.","policy":"read-only"}}"#
        guard case .action(_, let action) = b.handle(ask, storage: storage) else { Issue.record("Ask was refused"); return }
        #expect(action.policy == "read-only")
        #expect(action.reviewOf == nil)
        let plan = #"{"api":2,"type":"createChat","id":"2","payload":{"prompt":"x","policy":"plan"}}"#
        guard case .refused = b.handle(plan, storage: storage) else { Issue.record("plan was allowed"); return }
    }

    @Test func reviewCommentsNeedTheGrantAKnownChatAndPlaceableLines() {
        let good = #"{"api":2,"type":"addReviewComments","id":"1","payload":{"chatId":"chat-1","author":"Codex","comments":[{"path":"a.swift","line":3,"text":"Off by one."}]}}"#
        var without = bridge([.chatsRead])
        guard case .refused = without.handle(good, storage: storage) else { Issue.record("no grant, still added"); return }

        var b = bridge([.reviewComment])
        guard case .addReviewComments(_, "chat-1", "Codex", let comments) = b.handle(good, storage: storage) else {
            Issue.record("refused: \(b.lastRefusal ?? "?")"); return
        }
        #expect(comments == [PluginReviewComment(path: "a.swift", line: 3, text: "Off by one.")])

        let bad = [
            #"{"chatId":"chat-9","author":"Codex","comments":[{"path":"a.swift","line":3,"text":"x"}]}"#,
            #"{"chatId":"chat-1","comments":[{"path":"a.swift","line":3,"text":"x"}]}"#,
            #"{"chatId":"chat-1","author":"Codex","comments":[]}"#,
            #"{"chatId":"chat-1","author":"Codex","comments":[{"path":"../a.swift","line":3,"text":"x"}]}"#,
            #"{"chatId":"chat-1","author":"Codex","comments":[{"path":"/etc/hosts","line":3,"text":"x"}]}"#,
            #"{"chatId":"chat-1","author":"Codex","comments":[{"path":"a.swift","line":0,"text":"x"}]}"#,
            #"{"chatId":"chat-1","author":"Codex","comments":[{"path":"a.swift","line":3,"text":"  "}]}"#,
        ]
        for payload in bad {
            let message = #"{"api":2,"type":"addReviewComments","id":"2","payload":"# + payload + "}"
            guard case .refused = b.handle(message, storage: storage) else { Issue.record("allowed \(payload)"); continue }
        }
        let many = (0...PluginBridge.reviewCommentLimit).map { #"{"path":"a.swift","line":\#($0 + 1),"text":"x"}"# }
        let flood = #"{"api":2,"type":"addReviewComments","id":"3","payload":{"chatId":"chat-1","author":"Codex","comments":["#
            + many.joined(separator: ",") + "]}}"
        guard case .refused = b.handle(flood, storage: storage) else { Issue.record("too many comments added"); return }
    }

    @Test func sendingReviewIsAMessageThatAsksFirst() {
        var b = bridge([.chatsMessage])
        let send = #"{"api":2,"type":"sendReview","id":"1","payload":{"chatId":"chat-1"}}"#
        guard case .askAction(_, let action) = b.handle(send, storage: storage) else { Issue.record("refused"); return }
        #expect(action.capability == .chatsMessage)
        #expect(action.sendsReview)
        #expect(action.text == nil)
        #expect(action.describe(pluginName: "Second opinion", chatTitle: "Fix the cart")
                == "Second opinion wants to send your Review comments to “Fix the cart”.")
        var without = bridge([.reviewComment])
        guard case .refused = without.handle(send, storage: storage) else { Issue.record("sent without chats.message"); return }
    }

    @Test func aNoticeIsOneShortSentence() {
        var b = bridge([])
        guard case .notice(_, "Codex found nothing.") = b.handle(#"{"api":2,"type":"showNotice","payload":{"text":"Codex found nothing."}}"#,
                                                                 storage: storage) else { Issue.record("refused"); return }
        let long = String(repeating: "x", count: PluginBridge.noticeTextLimit + 1)
        guard case .refused = b.handle(#"{"api":2,"type":"showNotice","payload":{"text":"\#(long)"}}"#, storage: storage) else {
            Issue.record("a long notice was shown"); return
        }
    }

    @Test func reviewCommandsNeedABackgroundScriptAndApi2() throws {
        let command = PluginManifest.Contribution(id: "ask", title: "Ask {agent} to Review")
        var manifest = PluginManifest(id: "sh.abstract.second-opinion", name: "Second opinion", version: "1.0.0",
                                      capabilities: ["review.comment"], reviewActions: [command], background: "background.js")
        try manifest.validate()
        #expect(PluginContributions.resolve([], place: .review).isEmpty)

        manifest.background = nil
        #expect(throws: PluginValidationError.self) { try manifest.validate() }

        var old = PluginManifest(api: 1, id: "sh.abstract.old", name: "Old", version: "1.0.0",
                                 capabilities: ["review.comment"], background: "background.js")
        #expect(throws: PluginValidationError.self) { try old.validate() }
        old.capabilities = []
        try old.validate()
    }

    @Test func aReviewInvocationCarriesTheAgentAndWhatReviewCompares() {
        let invocation = PluginInvocation(place: .review, contributionId: "ask", chatId: "chat-1",
                                          agentId: "codex", scope: "uncommitted")
        #expect(invocation.jsonValue() == .object([
            "place": .string("review"), "contributionId": .string("ask"), "chatId": .string("chat-1"),
            "agentId": .string("codex"), "agentName": .string("Codex"), "scope": .string("uncommitted"),
        ]))
    }
}
