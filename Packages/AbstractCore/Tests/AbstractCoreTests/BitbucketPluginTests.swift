import Foundation
import JavaScriptCore
import Testing
@testable import AbstractCore

/// Recorded bkt --json envelopes, with a clean account and repository.
enum BitbucketPluginHarness {
    static var folder: URL {
        let here = URL(fileURLWithPath: #filePath)
        let repo = here.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return repo.appendingPathComponent("Abstract/Resources/Plugins/bitbucket.abstractplugin")
    }

    static func script() throws -> JSContext {
        let js = try #require(JSContext())
        js.evaluateScript(try String(contentsOf: folder.appendingPathComponent("background.js"), encoding: .utf8))
        return js
    }

    static func evaluate(_ expression: String, args: [String] = []) throws -> JSONValue {
        let js = try script()
        js.setObject(args, forKeyedSubscript: "__texts" as NSString)
        js.evaluateScript("const __args = __texts.map((one) => JSON.parse(one));")
        let result = js.evaluateScript("JSON.stringify(\(expression))")
        if let error = js.exception { throw AbstractError.message("\(error)") }
        let raw = try #require(result?.toString())
        return JSONValue(any: try JSONSerialization.jsonObject(with: Data(raw.utf8), options: .fragmentsAllowed))
    }

    struct Run {
        var args: [String]
        var where_: JSONValue
    }

    static func answer(_ op: String, input: String = "{}", context: String = #"{"projectKey":"mac:p1","remote":"https://bitbucket.org/sample/app.git"}"#,
                       replies: [String: [String: Any]]) throws -> (JSONValue, [Run]) {
        let js = try script()
        let repliesJSON = String(decoding: try JSONSerialization.data(withJSONObject: replies), as: UTF8.self)
        js.evaluateScript("""
            const __replies = \(repliesJSON);
            const __runs = [];
            let __result = "pending";
            const __run = (args, where) => {
              __runs.push({args, where: where || {}});
              const line = args.join(" ");
              const key = Object.keys(__replies).sort((a,b) => b.length-a.length).find((one) => line.startsWith(one));
              if (!key) { const error = new Error("bkt isn't installed."); error.missing = "bkt"; return Promise.reject(error); }
              const reply = __replies[key];
              const code = reply.code || 0;
              return Promise.resolve({ok: code === 0, code, stdout: reply.stdout || "", stderr: reply.stderr || ""});
            };
            BitbucketHost.answer("\(op)", \(input), \(context), __run)
              .then((value) => { __result = JSON.stringify({value}); }, (error) => { __result = JSON.stringify({error: String(error.message || error)}); });
            """)
        if let error = js.exception { throw AbstractError.message("\(error)") }
        let raw = try #require(js.evaluateScript("__result")?.toString())
        guard raw != "pending" else { throw AbstractError.message("\(op) never finished") }
        let result = JSONValue(any: try JSONSerialization.jsonObject(with: Data(raw.utf8)))
        let runsRaw = try #require(js.evaluateScript("JSON.stringify(__runs)")?.toString())
        let runs = (JSONValue(any: try JSONSerialization.jsonObject(with: Data(runsRaw.utf8))).array ?? []).map {
            Run(args: $0["args"]?.array?.compactMap(\.string) ?? [], where_: $0["where"] ?? .null)
        }
        if let error = result["error"]?.string { throw CodeHostError.failed(error) }
        return (result["value"] ?? .null, runs)
    }
}

@Suite("Bitbucket plugin")
struct BitbucketPluginTests {
    typealias H = BitbucketPluginHarness

