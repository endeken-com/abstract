import Foundation
import SQLite3
import Testing
@testable import AbstractCore

@Suite("Local usage")
struct LocalUsageTests {
    private func lines(_ rows: [String]) -> Data { Data(rows.joined(separator: "\n").utf8) }

    @Test func claudeCountsEachResponseOnceWithItsCacheSplit() {
        let usage = #""usage":{"input_tokens":2,"cache_creation_input_tokens":300,"cache_read_input_tokens":1000,"output_tokens":50,"cache_creation":{"ephemeral_1h_input_tokens":300,"ephemeral_5m_input_tokens":0}}"#
        let data = lines([
            #"{"type":"user","timestamp":"2026-09-22T20:10:00.000Z","message":{"role":"user"}}"#,
            #"{"type":"assistant","timestamp":"2026-09-22T20:10:04.541Z","cwd":"/w","requestId":"r1","message":{"id":"m1","model":"claude-opus-5",\#(usage)}}"#,
            #"{"type":"assistant","timestamp":"2026-09-22T20:10:04.546Z","cwd":"/w","requestId":"r1","message":{"id":"m1","model":"claude-opus-5",\#(usage)}}"#,
            #"{"type":"assistant","timestamp":"2026-09-22T20:11:00.000Z","cwd":"/w","requestId":"r2","message":{"id":"m2","model":"<synthetic>","usage":{"output_tokens":0}}}"#,
        ])
        let records = LocalUsage.claudeRecords(data)
        #expect(records.count == 1)
        #expect(records[0].tokens == LocalUsage.Tokens(input: 2, cacheWrite5m: 0, cacheWrite1h: 300, cacheRead: 1000, output: 50))
        #expect(records[0].key == "m1:r1" && records[0].cwd == "/w")
    }

    @Test func codexTakesEachTurnOnceUnderItsModel() {
        let data = lines([
            #"{"timestamp":"2026-08-22T00:02:00.805Z","type":"session_meta","payload":{"cwd":"/repo"}}"#,
            #"{"timestamp":"2026-08-22T00:02:01.299Z","type":"turn_context","payload":{"cwd":"/repo","model":"gpt-5.6-terra"}}"#,
            #"{"timestamp":"2026-08-22T00:02:08.451Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":1000},"last_token_usage":{"input_tokens":900,"cached_input_tokens":600,"output_tokens":100}}}}"#,
            #"{"timestamp":"2026-08-22T00:02:08.452Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":1000},"last_token_usage":{"input_tokens":900,"cached_input_tokens":600,"output_tokens":100}}}}"#,
        ])
        let records = LocalUsage.codexRecords(data)
        #expect(records.count == 1)
        #expect(records[0].model == "gpt-5.6-terra" && records[0].cwd == "/repo")
        #expect(records[0].tokens == LocalUsage.Tokens(input: 300, cacheRead: 600, output: 100))
    }

    @Test func openCodeStepsComeFromItsDatabaseWithTheirOwnCost() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("abstract-home-\(UUID().uuidString)").path
        defer { try? fm.removeItem(atPath: home) }
        let path = LocalUsage.openCodeDatabase(home: home)
        try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Self.writeOpenCodeDatabase(at: path)

        let records = LocalUsage.load(home: home, cache: nil)
        // The user's message and a failed step with no tokens don't count.
        #expect(records.map(\.model) == ["anthropic/claude-opus-4-6", "opencode/big-pickle"])
        #expect(records.allSatisfy { $0.provider == .opencode && $0.cwd == "/tmp/demo/worktree" })
        #expect(records[0].key == "opencode:msg_c1a0000002demoStep1000000")
        #expect(records[0].date == Date(timeIntervalSince1970: 1_790_000_001))
        #expect(records[0].tokens == LocalUsage.Tokens(input: 3, cacheWrite5m: 11071, output: 131))
        #expect(records[1].tokens == LocalUsage.Tokens(input: 474, cacheRead: 141, output: 170))

