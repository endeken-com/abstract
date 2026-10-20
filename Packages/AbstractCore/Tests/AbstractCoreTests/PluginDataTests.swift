import Foundation
import Testing
@testable import AbstractCore

@Suite struct PluginDataTests {
    let day1 = Date(timeIntervalSince1970: 1_700_000_000)
    var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    func usageEntries() -> [PluginData.UsageEntry] {
        func record(_ at: Date, cwd: String, input: Int, output: Int) -> LocalUsage.Record {
            LocalUsage.Record(key: nil, date: at, provider: .claude, model: "claude-sonnet-4-5",
                              cwd: cwd, tokens: .init(input: input, output: output))
        }
        return [
            .init(chatId: "chat-1", record: record(day1, cwd: "/secret/worktree", input: 100, output: 10)),
            .init(chatId: "chat-1", record: record(day1.addingTimeInterval(3600), cwd: "/secret/worktree", input: 200, output: 20)),
            .init(chatId: "chat-2", record: record(day1.addingTimeInterval(90_000), cwd: "/secret/other", input: 50, output: 5)),
            .init(chatId: nil, record: record(day1, cwd: "/secret/elsewhere", input: 7, output: 1)),
        ]
    }

    @Test func usagePerChatTotalsMatchTheLedger() throws {
        let payload = PluginData.usage(entries: usageEntries(), view: "chats", chatId: nil,
                                       page: PluginPage(), calendar: utc)
        #expect(Set((payload.object ?? [:]).keys) == ["items", "total", "offset", "limit", "hasMore"])
        #expect(payload["total"] == .number(2))
        let items = try #require(payload["items"]?.array)
        // Newest chat first; the outside-a-chat response has no chat row.
        #expect(items.map { $0["chatId"]?.string } == ["chat-2", "chat-1"])
        let chat1 = try #require(items.last?.object)
        #expect(Set(chat1.keys) == ["chatId", "inputTokens", "outputTokens", "cacheReadTokens",
                                    "cacheWriteTokens", "totalTokens", "costUsd", "responses", "lastAt"])
        #expect(chat1["inputTokens"] == .number(300))
        #expect(chat1["totalTokens"] == .number(330))
        #expect(chat1["responses"] == .number(2))
        // The folder a response ran in never leaves the Mac.
        #expect(!payload.compact().contains("/secret"))
        #expect(!payload.compact().contains("cwd"))
    }

    @Test func usageEntriesAndDaysViewsAreAllowlistedAndPaged() throws {
        let entries = PluginData.usage(entries: usageEntries(), view: "entries", chatId: "chat-1",
                                       page: PluginPage(offset: 0, limit: 1), calendar: utc)
        #expect(entries["total"] == .number(2))
        #expect(entries["hasMore"] == .bool(true))
        let first = try #require(entries["items"]?.array?.first?.object)
        #expect(Set(first.keys) == ["chatId", "at", "agentId", "model", "inputTokens", "outputTokens",
                                    "cacheReadTokens", "cacheWriteTokens", "totalTokens", "costUsd", "estimated"])
        let second = PluginData.usage(entries: usageEntries(), view: "entries", chatId: "chat-1",
                                      page: PluginPage(offset: 1, limit: 1), calendar: utc)
        #expect(second["hasMore"] == .bool(false))

        let days = PluginData.usage(entries: usageEntries(), view: "days", chatId: nil,
                                    page: PluginPage(), calendar: utc)
        let dayRow = try #require(days["items"]?.array?.first?.object)
        #expect(Set(dayRow.keys) == ["day", "agentId", "inputTokens", "outputTokens", "cacheReadTokens",
                                     "cacheWriteTokens", "totalTokens", "costUsd"])
        #expect(days["total"] == .number(2))
    }

    func timeline() -> Timeline {
        var timeline = Timeline()
        timeline.append(.text(role: .user, text: "Fix #42 please", blockId: nil, partial: false), at: day1)
        timeline.append(.toolUse(id: "t1", name: "Read", input: .object([
            "file_path": .string("Sources/App.swift"), "content": .string("file contents must not leak"),
        ]), edit: nil), at: day1.addingTimeInterval(5))
        timeline.append(.toolResult(toolUseId: "t1", output: "command output must not leak", isError: false, edit: nil),
                        at: day1.addingTimeInterval(6))
        timeline.append(.text(role: .assistant, text: "Done in abc1234, see pull/7", blockId: nil, partial: false),
                        at: day1.addingTimeInterval(10))
        timeline.append(.turnEnd(durationMs: 10_000, costUsd: nil, usage: nil, summary: "Fixed the thing"),
                        at: day1.addingTimeInterval(10))
        timeline.append(.status(.idle, detail: nil), at: day1.addingTimeInterval(10))
        return timeline
    }

    @Test func turnsCarryTimesOutcomeAndSummaryOnly() throws {
        let payload = PluginData.turns(chats: [(chatId: "chat-1", timeline: timeline())], page: PluginPage())
        #expect(payload["total"] == .number(1))
        let turn = try #require(payload["items"]?.array?.first?.object)
        #expect(Set(turn.keys).isSubset(of: ["chatId", "turn", "outcome", "startedAt", "endedAt", "durationMs", "summary"]))
        #expect(turn["outcome"] == .string("done"))
        #expect(turn["summary"] == .string("Fixed the thing"))
        #expect(turn["startedAt"]?.string?.isEmpty == false)
        // No message text rides along with a turn line.
        #expect(!payload.compact().contains("Fix #42"))
    }

    @Test func transcriptsAreScopedToThePickedProjects() throws {
        let chats = [
            (chatId: "in", projectKey: "mac-1:p1", timeline: timeline()),
            (chatId: "out", projectKey: "mac-1:p2", timeline: timeline()),
            (chatId: "none", projectKey: nil as String?, timeline: timeline()),
        ]
        let payload = PluginData.transcript(chats: chats, allowedProjectKeys: ["mac-1:p1"], page: PluginPage())
        let items = try #require(payload["items"]?.array)
        #expect(Set(items.compactMap { $0["chatId"]?.string }) == ["in"])
        #expect(items.count == 3)

        // No projects picked reads nothing, even with the grant.
        let empty = PluginData.transcript(chats: chats, allowedProjectKeys: [], page: PluginPage())
        #expect(empty["total"] == .number(0))
    }

    @Test func transcriptsNeverCarryFileContentsOrToolOutput() throws {
        let payload = PluginData.transcript(
            chats: [(chatId: "in", projectKey: "mac-1:p1", timeline: timeline())],
            allowedProjectKeys: ["mac-1:p1"], page: PluginPage())
        let text = payload.compact()
        #expect(!text.contains("must not leak"))
        let items = try #require(payload["items"]?.array)
        let user = try #require(items.first?.object)
        #expect(Set(user.keys) == ["chatId", "projectKey", "kind", "text", "references", "at"])
        #expect(user["references"]?["pullRequests"]?.array == [.number(42)])
        let tool = try #require(items.dropFirst().first?.object)
        #expect(Set(tool.keys) == ["chatId", "projectKey", "kind", "toolName", "filePaths", "at"])
        #expect(tool["filePaths"]?.array == [.string("Sources/App.swift")])
        let assistant = try #require(items.last?.object)
        #expect(assistant["references"]?["pullRequests"]?.array == [.number(7)])
        #expect(assistant["references"]?["commits"]?.array == [.string("abc1234")])

        // Paging walks the messages in order.
        let page2 = PluginData.transcript(
            chats: [(chatId: "in", projectKey: "mac-1:p1", timeline: timeline())],
            allowedProjectKeys: ["mac-1:p1"], page: PluginPage(offset: 2, limit: 1))
        #expect(page2["items"]?.array?.first?["kind"] == .string("assistant"))
        #expect(page2["hasMore"] == .bool(false))
    }

    @Test func automationsCarrySchedulesAndLastRunButNoPrompt() throws {
        let automation = Automation(
            id: "auto-1", name: "Nightly tidy", prompt: "secret instructions", providerId: "claude",
            projectId: "p1", rrule: "FREQ=DAILY;BYHOUR=9", timezone: "Europe/Berlin",
            nextRunAt: day1.addingTimeInterval(86_400))
        let run = AutomationRun(id: "run-1", automationId: "auto-1", firedAt: day1, trigger: .schedule,
                                status: .created, sessionId: "chat-9", error: "must not leak either")
        let payload = PluginData.automations(
            items: [(automation: automation, projectKey: "mac-1:p1", lastRun: run)], page: PluginPage())
        let row = try #require(payload["items"]?.array?.first?.object)
        #expect(Set(row.keys) == ["id", "name", "agentId", "enabled", "schedules", "projectKey", "nextRunAt", "lastRun"])
        #expect(row["schedules"]?.array?.first?["rrule"] == .string("FREQ=DAILY;BYHOUR=9"))
        #expect(row["lastRun"]?["outcome"] == .string("created"))
        #expect(row["lastRun"]?["chatId"] == .string("chat-9"))
        #expect(!payload.compact().contains("secret instructions"))
        #expect(!payload.compact().contains("must not leak"))
    }

    @Test func pagesClampToTheirLimits() {
        #expect(PluginPage(offset: -3, limit: 0).offset == 0)
        #expect(PluginPage(offset: -3, limit: 0).limit == 1)
        #expect(PluginPage(offset: 0, limit: 10_000).limit == PluginPage.maxLimit)
        #expect(PluginPage(payload: nil).limit == PluginPage.defaultLimit)
    }

    // MARK: Bridge and grants

    func storage() throws -> PluginStorage {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("abstract-plugin-data-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return PluginStorage(directory: dir, pluginId: "sh.abstract.test")
    }

    @Test func eachPullNeedsItsOwnGrant() throws {
        let store = try storage()
        var bridge = PluginBridge(capabilities: [.chatsRead])
        for type in ["getUsage", "getTurns", "getTranscript", "getAutomations"] {
            let denied = bridge.handle(#"{"api":1,"type":"\#(type)","id":"1","payload":{}}"#, storage: store)
            if case .refused = denied {} else { Issue.record("\(type) without its grant wasn't refused: \(denied)") }
        }
        // Without transcripts.read there is no message text to be had.
        bridge.capabilities = [.usageRead, .turnsRead, .automationsRead]
        #expect(bridge.handle(#"{"api":1,"type":"getUsage","id":"2","payload":{"view":"days","offset":5,"limit":10}}"#, storage: store)
                == .getUsage(id: "2", view: "days", page: PluginPage(offset: 5, limit: 10), chatId: nil))
        #expect(bridge.handle(#"{"api":1,"type":"getTurns","id":"3","payload":{"chatId":"c1"}}"#, storage: store)
                == .getTurns(id: "3", page: PluginPage(), chatId: "c1"))
        #expect(bridge.handle(#"{"api":1,"type":"getAutomations","id":"4","payload":{}}"#, storage: store)
                == .getAutomations(id: "4", page: PluginPage()))
        if case .refused = bridge.handle(#"{"api":1,"type":"getTranscript","id":"5","payload":{}}"#, storage: store) {} else {
            Issue.record("getTranscript without transcripts.read wasn't refused")
        }
        if case .refused = bridge.handle(#"{"api":1,"type":"getUsage","id":"6","payload":{"view":"everything"}}"#, storage: store) {} else {
            Issue.record("an unknown usage view wasn't refused")
        }
    }

    @Test func theNewCapabilitiesValidateAndReadPlainly() {
        for name in ["usage.read", "turns.read", "transcripts.read", "automations.read"] {
            #expect(PluginCapability(rawValue: name) != nil)
        }
        #expect(PluginCapability.usageRead.plainWords == "See what your chats used and cost")
        #expect(PluginCapability.turnsRead.plainWords == "See when your agents worked")
        #expect(PluginCapability.transcriptsRead.plainWords(transcriptProjects: ["abstract", "notes"])
                == "Read your chats' messages in abstract, notes")
        #expect(PluginCapability.transcriptsRead.plainWords(transcriptProjects: [])
                == "Read your chats' messages in no projects yet")
    }

    @Test func recordsFromBeforeScopingStillDecode() throws {
        let old = """
        [{"id":"sh.abstract.test","name":"Test","version":"1.0.0","source":"user","enabled":true,
          "grantedCapabilities":["chats.read"],"packageHash":"abc","installedAt":700000000}]
        """
        let records = try JSONDecoder().decode([PluginRecord].self, from: Data(old.utf8))
        #expect(records.first?.transcriptProjectKeys == [])
        #expect(records.first?.grantedCapabilities == [.chatsRead])
    }
}
