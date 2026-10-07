import Foundation
import Testing
@testable import AbstractCore

/// Retries, usage limits and warnings the agents report, as one-line notices
/// in the chat. `claude-limits.jsonl` follows the shapes of claude 2.1.283's
/// `api_retry` and `rate_limit_event` frames; `codex-warnings.jsonl` those of
/// codex-cli 0.156's warning items.
@Suite struct AgentNoticeTests {
    /// 13:00 in New York on 2026-10-07.
    static let resetsAt = Date(timeIntervalSince1970: 1791392400)
    static let newYork: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }()
    static let english = Locale(identifier: "en_US_POSIX")

    static func replay(_ fixture: String, _ parser: OutputParser) throws -> [AgentEvent] {
        let url = try #require(Bundle.module.url(forResource: fixture, withExtension: "jsonl", subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8)
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .flatMap { parser.feed($0, stream: .stdout) }
    }

    static func notices(_ events: [AgentEvent]) -> [AgentNotice] {
        events.compactMap { if case let .notice(notice) = $0 { notice } else { nil } }
    }

    static func notices(_ blocks: [TimelineBlock]) -> [AgentNotice] {
        blocks.compactMap { if case let .notice(_, notice) = $0 { notice } else { nil } }
    }

    // MARK: - Claude

    @Test func claudeFixtureReportsEachRetryAndLimitChange() throws {
        let events = try Self.replay("claude-limits", ClaudeProvider().makeParser())
        // "allowed" says nothing, and the second warning repeats the first.
        #expect(Self.notices(events) == [
            .retrying(attempt: 1, maxAttempts: 10, httpStatus: 529),
            .retrying(attempt: 2, maxAttempts: 10, httpStatus: 529),
            .nearLimit(resetsAt: Self.resetsAt),
            .limitReached(resetsAt: Self.resetsAt),
        ])
        #expect(!events.contains { if case .raw = $0 { true } else { false } })
    }

    @Test func claudeRetryClearsWhenOutputResumes() throws {
        var timeline = Timeline()
        timeline.append(contentsOf: try Self.replay("claude-limits", ClaudeProvider().makeParser()))
        // The reply came after the retries, so neither shows; the limits stay.
        #expect(Self.notices(timeline.blocks) == [.nearLimit(resetsAt: Self.resetsAt), .limitReached(resetsAt: Self.resetsAt)])
    }

    @Test func claudeRetryShowsOnlyTheLatestWhileWaiting() {
        let parser = ClaudeProvider().makeParser()
        var timeline = Timeline()
        for attempt in 1...3 {
            timeline.append(contentsOf: parser.feed(#"{"type":"system","subtype":"api_retry","attempt":\#(attempt),"max_retries":10,"retry_delay_ms":500,"error_status":529,"error":"overloaded"}"#, stream: .stdout))
        }
        // Stray output on stderr isn't the agent carrying on.
        timeline.append(.raw(line: "warn", stream: .stderr))
        #expect(Self.notices(timeline.blocks) == [.retrying(attempt: 3, maxAttempts: 10, httpStatus: 529)])
        timeline.append(contentsOf: parser.feed(#"{"type":"stream_event","event":{"type":"message_start","message":{"id":"m1"}}}"#, stream: .stdout))
        #expect(Self.notices(timeline.blocks).isEmpty)
    }

    @Test func claudeRetryWithoutAnAnswerHasNoStatus() {
        let events = ClaudeProvider().makeParser().feed(
            #"{"type":"system","subtype":"api_retry","attempt":4,"max_retries":10,"retry_delay_ms":8000,"error_status":null,"error":"unknown"}"#, stream: .stdout)
        #expect(events == [.notice(.retrying(attempt: 4, maxAttempts: 10, httpStatus: nil))])
    }

    @Test func claudeLimitWarnsAgainAfterItEases() {
        let parser = ClaudeProvider().makeParser()
        func status(_ s: String) -> [AgentEvent] {
            parser.feed(#"{"type":"rate_limit_event","rate_limit_info":{"status":"\#(s)","resetsAt":1791392400,"rateLimitType":"five_hour"}}"#, stream: .stdout)
        }
        #expect(status("allowed_warning") == [.notice(.nearLimit(resetsAt: Self.resetsAt))])
        #expect(status("allowed_warning").isEmpty)
        #expect(status("allowed").isEmpty)
        #expect(status("allowed_warning") == [.notice(.nearLimit(resetsAt: Self.resetsAt))])
        #expect(status("something_new").isEmpty)
    }

    @Test func claudeStillDropsFramesItDoesNotKnow() {
        let parser = ClaudeProvider().makeParser()
        #expect(parser.feed(#"{"type":"system","subtype":"some_future_frame","attempt":1}"#, stream: .stdout).isEmpty)
        #expect(parser.feed(#"{"type":"rate_limit_event"}"#, stream: .stdout).isEmpty)
        #expect(parser.feed(#"{"type":"system","subtype":"api_retry"}"#, stream: .stdout).isEmpty)
    }

    // MARK: - Codex

    @Test func codexWarningsKeepTheChatRunning() throws {
        let events = try Self.replay("codex-warnings", CodexProvider().makeParser())
        #expect(Self.notices(events) == [
            .warning("`model_reasoning_summary` is deprecated; use `model_reasoning_summary_format` instead."),
            .warning("Reconnecting... 1/5 (stream disconnected before completion)"),
        ])
        #expect(!events.contains { if case .error = $0 { true } else { false } })
        let statuses = events.compactMap { if case let .status(s, _) = $0 { s } else { nil } }
        #expect(statuses == [.running, .finished])

        var timeline = Timeline()
        timeline.append(contentsOf: events)
        #expect(Self.notices(timeline.blocks).count == 2)
    }

    @Test func codexErrorTheTurnFailsOverIsShownOnce() {
        let parser = CodexProvider().makeParser()
        var timeline = Timeline()
        timeline.append(contentsOf: parser.feed(#"{"type":"error","message":"You've hit your usage limit."}"#, stream: .stdout))
        #expect(Self.notices(timeline.blocks) == [.warning("You've hit your usage limit.")])
        let failed = parser.feed(#"{"type":"turn.failed","error":{"message":"You've hit your usage limit."}}"#, stream: .stdout)
        #expect(failed == [.error("You've hit your usage limit."), .status(.errored, detail: nil)])
        timeline.append(contentsOf: failed)
        #expect(Self.notices(timeline.blocks).isEmpty)
        #expect(timeline.blocks.contains { if case .error(_, "You've hit your usage limit.") = $0 { true } else { false } })
    }

    @Test func codexEmptyWarningsSayNothing() {
        let parser = CodexProvider().makeParser()
        #expect(parser.feed(#"{"type":"item.completed","item":{"id":"item_0","type":"error","message":""}}"#, stream: .stdout).isEmpty)
        #expect(parser.feed(#"{"type":"error"}"#, stream: .stdout).isEmpty)
    }

    // MARK: - Wording

    @Test func retryNamesTheAgentAttemptAndStatus() {
        #expect(AgentNotice.retrying(attempt: 2, maxAttempts: 10, httpStatus: 529).message(agent: "Claude")
            == "Claude is retrying (attempt 2 of 10, HTTP 529)")
        #expect(AgentNotice.retrying(attempt: 3, maxAttempts: nil, httpStatus: nil).message(agent: "Claude")
            == "Claude is retrying (attempt 3)")
    }

    @Test func limitsSayWhenTheyResetInLocalTime() {
        let morning = Date(timeIntervalSince1970: 1791392400 - 4 * 3600)
        let time = Self.resetsAt.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: Self.english,
                                                            calendar: Self.newYork, timeZone: Self.newYork.timeZone))
        #expect(time.hasPrefix("1:00"))
        func say(_ notice: AgentNotice, at now: Date) -> String {
            notice.message(agent: "Claude", now: now, calendar: Self.newYork, locale: Self.english)
        }
        #expect(say(.nearLimit(resetsAt: Self.resetsAt), at: morning) == "You're close to your usage limit; it resets at \(time)")
        #expect(say(.limitReached(resetsAt: Self.resetsAt), at: morning) == "You've hit your usage limit until \(time)")

        let dayBefore = morning.addingTimeInterval(-86400)
        #expect(say(.limitReached(resetsAt: Self.resetsAt), at: dayBefore) == "You've hit your usage limit until tomorrow at \(time)")
        let weekBefore = morning.addingTimeInterval(-5 * 86400)
        #expect(say(.nearLimit(resetsAt: Self.resetsAt), at: weekBefore) == "You're close to your usage limit; it resets Oct 7 at \(time)")

        #expect(say(.nearLimit(resetsAt: nil), at: morning) == "You're close to your usage limit.")
        #expect(say(.limitReached(resetsAt: nil), at: morning) == "You've hit your usage limit.")
        #expect(say(.warning("Reconnecting... 1/5"), at: morning) == "Reconnecting... 1/5")
    }
}