        // A subscription step logs no cost, so it's priced like the same model under Claude.
        let claude = LocalUsage.Record(key: nil, date: .now, provider: .claude, model: "claude-opus-4-6", cwd: "", tokens: records[0].tokens)
        #expect(ModelPricing.price(records[0]).cost == ModelPricing.price(claude).cost)
        #expect(ModelPricing.price(records[0]).cost > 0 && !ModelPricing.price(records[0]).estimated)
        // A model the table doesn't know keeps the cost OpenCode reported.
        #expect(ModelPricing.price(records[1]) == (0.0123, false))
    }

    @Test func openCodeWithoutADatabaseReportsNothing() {
        #expect(LocalUsage.openCodeRecords(database: "/nonexistent/opencode.db").isEmpty)
    }

    /// The fixture's rows in a `message` table shaped like OpenCode 1.18's.
    private static func writeOpenCodeDatabase(at path: String) throws {
        let url = try #require(Bundle.module.url(forResource: "opencode-messages", withExtension: "jsonl", subdirectory: "Fixtures"))
        var db: OpaquePointer?
        try #require(sqlite3_open(path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        try #require(sqlite3_exec(db, """
            CREATE TABLE message (id text PRIMARY KEY, session_id text NOT NULL, time_created integer NOT NULL,
                                  time_updated integer NOT NULL, data text NOT NULL)
            """, nil, nil, nil) == SQLITE_OK)
        for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") {
            let row = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            let data = try JSONSerialization.data(withJSONObject: try #require(row["data"]))
            var statement: OpaquePointer?
            try #require(sqlite3_prepare_v2(db, "INSERT INTO message VALUES (?, ?, 0, 0, ?)", -1, &statement, nil) == SQLITE_OK)
            defer { sqlite3_finalize(statement) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(statement, 1, try #require(row["id"] as? String), -1, transient)
            sqlite3_bind_text(statement, 2, try #require(row["session_id"] as? String), -1, transient)
            sqlite3_bind_text(statement, 3, String(decoding: data, as: UTF8.self), -1, transient)
            try #require(sqlite3_step(statement) == SQLITE_DONE)
        }
    }

    @Test func pricesFollowTheLongestPrefix() throws {
        let tokens = LocalUsage.Tokens(input: 1_000_000, cacheWrite5m: 1_000_000, cacheWrite1h: 1_000_000, cacheRead: 1_000_000, output: 1_000_000)
        // Opus 5: 5 in, 6.25 write 5m, 10 write 1h, 0.5 read, 25 out.
        #expect(try #require(ModelPricing.cost(provider: .claude, model: "claude-opus-5", tokens: tokens)) == 46.75)
        // Opus 5.5 doesn't fall back to Opus 5's rates.
        #expect(ModelPricing.rates(provider: .claude, model: "claude-opus-5-5")?.rates.input == 4)
        #expect(ModelPricing.rates(provider: .claude, model: "claude-fable-5-1")?.rates.cacheRead == 0.25)
        #expect(ModelPricing.rates(provider: .claude, model: "claude-opus-4-1-20250805")?.rates.output == 75)
        #expect(ModelPricing.cost(provider: .claude, model: "mystery", tokens: tokens) == nil)
        #expect(ModelPricing.rates(provider: .codex, model: "gpt-6-astra")?.known == false)
    }

    @Test func claudeQuotaComesFromRateLimitEvents() throws {
        let line = #"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","unifiedWindows":{"five_hour":{"utilization":0.05,"resetsAt":1790149200},"seven_day":{"utilization":0.15,"resetsAt":1790650800}}}}"#
        let quota = try #require(ClaudeAccounts.quota(fromLine: line))
        #expect(quota.session?.used == 0.05 && quota.weekly?.used == 0.15)
        #expect(quota.weekly?.resetsAt == Date(timeIntervalSince1970: 1790650800))
        #expect(ClaudeAccounts.quota(fromLine: #"{"type":"assistant"}"#) == nil)
    }

    @Test func codexQuotaReadsPercentagesAndCredits() throws {
        let line = Data(#"{"timestamp":"2026-09-23T04:29:40.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":0.0,"window_minutes":300,"resets_at":1790155775},"secondary":{"used_percent":1.0,"window_minutes":10080,"resets_at":1790714157},"credits":{"has_credits":false,"balance":"0"}}}}"#.utf8)
        let quota = try #require(CodexAccount.quota(fromLine: line, fallbackDate: .distantPast))
        #expect(quota.session?.used == 0 && quota.weekly?.used == 0.01)
        #expect(quota.credits == "0")
    }

    @Test func profilesAreEveryClaudeFolderWithTranscripts() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("abstract-home-\(UUID().uuidString)").path
        defer { try? fm.removeItem(atPath: home) }
        for dir in [".claude/projects", ".claude-work/projects", ".claude-empty", ".claudebar/projects"] {
            try fm.createDirectory(atPath: home + "/" + dir, withIntermediateDirectories: true)
        }
        try #"{"oauthAccount":{"emailAddress":"a@b.co","organizationType":"claude_team"}}"#.write(toFile: home + "/.claude-work/.claude.json", atomically: true, encoding: .utf8)
        let profiles = ClaudeAccounts.profiles(home: home)
        #expect(profiles.map { ($0.path as NSString).lastPathComponent } == [".claude", ".claude-work"])
        #expect(profiles[1].email == "a@b.co" && profiles[1].plan == "Team" && !profiles[1].isStandard)
        #expect(ClaudeAccounts.loginCommand(profiles[1]) == "CLAUDE_CONFIG_DIR=\(home)/.claude-work claude auth login")
    }
}
