import Foundation
import Synchronization
import Testing
@testable import AbstractCore

/// The code host contract (ABS-139), against a fake plugin that answers
/// from a table: every operation, a missing host, and errors.
@Suite struct CodeHostTests {
    static let declaration = CodeHostDeclaration(title: "Example", hosts: ["code.example.com"],
                                                 operations: CodeHostOperation.allCases)

    /// A fake plugin: records each call, answers from `answer`.
    final class FakePlugin: Sendable {
        let calls = Mutex<[(CodeHostOperation, JSONValue)]>([])
        let answer: @Sendable (CodeHostOperation, JSONValue) throws -> JSONValue

        init(answer: @escaping @Sendable (CodeHostOperation, JSONValue) throws -> JSONValue) { self.answer = answer }

        func host(_ declaration: CodeHostDeclaration = CodeHostTests.declaration) -> CodeHost {
            CodeHost(pluginId: "sh.example.code", declaration: declaration) { op, input in
                self.calls.withLock { $0.append((op, input)) }
                return try self.answer(op, input)
            }
        }

        var recorded: [(CodeHostOperation, JSONValue)] { calls.withLock { $0 } }
    }

    static func json(_ text: String) -> JSONValue {
        JSONValue(any: try! JSONSerialization.jsonObject(with: Data(text.utf8)))
    }

    static let pr = json("""
    {"number": 12, "title": "Add search", "state": "open", "isDraft": true, "url": "https://code.example.com/o/r/pull/12",
     "head": "feature/search", "base": "main", "author": "octo", "reviewDecision": "changesRequested",
     "mergeable": "CONFLICTING", "mergeState": "DIRTY", "additions": 10, "deletions": 2, "changedFiles": 3,
     "createdAt": "2026-10-01T10:00:00Z", "updatedAt": "2026-10-02T10:00:00Z", "body": "Adds search.", "mergeCommit": null,
     "checks": [{"name": "build", "workflow": "CI", "outcome": "failed", "url": "https://ci.example.com/1"},
                {"name": "lint", "workflow": null, "outcome": "passed", "url": null}],
     "reviews": [{"author": "rev", "verdict": "changesRequested", "body": "Fix it", "submittedAt": "2026-10-02T09:00:00Z",
                  "association": "MEMBER"}],
     "comments": [{"author": "ci[bot]", "body": "Deployed", "createdAt": "2026-10-02T08:00:00Z", "isBot": true,
                   "association": "NONE"}],
     "threads": []}
    """)

    static let thread = json("""
    {"id": "T1", "path": "Sources/Search.swift", "line": 40, "originalLine": 38, "isResolved": false, "isOutdated": false,
     "diffHunk": "@@ -1 +1 @@", "commit": "abc123",
     "comments": [{"id": "C1", "author": "rev", "avatar": "https://code.example.com/rev.png", "body": "Rename this",
                   "createdAt": "2026-10-02T09:00:00Z", "url": "https://code.example.com/c/1", "association": "MEMBER"}]}
    """)

    // MARK: Every operation

