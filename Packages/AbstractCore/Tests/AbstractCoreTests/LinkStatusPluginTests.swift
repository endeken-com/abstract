import Foundation
import JavaScriptCore
import Testing
@testable import AbstractCore

/// The bundled Link status plugin (ABS-126). Its logic is plain
/// JavaScript, so these tests run the shipped script over GitHub and
/// Linear replies recorded on test repositories and workspaces: accounts,
/// names and links are placeholders.
@Suite struct LinkStatusPluginTests {
    var pluginFolder: URL {
        let here = URL(fileURLWithPath: #filePath)
        let repo = here.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return repo.appendingPathComponent("Abstract/Resources/Plugins/link-status.abstractplugin")
    }

    func context() throws -> JSContext {
        let source = try String(contentsOf: pluginFolder.appendingPathComponent("background.js"), encoding: .utf8)
        let context = try #require(JSContext())
        context.evaluateScript(source)
        return context
    }

    /// Runs `expression` with `__args[n]` bound from JSON texts.
    func evaluate(_ expression: String, args: [String] = []) throws -> JSONValue {
        let context = try context()
        context.setObject(args, forKeyedSubscript: "__argTexts" as NSString)
        context.evaluateScript("const __args = __argTexts.map((text) => JSON.parse(text));")
        let result = context.evaluateScript("JSON.stringify(\(expression))")
        if let exception = context.exception {
            Issue.record("\(expression) threw: \(exception.toString() ?? "?")")
            return .null
        }
        let text = try #require(result?.toString())
        guard text != "undefined" else { return .null }
        return JSONValue(any: try JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed))
    }

    /// Runs `LinkStatus.lookUp` with a fetch that answers from `replies`
    /// (URL → body; a missing URL answers as the host does when the
    /// secret isn't entered), and returns the status and what was asked.
    func lookUp(_ url: String, replies: [String: String], secrets: Set<String> = ["github-token", "linear-api-key"]) throws
        -> (status: JSONValue, asked: [JSONValue]) {
        let context = try context()
        let repliesJSON = String(decoding: try JSONSerialization.data(withJSONObject: replies), as: UTF8.self)
        let secretsJSON = String(decoding: try JSONSerialization.data(withJSONObject: Array(secrets)), as: UTF8.self)
        context.evaluateScript("""
            const __replies = \(repliesJSON);
            const __secrets = \(secretsJSON);
            const __asked = [];
            let __status = "pending";
            const __fetch = (url, options) => {
              const secret = options.secretHeaders && options.secretHeaders.Authorization;
              __asked.push({ url, method: options.method || "GET", secret: secret ? secret.secret : null, body: options.body || null });
              if (secret && !__secrets.includes(secret.secret)) {
                return Promise.resolve({ message: "That secret hasn't been entered in Settings → Plugins yet." });
              }
              const body = __replies[url];
              return Promise.resolve(body === undefined ? { status: 404, body: "{}", bodyIsBase64: false }
                                                        : { status: 200, body, bodyIsBase64: false });
            };
            LinkStatus.lookUp(\(String(decoding: try JSONSerialization.data(withJSONObject: [url]), as: UTF8.self))[0], __fetch)
              .then((status) => { __status = JSON.stringify(status); }, (error) => { __status = "threw " + error; });
            """)
        let status = try #require(context.evaluateScript("__status")?.toString())
        #expect(!status.hasPrefix("threw"), "\(status)")
        #expect(status != "pending")
        let asked = try #require(context.evaluateScript("JSON.stringify(__asked)")?.toString())
        let askedValue = JSONValue(any: try JSONSerialization.jsonObject(with: Data(asked.utf8)))
        let statusValue = JSONValue(any: try JSONSerialization.jsonObject(with: Data(status.utf8), options: .fragmentsAllowed))
        return (statusValue, askedValue.array ?? [])
    }

    // MARK: Recorded replies

    static let repo = "https://api.github.com/repos/example/shop"

    /// `GET /repos/example/shop/pulls/n`, cut to the fields that matter.
    static func pull(_ number: Int, state: String = "open", draft: Bool = false, merged: Bool = false) -> String {
        """
        {"url":"\(repo)/pulls/\(number)","html_url":"https://github.com/example/shop/pull/\(number)","number":\(number),
         "state":"\(state)","title":"Apply the discount to empty carts","user":{"login":"author-a"},
         "draft":\(draft),"merged":\(merged),"merged_at":\(merged ? "\"2026-10-20T10:00:00Z\"" : "null"),
         "head":{"ref":"fix-cart","sha":"1111111111111111111111111111111111111111"},"base":{"ref":"main"}}
        """
    }

    static let checksURL = "\(repo)/commits/1111111111111111111111111111111111111111/check-runs?per_page=100"

