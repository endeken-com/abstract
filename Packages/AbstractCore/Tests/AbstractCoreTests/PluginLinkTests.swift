import Foundation
import Testing
@testable import AbstractCore

/// ABS-126: plugins decorate links in chats. The host finds the links
/// their patterns name, hands each one over cut to the pattern, keeps the
/// statuses fresh, and puts each after its link in the transcript.
@Suite struct PluginLinkTests {
    func manifest(_ contributes: [String: Any], background: String? = "background.js") throws -> PluginManifest {
        var object: [String: Any] = [
            "api": 2, "id": "sh.example.links", "name": "Links", "version": "1.0.0",
            "entry": "index.html", "capabilities": ["network"], "network": ["hosts": ["api.github.com"]],
            "contributes": contributes,
        ]
        if let background { object["background"] = background }
        return try PluginManifest.decode(JSONSerialization.data(withJSONObject: object))
    }

    func expectInvalid(_ manifest: PluginManifest) {
        #expect(throws: PluginValidationError.self) { try manifest.validate() }
    }

    static let github = ResolvedPluginContribution(
        pluginId: "sh.example.links", pluginName: "Links", place: .link,
        contribution: .init(id: "github", title: "GitHub",
                            patterns: ["https://github.com/*/*/pull/*", "https://github.com/*/*/issues/*"]))
    static let linear = ResolvedPluginContribution(
        pluginId: "sh.example.links", pluginName: "Links", place: .link,
        contribution: .init(id: "linear", title: "Linear", patterns: ["https://linear.app/*/issue/*"]))
    static let decorators = [github, linear]

    func match(_ contributionId: String, _ url: String) -> PluginLinks.Match {
        PluginLinks.Match(pluginId: "sh.example.links", contributionId: contributionId, url: url)
    }

    // MARK: The manifest

