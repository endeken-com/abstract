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

    /// Runs `LinearTracker.answer(operation, input)` with a fetch that
    /// answers from `replies` (no key entered answers as the host does),
    /// and returns the result, or the error, and what was asked.
    func answer(_ operation: String, _ input: [String: String] = [:], replies: [Reply], key: Bool = true) throws
        -> (result: JSONValue, error: String?, asked: [JSONValue]) {
        let source = try String(contentsOf: pluginFolder.appendingPathComponent("background.js"), encoding: .utf8)
        let context = try #require(JSContext())
        context.evaluateScript(source)
        let repliesJSON = String(decoding: try JSONSerialization.data(withJSONObject: replies.map {
            ["when": $0.when, "status": $0.status, "body": $0.body] as [String: Any]
        }), as: UTF8.self)
        let inputJSON = String(decoding: try JSONSerialization.data(withJSONObject: input), as: UTF8.self)
        context.evaluateScript("""
            const __replies = \(repliesJSON);
            const __asked = [];
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
            LinearTracker.answer("\(operation)", \(inputJSON), { fetch: __fetch })
              .then((result) => { __result = JSON.stringify(result); }, (error) => { __result = "null"; __error = String(error.message || error); });
            """)
        if let exception = context.exception { Issue.record("threw: \(exception.toString() ?? "?")") }
        let result = try #require(context.evaluateScript("__result")?.toString())
        #expect(result != "pending")
        let error = context.evaluateScript("__error")?.toString()
        let asked = try #require(context.evaluateScript("JSON.stringify(__asked)")?.toString())
        return (try json(result), error == "null" ? nil : error, try json(asked).array ?? [])
    }

    func json(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    // MARK: Recorded replies

    /// An issue node as Linear's GraphQL API returns it.
    static func node(_ key: String, title: String, state: String = "In Progress", type: String = "started",
                     assignee: String? = "Ada Example", description: String? = "Steps to reproduce") -> String {
        let person = assignee.map { #"{"name":"\#($0)","displayName":"\#($0.split(separator: " ")[0].lowercased())"}"# } ?? "null"
        let text = description.map { "\"\($0)\"" } ?? "null"
        return """
            {"id":"00000000-0000-0000-0000-\(String(repeating: "0", count: 12 - key.count))\(key.filter(\.isNumber))",
             "identifier":"\(key)","title":"\(title)","url":"https://linear.app/example/issue/\(key.lowercased())/\(title.lowercased().replacingOccurrences(of: " ", with: "-"))",
             "description":\(text),"state":{"name":"\(state)","type":"\(type)"},"assignee":\(person)}
            """
    }

    static let viewer = Reply(when: "viewer { name", body: #"{"data":{"viewer":{"name":"Ada Example","email":"ada@example.com"}}}"#)
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

    static let fixLogin = TrackerIssue(key: "ENG-12", title: "Fix login", state: "In Progress", assignee: "ada",
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
            let (result, error, asked) = try answer("issue", ["reference": reference], replies: [Self.one])
            #expect(error == nil)
            #expect(asked.first?["variables"]?["id"] == .string("ENG-12"), "\(reference)")
            #expect(TrackerAnswer.parse(.issue(reference), .object(["result": result])) == .issue(Self.fixLogin))
        }
        // Anything else isn't Linear's to answer, and nothing is asked.
        for reference in ["https://github.com/example/shop/issues/12", "https://linear.app/example/project/checkout", "fix login"] {
            let (result, _, asked) = try answer("issue", ["reference": reference], replies: [Self.one])
            #expect(result["issue"] == .null, "\(reference)")
            #expect(asked.isEmpty)
        }
    }

    @Test func aKeyLinearDoesntKnowFindsNothing() throws {
        let (result, error, _) = try answer("issue", ["reference": "ENG-404"], replies: [Self.notFound])
        #expect(error == nil)
        #expect(result["issue"] == .null)
    }

    // MARK: Searching

    @Test func anEmptySearchListsYourOpenIssues() throws {
        let (result, error, asked) = try answer("searchIssues", ["query": ""], replies: [Self.assigned])
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
        let (result, _, asked) = try answer("searchIssues", ["query": "login"], replies: [Self.search])
        #expect(asked[0]["variables"] == .object(["term": .string("login")]))
        #expect(TrackerAnswer.parse(.searchIssues(query: "login", project: nil), .object(["result": result])).issues == [Self.fixLoginListed])

        let (_, _, scoped) = try answer("searchIssues", ["query": "login", "project": "team:ENG"], replies: [Self.search])
        #expect(scoped[0]["variables"]?["filter"] == .object(["team": .object(["key": .object(["eq": .string("ENG")])])]))
        let (_, _, project) = try answer("searchIssues", ["query": "", "project": "project:project-1"], replies: [Self.assigned])
        #expect(project[0]["variables"]?["filter"]?["project"]?["id"]?["eq"] == .string("project-1"))
        // A key typed into the search is that issue.
        let (byKey, _, keyAsked) = try answer("searchIssues", ["query": "ENG-12"], replies: [Self.one])
        #expect(keyAsked[0]["query"]?.string?.contains("issue(id") == true)
        #expect(TrackerAnswer.parse(.searchIssues(query: "ENG-12", project: nil), .object(["result": byKey])).issues == [Self.fixLoginListed])
    }

    @Test func teamsAndProjectsAreListed() throws {
        let (result, _, _) = try answer("listProjects", replies: [Self.teamsAndProjects])
        #expect(TrackerAnswer.parse(.listProjects, .object(["result": result])) == .projects([
            TrackerProject(id: "team:ENG", name: "Engineering", kind: .team, key: "ENG"),
            TrackerProject(id: "project:project-1", name: "Checkout", kind: .project),
        ]))
    }

    // MARK: Connecting and errors

    @Test func accessSaysWhoseKeyItIsOrWhatToDo() throws {
        let (ready, _, _) = try answer("access", replies: [Self.viewer])
        #expect(TrackerAccess(ready) == TrackerAccess(ready: true, account: "Ada Example"))

        let (missing, _, _) = try answer("access", replies: [Self.viewer], key: false)
        #expect(TrackerAccess(missing) == TrackerAccess(ready: false, problem: "Enter your Linear API key in Settings → Plugins → Linear."))

        let (refused, _, _) = try answer("access", replies: [Self.unauthorized])
        #expect(TrackerAccess(refused)?.ready == false)
        #expect(TrackerAccess(refused)?.problem?.hasPrefix("Linear didn't accept this API key.") == true)
    }

    @Test func aSearchThatFailsSaysWhy() throws {
        let (_, noKey, _) = try answer("searchIssues", ["query": "login"], replies: [], key: false)
        #expect(noKey == "Enter your Linear API key in Settings → Plugins → Linear.")
        let (_, down, _) = try answer("searchIssues", ["query": "login"], replies: [])
        #expect(down == "Linear answered with HTTP 500.")
        let (_, unknown, _) = try answer("createIssue", replies: [])
        #expect(unknown == "Linear doesn't answer createIssue.")
    }

    // MARK: What the agent reads

    @Test func attachingAFoundIssueSendsTheSameLineAsBeforeThePlugin() throws {
        let (result, _, _) = try answer("issue", ["reference": "ENG-12"], replies: [Self.one])
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
}