    /// `GET …/commits/<sha>/check-runs`.
    static func checks(_ runs: [(status: String, conclusion: String?)]) -> String {
        let items = runs.enumerated().map { index, run in
            #"{"id":\#(index + 1),"name":"check-\#(index + 1)","status":"\#(run.status)","conclusion":\#(run.conclusion.map { "\"\($0)\"" } ?? "null")}"#
        }
        return #"{"total_count":\#(runs.count),"check_runs":[\#(items.joined(separator: ","))]}"#
    }

    /// `GET /repos/example/shop/issues/n`.
    static func issue(_ number: Int, state: String, reason: String? = nil, pullRequest: Bool = false) -> String {
        """
        {"url":"\(repo)/issues/\(number)","number":\(number),"title":"Empty carts get a discount","state":"\(state)",
         "state_reason":\(reason.map { "\"\($0)\"" } ?? "null"),"user":{"login":"reporter-a"}\(pullRequest ? #","pull_request":{"url":"x"}"# : "")}
        """
    }

    /// The Linear GraphQL reply for one issue.
    static func linear(state: String, type: String, assignee: String?) -> String {
        let person = assignee.map { #"{"name":"\#($0) Example","displayName":"\#($0.lowercased())"}"# } ?? "null"
        return #"{"data":{"issue":{"identifier":"SHOP-7","state":{"name":"\#(state)","type":"\#(type)"},"assignee":\#(person)}}}"#
    }

    // MARK: The package

    @Test func theBundledPackageDecoratesGitHubAndLinearLinksFromTheBackground() throws {
        let manifest = try PluginPackage.inspect(folder: pluginFolder).manifest
        try manifest.validate()
        #expect(manifest.id == "sh.abstract.link-status")
        #expect(manifest.background == "background.js")
        #expect(manifest.grantedCapabilities == [.network, .secrets])
        #expect(manifest.networkHosts == ["api.github.com", "api.linear.app"])
        #expect(manifest.secretDeclarations.map(\.name) == ["github-token", "linear-api-key"])
        #expect(manifest.contributes.linkDecorators.map(\.id) == ["github", "linear"])
        #expect(manifest.appearanceSentences.contains("GitHub — a status after links to github.com in your chats."))
        #expect(manifest.appearanceSentences.contains("Linear — a status after links to linear.app in your chats."))
    }

    @Test func theLinksItsPatternsHandOverAreTheOnesItReads() throws {
        let manifest = try PluginPackage.inspect(folder: pluginFolder).manifest
        let plugin = ResolvedPluginContribution(pluginId: manifest.id, pluginName: manifest.name, place: .link,
                                                contribution: manifest.contributes.linkDecorators[0])
        let linear = ResolvedPluginContribution(pluginId: manifest.id, pluginName: manifest.name, place: .link,
                                                contribution: manifest.contributes.linkDecorators[1])
        let text = "https://github.com/example/shop/pull/43/files, https://github.com/example/shop/issues/12 and https://linear.app/example/issue/SHOP-7/apply-the-discount"
        let handed = PluginLinks.matches(in: text, decorators: [plugin, linear]).map(\.url)
        #expect(handed.count == 3)
        let parsed = try evaluate("__args[0].map((url) => LinkStatus.parse(url))",
                                  args: [String(decoding: try JSONSerialization.data(withJSONObject: handed), as: UTF8.self)])
        #expect(parsed.array?.map { $0["kind"]?.string } == ["pull", "issue", "linear"])
        #expect(parsed.array?[0]["number"] == .number(43))
        #expect(parsed.array?[2]["identifier"] == .string("SHOP-7"))
        #expect(try evaluate("LinkStatus.parse('https://github.com/example/shop')") == .null)
    }

    // MARK: Pull requests

    @Test func aMergedPullRequestShowsMergedWithoutAskingForChecks() throws {
        let (status, asked) = try lookUp("https://github.com/example/shop/pull/43",
                                         replies: ["\(Self.repo)/pulls/43": Self.pull(43, state: "closed", merged: true)])
        #expect(status == .object(["label": .string("Merged"), "tone": .string("merged")]))
        #expect(asked.count == 1)
        #expect(asked.first?["secret"] == .string("github-token"))
    }

    @Test func anOpenPullRequestShowsItsChecks() throws {
        func status(_ runs: [(status: String, conclusion: String?)], draft: Bool = false) throws -> JSONValue {
            try lookUp("https://github.com/example/shop/pull/44", replies: [
                "\(Self.repo)/pulls/44": Self.pull(44, draft: draft), Self.checksURL: Self.checks(runs),
            ]).status
        }
        #expect(try status([("completed", "success"), ("completed", "failure")])
                == .object(["label": .string("Open · Checks failing"), "tone": .string("failing")]))
        #expect(try status([("completed", "success"), ("in_progress", nil)])
                == .object(["label": .string("Open · Checks running"), "tone": .string("open")]))
        #expect(try status([("completed", "success"), ("completed", "skipped")])
                == .object(["label": .string("Open · Checks passed"), "tone": .string("open")]))
        #expect(try status([]) == .object(["label": .string("Open"), "tone": .string("open")]))
        #expect(try status([("completed", "success")], draft: true)
                == .object(["label": .string("Draft · Checks passed"), "tone": .string("draft")]))
        #expect(try lookUp("https://github.com/example/shop/pull/45", replies: [
            "\(Self.repo)/pulls/45": Self.pull(45, state: "closed"),
        ]).status == .object(["label": .string("Closed"), "tone": .string("closed")]))
    }

    @Test func withoutATokenItAsksAgainAsAPublicRepository() throws {
        let (status, asked) = try lookUp("https://github.com/example/shop/pull/43",
                                         replies: ["\(Self.repo)/pulls/43": Self.pull(43, state: "closed", merged: true)],
                                         secrets: [])
        #expect(status["label"] == .string("Merged"))
        #expect(asked.map { $0["secret"] } == [.string("github-token"), .null])
    }

    @Test func aPullRequestItCantReadShowsNothing() throws {
        #expect(try lookUp("https://github.com/example/private/pull/1", replies: [:]).status == .null)
    }

    // MARK: Issues

    @Test func anIssueShowsOpenOrClosedTheWayGitHubColoursIt() throws {
        func status(_ body: String) throws -> JSONValue {
            try lookUp("https://github.com/example/shop/issues/12", replies: ["\(Self.repo)/issues/12": body]).status
        }
        #expect(try status(Self.issue(12, state: "open")) == .object(["label": .string("Open"), "tone": .string("open")]))
        #expect(try status(Self.issue(12, state: "closed", reason: "completed"))
                == .object(["label": .string("Closed"), "tone": .string("merged")]))
        #expect(try status(Self.issue(12, state: "closed", reason: "not_planned"))
                == .object(["label": .string("Closed as not planned"), "tone": .string("neutral")]))
    }

    @Test func anIssueLinkThatIsAPullRequestShowsThePullRequest() throws {
        let (status, _) = try lookUp("https://github.com/example/shop/issues/43", replies: [
            "\(Self.repo)/issues/43": Self.issue(43, state: "closed", pullRequest: true),
            "\(Self.repo)/pulls/43": Self.pull(43, state: "closed", merged: true),
        ])
        #expect(status["label"] == .string("Merged"))
    }

    // MARK: Linear

    @Test func aLinearIssueShowsItsStateAndWhoHasIt() throws {
        func lookUpLinear(_ body: String, secrets: Set<String> = ["linear-api-key"]) throws -> (status: JSONValue, asked: [JSONValue]) {
            try lookUp("https://linear.app/example/issue/SHOP-7", replies: ["https://api.linear.app/graphql": body], secrets: secrets)
        }
        let (started, asked) = try lookUpLinear(Self.linear(state: "In Progress", type: "started", assignee: "Ada"))
        #expect(started == .object(["label": .string("In Progress · ada"), "tone": .string("open")]))
        #expect(asked.first?["method"] == .string("POST"))
        #expect(asked.first?["secret"] == .string("linear-api-key"))
        #expect(asked.first?["body"]?.string?.contains(#""id":"SHOP-7""#) == true)
        #expect(try lookUpLinear(Self.linear(state: "Done", type: "completed", assignee: nil)).status
                == .object(["label": .string("Done"), "tone": .string("merged")]))
        #expect(try lookUpLinear(Self.linear(state: "Canceled", type: "canceled", assignee: nil)).status["tone"] == .string("closed"))
        #expect(try lookUpLinear(Self.linear(state: "Todo", type: "unstarted", assignee: nil)).status["tone"] == .string("neutral"))
        // No key entered: nothing to show, and it isn't asked without one.
        let missing = try lookUpLinear(Self.linear(state: "Done", type: "completed", assignee: nil), secrets: [])
        #expect(missing.status == .null)
        #expect(missing.asked.count == 1)
    }

    @Test func everyStatusFitsAPill() throws {
        let long = try evaluate("LinkStatus.linear(__args[0])",
                                args: [Self.linear(state: "Waiting for the design review to finish", type: "started", assignee: "Bartholomew")])
        let label = try #require(long["label"]?.string)
        #expect(label.count <= PluginLinkStatus.labelLimit)
        #expect(PluginLinkStatus(long) != nil)
        for tone in try evaluate("[LinkStatus.pullRequest({state:'open'}), LinkStatus.issue({state:'closed'})].map((s) => s.tone)").array ?? [] {
            #expect(tone.string.flatMap(PluginLinkStatus.Tone.init(rawValue:)) != nil)
        }
    }
}
