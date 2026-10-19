import Foundation
import JavaScriptCore
import Testing
@testable import AbstractCore

/// The bundled Kanban plugin (ABS-86). Its board is pure JavaScript over
/// the host snapshot, so these tests run the shipped `board.js` itself.
@Suite struct KanbanPluginTests {
    let fm = FileManager.default

    var pluginFolder: URL {
        let here = URL(fileURLWithPath: #filePath)
        let repo = here.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return repo.appendingPathComponent("Abstract/Resources/Plugins/kanban.abstractplugin")
    }

    /// 2026-10-18T12:00:00Z, the "now" every fixture is measured against.
    static let nowMs = 1_792_324_800_000.0

    func boardContext() throws -> JSContext {
        let source = try String(contentsOf: pluginFolder.appendingPathComponent("board.js"), encoding: .utf8)
        let context = try #require(JSContext())
        context.evaluateScript(source)
        if let exception = context.exception {
            Issue.record("board.js threw: \(exception.toString() ?? "?")")
        }
        return context
    }

    /// Runs `KanbanBoard.<call>` where the argument JSON texts are bound as
    /// `__args[0]`, `__args[1]`, …, and returns the result as a JSONValue.
    func evaluate(_ call: String, args: [String]) throws -> JSONValue {
        let context = try boardContext()
        context.setObject(args, forKeyedSubscript: "__argTexts" as NSString)
        context.evaluateScript("const __args = __argTexts.map((text) => JSON.parse(text));")
        let result = context.evaluateScript("JSON.stringify(KanbanBoard.\(call))")
        if let exception = context.exception {
            Issue.record("KanbanBoard.\(call) threw: \(exception.toString() ?? "?")")
            return .null
        }
        let text = try #require(result?.toString())
        let object = try JSONSerialization.jsonObject(with: Data(text.utf8))
        return JSONValue(any: object)
    }

    func build(snapshot: String, filter: String = "{}") throws -> JSONValue {
        try evaluate("build(__args[0], __args[1], \(Self.nowMs))", args: [snapshot, filter])
    }

    func column(_ board: JSONValue, _ key: String) -> JSONValue? {
        board["columns"]?.array?.first { $0["key"] == .string(key) }
    }

    func cardIds(_ board: JSONValue, _ key: String) -> [String] {
        column(board, key)?["cards"]?.array?.compactMap { $0["id"]?.string } ?? []
    }

    // One chat per column, plus a pinned one, an archived one, a standalone
    // one, and a same-named project on a second Mac. No real paths anywhere.
    var fixture: String {
        #"""
        {
          "macs": [
            {"id": "mac-a", "name": "Desk", "isThisMac": true, "reachable": true},
            {"id": "mac-b", "name": "Studio", "isThisMac": false, "reachable": false},
            {"id": "mac-c", "name": "Laptop", "isThisMac": false, "reachable": true}
          ],
          "projects": [
            {"key": "mac-a:p1", "name": "abstract", "macId": "mac-a", "archived": false},
            {"key": "mac-c:p1", "name": "abstract", "macId": "mac-c", "archived": false},
            {"key": "mac-a:p2", "name": "site", "macId": "mac-a", "archived": false},
            {"key": "mac-a:p3", "name": "notes", "macId": "mac-a", "archived": false}
          ],
          "chats": [
            {"id": "c-needs", "title": "Fix login", "projectKey": "mac-a:p1", "agentId": "claude", "branch": "fix/login", "status": "waitingInput", "progress": "needsYou", "pinned": true, "archived": false, "createdAt": "2026-10-17T12:00:00Z", "lastActivityAt": "2026-10-18T11:00:00Z", "hasChanges": true, "backgroundTasks": 0, "pullRequest": null, "macId": "mac-a"},
            {"id": "c-work", "title": "Build board", "projectKey": "mac-c:p1", "agentId": "codex", "branch": "feat/board", "status": "running", "progress": "working", "pinned": false, "archived": false, "createdAt": "2026-10-17T12:00:00Z", "lastActivityAt": "2026-10-18T11:30:00Z", "hasChanges": true, "backgroundTasks": 0, "pullRequest": null, "macId": "mac-c"},
            {"id": "c-review", "title": "Ship site", "projectKey": "mac-a:p2", "agentId": "muse", "branch": "feat/site", "status": "finished", "progress": "readyToReview", "pinned": false, "archived": false, "createdAt": "2026-10-17T12:00:00Z", "lastActivityAt": "2026-10-18T10:00:00Z", "hasChanges": true, "backgroundTasks": 0, "pullRequest": {"number": 42, "state": "open", "isDraft": false, "checks": "failing", "changesRequested": true}, "macId": "mac-a"},
            {"id": "c-notes", "title": "Write notes", "projectKey": "mac-a:p3", "agentId": "claude", "branch": "docs", "status": "finished", "progress": "readyToReview", "pinned": false, "archived": false, "createdAt": "2026-10-17T12:00:00Z", "lastActivityAt": "2026-10-18T09:00:00Z", "hasChanges": true, "backgroundTasks": 0, "pullRequest": null, "macId": "mac-a"},
            {"id": "c-done", "title": "Old cleanup", "projectKey": null, "agentId": "opencode", "branch": null, "status": "finished", "progress": "done", "pinned": false, "archived": false, "createdAt": "2026-10-10T12:00:00Z", "lastActivityAt": "2026-10-16T12:00:00Z", "hasChanges": false, "backgroundTasks": 0, "pullRequest": {"number": 7, "state": "merged", "isDraft": false, "checks": "passed", "changesRequested": false}, "macId": "mac-a"},
            {"id": "c-arch", "title": "Archived thing", "projectKey": "mac-a:p3", "agentId": "claude", "branch": "x", "status": "finished", "progress": "done", "pinned": false, "archived": true, "createdAt": "2026-10-10T12:00:00Z", "lastActivityAt": "2026-10-15T12:00:00Z", "hasChanges": false, "backgroundTasks": 0, "pullRequest": null, "macId": "mac-a"}
          ]
        }
        """#
    }

    // MARK: The board

    @Test func chatsLandInTheirProgressColumnAndPinsStayPut() throws {
        let board = try build(snapshot: fixture)
        #expect(cardIds(board, "needsYou") == ["c-needs"])
        #expect(cardIds(board, "working") == ["c-work"])
        #expect(cardIds(board, "readyToReview") == ["c-review", "c-notes"])
        #expect(cardIds(board, "done") == ["c-done"])
        #expect(board["shown"]?.int == 5)
        // The pinned chat keeps its real column and says it is pinned.
        let pinned = try #require(column(board, "needsYou")?["cards"]?.array?.first)
        #expect(pinned["pinned"] == .bool(true))
        #expect(pinned["agentName"] == .string("Claude Code"))
        #expect(pinned["age"] == .string("1h"))
        // Archived chats stay hidden until asked for.
        let withArchived = try build(snapshot: fixture, filter: #"{"showArchived": true}"#)
        #expect(cardIds(withArchived, "done") == ["c-done", "c-arch"])
    }

    @Test func sameNamedProjectsOnDifferentMacsStayApart() throws {
        let board = try build(snapshot: fixture)
        let labels = board["projects"]?.array?.filter { $0["name"] == .string("abstract") }
            .compactMap { $0["label"]?.string } ?? []
        #expect(labels == ["abstract · Desk", "abstract · Laptop"])
        // Filtering to one Mac's copy keeps only its chats.
        let deskOnly = try build(snapshot: fixture, filter: #"{"projects": ["mac-a:p1"]}"#)
        #expect(cardIds(deskOnly, "needsYou") == ["c-needs"])
        #expect(deskOnly["shown"]?.int == 1)
        // Standalone is its own choice.
        let standalone = try build(snapshot: fixture, filter: #"{"projects": ["__standalone__"]}"#)
        #expect(cardIds(standalone, "done") == ["c-done"])
        let done = try #require(column(board, "done")?["cards"]?.array?.first)
        #expect(done["projectName"] == .string("Standalone"))
        let remote = try #require(column(board, "working")?["cards"]?.array?.first)
        #expect(remote["projectName"] == .string("abstract · Laptop"))
        // The label already names the Mac, so the card doesn't repeat it.
        #expect(remote["macName"] == .string(""))
    }

    @Test func threeSelectedProjectsShowOnlyTheirCardsUntilCleared() throws {
        let three = #"{"projects": ["mac-a:p1", "mac-a:p2", "mac-a:p3"]}"#
        let board = try build(snapshot: fixture, filter: three)
        #expect(board["shown"]?.int == 3)
        #expect(cardIds(board, "working").isEmpty)
        #expect(cardIds(board, "done").isEmpty)
        let cleared = try build(snapshot: fixture, filter: "{}")
        #expect(cleared["shown"]?.int == 5)
    }

    @Test func agentMacAndSearchFiltersAndEmptyResults() throws {
        let byAgent = try build(snapshot: fixture, filter: #"{"agents": ["claude"], "macs": ["mac-a"]}"#)
        #expect(byAgent["shown"]?.int == 2)
        for query in ["login", "feat/site", "#42", "42"] {
            let found = try build(snapshot: fixture, filter: "{\"search\": \"\(query)\"}")
            #expect(found["shown"]?.int == 1, "search \(query)")
        }
        let none = try build(snapshot: fixture, filter: #"{"search": "no such chat"}"#)
        #expect(none["emptyKind"] == .string("noMatches"))
        #expect(none["filterActive"] == .bool(true))
        let empty = try build(snapshot: #"{"macs": [], "projects": [], "chats": []}"#)
        #expect(empty["emptyKind"] == .string("noChats"))
    }

    @Test func cardsCarryTheirPullRequestAndOfflineMacsAreNamed() throws {
        let board = try build(snapshot: fixture)
        let review = try #require(column(board, "readyToReview")?["cards"]?.array?.first)
        #expect(review["pullRequestLine"] == .string("#42 · checks failing · changes requested"))
        let done = try #require(column(board, "done")?["cards"]?.array?.first)
        // A merged pull request's checks no longer matter.
        #expect(done["pullRequestLine"] == .string("#7 · merged"))
        #expect(board["unreachableMacs"]?.array == [.string("Studio")])
        #expect(board["macs"]?.array?.first { $0["label"] == .string("Studio") }?["reachable"] == .bool(false))
    }

    @Test func savedFiltersAreReadBackTolerantly() throws {
        let saved = try evaluate(#"normalizeFilter(__args[0])"#,
                                 args: [#"{"projects": ["mac-a:p1", 3], "agents": "claude", "search": 5, "showArchived": "yes"}"#])
        #expect(saved["projects"]?.array == [.string("mac-a:p1")])
        #expect(saved["agents"]?.array?.isEmpty == true)
        #expect(saved["search"] == .string(""))
        #expect(saved["showArchived"] == .bool(false))
        let junk = try evaluate(#"normalizeFilter(__args[0])"#, args: [#""junk""#])
        #expect(junk["projects"]?.array?.isEmpty == true)
    }

    // MARK: Through the host snapshot

    func hostSnapshot(status: SessionStatus, hasChanges: Bool?, pullRequest: SidebarChats.PullRequestFacts?) -> String {
        let session = Session(id: "chat-1", projectId: "project-1", name: "Move me", providerId: "claude",
                              branch: "feat/move", status: status,
                              createdAt: Date(timeIntervalSince1970: 1_000), lastEventAt: Date(timeIntervalSince1970: 2_000))
        let chat = SidebarChats.Chat(session: session, pullRequest: pullRequest, hasChanges: hasChanges,
                                     projectName: "abstract", mac: "Desk")
        let snapshot = PluginSnapshot.build(
            revision: 1, capabilities: [.projectsRead, .chatsRead, .chatsOpen, .storageOwn],
            macs: [.init(id: "mac-a", name: "Desk", isThisMac: true, reachable: true)],
            projects: [.init(key: PluginSnapshot.projectKey(macId: "mac-a", projectId: "project-1"),
                             name: "abstract", macId: "mac-a", archived: false)],
            chats: [.init(chat: chat, projectKey: PluginSnapshot.projectKey(macId: "mac-a", projectId: "project-1"),
                          macId: "mac-a")])
        return snapshot.jsonValue().compact()
    }

    @Test func aChatMovesAcrossTheBoardAsItsTurnRuns() throws {
        // Waiting for an answer: Needs you. Answered: Working. Turn over
        // with changes: Ready to review. Pull request merged: Done.
        let waiting = try build(snapshot: hostSnapshot(status: .waitingInput, hasChanges: true, pullRequest: nil))
        #expect(cardIds(waiting, "needsYou") == ["chat-1"])
        let answered = try build(snapshot: hostSnapshot(status: .running, hasChanges: true, pullRequest: nil))
        #expect(cardIds(answered, "working") == ["chat-1"])
        let turned = try build(snapshot: hostSnapshot(status: .finished, hasChanges: true, pullRequest: nil))
        #expect(cardIds(turned, "readyToReview") == ["chat-1"])
        let merged = try build(snapshot: hostSnapshot(
            status: .finished, hasChanges: false,
            pullRequest: .init(number: 9, state: .merged, checks: .passed)))
        #expect(cardIds(merged, "done") == ["chat-1"])
    }

    // MARK: The package

    @Test func theBundledKanbanManifestIsValid() throws {
        guard fm.fileExists(atPath: pluginFolder.path) else { return }
        let inspection = try PluginPackage.inspect(folder: pluginFolder)
        #expect(inspection.manifest.id == "sh.abstract.kanban")
        #expect(inspection.manifest.grantedCapabilities == [.projectsRead, .chatsRead, .chatsOpen, .storageOwn])
        #expect(inspection.manifest.view?.title == "Kanban")
        for file in ["index.html", "board.js", "app.js", "style.css"] {
            #expect(fm.fileExists(atPath: pluginFolder.appendingPathComponent(file).path), "\(file) is missing")
        }
    }

    @Test func kanbanTalksOnlyThroughTheHostBridge() throws {
        let app = try String(contentsOf: pluginFolder.appendingPathComponent("app.js"), encoding: .utf8)
        let boardSource = try String(contentsOf: pluginFolder.appendingPathComponent("board.js"), encoding: .utf8)
        for granted in ["\"openChat\"", "\"getSnapshot\"", "\"storage.get\"", "\"storage.set\""] {
            #expect(app.contains(granted), "app.js never sends \(granted)")
        }
        // No way around the host: no network, no web storage, no eval.
        for forbidden in ["fetch(", "XMLHttpRequest", "WebSocket", "localStorage", "sessionStorage", "eval("] {
            #expect(!app.contains(forbidden) && !boardSource.contains(forbidden), "found \(forbidden)")
        }
        #expect(!boardSource.contains("document."))
        #expect(!boardSource.contains("AbstractPlugin"))
        // The plugin themes from the host's tokens, never its own palette.
        let css = try String(contentsOf: pluginFolder.appendingPathComponent("style.css"), encoding: .utf8)
        for token in ["--abstract-canvas", "--abstract-text", "--abstract-surface"] {
            #expect(css.contains(token), "style.css never uses \(token)")
        }
        for theme in Theme.allCases {
            let context = PluginContext.jsonValue(theme: theme, locale: "en_US", pluginId: "sh.abstract.kanban",
                                                  pluginVersion: "1.0.0",
                                                  capabilities: [.projectsRead, .chatsRead, .chatsOpen, .storageOwn])
            #expect(context["theme"] == .string(theme.rawValue))
            #expect(context["tokens"]?["canvas"]?.string?.hasPrefix("#") == true)
        }
    }
}