    @Test func aLinkDecoratorNamesItsPatternsAndTheReviewNamesTheirSites() throws {
        let manifest = try manifest(["linkDecorators": [
            ["id": "github", "title": "GitHub", "patterns": ["https://github.com/*/*/pull/*", "https://github.com/*/*/issues/*"]],
        ]])
        try manifest.validate()
        #expect(manifest.contributes.linkDecorators.first?.patterns?.count == 2)
        #expect(manifest.appearanceSentences == [
            "GitHub — a status after links to github.com in your chats.",
            "In the background — it runs while it's on, even with its screen closed.",
        ])
        let resolved = PluginContributions.resolve([], place: .link)
        #expect(resolved.isEmpty)
    }

    @Test func aLinkDecoratorNeedsABackgroundScriptAndSoundPatterns() throws {
        let decorator: [String: Any] = ["id": "github", "title": "GitHub", "patterns": ["https://github.com/*/*/pull/*"]]
        expectInvalid(try manifest(["linkDecorators": [decorator]], background: nil))
        for patterns in [[], ["http://github.com/*/*/pull/*"], ["https://*.github.com/*"], ["https://github.com/a*/pull"],
                         ["https://github.com"], ["https://github.com//pull"], ["https://github.com/pull?x=1"]] {
            expectInvalid(try manifest(["linkDecorators": [["id": "github", "title": "GitHub", "patterns": patterns]]]))
        }
        expectInvalid(try manifest(["linkDecorators": [["id": "github", "title": "GitHub"]]]))
        // Patterns decide what a plugin is handed, so only a decorator has them.
        expectInvalid(try manifest(["chatPanelTabs": [["id": "tab", "title": "Tab", "patterns": ["https://github.com/*"]]]]))
    }

    // MARK: Matching

    @Test func aLinkIsHandedOverCutToItsPatternWithoutQueryOrFragment() throws {
        let pattern = try #require(PluginLinks.Pattern("https://github.com/*/*/pull/*"))
        func canonical(_ text: String) -> String? { URL(string: text).flatMap(pattern.canonical) }
        #expect(canonical("https://github.com/example/shop/pull/43") == "https://github.com/example/shop/pull/43")
        #expect(canonical("https://github.com/example/shop/pull/43/files?token=abc#diff") == "https://github.com/example/shop/pull/43")
        #expect(canonical("https://GitHub.com/example/shop/pull/43") == "https://github.com/example/shop/pull/43")
        #expect(canonical("https://github.com/example/shop/issues/43") == nil)
        #expect(canonical("https://github.com/example/shop/pull") == nil)
        #expect(canonical("http://github.com/example/shop/pull/43") == nil)
        #expect(canonical("https://gist.github.com/example/shop/pull/43") == nil)
        #expect(canonical("https://user:secret@github.com/example/shop/pull/43") == nil)
        #expect(canonical("https://github.com:8443/example/shop/pull/43") == nil)
    }

    @Test func theLinksInAMessageAreFoundBareOrInMarkdownOnceEach() {
        let text = """
            Merged in https://github.com/example/shop/pull/43. The bug is [#12](https://github.com/example/shop/issues/12),
            tracked as https://linear.app/example/issue/SHOP-7/apply-the-discount, and again: https://github.com/example/shop/pull/43/files!
            Not https://example.com/pull/1 or `https://github.com/example/shop`.
            """
        #expect(PluginLinks.matches(in: text, decorators: Self.decorators) == [
            match("github", "https://github.com/example/shop/pull/43"),
            match("github", "https://github.com/example/shop/issues/12"),
            match("linear", "https://linear.app/example/issue/SHOP-7"),
        ])
        #expect(PluginLinks.matches(in: text, decorators: []).isEmpty)
    }

    @Test func aPastedListIsLookedUpOnlySoFar() {
        let text = (1...40).map { "https://github.com/example/shop/pull/\($0)" }.joined(separator: "\n")
        #expect(PluginLinks.matches(in: text, decorators: Self.decorators).count == PluginLinks.perTextLimit)
    }

    // MARK: Decorating the transcript

    @Test func eachDecoratedLinkGetsItsPillAfterItInItsOwnParagraph() throws {
        let markdown = """
            See https://github.com/example/shop/pull/43 and [**the** issue](https://github.com/example/shop/issues/12).

            - https://example.com/other
            """
        let parsed = try AttributedString(markdown: markdown, options: .init(interpretedSyntax: .full))
        let decorated = PluginLinks.decorate(parsed) { url in
            guard let match = PluginLinks.match(url, decorators: Self.decorators) else { return nil }
            return AttributedString(match.url.hasSuffix("43") ? " [Merged]" : " [Open]")
        }
        let plain = String(decorated.characters)
        #expect(plain.contains("https://github.com/example/shop/pull/43 [Merged] and the issue [Open]."))
        #expect(!plain.contains("other ["))
        // The pill sits in the link's paragraph, not a block of its own.
        let pill = try #require(decorated.range(of: "[Merged]"))
        let link = try #require(decorated.range(of: "https://github.com/example/shop/pull/43"))
        #expect(decorated[pill].runs.first?.presentationIntent == decorated[link].runs.first?.presentationIntent)
        #expect(decorated[pill].runs.first?.presentationIntent != nil)
    }

    @Test func aLinkWithNothingToShowIsLeftAlone() throws {
        let parsed = try AttributedString(markdown: "See https://github.com/example/shop/pull/43.")
        #expect(PluginLinks.decorate(parsed) { _ in nil } == parsed)
    }

    // MARK: Statuses

    @Test func aStatusIsAskedForAgainEveryFiveMinutesAndKeptThroughAFailure() {
        var cache = PluginLinkCache()
        let pr = match("github", "https://github.com/example/shop/pull/43")
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        #expect(cache.isDue(pr, now: t0))
        cache.asking(pr, now: t0)
        #expect(!cache.isDue(pr, now: t0 + 600), "an answer is still on its way")
        cache.answered(pr, .status(PluginLinkStatus(label: "Open", tone: .open)))
        #expect(cache.status(pr)?.label == "Open")
        #expect(!cache.isDue(pr, now: t0 + PluginLinks.checkInterval))
        // Checked every 30 seconds and due after 4½ minutes: a change shows within 5.
        #expect(PluginLinks.refreshAfter + PluginLinks.checkInterval <= 300)
        #expect(cache.isDue(pr, now: t0 + PluginLinks.refreshAfter))
        cache.asking(pr, now: t0 + PluginLinks.refreshAfter)
        cache.answered(pr, .failed)
        #expect(cache.status(pr)?.label == "Open", "a failed lookup doesn't blank the pill")
        cache.asking(pr, now: t0 + 2 * PluginLinks.refreshAfter)
        cache.answered(pr, .status(PluginLinkStatus(label: "Closed", tone: .closed)))
        #expect(cache.status(pr) == PluginLinkStatus(label: "Closed", tone: .closed))
        cache.forget(pluginIds: [])
        #expect(cache.status(pr) == nil)
    }

    @Test func onlyABackgroundScriptAnswersALookupWithAShortLabelAndAKnownTone() {
        let storage = PluginStorage(directory: FileManager.default.temporaryDirectory, pluginId: "sh.example.links")
        func send(_ bridge: inout PluginBridge, _ payload: String) -> PluginBridge.Outcome {
            bridge.handle(#"{"api":2,"type":"links.result","payload":\#(payload)}"#, storage: storage)
        }
        var screen = PluginBridge(capabilities: [])
        guard case .refused = send(&screen, #"{"callId":"c1","status":{"label":"Open","tone":"open"}}"#) else {
            Issue.record("a screen answered a lookup"); return
        }
        var background = PluginBridge(capabilities: [])
        background.isBackground = true
        #expect(send(&background, #"{"callId":"c1","status":{"label":"Merged","tone":"merged"}}"#)
                == .linkResult(callId: "c1", .status(PluginLinkStatus(label: "Merged", tone: .merged))))
        #expect(send(&background, #"{"callId":"c2","status":null}"#) == .linkResult(callId: "c2", .status(nil)))
        #expect(send(&background, #"{"callId":"c3","error":"GitHub said no"}"#) == .linkResult(callId: "c3", .failed))
        #expect(send(&background, #"{"callId":"c4","status":{"label":"Open","tone":"blinking"}}"#) == .linkResult(callId: "c4", .failed))
        let long = String(repeating: "x", count: PluginLinkStatus.labelLimit + 1)
        #expect(send(&background, #"{"callId":"c5","status":{"label":"\#(long)","tone":"open"}}"#) == .linkResult(callId: "c5", .failed))
        #expect(send(&background, #"{"callId":"c6","status":{"label":"Two\nlines","tone":"open"}}"#) == .linkResult(callId: "c6", .failed))
        guard case .refused = send(&background, #"{"status":null}"#) else {
            Issue.record("a result without its lookup was taken"); return
        }
    }

    @Test func aLookupEndsWithItsAnswerOrItsTimeLimit() async {
        let lookups = PluginLinkLookups(timeout: 0.2)
        let answered = await lookups.lookUp { id in
            Task { await lookups.finish(id, .status(PluginLinkStatus(label: "Open", tone: .open))) }
            return true
        }
        #expect(answered == .status(PluginLinkStatus(label: "Open", tone: .open)))
        #expect(await lookups.lookUp { _ in true } == .failed)
        #expect(await lookups.lookUp { _ in false } == .failed)
        #expect(await lookups.pending == 0)
    }
}
