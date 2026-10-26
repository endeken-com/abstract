import Foundation
import JavaScriptCore
import Testing
@testable import AbstractCore

/// Runs the bundled GitHub plugin's script (ABS-139) outside Abstract: its
/// logic is plain JavaScript, so tests hand it `gh` output recorded on test
/// repositories (accounts, names and links are placeholders) and read its
/// answers the way core does.
enum GitHubPluginHarness {
    static var folder: URL {
        let here = URL(fileURLWithPath: #filePath)
        let repo = here.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return repo.appendingPathComponent("Abstract/Resources/Plugins/github.abstractplugin")
    }

    static func context() throws -> JSContext {
        let source = try String(contentsOf: folder.appendingPathComponent("background.js"), encoding: .utf8)
        let context = try #require(JSContext())
        context.evaluateScript(source)
        return context
    }

    /// `expression` with `__args[n]` bound from JSON texts, as JSON.
    static func evaluate(_ expression: String, args: [String] = []) throws -> JSONValue {
        let context = try context()
        context.setObject(args, forKeyedSubscript: "__argTexts" as NSString)
        context.evaluateScript("const __args = __argTexts.map((text) => JSON.parse(text));")
        let result = context.evaluateScript("JSON.stringify(\(expression))")
        if let exception = context.exception { throw AbstractError.message("\(expression) threw: \(exception)") }
        let text = try #require(result?.toString())
        guard text != "undefined" else { return .null }
        return JSONValue(any: try JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed))
    }

    /// A pull request from `gh pr view/list --json`, through the plugin, as core reads it.
    static func decode(_ data: Data) throws -> PullRequest {
        let value = try evaluate("GitHubHost.pullRequest(__args[0])", args: [String(decoding: data, as: UTF8.self)])
        guard let pr = PullRequest(contract: value) else { throw AbstractError.message("Unexpected pull request JSON from gh") }
        return pr
    }

    /// Review threads from the plugin's GraphQL query.
    static func decodeThreads(_ data: Data) throws -> [PullRequest.ReviewThread] {
        try evaluate("GitHubHost.threads(__args[0])", args: [String(decoding: data, as: UTF8.self)])
            .array?.compactMap(PullRequest.ReviewThread.init(contract:)) ?? []
    }

    /// Issues or pull requests from `gh issue/pr list --json`.
    static func decodeItems(_ data: Data, isPullRequest: Bool) throws -> [ForgeItem] {
        try evaluate("__args[0].map((json) => GitHubHost.item(json, \(isPullRequest))).filter(Boolean)",
                     args: [String(decoding: data, as: UTF8.self)])
            .array?.compactMap(ForgeItem.init(contract:)) ?? []
    }

    struct Run: Sendable {
        var args: [String]
        var where_: JSONValue
    }

    /// Answers one operation with `gh` answering from `replies`: the first
    /// whose key the command line starts with (`"pr view"`), as
    /// `{ code, stdout, stderr }`; none answers as a missing gh would.
    static func answer(_ op: String, input: String = "{}", context: String = #"{"projectKey": "mac:p1"}"#,
                       replies: [String: [String: Any]] = [:]) throws -> (result: JSONValue, runs: [Run]) {
        let js = try Self.context()
        let repliesJSON = String(decoding: try JSONSerialization.data(withJSONObject: replies), as: UTF8.self)
        js.evaluateScript("""
            const __replies = \(repliesJSON);
            const __runs = [];
            let __result = "pending";
            const __run = (args, where) => {
              __runs.push({ args, where: where || {} });
              const line = args.join(" ");
              const key = Object.keys(__replies).sort((a, b) => b.length - a.length).find((k) => line.startsWith(k));
              if (key === undefined) {
                const error = new Error("gh isn't installed.");
                error.missing = "gh"; error.install = "brew install gh";
                return Promise.reject(error);
              }
              const reply = __replies[key];
              const code = reply.code || 0;
              return Promise.resolve({ code, ok: code === 0, stdout: reply.stdout || "", stderr: reply.stderr || "" });
            };
            GitHubHost.answer("\(op)", \(input), \(context), __run)
              .then((value) => { __result = JSON.stringify({ value }); }, (error) => { __result = JSON.stringify({ error: String(error.message || error) }); });
            """)
        if let exception = js.exception { throw AbstractError.message("\(op) threw: \(exception)") }
        let text = try #require(js.evaluateScript("__result")?.toString())
        guard text != "pending" else { throw AbstractError.message("\(op) never finished") }
        let result = JSONValue(any: try JSONSerialization.jsonObject(with: Data(text.utf8)))
        let runsText = try #require(js.evaluateScript("JSON.stringify(__runs)")?.toString())
        let runs = (JSONValue(any: try JSONSerialization.jsonObject(with: Data(runsText.utf8))).array ?? []).map {
            Run(args: $0["args"]?.array?.compactMap(\.string) ?? [], where_: $0["where"] ?? .null)
        }
        if let error = result["error"]?.string { throw CodeHostError.failed(error) }
        return (result["value"] ?? .null, runs)
    }
}

