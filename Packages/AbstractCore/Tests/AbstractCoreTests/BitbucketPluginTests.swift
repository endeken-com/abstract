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
              // Like bkt 0.35.2, which has only the global --json flag.
              if (args.includes("--output")) return Promise.resolve({ok: false, code: 1, stdout: "", stderr: "Error: unknown flag: --output\\n"});
              // Bitbucket Cloud takes at most 50 a page, and bkt pages by --limit.
              const limit = args.indexOf("--limit");
              if (args.includes("--workspace") && limit >= 0 && Number(args[limit + 1]) > 50)
                return Promise.resolve({ok: false, code: 1, stdout: "", stderr: "Error: 400 Bad Request: Invalid pagelen\\n"});
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

    /// Loads `script` as the app does, with `window.AbstractPlugin` and a
    /// page's `status` and `detail` paragraphs, and `bkt` answering `reply`
    /// (nil when it isn't installed).
    static func load(_ script: String, reply: [String: Any]?) throws -> (texts: [String: String], runs: [[String]], hosts: [String]?) {
        let js = try #require(JSContext())
        let replyJSON = String(decoding: try JSONSerialization.data(withJSONObject: reply ?? ["missing": true]), as: UTF8.self)
        js.evaluateScript("""
            var window = this;
            const __reply = \(replyJSON);
            const __runs = [];
            const __texts = {};
            let __hosts = null;
            var document = { getElementById: (id) => ({ set textContent(value) { __texts[id] = value; } }) };
            window.AbstractPlugin = {
              cli: { run: (args) => {
                __runs.push(args);
                if (__reply.missing) {
                  const error = new Error("bkt isn't installed."); error.missing = "bkt";
                  error.install = "brew install avivsinai/tap/bitbucket-cli"; return Promise.reject(error);
                }
                if (args.includes("--output")) return Promise.resolve({ok: false, code: 1, stdout: "", stderr: "Error: unknown flag: --output\\n"});
                const code = __reply.code || 0;
                return Promise.resolve({ok: code === 0, code, stdout: __reply.stdout || "", stderr: __reply.stderr || ""});
              } },
              codeHost: { handle: () => {}, setHosts: (hosts) => { __hosts = hosts; } },
            };
            """)
        js.evaluateScript(try String(contentsOf: folder.appendingPathComponent(script), encoding: .utf8))
        if let error = js.exception { throw AbstractError.message("\(error)") }
        let raw = try #require(js.evaluateScript("JSON.stringify({texts: __texts, runs: __runs, hosts: __hosts})")?.toString())
        let out = JSONValue(any: try JSONSerialization.jsonObject(with: Data(raw.utf8)))
        let texts = (out["texts"]?.object ?? [:]).compactMapValues(\.string)
        let runs = (out["runs"]?.array ?? []).map { $0.array?.compactMap(\.string) ?? [] }
        return (texts, runs, out["hosts"]?.array?.compactMap(\.string))
    }
}

@Suite("Bitbucket plugin")
struct BitbucketPluginTests {
    typealias H = BitbucketPluginHarness