    private let cloudAuth = #"{"hosts":[{"key":"cloud","kind":"cloud","base_url":"https://api.bitbucket.org/2.0","username":"sample"}],"contexts":[{"name":"cloud","host":"cloud","active":true}]}"#
    private let dcAuth = #"{"hosts":[{"key":"team","kind":"dc","base_url":"https://code.example.com/bitbucket","username":"sample"}],"contexts":[{"name":"team","host":"team","active":true}]}"#
    private let cloudPR = #"{"id":12,"title":"Fix cart","state":"OPEN","draft":true,"created_on":"2026-10-20T11:00:00Z","updated_on":"2026-10-20T12:00:00Z","description":"Fixes checkout.","author":{"nickname":"sample"},"source":{"branch":{"name":"fix/cart"}},"destination":{"branch":{"name":"main"}},"links":{"html":{"href":"https://bitbucket.org/sample/app/pull-requests/12"}},"participants":[{"user":{"nickname":"reviewer"},"approved":true}]}"#
    private let dcPR = #"{"id":9,"title":"Fix build","state":"MERGED","draft":false,"createdDate":1792494000000,"updatedDate":1792497600000,"description":"Build fix.","author":{"user":{"name":"sample"}},"fromRef":{"displayId":"fix/build"},"toRef":{"displayId":"main"},"links":{"self":[{"href":"https://code.example.com/projects/APP/repos/app/pull-requests/9"}]},"reviewers":[{"user":{"name":"reviewer"},"approved":true}]}"#
    private let builds = #"{"statuses":[{"state":"SUCCESSFUL","key":"unit","name":"Unit tests","url":"https://ci.example.com/1"},{"state":"FAILED","key":"lint","name":"Lint"},{"state":"INPROGRESS","key":"deploy"}]}"#