    @Test func accessReadsEachState() async {
        for (answer, expected) in [
            (#"{"access": "ready", "viewer": "octo"}"#, CodeHostAccess.ready(viewer: "octo")),
            (#"{"access": "signedOut", "hint": "gh auth login"}"#, .signedOut(hint: "gh auth login")),
            (#"{"access": "missing", "install": "brew install gh"}"#, .missing(install: "brew install gh")),
        ] {
            let plugin = FakePlugin { _, _ in Self.json(answer) }
            #expect(await plugin.host().access() == expected)
        }
        // A plugin that fails to answer says nothing about the tool: it's
        // unavailable, never missing, and blocks nothing.
        let broken = FakePlugin { _, _ in throw CodeHostError.unavailable("Example isn't running, so it can't answer.") }
        let access = await broken.host().access()
        #expect(access == .unavailable("Example isn't running, so it can't answer."))
        #expect(!access.blocks && !access.isReady)
        #expect(CodeHostAccess.missing(install: nil).blocks && CodeHostAccess.signedOut(hint: nil).blocks)
    }

    @Test func listingAndOnePullRequestDecodeAbstractsShape() async throws {
        let plugin = FakePlugin { op, _ in
            op == .listPullRequests ? .object(["pullRequests": .array([Self.pr, .object(["bad": .bool(true)])])])
                                    : .object(["pullRequest": Self.pr])
        }
        let host = plugin.host()
        let list = try await host.pullRequests(state: "open", limit: 5)
        #expect(list.count == 1)
        let pr = try #require(try await host.pullRequest(branch: "feature/search"))
        #expect(pr.number == 12 && pr.isDraft && pr.state == .open)
        #expect(pr.head == "feature/search" && pr.base == "main" && pr.author == "octo")
        #expect(pr.reviewDecision == .changesRequested)
        #expect(pr.hasConflicts)
        #expect(pr.checksSummary.failed == 1 && pr.checksSummary.passed == 1)
        #expect(pr.reviews.first?.verdict == .changesRequested)
        #expect(PullRequest.isCollaborator(pr.reviews.first?.association))
        #expect(pr.comments.first?.isBot == true)
        #expect(pr.createdAt == ISO8601DateFormatter().date(from: "2026-10-01T10:00:00Z"))
        _ = try await host.pullRequest(number: 12)
        let inputs = plugin.recorded.map(\.1)
        #expect(inputs[0]["state"]?.string == "open" && inputs[0]["limit"]?.int == 5)
        #expect(inputs[1]["branch"]?.string == "feature/search")
        #expect(inputs[2]["number"]?.int == 12)
    }

    @Test func aPullRequestRoundTripsThroughTheContract() throws {
        var pr = try #require(PullRequest(contract: Self.pr))
        pr.threads = [try #require(PullRequest.ReviewThread(contract: Self.thread))]
        pr.mergeCommit = "def456"
        let back = try #require(PullRequest(contract: pr.contractJSON()))
        #expect(back == pr)
    }

    @Test func noPullRequestIsNil() async throws {
        let plugin = FakePlugin { _, _ in .object(["pullRequest": .null]) }
        #expect(try await plugin.host().pullRequest(branch: "nothing") == nil)
    }

    @Test func writesSendTheirInputs() async throws {
        let plugin = FakePlugin { op, _ in op == .create ? .object(["pullRequest": Self.pr]) : .object([:]) }
        let host = plugin.host()
        let created = try await host.create(branch: "feature/search", base: "main", title: "Add search", body: "Body", draft: true)
        #expect(created?.number == 12)
        try await host.merge(number: 12, method: .squash, deleteBranch: true)
        try await host.markReady(number: 12)
        try await host.close(number: 12)
        try await host.rerunFailed(number: 12)
        try await host.updateBranch(number: 12)
        let calls = plugin.recorded
        #expect(calls.map(\.0) == [.create, .merge, .markReady, .close, .rerunFailed, .updateBranch])
        #expect(calls[0].1["draft"]?.bool == true && calls[0].1["base"]?.string == "main" && calls[0].1["title"]?.string == "Add search")
        #expect(calls[1].1["method"]?.string == "squash" && calls[1].1["deleteBranch"]?.bool == true)
        #expect(calls.dropFirst(2).allSatisfy { $0.1["number"]?.int == 12 })
        #expect(calls.allSatisfy { $0.0.isWrite })
    }

    @Test func threadsPushAccessAndSearch() async throws {
        let item = Self.json(#"{"number": 7, "title": "Crash", "url": "https://code.example.com/o/r/issues/7", "state": "open", "body": "It crashes", "isPullRequest": false}"#)
        let plugin = FakePlugin { op, input in
            switch op {
            case .reviewThreads: return .object(["threads": .array([Self.thread])])
            case .pushAccess: return .object(["access": .string(input["slug"]?.string == "o/r" ? "push" : "readOnly")])
            default: return .object(["items": .array([item])])
            }
        }
        let host = plugin.host()
        let threads = try await host.reviewThreads(number: 12)
        #expect(threads.first?.comments.first?.author == "rev")
        #expect(threads.first?.line == 40 && threads.first?.commit == "abc123")
        #expect(await host.pushAccess(slug: "o/r") == .push)
        #expect(await host.pushAccess(slug: "x/y") == .readOnly)
        let found = try await host.search("crash", pullRequests: false)
        #expect(found.first?.attachment.kind == .githubIssue)
        #expect(found.first?.state == "OPEN")
        #expect(plugin.recorded.last?.1["kind"]?.string == "issue")
        #expect(ForgeItem(contract: found[0].contractJSON()) == found[0])
    }

    // MARK: Missing host and errors

    @Test func aRemoteOnNoPluginsHostHasNoCodeHost() {
        let candidate = CodeHosts.Candidate(pluginId: "sh.example.code", declaration: Self.declaration)
        #expect(CodeHosts.match(remote: "git@code.example.com:o/r.git", among: [candidate]) == candidate)
        #expect(CodeHosts.match(remote: "https://CODE.example.com/o/r", among: [candidate]) == candidate)
        #expect(CodeHosts.match(remote: "https://gitlab.com/o/r", among: [candidate]) == nil)
        #expect(CodeHosts.match(remote: nil, among: [candidate]) == nil)
        #expect(CodeHosts.match(remote: "/Users/test/repo", among: [candidate]) == nil)
        #expect(CodeHostError.noHost("gitlab.com").errorDescription == "Install a plugin for gitlab.com to see pull requests.")
        // Enterprise hosts the script added count too.
        let enterprise = CodeHosts.Candidate(pluginId: "sh.example.code", declaration: Self.declaration,
                                             extraHosts: ["git.corp.example"])
        #expect(CodeHosts.match(remote: "https://git.corp.example/o/r", among: [enterprise]) == enterprise)
    }

    @Test func anOperationItDoesntListIsntAsked() async {
        let plugin = FakePlugin { _, _ in .object([:]) }
        let small = CodeHostDeclaration(title: "Small", hosts: ["code.example.com"], operations: Array(CodeHostOperation.required))
        let host = plugin.host(small)
        #expect(!host.answers(.merge))
        await #expect(throws: CodeHostError.unsupported(host: "Small", .merge)) { try await host.merge(number: 1, method: .merge) }
        #expect(plugin.recorded.isEmpty)
    }

    @Test func errorsAndBadAnswersSurface() async {
        let failing = FakePlugin { _, _ in throw CodeHostError.failed("Not Found") }
        await #expect(throws: CodeHostError.failed("Not Found")) { try await failing.host().pullRequests() }
        let malformed = FakePlugin { _, _ in .object(["nope": .bool(true)]) }
        await #expect(throws: CodeHostError.malformed(.listPullRequests)) { try await malformed.host().pullRequests() }
        await #expect(throws: CodeHostError.malformed(.pullRequest)) { try await malformed.host().pullRequest(number: 1) }
        await #expect(throws: CodeHostError.malformed(.reviewThreads)) { try await malformed.host().reviewThreads(number: 1) }
        #expect(throws: CodeHostError.failed("boom")) { try PluginCodeHostAnswer.failed("boom").value() }
    }

    @Test func missingChatPRLookupIsThrottled() {
        let now = ContinuousClock.now
        #expect(PullRequestLookup.isDue(last: nil, now: now))
        #expect(!PullRequestLookup.isDue(last: now.advanced(by: .seconds(-599)), now: now))
        #expect(PullRequestLookup.isDue(last: now.advanced(by: .seconds(-600)), now: now))
        #expect(!PullRequestLookup.isDue(last: now, now: now))
    }

    @Test func listingFailuresExplainTheNextStep() {
        let at = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(PullRequestListingError.message("Resource protected by organization SAML enforcement: https://github.com/orgs/acme/sso", lastLoaded: nil, retryAfter: 30)
            == "GitHub needs you to re-authorise SSO for acme.")
        #expect(PullRequestListingError.message("Please run gh repo set-default", lastLoaded: nil, retryAfter: 30)
            == "Choose the default repository: `gh repo set-default`.")
        #expect(PullRequestListingError.message("could not resolve host: github.com", lastLoaded: at, retryAfter: 30)
            .hasPrefix("Offline — showing PRs from "))
        #expect(PullRequestListingError.message("API rate limit exceeded", lastLoaded: nil, retryAfter: 30)
            .hasPrefix("GitHub rate limit — retrying at "))
    }

    // MARK: Manifest and bridge

    func manifest(_ codeHost: CodeHostDeclaration?, background: String? = "background.js") -> PluginManifest {
        PluginManifest(id: "sh.example.code", name: "Example", version: "1.0.0", capabilities: [], codeHost: codeHost,
                       background: background)
    }

    @Test func aDeclarationIsChecked() {
        #expect(throws: Never.self) { try manifest(Self.declaration).validate() }
        #expect(throws: PluginValidationError.self) { try manifest(Self.declaration, background: nil).validate() }
        for bad in [
            CodeHostDeclaration(title: "", hosts: ["code.example.com"], operations: CodeHostOperation.allCases),
            CodeHostDeclaration(title: "X", hosts: [], operations: CodeHostOperation.allCases),
            CodeHostDeclaration(title: "X", hosts: ["*.example.com"], operations: CodeHostOperation.allCases),
            CodeHostDeclaration(title: "X", hosts: ["code.example.com"], operations: [.access, .pullRequest]),
            CodeHostDeclaration(title: "X", hosts: ["code.example.com"], operations: CodeHostOperation.allCases + [.merge]),
        ] {
            #expect(throws: PluginValidationError.self, "\(bad)") { try manifest(bad).validate() }
        }
        #expect(manifest(Self.declaration).appearanceSentences.contains { $0.hasPrefix("Pull requests for code.example.com") })
        let decoded = try? PluginManifest.decode(Data(#"""
        {"api": 2, "id": "sh.example.code", "name": "Example", "version": "1.0.0", "entry": "index.html", "capabilities": [],
         "background": "background.js",
         "contributes": {"codeHost": {"title": "Example", "hosts": ["code.example.com"],
                                      "operations": ["access", "listPullRequests", "pullRequest", "merge"]}}}
        """#.utf8))
        #expect(decoded?.contributes.codeHost?.answers.contains(.merge) == true)
    }

    @Test func onlyACodeHostsScriptAnswers() {
        let storage = PluginStorage(directory: FileManager.default.temporaryDirectory, pluginId: "sh.example.code")
        let answer = #"{"api": 2, "type": "codeHost.result", "payload": {"callId": "k1", "result": {"pullRequest": null}}}"#
        var screen = PluginBridge(capabilities: [])
        screen.isCodeHost = true
        guard case .refused = screen.handle(answer, storage: storage) else { Issue.record("a screen answered"); return }
        var other = PluginBridge(capabilities: [])
        other.isBackground = true
        guard case .refused = other.handle(answer, storage: storage) else { Issue.record("a non-host answered"); return }
        var host = PluginBridge(capabilities: [])
        host.isBackground = true
        host.isCodeHost = true
        #expect(host.handle(answer, storage: storage) == .codeHostResult(callId: "k1", .result(.object(["pullRequest": .null]))))
        let failed = #"{"api": 2, "type": "codeHost.result", "payload": {"callId": "k2", "error": "Not Found"}}"#
        #expect(host.handle(failed, storage: storage) == .codeHostResult(callId: "k2", .failed("Not Found")))
        let hosts = #"{"api": 2, "type": "codeHost.hosts", "id": "3", "payload": {"hosts": ["Git.Corp.Example"]}}"#
        #expect(host.handle(hosts, storage: storage) == .codeHostHosts(id: "3", ["git.corp.example"]))
        let wild = #"{"api": 2, "type": "codeHost.hosts", "id": "4", "payload": {"hosts": ["*.example.com"]}}"#
        guard case .refused = host.handle(wild, storage: storage) else { Issue.record("a wildcard host passed"); return }
    }

    // MARK: Calls

    @Test func aCallIsAnsweredByItsId() async {
        let calls = PluginCodeHostCalls(pluginName: "Example")
        let sent = Box<String?>(nil)
        async let answer = calls.call(.pullRequest) { id in sent.set(id); return true }
        while sent.get() == nil { try? await Task.sleep(for: .milliseconds(5)) }
        await calls.finish(sent.get()!, .result(.object(["pullRequest": .null])))
        #expect(await answer == .result(.object(["pullRequest": .null])))
        #expect(await calls.pending == 0)
    }

    @Test func aScriptThatIsntRunningCantAnswer() async {
        let calls = PluginCodeHostCalls(pluginName: "Example")
        let answer = await calls.call(.access) { _ in false }
        #expect(answer == .failed("Example isn't running, so it can't answer."))
    }

    @Test func onlyALiveWriteThePersonStartedLetsCommandsRunUnasked() async {
        let calls = PluginCodeHostCalls(pluginName: "Example")
        let mergeBox = Box<String?>(nil), listBox = Box<String?>(nil)
        async let merge = calls.call(.merge) { id in mergeBox.set(id); return true }
        async let list = calls.call(.listPullRequests) { id in listBox.set(id); return true }
        while mergeBox.get() == nil || listBox.get() == nil { try? await Task.sleep(for: .milliseconds(5)) }
        let mergeId = mergeBox.get()!, listId = listBox.get()!
        #expect(await !calls.authorizesWrite(listId))
        #expect(await !calls.authorizesWrite("made-up"))
        #expect(await !calls.authorizesWrite(nil))
        for _ in 0..<PluginCodeHostCalls.writesPerCall { #expect(await calls.authorizesWrite(mergeId)) }
        #expect(await !calls.authorizesWrite(mergeId))
        await calls.finish(listId, .result(.object([:])))
        await calls.failAll("stopped")
        #expect(await merge == .failed("stopped"))
        _ = await list
        #expect(await !calls.authorizesWrite(mergeId))
    }
}

/// A value tests share across tasks.
private final class Box<T: Sendable>: Sendable {
    private let value: Mutex<T>
    init(_ value: T) { self.value = Mutex(value) }
    func get() -> T { value.withLock { $0 } }
    func set(_ new: T) { value.withLock { $0 = new } }
}