    // bkt auth status --json, shaped like bkt 0.35.2's answer.
    private let cloudAuth = #"{"active_context":"cloud","hosts":[{"key":"cloud","kind":"cloud","base_url":"https://api.bitbucket.org/2.0","username":"sample","auth_method":"basic","token_source":"keyring"}],"contexts":[{"name":"cloud","host":"cloud","workspace":"sample","active":true}]}"#
    private let dcAuth = #"{"active_context":"team","hosts":[{"key":"team","kind":"dc","base_url":"https://code.example.com/bitbucket","username":"sample","auth_method":"basic","token_source":"keyring"}],"contexts":[{"name":"team","host":"team","active":true}]}"#
    /// What bkt 0.35.2 answers with no host configured, exit 0.
    private let signedOutAuth = #"{"hosts":null,"contexts":null}"#
    private let cloudPR = #"{"id":12,"title":"Fix cart","state":"OPEN","draft":true,"created_on":"2026-10-20T11:00:00Z","updated_on":"2026-10-20T12:00:00Z","description":"Fixes checkout.","author":{"nickname":"sample"},"source":{"branch":{"name":"fix/cart"}},"destination":{"branch":{"name":"main"}},"links":{"html":{"href":"https://bitbucket.org/sample/app/pull-requests/12"}},"participants":[{"user":{"nickname":"reviewer"},"approved":true}]}"#
    private let dcPR = #"{"id":9,"title":"Fix build","state":"MERGED","draft":false,"createdDate":1792494000000,"updatedDate":1792497600000,"description":"Build fix.","author":{"user":{"name":"sample"}},"fromRef":{"displayId":"fix/build"},"toRef":{"displayId":"main"},"links":{"self":[{"href":"https://code.example.com/projects/APP/repos/app/pull-requests/9"}]},"reviewers":[{"user":{"name":"reviewer"},"approved":true}]}"#
    private let builds = #"{"statuses":[{"state":"SUCCESSFUL","key":"unit","name":"Unit tests","url":"https://ci.example.com/1"},{"state":"FAILED","key":"lint","name":"Lint"},{"state":"INPROGRESS","key":"deploy"}]}"#