    @Test func manifestDeclaresOnlySupportedOperations() throws {
        let manifest = try PluginManifest.decode(Data(contentsOf: H.folder.appendingPathComponent("manifest.json")))
        try manifest.validate()
        #expect(manifest.cli?.binary == "bkt")
        #expect(manifest.contributes.codeHost?.hosts == ["bitbucket.org"])
        #expect(manifest.contributes.codeHost?.answers == Set([.access, .listPullRequests, .pullRequest, .create, .merge,
                                                               .markReady, .close, .reviewThreads, .searchIssuesAndPullRequests]))
        #expect(manifest.contributes.codeHost?.answers.contains(.rerunFailed) == false)
        #expect(manifest.contributes.codeHost?.answers.contains(.updateBranch) == false)
        #expect(manifest.contributes.settingsPage != nil)
    }

    @Test func installsOnFirstBitbucketOfferAndRespectsOptOut() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bitbucket-plugin-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = PluginManager(store: try Store.inMemory(), pluginsRoot: root.appendingPathComponent("Plugins"),
                                    dataRoot: root.appendingPathComponent("Data"))
        #expect(manager.installDefaults(from: [H.folder], ids: ["sh.abstract.bitbucket"]))
        let installed = try #require(manager.records().first)
        #expect(installed.enabled && installed.grantedCLI?.binary == "bkt")
        manager.setEnabled(installed.id, false)
        #expect(!manager.installDefaults(from: [H.folder], ids: ["sh.abstract.bitbucket"]))
        #expect(manager.records().first?.enabled == false)
        manager.remove(installed.id)
        #expect(!manager.installDefaults(from: [H.folder], ids: ["sh.abstract.bitbucket"]))
        #expect(manager.records().isEmpty)
    }

    @Test func cloudAndDataCenterMapToAbstractPullRequests() throws {
        let cloud = try H.evaluate("BitbucketHost.pr(__args[0], 'cloud')", args: [cloudPR])
        let mapped = try #require(PullRequest(contract: cloud))
        #expect(mapped.state == .open && mapped.isDraft)
        #expect(mapped.head == "fix/cart" && mapped.base == "main")
        #expect(mapped.author == "sample" && mapped.reviewDecision == .approved)
        #expect(mapped.hostTitle == "Bitbucket")
        #expect(mapped.mergeMethods == [.squash, .merge, .fastForward])
        let dc = try #require(PullRequest(contract: H.evaluate("BitbucketHost.pr(__args[0], 'dc')", args: [dcPR])))
        #expect(dc.state == .merged && dc.number == 9)
        #expect(dc.url?.host == "code.example.com" && dc.head == "fix/build")
        #expect(dc.createdAt != nil && dc.updatedAt != nil)
    }

    @Test func listsPRsWithBuildStatusAndReadsComments() throws {
        let notes = #"{"comments":[{"id":31,"content":{"raw":"Please fix"},"user":{"nickname":"reviewer"},"inline":{"path":"src/cart.js","to":7}},{"id":32,"parent":{"id":31},"content":{"raw":"Done"},"user":{"nickname":"sample"}},{"id":33,"content":{"raw":"Ship it"},"user":{"nickname":"reviewer"}}]}"#
        let (listed, runs) = try H.answer("listPullRequests", replies: [
            "auth status": ["stdout": cloudAuth], "pr list": ["stdout": #"{"pull_requests":[\#(cloudPR)]}"#],
            "pr checks": ["stdout": builds],
        ])
        let pr = try #require(listed["pullRequests"]?.array?.first.flatMap(PullRequest.init(contract:)))
        #expect(pr.checks.map(\.outcome) == [.passed, .failed, .pending])
        #expect(runs[1].args == ["pr", "list", "--state", "ALL", "--limit", "100", "--json", "--context", "cloud",
                                  "--workspace", "sample", "--repo", "app"])
        let (detail, _) = try H.answer("pullRequest", input: #"{"number":12}"#, replies: [
            "auth status": ["stdout": cloudAuth], "pr view": ["stdout": #"{"pull_request":\#(cloudPR)}"#],
            "pr checks": ["stdout": builds], "pr comments": ["stdout": notes],
        ])
        let whole = try #require(PullRequest(contract: detail["pullRequest"] ?? .null))
        #expect(whole.comments.map(\.body) == ["Ship it"])
        let (threadResult, _) = try H.answer("reviewThreads", input: #"{"number":12}"#,
                                             replies: ["auth status": ["stdout": cloudAuth], "pr comments": ["stdout": notes]])
        let thread = try #require(threadResult["threads"]?.array?.first.flatMap(PullRequest.ReviewThread.init(contract:)))
        #expect(thread.path == "src/cart.js" && thread.line == 7)
        #expect(thread.comments.map(\.body) == ["Please fix", "Done"])
    }

    @Test func dataCenterListsAndViewsItsOwnJSONShape() throws {
        let place = #"{"projectKey":"mac:p2","remote":"ssh://git@code.example.com/APP/app.git"}"#
        let (listed, listRuns) = try H.answer("listPullRequests", context: place, replies: [
            "auth status": ["stdout": dcAuth], "pr list": ["stdout": #"{"pull_requests":[\#(dcPR)]}"#],
        ])
        let summary = try #require(listed["pullRequests"]?.array?.first.flatMap(PullRequest.init(contract:)))
        #expect(summary.state == .merged && summary.head == "fix/build")
        #expect(listRuns.last?.args.suffix(6) == ["--context", "team", "--project", "APP", "--repo", "app"])
        let (viewed, _) = try H.answer("pullRequest", input: #"{"number":9}"#, context: place, replies: [
            "auth status": ["stdout": dcAuth], "pr view": ["stdout": #"{"pull_request":\#(dcPR)}"#],
            "pr comments": ["stdout": #"{"comments":[]}"#],
        ])
        #expect(PullRequest(contract: viewed["pullRequest"] ?? .null)?.number == 9)
        #expect(try H.evaluate("BitbucketHost.state('DECLINED')") == .string("closed"))
        let notes = #"{"comments":[{"id":4,"text":"Fix line","author":{"name":"reviewer"},"anchor":{"path":"app.swift","line":5}},{"id":5,"parent":{"id":4},"text":"Fixed","author":{"name":"sample"}}]}"#
        let mapped = try H.evaluate("BitbucketHost.comments(__args[0], 'dc')", args: [notes])
        let thread = try #require(mapped["threads"]?.array?.first.flatMap(PullRequest.ReviewThread.init(contract:)))
        #expect(thread.path == "app.swift" && thread.comments.map(\.author) == ["reviewer", "sample"])
        let nested = #"{"comments":[{"id":4,"text":"Fix line","author":{"name":"reviewer"},"anchor":{"path":"app.swift","line":5},"comments":[{"id":5,"text":"Fixed","author":{"name":"sample"}}]}]}"#
        let nestedThreads = try H.evaluate("BitbucketHost.comments(__args[0], 'dc')", args: [nested])["threads"]?.array
        #expect(nestedThreads?.first.flatMap(PullRequest.ReviewThread.init(contract:))?.comments.map(\.body) == ["Fix line", "Fixed"])
    }

    @Test func createsAndMergesWithEachDeploymentsStrategy() throws {
        let (created, runs) = try H.answer("create", input: #"{"branch":"fix/cart","base":"main","title":"Fix cart","body":"Body","draft":true}"#,
                                           context: #"{"projectKey":"mac:p1","chatId":"chat","callId":"call","remote":"https://bitbucket.org/sample/app.git"}"#,
                                           replies: ["auth status": ["stdout": cloudAuth], "pr create": ["stdout": #"{"id":12,"title":"Fix cart"}"#],
                                                     "pr view": ["stdout": #"{"pull_request":\#(cloudPR)}"#],
                                                     "pr checks": ["stdout": builds], "pr comments": ["stdout": #"{"comments":[]}"#]])
        #expect(PullRequest(contract: created["pullRequest"] ?? .null)?.number == 12)
        #expect(runs[1].args == ["pr", "create", "--source", "fix/cart", "--title", "Fix cart", "--description", "Body", "--json", "--target", "main", "--draft", "--context", "cloud", "--workspace", "sample", "--repo", "app"])
        #expect(runs[1].where_["callId"]?.string == "call")
        let (_, cloudRuns) = try H.answer("merge", input: #"{"number":12,"method":"squash"}"#,
                                          replies: ["auth status": ["stdout": cloudAuth], "pr merge": [:]])
        #expect(cloudRuns.last?.args == ["pr", "merge", "12", "--strategy", "squash", "--context", "cloud",
                                            "--workspace", "sample", "--repo", "app"])
        let (_, dcRuns) = try H.answer("merge", input: #"{"number":9,"method":"fastForward"}"#,
                                       context: #"{"remote":"ssh://git@code.example.com/APP/app.git"}"#,
                                       replies: ["auth status": ["stdout": dcAuth], "pr merge": [:]])
        #expect(dcRuns.last?.args == ["pr", "merge", "9", "--strategy", "ff", "--context", "team",
                                         "--project", "APP", "--repo", "app"])
        #expect(throws: CodeHostError.self) {
            try H.answer("merge", input: #"{"number":9,"method":"rebase"}"#,
                         replies: ["auth status": ["stdout": cloudAuth]])
        }
    }

    @Test func dataCenterHostAndUnsupportedIssueSearch() throws {
        #expect(try H.evaluate("BitbucketHost.hosts(__args[0])", args: [dcAuth]) == .array([.string("code.example.com")]))
        let (found, _) = try H.answer("searchIssuesAndPullRequests", input: #"{"kind":"issue","query":"one"}"#,
                                      replies: ["auth status": ["stdout": cloudAuth]])
        #expect(found["items"]?.array?.isEmpty == true)
        var attachment = ForgeItem(number: 12, title: "Fix cart", url: "https://bitbucket.org/sample/app/pull-requests/12",
                                   state: "OPEN", body: nil, isPullRequest: true, isDraft: false,
                                   baseRefName: "main", headRefName: "fix/cart").attachment
        attachment.trackerName = "Bitbucket"
        #expect(attachment.promptText.hasPrefix("Bitbucket PR #12: Fix cart"))
    }
}
