import Foundation
import Testing
@testable import AbstractCore

@Suite("Revund")
struct RevundTests {
    private let json = #"""
    {"schema_version":"1","model":"claude-sonnet-4-6","duration_ms":8200,
     "findings":[
      {"id":"a1","fingerprint":"a1b2","pass":"style","severity":"nitpick","file":"src/b.ts","line":3,"body":"Name it for what it holds.","why":"","confidence":0.8},
      {"id":"c3","fingerprint":"c3d4","pass":"security","severity":"blocker","file":"src/auth/token.ts","line":14,
       "body":"Compared with ==, which leaks timing.","why":"The token can be recovered byte by byte.","confidence":0.97,
       "suggest":"if timingSafeEqual(token, expected) {",
       "snippet":[{"number":13,"text":"// check"},{"number":14,"text":"if token == expected {","hit":true}]}],
     "summary":{"total":2,"by_severity":{"blocker":1,"warning":0,"nitpick":1}}}
    """#

    @Test func decodesTheCLIReviewWorstFirst() throws {
        let report = try Revund.decode(stdout: "→ parsing diff\n" + json)
        #expect(report.findings.map(\.id) == ["c3", "a1"])
        #expect(report.summary == "1 blocker · 1 nitpick")
        #expect(report.findings[1].why == nil)
        #expect(report.findings[0].location == "src/auth/token.ts:14")
        #expect(report.durationMs == 8200)
    }

    @Test func unknownSeveritiesReadAsWarnings() throws {
        let report = try Revund.decode(Data(#"{"findings":[{"pass":"x","severity":"odd","file":"a","line":1,"body":"b"}]}"#.utf8))
        #expect(report.findings.first?.severity == .warning)
    }

    @Test func argumentsFollowTheScope() {
        #expect(Revund.reviewArgs(repo: "/wt", scope: .uncommitted).suffix(4) == ["--repo", "/wt", "--base", "HEAD"])
        #expect(Revund.reviewArgs(repo: "/wt", scope: .since("abc123")).last == "abc123")
        #expect(Revund.reviewArgs(repo: "/wt", scope: .uncommitted).contains("--json"))
    }

    @Test func progressLinesAreCleaned() {
        #expect(Revund.progress("✓ security · 3 findings · 12s") == "security · 3 findings · 12s")
        #expect(Revund.progress("→ parsing diff") == "parsing diff")
        #expect(Revund.progress("Error: boom") == nil)
    }

    @Test func agentTextCarriesPlaceWhyLinesAndFix() throws {
        let report = try Revund.decode(Data(json.utf8))
        let text = Revund.agentText(report.findings)
        #expect(text.hasPrefix("1. [blocker] security · src/auth/token.ts:14\nCompared with ==, which leaks timing.\nWhy: The token"))
        #expect(text.contains("> 14 if token == expected {"))
        #expect(text.contains("Suggested fix:\n```\nif timingSafeEqual(token, expected) {\n```"))
        #expect(text.contains("2. [nitpick] style · src/b.ts:3"))
        let attachment = Revund.attachment(report.findings, scope: "uncommitted changes")
        #expect(attachment.label == "Revund · 1 blocker · 1 nitpick")
        #expect(attachment.promptText.hasPrefix("Revund review: 1 blocker · 1 nitpick\nReviewed: uncommitted changes\n\n1. [blocker]"))
    }

    @Test func checkRunAnnotationsBecomeFindings() throws {
        let a = try JSONDecoder().decode(JSONValue.self, from: Data(#"""
        {"path":"src/auth/token.ts","start_line":14,"end_line":14,"annotation_level":"failure","title":"[blocker] security",
         "message":"Compared with ==.","raw_details":"Leaks timing.\n\nSuggested fix:\nif safe(a, b) {"}
        """#.utf8))
        let f = try #require(Revund.finding(annotation: a))
        #expect(f.severity == .blocker)
        #expect(f.pass == "security")
        #expect(f.why == "Leaks timing.")
        #expect(f.suggest == "if safe(a, b) {")
        #expect(f.line == 14)
    }

    @Test func onlyRevundCheckRunsCount() throws {
        let runs = try JSONDecoder().decode(JSONValue.self, from: Data(#"""
        {"check_runs":[{"id":1,"name":"build","conclusion":"success"},
          {"id":2,"name":"revund/security","conclusion":"failure","html_url":"https://github.com/o/r/runs/2",
           "output":{"title":"1 findings · 1 blocker · 0 warning · 0 nitpick","annotations_count":1}},
          {"id":3,"name":"revund/style","conclusion":null,"output":{"title":null,"annotations_count":0}}]}
        """#.utf8))
        let found = Revund.checks(runs)
        #expect(found.map(\.0.pass) == ["security", "style"])
        #expect(found[0].annotations == 1)
        #expect(found[1].0.isRunning)
    }

    @Test func signedInAccountIsReadWithoutTheToken() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".revund"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try Data(#"{"access_token":"revund_x","expires_at":"2027-01-01T00:00:00Z","email":"a@b.dev","org_slug":"acme"}"#.utf8)
            .write(to: home.appendingPathComponent(".revund/credentials"))
        let account = try #require(RevundAccount.read(home: home.path))
        #expect(account.email == "a@b.dev")
        #expect(account.org == "acme")
        #expect(account.expiresAt != nil)
        #expect(RevundAccount.read(home: "/nonexistent") == nil)
    }
}
