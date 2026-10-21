import Foundation
import JavaScriptCore
import Testing
@testable import AbstractCore

/// The official Linear plugin (ABS-141). Its logic is plain JavaScript,
/// so these tests run the shipped script over Linear GraphQL replies cut
/// to the fields it reads, with placeholder workspaces, people and links.
@Suite struct LinearPluginTests {
    var pluginFolder: URL {
        let here = URL(fileURLWithPath: #filePath)
        let repo = here.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return repo.appendingPathComponent("Abstract/Resources/Plugins/linear.abstractplugin")
    }

    /// One recorded reply: the first whose `when` is in the request's
    /// GraphQL query answers it.
    struct Reply {
        var when: String
        var status: Int = 200
        var body: String
    }

    /// What the fake `linear` answers to a command starting with `args`.
    struct Run {
        var args: [String]
        var code: Int = 0
        var stdout: String = ""
        var stderr: String = ""
    }

    /// Runs `LinearTracker.answer(operation, input)` with a fetch that
    /// answers from `replies` (no key entered answers as the host does),
    /// and, when `cli` is given, a `linear` that answers from it (nil
    /// leaves the CLI out; `missing` is the host's answer when it isn't
    /// installed). Returns the result, or the error, what was fetched and
    /// what was run.
    func answer(_ operation: String, _ input: [String: String] = [:], replies: [Reply] = [], key: Bool = true,
                cli: [Run]? = nil, missing: Bool = false, settings: [String: String] = [:]) throws
        -> (result: JSONValue, error: String?, asked: [JSONValue], ran: [[String]]) {
        let source = try String(contentsOf: pluginFolder.appendingPathComponent("background.js"), encoding: .utf8)
        let context = try #require(JSContext())
        context.evaluateScript(source)
        func literal(_ value: Any) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed), as: UTF8.self)
        }
        let repliesJSON = try literal(replies.map { ["when": $0.when, "status": $0.status, "body": $0.body] as [String: Any] })
        let runsJSON = try literal((cli ?? []).map {
            ["args": $0.args, "code": $0.code, "stdout": $0.stdout, "stderr": $0.stderr] as [String: Any]
        })
        context.evaluateScript("""
            const __replies = \(repliesJSON);
            const __runs = \(runsJSON);
            const __asked = [];
            const __ran = [];
            let __result = "pending";
            let __error = null;
            const __fetch = (url, options) => {
              const body = JSON.parse(options.body);
              const secret = options.secretHeaders && options.secretHeaders.Authorization;
              __asked.push({ url, method: options.method, secret: secret ? secret.secret : null, query: body.query, variables: body.variables });
              if (!\(key)) return Promise.resolve({ message: "That secret hasn't been entered in Settings → Plugins yet." });
              const reply = __replies.find((r) => body.query.includes(r.when));
              return Promise.resolve(reply ? { status: reply.status, body: reply.body, bodyIsBase64: false }
                                           : { status: 500, body: "{}", bodyIsBase64: false });
            };
            const __cli = (args) => {
              __ran.push(args);
              if (\(missing)) {
                const error = new Error("linear isn't installed.");
                error.missing = "linear"; error.install = "brew install schpet/tap/linear";
                return Promise.reject(error);
              }
              const run = __runs.find((r) => r.args.every((word, i) => args[i] === word));
              if (!run) return Promise.resolve({ code: 1, ok: false, stdout: "", stderr: "unexpected " + args.join(" "), truncated: false });
              return Promise.resolve({ code: run.code, ok: run.code === 0, stdout: run.stdout, stderr: run.stderr, truncated: false });
            };
            LinearTracker.answer("\(operation)", \(try literal(input)),
                                 { fetch: __fetch, cli: \(cli == nil && !missing ? "null" : "__cli"), settings: \(try literal(settings)) })
              .then((result) => { __result = JSON.stringify(result); }, (error) => { __result = "null"; __error = String(error.message || error); });
            """)
        if let exception = context.exception { Issue.record("threw: \(exception.toString() ?? "?")") }
        let result = try #require(context.evaluateScript("__result")?.toString())
        #expect(result != "pending")
        let error = context.evaluateScript("__error")?.toString()
        let asked = try #require(context.evaluateScript("JSON.stringify(__asked)")?.toString())
        let ran = try #require(context.evaluateScript("JSON.stringify(__ran)")?.toString())
        let runs = (try json(ran).array ?? []).map { ($0.array ?? []).compactMap(\.string) }
        return (try json(result), error == "null" ? nil : error, try json(asked).array ?? [], runs)
    }

    func json(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    // MARK: Recorded replies

    /// An issue node as Linear's GraphQL API returns it.
    static func node(_ key: String, title: String, state: String = "In Progress", type: String = "started",
                     assignee: String? = "Sample Person", description: String? = "Steps to reproduce") -> String {
        let person = assignee.map { #"{"name":"\#($0)","displayName":"\#($0.split(separator: " ")[0].lowercased())"}"# } ?? "null"
        let text = description.map { "\"\($0)\"" } ?? "null"
        return """
            {"id":"00000000-0000-0000-0000-\(String(repeating: "0", count: 12 - key.count))\(key.filter(\.isNumber))",
             "identifier":"\(key)","title":"\(title)","url":"https://linear.app/example/issue/\(key.lowercased())/\(title.lowercased().replacingOccurrences(of: " ", with: "-"))",
             "description":\(text),"state":{"name":"\(state)","type":"\(type)"},"assignee":\(person)}
            """
    }

    static let viewer = Reply(when: "viewer { name", body: #"{"data":{"viewer":{"name":"Sample Person"}}}"#)
    static let assigned = Reply(when: "assignedIssues", body: """
        {"data":{"viewer":{"assignedIssues":{"nodes":[\(node("ENG-12", title: "Fix login", description: nil)),\(node("ENG-7", title: "Empty carts", state: "Todo", type: "unstarted", assignee: nil, description: nil))]}}}}
        """)
    static let search = Reply(when: "searchIssues", body: """
        {"data":{"searchIssues":{"nodes":[\(node("ENG-12", title: "Fix login", description: nil))]}}}
        """)
    static let one = Reply(when: "issue(id", body: """
        {"data":{"issue":\(node("ENG-12", title: "Fix login"))}}
        """)
    static let notFound = Reply(when: "issue(id", body: """
        {"errors":[{"message":"Entity not found: Issue","extensions":{"type":"invalid input","code":"INPUT_ERROR"}}],"data":null}
        """)
    static let unauthorized = Reply(when: "viewer", status: 400, body: """
        {"errors":[{"message":"Authentication required, not authenticated","extensions":{"code":"AUTHENTICATION_ERROR"}}]}
        """)
    static let teamsAndProjects = Reply(when: "teams(", body: """
        {"data":{"teams":{"nodes":[{"id":"team-1","name":"Engineering","key":"ENG"}]},
                 "projects":{"nodes":[{"id":"project-1","name":"Checkout"}]}}}
        """)

    static let fixLogin = TrackerIssue(key: "ENG-12", title: "Fix login", state: "In Progress", assignee: "sample",
                                       url: "https://linear.app/example/issue/eng-12/fix-login", excerpt: "Steps to reproduce")
    /// As a search lists it: no description, as the Linear CLI lists it.
    static var fixLoginListed: TrackerIssue {
        var listed = fixLogin
        listed.excerpt = nil
        return listed
    }

    // MARK: The package

    @Test func theBundledPackageIsALinearTrackerThatReachesOnlyLinear() throws {
        let manifest = try PluginPackage.inspect(folder: pluginFolder).manifest
        try manifest.validate()
        #expect(manifest.id == PromptAttachment.linearTrackerId)
        #expect(manifest.networkHosts == ["api.linear.app"])
        #expect(manifest.secretDeclarations.map(\.name) == ["api-key"])
        #expect(manifest.background == "background.js")
        let tracker = try #require(manifest.contributes.issueTracker)
        #expect(tracker.title == "Linear")
        #expect(tracker.keyExample == "ENG-123")
        #expect(tracker.isKey("eng-123") && !tracker.isKey("fix login"))
        #expect(PluginPackage.fileData(in: pluginFolder, relativePath: tracker.icon ?? "") != nil)
    }

    // MARK: Keys and links

    @Test func aKeyOrALinearLinkIsAskedForAsThatIssue() throws {
        for reference in ["eng-12", "ENG-12", "https://linear.app/example/issue/ENG-12/fix-login", "https://linear.app/example/issue/eng-12"] {
            let (result, error, asked, _) = try answer("issue", ["reference": reference], replies: [Self.one])
            #expect(error == nil)
            #expect(asked.first?["variables"]?["id"] == .string("ENG-12"), "\(reference)")
            #expect(TrackerAnswer.parse(.issue(reference), .object(["result": result])) == .issue(Self.fixLogin))
        }
        // Anything else isn't Linear's to answer, and nothing is asked.
        for reference in ["https://github.com/example/shop/issues/12", "https://linear.app/example/project/checkout", "fix login"] {
            let (result, _, asked, _) = try answer("issue", ["reference": reference], replies: [Self.one])
            #expect(result["issue"] == .null, "\(reference)")
            #expect(asked.isEmpty)
        }
    }

    @Test func aKeyLinearDoesntKnowFindsNothing() throws {
        let (result, error, _, _) = try answer("issue", ["reference": "ENG-404"], replies: [Self.notFound])
        #expect(error == nil)
        #expect(result["issue"] == .null)
    }

    // MARK: Searching

    @Test func anEmptySearchListsYourOpenIssues() throws {
        let (result, error, asked, _) = try answer("searchIssues", ["query": ""], replies: [Self.assigned])
        #expect(error == nil)
        #expect(asked.count == 1)
        #expect(asked[0]["url"] == .string("https://api.linear.app/graphql"))
        #expect(asked[0]["secret"] == .string("api-key"))
        #expect(asked[0]["query"]?.string?.contains("assignedIssues") == true)
        #expect(asked[0]["query"]?.string?.contains("description") == false)
        #expect(asked[0]["variables"]?["filter"]?["state"]?["type"]?["nin"] == .array([.string("completed"), .string("canceled")]))
        let issues = TrackerAnswer.parse(.searchIssues(query: "", project: nil), .object(["result": result])).issues
        #expect(issues == [Self.fixLoginListed, TrackerIssue(key: "ENG-7", title: "Empty carts", state: "Todo",
                                                        url: "https://linear.app/example/issue/eng-7/empty-carts")])
    }

    @Test func wordsSearchLinearAndATeamOrProjectNarrowsIt() throws {
        let (result, _, asked, _) = try answer("searchIssues", ["query": "login"], replies: [Self.search])
        #expect(asked[0]["variables"] == .object(["term": .string("login")]))
        #expect(TrackerAnswer.parse(.searchIssues(query: "login", project: nil), .object(["result": result])).issues == [Self.fixLoginListed])

        let (_, _, scoped, _) = try answer("searchIssues", ["query": "login", "project": "team:ENG"], replies: [Self.search])
        #expect(scoped[0]["variables"]?["filter"] == .object(["team": .object(["key": .object(["eq": .string("ENG")])])]))
        let (_, _, project, _) = try answer("searchIssues", ["query": "", "project": "project:project-1"], replies: [Self.assigned])
        #expect(project[0]["variables"]?["filter"]?["project"]?["id"]?["eq"] == .string("project-1"))
        // A key typed into the search is that issue.
        let (byKey, _, keyAsked, _) = try answer("searchIssues", ["query": "ENG-12"], replies: [Self.one])
        #expect(keyAsked[0]["query"]?.string?.contains("issue(id") == true)
        #expect(TrackerAnswer.parse(.searchIssues(query: "ENG-12", project: nil), .object(["result": byKey])).issues == [Self.fixLoginListed])
    }

    @Test func teamsAndProjectsAreListed() throws {
        let (result, _, _, _) = try answer("listProjects", replies: [Self.teamsAndProjects])
        #expect(TrackerAnswer.parse(.listProjects, .object(["result": result])) == .projects([
            TrackerProject(id: "team:ENG", name: "Engineering", kind: .team, key: "ENG"),
            TrackerProject(id: "project:project-1", name: "Checkout", kind: .project),
        ]))
    }

    // MARK: Connecting and errors

    @Test func accessSaysWhoseKeyItIsOrWhatToDo() throws {
        let (ready, _, _, _) = try answer("access", replies: [Self.viewer])
        #expect(TrackerAccess(ready) == TrackerAccess(ready: true, account: "Sample Person"))

        let (missing, _, _, _) = try answer("access", replies: [Self.viewer], key: false)
        #expect(TrackerAccess(missing) == TrackerAccess(ready: false, problem: "Enter your Linear API key in Settings → Plugins → Linear."))

        let (refused, _, _, _) = try answer("access", replies: [Self.unauthorized])
        #expect(TrackerAccess(refused)?.ready == false)
        #expect(TrackerAccess(refused)?.problem?.hasPrefix("Linear didn't accept this API key.") == true)
    }

    @Test func aSearchThatFailsSaysWhy() throws {
        let (_, noKey, _, _) = try answer("searchIssues", ["query": "login"], replies: [], key: false)
        #expect(noKey == "Enter your Linear API key in Settings → Plugins → Linear.")
        let (_, down, _, _) = try answer("searchIssues", ["query": "login"], replies: [])
        #expect(down == "Linear answered with HTTP 500.")
        let (_, unknown, _, _) = try answer("createIssue", replies: [])
        #expect(unknown == "Linear doesn't answer createIssue.")
    }

    // MARK: What the agent reads

    @Test func attachingAFoundIssueSendsTheSameLineAsBeforeThePlugin() throws {
        let (result, _, _, _) = try answer("issue", ["reference": "ENG-12"], replies: [Self.one])
        let issue = try #require(TrackerAnswer.parse(.issue("ENG-12"), .object(["result": result])).issues.first)
        let attachment = issue.attachment(trackerId: PromptAttachment.linearTrackerId, trackerName: "Linear")
        // As Abstract wrote it when Linear was in core.
        #expect(attachment.promptText == """
            Linear Issue ENG-12: Fix login
            https://linear.app/example/issue/eng-12/fix-login
            State: In Progress

            Steps to reproduce
            """)
    }

    // MARK: The Linear CLI

    /// `linear` output recorded on this Mac, rebuilt with placeholder
    /// workspaces, people, ids and issues (Fixtures/linear-cli).
    func recorded(_ name: String) throws -> String {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/linear-cli/\(name)", withExtension: nil))
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The CLI signed in to two workspaces, `example` the default.
    func signedIn() throws -> [Run] {
        [
            Run(args: ["auth", "list"], stdout: try recorded("auth-list.txt")),
            Run(args: ["auth", "whoami"], stdout: try recorded("auth-whoami.txt")),
            Run(args: ["issue", "query", "--workspace", "example", "--all-teams", "--search=login"], stdout: try recorded("issue-query-search.json")),
            Run(args: ["issue", "query", "--workspace", "example", "--team=ENG"], stdout: try recorded("issue-query-search.json")),
            Run(args: ["issue", "query"], stdout: try recorded("issue-query-mine.json")),
            Run(args: ["issue", "view", "ENG-12"], stdout: try recorded("issue-view.json")),
            Run(args: ["issue", "view"], code: 1, stderr: try recorded("issue-view-missing.txt")),
            Run(args: ["team", "list"], stdout: try recorded("team-list.txt")),
            Run(args: ["project", "list"], stdout: try recorded("project-list.json")),
        ]
    }

    static let cliMode = ["mode": "cli"]

    @Test func theCLIModeDeclaresOnlyReadCommandsAndNeverTheToken() throws {
        let manifest = try PluginPackage.inspect(folder: pluginFolder).manifest
        let cli = try #require(manifest.cli)
        #expect(manifest.grantedCapabilities.contains(.cli))
        #expect(cli.binary == "linear")
        #expect(cli.install == "brew install schpet/tap/linear")
        #expect(cli.commands.map(\.words) == ["auth whoami", "auth list", "issue query", "issue view", "team list", "project list"])
        #expect(cli.writes.isEmpty)
        #expect(cli.command(for: ["auth", "token"]) == nil)
        #expect(!cli.commands.contains { $0.args.first == "auth" && $0.args.dropFirst().first == "token" })
    }

    @Test func everyCommandItRunsIsDeclaredAndNamesTheWorkspace() throws {
        let cli = try #require(try PluginPackage.inspect(folder: pluginFolder).manifest.cli)
        var ran: [[String]] = []
        for (operation, input) in [("access", [:]), ("searchIssues", ["query": ""]), ("searchIssues", ["query": "login"]),
                                   ("issue", ["reference": "ENG-12"]), ("listProjects", [:])] as [(String, [String: String])] {
            let out = try answer(operation, input, cli: try signedIn(), settings: Self.cliMode)
            #expect(out.error == nil, "\(operation)")
            #expect(out.asked.isEmpty, "the CLI mode fetched for \(operation)")
            ran += out.ran
        }
        #expect(!ran.isEmpty)
        for args in ran {
            let command = try #require(cli.command(for: args), "\(args) isn't declared")
            #expect(command.access == .read)
            #expect(!args.contains("token"))
            if args != ["auth", "list"] { #expect(args.contains("--workspace"), "\(args)") }
        }
    }

    @Test func theCLIsWorkspacesAreReadWithoutWhoIsSignedIn() throws {
        let context = try #require(JSContext())
        context.evaluateScript(try String(contentsOf: pluginFolder.appendingPathComponent("background.js"), encoding: .utf8))
        context.setObject(try recorded("auth-list.txt"), forKeyedSubscript: "__list" as NSString)
        let text = try #require(context.evaluateScript("JSON.stringify(LinearTracker.workspaces(__list))")?.toString())
        #expect(try json(text) == .array([
            .object(["slug": .string("example"), "name": .string("Example"), "isDefault": .bool(true)]),
            .object(["slug": .string("sandbox"), "name": .string("Sample Org"), "isDefault": .bool(false)]),
        ]))
        #expect(!text.contains("@") && !text.contains("Sample Person"))
        context.setObject(try recorded("auth-list-none.txt"), forKeyedSubscript: "__none" as NSString)
        #expect(context.evaluateScript("JSON.stringify(LinearTracker.workspaces(__none))")?.toString() == "[]")
    }

    @Test func theWorkspacePickedOnTheSettingsPageIsTheOneSearched() throws {
        let picked = try answer("searchIssues", ["query": ""], cli: try signedIn(), settings: ["mode": "cli", "workspace": "sandbox"])
        #expect(picked.ran.last?.starts(with: ["issue", "query", "--workspace", "sandbox"]) == true)
        // Unpicked, or picked but no longer signed in: the CLI's default.
        for settings in [Self.cliMode, ["mode": "cli", "workspace": "gone"]] {
            let out = try answer("searchIssues", ["query": ""], cli: try signedIn(), settings: settings)
            #expect(out.ran.last?.starts(with: ["issue", "query", "--workspace", "example"]) == true, "\(settings)")
        }
    }

    @Test func theCLIModeSearchesYourOpenIssuesWordsTeamsAndProjects() throws {
        let mine = try answer("searchIssues", ["query": ""], cli: try signedIn(), settings: Self.cliMode)
        #expect(mine.ran.last == ["issue", "query", "--workspace", "example", "--all-teams", "--assignee", "self",
                                  "--state", "triage", "--state", "backlog", "--state", "unstarted", "--state", "started",
                                  "--limit", "30", "--json", "--no-pager"])
        let words = try answer("searchIssues", ["query": "login"], cli: try signedIn(), settings: Self.cliMode)
        #expect(words.ran.last == ["issue", "query", "--workspace", "example", "--all-teams", "--search=login",
                                   "--limit", "30", "--json", "--no-pager"])
        // Typed text is never an option of its own.
        let dashed = try answer("searchIssues", ["query": "--json"], cli: try signedIn(), settings: Self.cliMode)
        #expect(dashed.ran.last?.contains("--search=--json") == true)
        let team = try answer("searchIssues", ["query": "login", "project": "team:ENG"], cli: try signedIn(), settings: Self.cliMode)
        #expect(team.ran.last?.starts(with: ["issue", "query", "--workspace", "example", "--team=ENG", "--search=login"]) == true)
        let project = try answer("searchIssues", ["query": "", "project": "project:p-1"], cli: try signedIn(), settings: Self.cliMode)
        #expect(project.ran.last?.contains("--project=p-1") == true)
    }

    @Test func theCLIModeLooksUpKeysAndLinksAndFindsNothingForAnUnknownKey() throws {
        for reference in ["eng-12", "https://linear.app/example/issue/ENG-12/fix-login"] {
            let out = try answer("issue", ["reference": reference], cli: try signedIn(), settings: Self.cliMode)
            #expect(out.ran.last == ["issue", "view", "ENG-12", "--workspace", "example", "--json", "--no-comments", "--no-download", "--no-pager"])
            #expect(TrackerAnswer.parse(.issue(reference), .object(["result": out.result])) == .issue(Self.fixLogin))
        }
        let unknown = try answer("issue", ["reference": "ENG-404"], cli: try signedIn(), settings: Self.cliMode)
        #expect(unknown.error == nil)
        #expect(unknown.result["issue"] == .null)
    }

    @Test func theCLIModeSaysWhatToDoWhenItIsMissingOrSignedOut() throws {
        let ready = try answer("access", cli: try signedIn(), settings: Self.cliMode)
        #expect(TrackerAccess(ready.result) == TrackerAccess(ready: true, account: "Sample Person"))

        let missing = try answer("access", missing: true, settings: Self.cliMode)
        #expect(TrackerAccess(missing.result) == TrackerAccess(ready: false,
            problem: "The Linear CLI isn't installed. Install it with `brew install schpet/tap/linear`, then run `linear auth login`."))

        let none = try answer("access", cli: [Run(args: ["auth", "list"], stdout: try recorded("auth-list-none.txt"))], settings: Self.cliMode)
        #expect(TrackerAccess(none.result) == TrackerAccess(ready: false,
            problem: "The Linear CLI isn't signed in. Run `linear auth login` in a terminal, then try again."))

        let failed = try answer("searchIssues", ["query": "login"], cli: [
            Run(args: ["auth", "list"], stdout: try recorded("auth-list.txt")),
            Run(args: ["issue", "query"], code: 1, stderr: try recorded("auth-whoami-signed-out.txt")),
        ], settings: Self.cliMode)
        #expect(failed.error?.hasPrefix("Failed to get user info: No API key configured.") == true)
    }

    @Test func withNothingPickedItUsesTheKeyOnceEnteredElseASignedInCLI() throws {
        let keyed = try answer("searchIssues", ["query": "login"], replies: [Self.viewer, Self.search], cli: try signedIn())
        #expect(keyed.ran.allSatisfy { $0.first == "auth" })
        #expect(keyed.asked.contains { $0["query"]?.string?.contains("searchIssues") == true })

        let cliOnly = try answer("searchIssues", ["query": "login"], key: false, cli: try signedIn())
        #expect(cliOnly.ran.last?.starts(with: ["issue", "query"]) == true)

        let neither = try answer("access", key: false, missing: true)
        #expect(TrackerAccess(neither.result)?.problem
                == "Enter your Linear API key, or sign in to the Linear CLI, in Settings → Plugins → Linear.")
        // A picked mode is kept even when the other would work.
        let picked = try answer("searchIssues", ["query": "login"], replies: [Self.viewer, Self.search], cli: try signedIn(),
                                settings: ["mode": "apiKey"])
        #expect(picked.ran.isEmpty)
    }

    // MARK: Both modes

    /// The GraphQL replies for the same placeholder workspace the CLI
    /// output was rebuilt with.
    static let sameWorkspace: [Reply] = [
        viewer, assigned, search, one,
        Reply(when: "teams(", body: """
            {"data":{"teams":{"nodes":[{"id":"t-1","name":"Engineering","key":"ENG"},{"id":"t-2","name":"Site Ops","key":"OPS"}]},
                     "projects":{"nodes":[{"id":"00000000-0000-0000-0000-000000000080","name":"Checkout"}]}}}
            """),
    ]

    @Test func bothModesGiveTheSameResults() throws {
        let questions: [(String, [String: String], TrackerRequest)] = [
            ("searchIssues", ["query": ""], .searchIssues(query: "", project: nil)),
            ("searchIssues", ["query": "login"], .searchIssues(query: "login", project: nil)),
            ("searchIssues", ["query": "ENG-12"], .searchIssues(query: "ENG-12", project: nil)),
            ("issue", ["reference": "ENG-12"], .issue("ENG-12")),
            ("issue", ["reference": "https://linear.app/example/issue/eng-12/fix-login"], .issue("https://linear.app/example/issue/eng-12/fix-login")),
            ("listProjects", [:], .listProjects),
        ]
        for (operation, input, request) in questions {
            let api = try answer(operation, input, replies: Self.sameWorkspace, settings: ["mode": "apiKey"])
            let cli = try answer(operation, input, cli: try signedIn(), settings: Self.cliMode)
            #expect(api.error == nil && cli.error == nil, "\(operation) \(input)")
            let fromAPI = TrackerAnswer.parse(request, .object(["result": api.result]))
            let fromCLI = TrackerAnswer.parse(request, .object(["result": cli.result]))
            #expect(fromAPI == fromCLI, "\(operation) \(input)")
            if case .failed = fromAPI { Issue.record("\(operation) failed") }
        }
        let api = try answer("access", replies: Self.sameWorkspace, settings: ["mode": "apiKey"])
        let cli = try answer("access", cli: try signedIn(), settings: Self.cliMode)
        #expect(TrackerAccess(api.result) == TrackerAccess(cli.result))
    }
}