    @Test func manifestDeclaresOnlySupportedOperations() throws {
        let manifest = try PluginManifest.decode(Data(contentsOf: H.folder.appendingPathComponent("manifest.json")))
        try manifest.validate()
        #expect(manifest.cli?.binary == "bkt")
        #expect(manifest.cli?.install == "brew install avivsinai/tap/bitbucket-cli")
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
        #expect(runs[0].args == ["auth", "status", "--json"])
        #expect(runs[1].args == ["pr", "list", "--state", "ALL", "--limit", "50", "--json", "--context", "cloud",
                                  "--workspace", "sample", "--repo", "app"])
        let (detail, _) = try H.answer("pullRequest", input: #"{"number":12}"#, replies: [
            "auth status": ["stdout": cloudAuth], "pr view": ["stdout": #"{"pull_request":\#(cloudPR)}"#],
            "pr checks": ["stdout": builds], "pr comments": ["stdout": notes],
        ])
        let (byBranch, branchRuns) = try H.answer("pullRequest", input: #"{"branch":"fix/cart"}"#, replies: [
            "auth status": ["stdout": cloudAuth], "pr list": ["stdout": #"{"pull_requests":[\#(cloudPR)]}"#],
            "pr view": ["stdout": #"{"pull_request":\#(cloudPR)}"#], "pr checks": ["stdout": builds],
            "pr comments": ["stdout": notes],
        ])
        #expect(PullRequest(contract: byBranch["pullRequest"] ?? .null)?.number == 12)
        #expect(branchRuns[1].args.prefix(5) == ["pr", "list", "--state", "OPEN", "--limit"] && branchRuns[1].args[5] == "50")
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
        #expect(listRuns.last?.args == ["pr", "list", "--state", "ALL", "--limit", "100", "--json",
                                        "--context", "team", "--project", "APP", "--repo", "app"])
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

    @Test func accessAsksBktWithTheGlobalJSONFlag() throws {
        let (ready, runs) = try H.answer("access", replies: ["auth status": ["stdout": cloudAuth]])
        #expect(ready["access"]?.string == "ready" && ready["viewer"]?.string == "sample")
        #expect(runs.map(\.args) == [["auth", "status", "--json"]])
        #expect(!runs.contains { $0.args.contains("--output") })
        let (signedOut, _) = try H.answer("access", replies: ["auth status": ["stdout": signedOutAuth]])
        #expect(signedOut["access"]?.string == "signedOut" && signedOut["hint"]?.string == "bkt auth login")
        let (missing, _) = try H.answer("access", replies: [:])
        #expect(missing["access"]?.string == "missing" && missing["install"]?.string == "brew install avivsinai/tap/bitbucket-cli")
        // A bkt without a flag Abstract uses is out of date, not signed out.
        let old = ["auth status": ["code": 1, "stderr": "Error: unknown flag: --json\n"]] as [String: [String: Any]]
        #expect {
            try H.answer("access", replies: old)
        } throws: { error in
            "\(error)".contains("Update it with brew upgrade bitbucket-cli") && "\(error)".contains("unknown flag: --json")
        }
    }

    @Test func backgroundPublishesSignedInHostsFromAuthStatusJSON() throws {
        let started = try H.load("background.js", reply: ["stdout": dcAuth])
        #expect(started.runs == [["auth", "status", "--json"]])
        #expect(started.hosts == ["code.example.com"])
        let signedOut = try H.load("background.js", reply: ["stdout": signedOutAuth])
        #expect(signedOut.runs == [["auth", "status", "--json"]])
        #expect(signedOut.hosts == [])
    }

    @Test func settingsShowsSignInStateWithoutAFlagError() throws {
        let signedIn = try H.load("settings.js", reply: ["stdout": cloudAuth])
        #expect(signedIn.runs == [["auth", "status", "--json"]])
        #expect(signedIn.texts["status"] == "Signed in with the Bitbucket CLI.")
        #expect(signedIn.texts["detail"] == "sample · https://api.bitbucket.org/2.0 (Cloud)")
        let signedOut = try H.load("settings.js", reply: ["stdout": signedOutAuth])
        #expect(signedOut.runs == [["auth", "status", "--json"]])
        #expect(signedOut.texts["status"] == "Not signed in.")
        #expect(signedOut.texts["detail"] == "Run bkt auth login in a terminal, then come back here.")
        let missing = try H.load("settings.js", reply: nil)
        #expect(missing.texts["status"] == "The Bitbucket CLI isn't installed.")
        #expect(missing.texts["detail"] == "Install it with brew install avivsinai/tap/bitbucket-cli, then run bkt auth login.")
        let old = try H.load("settings.js", reply: ["code": 1, "stderr": "Error: unknown flag: --json\n"])
        #expect(old.texts["status"] == "This version of the Bitbucket CLI needs an update.")
        #expect(old.texts["detail"]?.hasPrefix("Update it with brew upgrade bitbucket-cli") == true)
        for page in [signedIn, signedOut, old] { #expect(!page.runs.joined().contains("--output")) }
    }

    @Test func reviewersAndParticipantsBothCount() throws {
        // Cloud's pr list gives reviewers as bare users, with no vote.
        let listed = #"{"id":12,"title":"Fix cart","state":"OPEN","reviewers":[{"nickname":"reviewer","display_name":"Reviewer"}]}"#
        let summary = try #require(PullRequest(contract: H.evaluate("BitbucketHost.pr(__args[0], 'cloud')", args: [listed])))
        #expect(summary.reviews.map(\.author) == ["reviewer"] && summary.reviewDecision == .reviewRequired)
        // Cloud's pr view adds participants, which carry the votes; a commenter isn't a reviewer.
        let viewed = #"{"id":12,"title":"Fix cart","state":"OPEN","reviewers":[{"nickname":"reviewer"}],"participants":[{"user":{"nickname":"reviewer"},"role":"REVIEWER","approved":true},{"user":{"nickname":"bystander"},"role":"PARTICIPANT","approved":false}]}"#
        let detail = try #require(PullRequest(contract: H.evaluate("BitbucketHost.pr(__args[0], 'cloud')", args: [viewed])))
        #expect(detail.reviews.map(\.author) == ["reviewer"] && detail.reviewDecision == .approved)
        // Data Center lists reviewers and participants separately.
        let dc = #"{"id":9,"title":"Fix build","state":"OPEN","reviewers":[{"user":{"name":"lead"},"role":"REVIEWER","approved":false,"status":"NEEDS_WORK"}],"participants":[{"user":{"name":"bystander"},"role":"PARTICIPANT","approved":false,"status":"UNAPPROVED"}]}"#
        let mapped = try #require(PullRequest(contract: H.evaluate("BitbucketHost.pr(__args[0], 'dc')", args: [dc])))
        #expect(mapped.reviews.map(\.author) == ["lead"] && mapped.reviewDecision == .changesRequested)
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
