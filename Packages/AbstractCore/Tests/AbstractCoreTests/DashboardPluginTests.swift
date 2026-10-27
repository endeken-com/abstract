import Foundation
import JavaScriptCore
import Testing
@testable import AbstractCore

@Suite struct DashboardPluginTests {
    var pluginFolder: URL {
        let here = URL(fileURLWithPath: #filePath)
        let repo = here.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return repo.appendingPathComponent("Abstract/Resources/Plugins/dashboard.abstractplugin")
    }

    func build(snapshot: String, usage: String = "[]", turns: String = "[]", filter: String = "{}") throws -> JSONValue {
        let source = try String(contentsOf: pluginFolder.appendingPathComponent("dashboard.js"), encoding: .utf8)
        let context = try #require(JSContext())
        context.evaluateScript(source)
        context.setObject([snapshot, usage, turns, filter], forKeyedSubscript: "__texts" as NSString)
        let result = context.evaluateScript("JSON.stringify(Dashboard.build(...__texts.map(JSON.parse), Date.parse('2026-10-18T12:00:00Z')))")
        if let exception = context.exception { Issue.record("dashboard.js threw: \(exception)") }
        let json = try #require(result?.toString())
        return JSONValue(any: try JSONSerialization.jsonObject(with: Data(json.utf8)))
    }

    var snapshot: String {
        #"""
        {"macs":[{"id":"desk","name":"Desk","isThisMac":true},{"id":"laptop","name":"Laptop","isThisMac":false}],
         "projects":[{"key":"desk:p","name":"App","macId":"desk"},{"key":"laptop:p","name":"App","macId":"laptop"}],
         "chats":[
           {"id":"n-old","title":"Old question","progress":"needsYou","projectKey":"desk:p","macId":"desk","archived":false,"lastActivityAt":"2026-10-15T12:00:00Z"},
           {"id":"n-new","title":"New question","progress":"needsYou","projectKey":"desk:p","macId":"desk","archived":false,"lastActivityAt":"2026-10-18T12:00:00Z"},
           {"id":"w","title":"Working","progress":"working","projectKey":"laptop:p","macId":"laptop","archived":false,"lastActivityAt":"2026-10-17T12:00:00Z"},
           {"id":"r","title":"Review","progress":"readyToReview","projectKey":"desk:p","macId":"desk","archived":false,"lastActivityAt":"2026-10-16T12:00:00Z"},
           {"id":"d","title":"Done","progress":"done","projectKey":"desk:p","macId":"desk","archived":false,"lastActivityAt":"2026-10-17T12:00:00Z"},
           {"id":"old","title":"Old done","progress":"done","projectKey":"desk:p","macId":"desk","archived":false,"lastActivityAt":"2026-10-10T12:00:00Z"},
           {"id":"archived","title":"Hidden","progress":"working","projectKey":"desk:p","macId":"desk","archived":true,"lastActivityAt":"2026-10-18T12:00:00Z"}
         ]}
        """#
    }

    @Test func countsMatchProgressAndShowOldestFirst() throws {
        let dashboard = try build(snapshot: snapshot)
        let cards = try #require(dashboard["cards"]?.array)
        #expect(cards.map { $0["count"]?.int } == [2, 1, 1])
        #expect(cards[0]["chats"]?.array?.compactMap { $0["id"]?.string } == ["n-old", "n-new"])
        #expect(dashboard["doneThisWeek"]?.int == 1)
        #expect(dashboard["projects"]?.array?.compactMap { $0["label"]?.string } == ["App · Desk", "App · Laptop"])
    }

    @Test func filtersKeepProjectsOnDifferentMacsApart() throws {
        let project = try build(snapshot: snapshot, filter: #"{"project":"laptop:p"}"#)
        #expect(project["cards"]?.array?.compactMap { $0["count"]?.int } == [0, 1, 0])
        let mac = try build(snapshot: snapshot, filter: #"{"mac":"desk"}"#)
        #expect(mac["cards"]?.array?.compactMap { $0["count"]?.int } == [2, 0, 1])
    }

    @Test func thisMonthsUsageMatchesAllEntriesAndFiltersByChat() throws {
        let usage = #"""
        [{"chatId":"n-old","agentId":"claude","at":"2026-10-15T12:00:00Z","totalTokens":100,"costUsd":0.5},
         {"chatId":"w","agentId":"codex","at":"2026-10-17T12:00:00Z","totalTokens":200,"costUsd":1.25},
         {"agentId":"claude","at":"2026-10-18T12:00:00Z","totalTokens":30,"costUsd":0.1},
         {"chatId":"n-old","agentId":"claude","at":"2026-09-30T12:00:00Z","totalTokens":900,"costUsd":9}]
        """#
        let all = try build(snapshot: snapshot, usage: usage)
        #expect(all["tokens"]?.int == 330)
        #expect(abs((all["cost"]?.double ?? 0) - 1.85) < 0.00001)
        #expect(all["agents"]?.array?.compactMap { $0["agentId"]?.string } == ["codex", "claude"])
        let desk = try build(snapshot: snapshot, usage: usage, filter: #"{"mac":"desk"}"#)
        #expect(desk["tokens"]?.int == 100)
    }

    @Test func historyCountsEachOutcomeInItsLocalDay() throws {
        let turns = #"""
        [{"chatId":"n-old","endedAt":"2026-10-17T12:00:00Z","outcome":"done"},
         {"chatId":"n-old","endedAt":"2026-10-17T13:00:00Z","outcome":"failed"},
         {"chatId":"w","endedAt":"2026-10-17T14:00:00Z","outcome":"stopped"},
         {"chatId":"n-old","endedAt":"2026-10-01T12:00:00Z","outcome":"done"}]
        """#
        let all = try build(snapshot: snapshot, turns: turns)
        let yesterday = try #require(all["days"]?.array?.first { $0["date"] == .string("2026-10-17") })
        #expect(all["days"]?.array?.count == 14)
        #expect(yesterday["done"]?.int == 1)
        #expect(yesterday["stopped"]?.int == 1)
        #expect(yesterday["failed"]?.int == 1)
        let desk = try build(snapshot: snapshot, turns: turns, filter: #"{"mac":"desk"}"#)
        let deskYesterday = try #require(desk["days"]?.array?.first { $0["date"] == .string("2026-10-17") })
        #expect(deskYesterday["stopped"]?.int == 0)
    }

    @Test func bundledDashboardUsesOnlyExistingReadGrants() throws {
        let inspection = try PluginPackage.inspect(folder: pluginFolder)
        #expect(inspection.manifest.id == "sh.abstract.dashboard")
        #expect(inspection.manifest.grantedCapabilities == [.projectsRead, .chatsRead, .chatsOpen,
                                                             .usageRead, .turnsRead, .storageOwn])
        #expect(inspection.manifest.view?.title == "Dashboard")
        #expect(inspection.manifest.contributes.homeWidgets.count == 1)
    }
}
