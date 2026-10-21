import Foundation
import JavaScriptCore
import Testing
@testable import AbstractCore

/// Small, anonymized acli replies in the shapes Jira Cloud returns.
@Suite struct JiraPluginTests {
    var folder: URL {
        let here = URL(fileURLWithPath: #filePath)
        let repo = here.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return repo.appendingPathComponent("Abstract/Resources/Plugins/jira.abstractplugin")
    }

    struct Run {
        var args: [String]
        var code = 0
        var stdout = ""
        var stderr = ""
    }

    func answer(_ operation: String, _ input: [String: String] = [:], runs: [Run], missing: Bool = false) throws
        -> (result: JSONValue, error: String?, commands: [[String]]) {
        let source = try String(contentsOf: folder.appendingPathComponent("background.js"), encoding: .utf8)
        let js = try #require(JSContext())
        js.evaluateScript(source)
        func literal(_ value: Any) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed), as: UTF8.self)
        }
        let replies = try literal(runs.map { ["args": $0.args, "code": $0.code, "stdout": $0.stdout, "stderr": $0.stderr] as [String: Any] })
        js.evaluateScript("""
            const __replies = \(replies);
            const __commands = [];
            let __result = "pending";
            const __cli = (args) => {
              __commands.push(args);
              if (\(missing)) { const error = new Error("acli missing"); error.missing = "acli"; return Promise.reject(error); }
              const reply = __replies.find((r) => r.args.every((word, index) => args[index] === word));
              if (!reply) return Promise.resolve({ok:false, stderr:"unexpected " + args.join(" ")});
              return Promise.resolve({ok:reply.code === 0, code:reply.code, stdout:reply.stdout, stderr:reply.stderr});
            };
            JiraTracker.answer(\(try literal(operation)), \(try literal(input)), __cli)
              .then((value) => { __result = JSON.stringify({value}); },
                    (error) => { __result = JSON.stringify({error:String(error.message || error)}); });
            """)
        if let exception = js.exception { throw AbstractError.message(exception.toString() ?? "JavaScript failed") }
        let raw = try #require(js.evaluateScript("__result")?.toString())
        #expect(raw != "pending")
        let decoded = try JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8))
        let commandText = try #require(js.evaluateScript("JSON.stringify(__commands)")?.toString())
        let commands = (try JSONDecoder().decode(JSONValue.self, from: Data(commandText.utf8)).array ?? [])
            .map { ($0.array ?? []).compactMap(\.string) }
        return (decoded["value"] ?? .null, decoded["error"]?.string, commands)
    }

    static let signedIn = Run(args: ["jira", "auth", "status"], stdout: """
        ✓ Authenticated
          Site: sample.atlassian.net
          Email: person@example.com
        """)
    static let item = #"{"key":"PROJ-123","fields":{"summary":"Fix checkout","status":{"name":"In Progress"},"assignee":{"displayName":"Sample Person"},"description":{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"Payment fails"},{"type":"hardBreak"},{"type":"text","text":"on retry."}]},{"type":"paragraph","content":[{"type":"text","text":"Please investigate."}]}]}}}"#
    static let view = Run(args: ["jira", "workitem", "view"], stdout: item)
    static let search = Run(args: ["jira", "workitem", "search"], stdout: #"{"issues":[{"key":"PROJ-123","fields":{"summary":"Fix checkout","status":{"name":"In Progress"},"assignee":{"displayName":"Sample Person"}}}]}"#)

    @Test func packageDeclaresOnlyFourReadCommandsAndIsOffByDefault() throws {
        let manifest = try PluginPackage.inspect(folder: folder).manifest
        try manifest.validate()
        #expect(manifest.id == "sh.abstract.jira")
        #expect(manifest.background == "background.js")
        #expect(manifest.grantedCapabilities == [.cli])
        let cli = try #require(manifest.cli)
        #expect(cli.binary == "acli" && cli.install == "brew install acli")
        #expect(cli.commands.map(\.words) == ["jira auth status", "jira workitem search", "jira workitem view", "jira project list"])
        #expect(cli.writes.isEmpty)
        #expect(!PluginManager.defaultPluginIds.contains(manifest.id))
        let tracker = try #require(manifest.contributes.issueTracker)
        #expect(tracker.title == "Jira" && tracker.isKey("PROJ-123"))
        #expect(PluginPackage.fileData(in: folder, relativePath: tracker.icon ?? "") != nil)
        #expect(manifest.contributes.settingsPage != nil)
    }

    @Test func keysAndLinksLoadOneJiraIssueAndAttachItsDescription() throws {
        for reference in ["proj-123", "https://sample.atlassian.net/browse/PROJ-123", "https://sample.atlassian.net/browse/proj-123?focusedCommentId=1"] {
            let found = try answer("issue", ["reference": reference], runs: [Self.signedIn, Self.view])
            #expect(found.error == nil)
            #expect(found.commands.last == ["jira", "workitem", "view", "PROJ-123", "--json"])
            let issue = try #require(TrackerAnswer.parse(.issue(reference), .object(["result": found.result])).issues.first)
            #expect(issue == TrackerIssue(key: "PROJ-123", title: "Fix checkout", state: "In Progress",
                                          assignee: "Sample Person", url: "https://sample.atlassian.net/browse/PROJ-123",
                                          excerpt: "Payment fails\non retry.\nPlease investigate."))
            let attachment = issue.attachment(trackerId: "sh.abstract.jira", trackerName: "Jira")
            #expect(attachment.promptText.contains("Jira Issue PROJ-123: Fix checkout"))
        }
        let otherSite = try answer("issue", ["reference": "https://other.atlassian.net/browse/PROJ-123"], runs: [Self.signedIn])
        #expect(otherSite.result["issue"] == .null)
        #expect(otherSite.commands.count == 1)
    }

    @Test func wordsBuildSafeJQLAndMapAtMostTwentySearchResults() throws {
        let found = try answer("searchIssues", ["query": "payment \"retry\"", "project": "project:PROJ"],
                               runs: [Self.signedIn, Self.search])
        #expect(found.error == nil)
        #expect(found.commands.last == ["jira", "workitem", "search", "--jql",
                                        "project = PROJ AND text ~ \"payment \\\"retry\\\"\" ORDER BY updated DESC",
                                        "--limit", "20", "--json"])
        let issues = TrackerAnswer.parse(.searchIssues(query: "payment", project: "project:PROJ"),
                                         .object(["result": found.result])).issues
        #expect(issues == [TrackerIssue(key: "PROJ-123", title: "Fix checkout", state: "In Progress",
                                        assignee: "Sample Person", url: "https://sample.atlassian.net/browse/PROJ-123")])
        let byKey = try answer("searchIssues", ["query": "PROJ-123"], runs: [Self.signedIn, Self.view])
        #expect(byKey.commands.last?.prefix(3) == ["jira", "workitem", "view"])
        #expect(byKey.result["issues"]?.array?.first?["excerpt"] == nil)
    }

    @Test func listsProjectsForFutureProjectSearchScope() throws {
        let projects = Run(args: ["jira", "project", "list"], stdout: #"[{"key":"PROJ","name":"Sample project"}]"#)
        let found = try answer("listProjects", runs: [Self.signedIn, projects])
        #expect(found.commands.last == ["jira", "project", "list", "--limit", "500", "--json"])
        #expect(TrackerAnswer.parse(.listProjects, .object(["result": found.result])) == .projects([
            TrackerProject(id: "project:PROJ", name: "Sample project", kind: .project, key: "PROJ"),
        ]))
    }

    @Test func missingAndSignedOutExplainWhatToDo() throws {
        let missing = try answer("access", runs: [], missing: true)
        #expect(TrackerAccess(missing.result)?.problem?.contains("brew install acli") == true)
        #expect(TrackerAccess(missing.result)?.problem?.contains("acli jira auth login") == true)
        let signedOut = try answer("access", runs: [Run(args: ["jira", "auth", "status"], code: 1, stderr: "Not authenticated")])
        #expect(TrackerAccess(signedOut.result)?.ready == false)
        #expect(TrackerAccess(signedOut.result)?.problem?.contains("acli jira auth login") == true)
    }
}