@Suite("GitHub plugin")
struct GitHubPluginTests {
    typealias H = GitHubPluginHarness

    private let detail = #"""
    {"number": 12, "title": "Derive chat status", "state": "OPEN", "isDraft": false,
     "url": "https://github.com/acme/app/pull/12", "headRefName": "abstract/derive-status", "baseRefName": "main",
     "author": {"login": "wes", "is_bot": false}, "reviewDecision": "CHANGES_REQUESTED",
     "mergeable": "CONFLICTING", "mergeStateStatus": "DIRTY", "additions": 10, "deletions": 2, "changedFiles": 2,
     "createdAt": "2026-09-22T21:16:26Z", "updatedAt": "2026-09-22T22:00:00Z", "body": "Rows derive status.",
     "statusCheckRollup": [
       {"__typename": "CheckRun", "name": "test", "workflowName": "CI", "status": "COMPLETED", "conclusion": "SUCCESS", "detailsUrl": "https://ci/1"},
       {"__typename": "CheckRun", "name": "lint", "workflowName": "CI", "status": "COMPLETED", "conclusion": "FAILURE", "detailsUrl": "https://github.com/acme/app/actions/runs/77/job/2"},
       {"__typename": "CheckRun", "name": "e2e", "workflowName": "CI", "status": "IN_PROGRESS", "conclusion": ""},
       {"__typename": "CheckRun", "name": "deploy", "status": "COMPLETED", "conclusion": "SKIPPED"},
       {"__typename": "StatusContext", "context": "vercel", "state": "PENDING", "targetUrl": "https://vercel/3"}
     ],
     "reviews": [{"author": {"login": "ana"}, "state": "CHANGES_REQUESTED", "body": "Keep stored status for archived chats.", "submittedAt": "2026-09-22T21:30:00Z"}],
     "comments": [
       {"author": {"login": "linear-code"}, "authorAssociation": "NONE", "body": "<p>DGDEV-1</p>", "createdAt": "2026-09-22T21:17:00Z"},
       {"author": {"login": "ana"}, "authorAssociation": "MEMBER", "body": "Looks close.", "createdAt": "2026-09-22T21:31:00Z"}
     ]}
    """#

    // MARK: The manifest

    @Test func itIsAValidCodeHostWithTheCommandsTheTicketLists() throws {
        let manifest = try PluginManifest.decode(Data(contentsOf: H.folder.appendingPathComponent("manifest.json")))
        try manifest.validate()
        let cli = try #require(manifest.cli)
        #expect(cli.binary == "gh")
        #expect(Set(cli.reads.map(\.words)) == ["auth status", "pr list", "pr view", "api graphql", "issue list", "issue view", "repo view"])
        #expect(Set(cli.writes.map(\.words)) == ["pr create", "pr merge", "pr ready", "pr close", "pr update-branch", "run rerun"])
        #expect(manifest.contributes.codeHost?.hosts == ["github.com"])
        #expect(manifest.contributes.codeHost?.answers == Set(CodeHostOperation.allCases))
        #expect(manifest.contributes.settingsPage != nil)
        #expect(PluginManager.defaultPluginIds.contains(manifest.id))
        let inspection = try PluginPackage.inspect(folder: H.folder)
        #expect(inspection.manifest.id == "sh.abstract.github")
    }

    @Test func itIsInstalledAndOnByDefaultOnce() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("github-default-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let manager = PluginManager(store: try Store.inMemory(), pluginsRoot: root.appendingPathComponent("Plugins"),
                                    dataRoot: root.appendingPathComponent("Data"))
        #expect(manager.installDefaults(from: [H.folder]))
        let record = try #require(manager.records().first)
        #expect(record.id == "sh.abstract.github" && record.enabled && record.source == .bundled)
        #expect(record.grantedCapabilities == [.cli] && record.grantedCLI?.binary == "gh" && record.grantedBackground)
        // Turned off, it stays off; removed, it stays removed.
        manager.setEnabled(record.id, false)
        manager.installDefaults(from: [H.folder])
        #expect(manager.records().first?.enabled == false)
        manager.remove(record.id)
        manager.installDefaults(from: [H.folder])
        #expect(manager.records().isEmpty)
    }

    // MARK: Decoding recorded gh output

    @Test func readsADetailedPullRequest() throws {
        let pr = try H.decode(Data(detail.utf8))
        #expect(pr.number == 12)
        #expect(pr.state == .open)
        #expect(pr.head == "abstract/derive-status" && pr.base == "main")
        #expect(pr.reviewDecision == .changesRequested)
        #expect(pr.hasConflicts)
        #expect(pr.mergeState == "DIRTY")
        #expect(pr.url?.absoluteString == "https://github.com/acme/app/pull/12")
        #expect(pr.reviews.first?.verdict == .changesRequested)
        #expect(pr.comments.map(\.isBot) == [true, false])
        #expect(pr.createdAt == ISO8601DateFormatter().date(from: "2026-09-22T21:16:26Z"))
    }

    @Test func checkRunsAndCommitStatusesShareOneOutcome() throws {
        let pr = try H.decode(Data(detail.utf8))
        #expect(pr.checks.map(\.outcome) == [.passed, .failed, .pending, .skipped, .pending])
        let sum = pr.checksSummary
        #expect((sum.passed, sum.failed, sum.pending, sum.skipped) == (1, 1, 2, 1))
        #expect(pr.checks.last?.name == "vercel")
    }

    @Test func checksRefreshEvenWhenPRTimestampDoesNot() throws {
        let detail = try H.decode(Data(detail.utf8))
        var summary = detail
        summary.checks[2].outcome = .passed
        summary.reviews = []
        summary.comments = []
        summary.mergeable = nil
        let refreshed = detail.refreshingSummary(with: summary)
        #expect(refreshed.updatedAt == detail.updatedAt)
        #expect(refreshed.checks[2].outcome == .passed)
        #expect(refreshed.reviews == detail.reviews)
        #expect(refreshed.comments == detail.comments)
        #expect(refreshed.mergeable == detail.mergeable)
    }

    @Test func aListSkipsEntriesItCannotRead() throws {
        let list = #"[{"number": 3, "title": "A", "state": "MERGED", "headRefName": "x", "baseRefName": "main", "mergeCommit": {"oid": "abc123"}}, {"oops": true}]"#
        let (value, runs) = try H.answer("listPullRequests", input: #"{"state": "all", "limit": 100}"#,
                                         replies: ["pr list": ["stdout": list]])
        let prs = value["pullRequests"]?.array?.compactMap(PullRequest.init(contract:)) ?? []
        #expect(prs.map(\.number) == [3])
        #expect(prs.first?.state == .merged)
        #expect(prs.first?.checks.isEmpty == true)
        #expect(prs.first?.mergeCommit == "abc123")
        #expect(runs.first?.args == ["pr", "list", "--state", "all", "--limit", "100", "--json", GitHubPluginHarness.summaryFields])
        #expect(runs.first?.where_["projectKey"]?.string == "mac:p1")
    }

    @Test func aChatPullRequestBeyondTheRecentLimitIsFoundByHead() throws {
        let old = #"[{"number": 12, "title": "Old but open", "state": "OPEN", "headRefName": "chat/old", "baseRefName": "main"}]"#
        let (value, runs) = try H.answer("listPullRequests", input: #"{"branches":["chat/old","chat/old"],"limit":100}"#,
                                         replies: ["pr list --head": ["stdout": old], "pr list": ["stdout": "[]"]])
        #expect(value["pullRequests"]?.array?.compactMap(PullRequest.init(contract:)).map(\.number) == [12])
        #expect(runs.count == 2)
        #expect(runs[1].args == ["pr", "list", "--head", "chat/old", "--state", "all", "--limit", "5",
                                 "--json", H.summaryFields])
    }

    @Test func aProjectCallCarriesTheResolvedHostAndRepository() throws {
        let (_, runs) = try H.answer("listPullRequests", context: #"{"projectKey":"mac:p1","host":"github.example.com","repository":"acme/app"}"#,
                                     replies: ["pr list": ["stdout": "[]"]])
        #expect(runs[0].where_["githubHost"]?.string == "github.example.com")
        #expect(runs[0].where_["githubRepository"]?.string == "acme/app")
    }

    @Test func accessChecksTheProjectsEnterpriseHost() throws {
        let (_, runs) = try H.answer("access", context: #"{"projectKey":"mac:p1","host":"github.example.com","repository":"acme/app"}"#,
                                     replies: ["auth status": ["code": 1, "stderr": "not signed in"]])
        #expect(runs.first?.args == ["auth", "status", "--hostname", "github.example.com"])
    }

    @Test func reviewThreadsKeepTheirRepliesInOrder() throws {
        let json = #"""
        {"data": {"repository": {"pullRequest": {"reviewThreads": {"nodes": [
          {"id": "T1", "isResolved": false, "isOutdated": true, "path": "app/layout.tsx", "line": null, "originalLine": 37,
           "comments": {"nodes": [
             {"id": "C1", "author": {"login": "ana", "avatarUrl": "https://avatars.githubusercontent.com/u/1"}, "body": "Blocker.", "createdAt": "2026-09-22T14:30:25Z", "diffHunk": "@@ -15,3 +15,4 @@", "originalCommit": {"oid": "def456"}},
             {"id": "C2", "author": {"login": "wes", "avatarUrl": "https://avatars.githubusercontent.com/u/2"}, "body": "Fixed.", "createdAt": "2026-09-23T04:41:00Z"}
           ]}},
          {"id": "T2", "isResolved": true, "isOutdated": false, "path": "a.swift", "line": 4, "comments": {"nodes": []}}
        ]}}}}}
        """#
        let (value, runs) = try H.answer("reviewThreads", input: #"{"number": 12}"#, replies: ["api graphql": ["stdout": json]])
        let threads = value["threads"]?.array?.compactMap(PullRequest.ReviewThread.init(contract:)) ?? []
        #expect(threads.map(\.id) == ["T1", "T2"])
        #expect(threads[0].line == nil && threads[0].originalLine == 37 && threads[0].isOutdated)
        #expect(threads[0].comments.map(\.author) == ["ana", "wes"])
        #expect(threads[0].comments[0].avatar?.host == "avatars.githubusercontent.com")
        #expect(threads[0].diffHunk == "@@ -15,3 +15,4 @@")
        #expect(threads[0].commit == "def456" && threads[1].commit == nil)
        #expect(threads[1].isResolved)
        #expect(runs.first?.args.prefix(8) == ["api", "graphql", "-F", "owner={owner}", "-F", "name={repo}", "-F", "number=12"])
    }

    @Test func viewerPermissionSaysWhoCanPush() throws {
        for (permission, access) in [("ADMIN", "push"), ("MAINTAIN", "push"), ("write", "push"), ("TRIAGE", "readOnly"),
                                     ("READ", "readOnly"), ("", "unknown")] {
            let (value, runs) = try H.answer("pushAccess", input: #"{"slug": "acme/app"}"#,
                                             replies: ["repo view": ["stdout": permission + "\n"]])
            #expect(RepoAccess(rawValue: value["access"]?.string ?? "") == RepoAccess(rawValue: access), "\(permission)")
            #expect(runs.first?.args == ["repo", "view", "acme/app", "--json", "viewerPermission", "--jq", ".viewerPermission"])
        }
        let (failed, _) = try H.answer("pushAccess", input: #"{"slug": "acme/app"}"#, replies: ["repo view": ["code": 1]])
        #expect(failed["access"]?.string == "unknown")
    }

    // MARK: Operations

    @Test func accessSaysMissingSignedOutOrWho() throws {
        let (missing, _) = try H.answer("access")
        #expect(missing["access"]?.string == "missing" && missing["install"]?.string == "brew install gh")
        let (signedOut, _) = try H.answer("access", replies: ["auth status": ["code": 1, "stderr": "You are not logged into any GitHub hosts."]])
        #expect(signedOut["access"]?.string == "signedOut" && signedOut["hint"]?.string == "gh auth login")
        let (ready, runs) = try H.answer("access", replies: [
            "auth status": ["stdout": "github.com\n  ✓ Logged in to github.com account octo-test (keyring)"],
            "api graphql": ["stdout": #"{"data": {"viewer": {"login": "octo-test"}}}"#],
        ])
        #expect(ready["access"]?.string == "ready" && ready["viewer"]?.string == "octo-test")
        #expect(runs.map { $0.args.prefix(2).joined(separator: " ") } == ["auth status", "api graphql"])
    }

    @Test func onePullRequestByBranchOrNumber() throws {
        let (byBranch, runs) = try H.answer("pullRequest", input: #"{"branch": "abstract/derive-status"}"#,
                                            context: #"{"projectKey": "mac:p1", "chatId": "c1"}"#,
                                            replies: ["pr view": ["stdout": detail]])
        #expect(PullRequest(contract: byBranch["pullRequest"] ?? .null)?.number == 12)
        #expect(runs.first?.args == ["pr", "view", "abstract/derive-status", "--json", GitHubPluginHarness.detailFields])
        #expect(runs.first?.where_["chatId"]?.string == "c1")
        let (none, _) = try H.answer("pullRequest", input: #"{"number": 9}"#,
                                     replies: ["pr view": ["code": 1, "stderr": "no pull requests found for branch \"x\""]])
        #expect(none["pullRequest"] == .null)
        #expect(throws: CodeHostError.failed("HTTP 502")) {
            try H.answer("pullRequest", input: #"{"number": 9}"#, replies: ["pr view": ["code": 1, "stderr": "HTTP 502\n"]])
        }
    }

    @Test func createOpensItAndReadsItBack() throws {
        let (value, runs) = try H.answer("create", input: #"{"branch": "fix-cart", "base": "main", "title": "Fix cart", "body": "Body", "draft": true}"#,
                                         context: #"{"chatId": "c1", "callId": "k1"}"#,
                                         replies: ["pr create": ["stdout": "https://github.com/acme/app/pull/12\n"], "pr view": ["stdout": detail]])
        #expect(PullRequest(contract: value["pullRequest"] ?? .null)?.number == 12)
        #expect(runs[0].args == ["pr", "create", "--head", "fix-cart", "--title", "Fix cart", "--body", "Body", "--base", "main", "--draft"])
        // The write carries the call the person started, so it doesn't ask again.
        #expect(runs[0].where_["callId"]?.string == "k1")
    }

    @Test func mergeReadyCloseAndUpdate() throws {
        var (_, runs) = try H.answer("merge", input: #"{"number": 12, "method": "squash", "deleteBranch": false}"#,
                                     replies: ["pr merge": [:]])
        #expect(runs.first?.args == ["pr", "merge", "12", "--squash"])
        (_, runs) = try H.answer("merge", input: #"{"number": 12, "method": "rebase", "deleteBranch": true}"#, replies: ["pr merge": [:]])
        #expect(runs.first?.args == ["pr", "merge", "12", "--rebase", "--delete-branch"])
        #expect(throws: CodeHostError.self) { try H.answer("merge", input: #"{"number": 12, "method": "--admin"}"#, replies: ["pr merge": [:]]) }
        (_, runs) = try H.answer("markReady", input: #"{"number": 12}"#, replies: ["pr ready": [:]])
        #expect(runs.first?.args == ["pr", "ready", "12"])
        (_, runs) = try H.answer("close", input: #"{"number": 12}"#, replies: ["pr close": [:]])
        #expect(runs.first?.args == ["pr", "close", "12"])
        (_, runs) = try H.answer("updateBranch", input: #"{"number": 12}"#, replies: ["pr update-branch": [:]])
        #expect(runs.first?.args == ["pr", "update-branch", "12"])
        #expect(throws: CodeHostError.failed("Pull request #12 is not mergeable")) {
            try H.answer("merge", input: #"{"number": 12, "method": "merge"}"#,
                         replies: ["pr merge": ["code": 1, "stderr": "Pull request #12 is not mergeable"]])
        }
    }

    @Test func rerunFailedRunsTheFailedActionsRunsAgain() throws {
        let (_, runs) = try H.answer("rerunFailed", input: #"{"number": 12}"#,
                                     replies: ["pr view": ["stdout": detail], "run rerun": [:]])
        #expect(runs.map(\.args) == [["pr", "view", "12", "--json", "statusCheckRollup"], ["run", "rerun", "77", "--failed"]])
    }

    @Test func searchFindsIssuesAndPullRequestsToAttach() throws {
        let json = #"[{"number":7,"title":"Add login","url":"u","state":"OPEN","body":"b","isDraft":false,"baseRefName":"main","headRefName":"feat/login"}]"#
        let items = try H.decodeItems(Data(json.utf8), isPullRequest: true)
        #expect(items.first?.attachment.promptText == "GitHub PR #7: Add login\nu\nBase: main\nHead: feat/login\n\nb")

        var (value, runs) = try H.answer("searchIssuesAndPullRequests", input: #"{"query": "", "kind": "issue", "limit": 30}"#,
                                         replies: ["issue list": ["stdout": #"[{"number":3,"title":"Crash","url":"u","state":"OPEN","body":"b"}]"#]])
        #expect(value["items"]?.array?.count == 1)
        #expect(runs.first?.args == ["issue", "list", "--limit", "30", "--json", "number,title,url,state,body", "--state", "open"])
        (value, runs) = try H.answer("searchIssuesAndPullRequests", input: #"{"query": "login bug", "kind": "pullRequest", "limit": 5}"#,
                                     replies: ["pr list": ["stdout": json]])
        #expect(runs.first?.args.suffix(4) == ["--state", "all", "--search", "login bug"])
        (value, runs) = try H.answer("searchIssuesAndPullRequests", input: ##"{"query": "#12", "kind": "issue"}"##,
                                     replies: ["issue view": ["stdout": #"{"number":12,"title":"One","url":"u","state":"CLOSED"}"#]])
        #expect(runs.first?.args.prefix(3) == ["issue", "view", "12"])
        #expect(ForgeItem(contract: value["items"]?.array?.first ?? .null)?.state == "CLOSED")
        #expect(throws: CodeHostError.failed("This project's repository isn't on GitHub.")) {
            try H.answer("searchIssuesAndPullRequests", input: #"{"query": "", "kind": "issue"}"#,
                         replies: ["issue list": ["code": 1, "stderr": "none of the git remotes configured for this repository point to a known GitHub host"]])
        }
    }

    @Test func numbersAndLinksAreLookedUpDirectly() throws {
        #expect(try H.evaluate(##"GitHubHost.directReference("#12")"##) == .string("12"))
        #expect(try H.evaluate(#"GitHubHost.directReference("12")"#) == .string("12"))
        #expect(try H.evaluate(#"GitHubHost.directReference("https://github.com/o/r/pull/3")"#) == .string("https://github.com/o/r/pull/3"))
        #expect(try H.evaluate(#"GitHubHost.directReference("login bug")"#) == .null)
    }

    @Test func enterpriseHostsItIsSignedInToAreItsToo() throws {
        let output = """
        github.com
          ✓ Logged in to github.com account octo-test (keyring)
        git.example.com
          ✓ Logged in to git.example.com account octo-test (GH_TOKEN)
        """
        #expect(try H.evaluate("GitHubHost.signedInHosts(__args[0])", args: [#""\#(output.replacingOccurrences(of: "\n", with: "\\n"))""#])
                == .array([.string("git.example.com")]))
    }

    @Test func anUnknownOperationFails() {
        #expect(throws: CodeHostError.self) { try H.answer("deleteRepository") }
    }
}

extension GitHubPluginHarness {
    static var summaryFields: String { (try? evaluate("GitHubHost.summaryFields").string) ?? "" }
    static var detailFields: String { (try? evaluate("GitHubHost.detailFields").string) ?? "" }
}
