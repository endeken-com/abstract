import Foundation

/// A turn as the line after it tells it: how it ended, how long it took and
/// what it used. Abstract times every turn itself, from the log, the same way
/// for every agent; what an agent reports is only a fallback.
public struct TurnRecap: Sendable, Hashable {
    public enum Outcome: Sendable, Hashable { case done, stopped, failed }

    public var outcome: Outcome
    /// What the agent said it did.
    public var summary: String?
    /// Your message, or what the agent did first when it carried on by itself.
    public var start: Date?
    /// The agent's turn-end, or the chat going idle, stopped or failed.
    public var end: Date?
    /// How long the agent said the turn took (Claude's `duration_ms`).
    public var reportedMs: Int?
    public var usage: UsageTotals?
    public var costUsd: Double?

    public init(outcome: Outcome = .done, summary: String? = nil, start: Date? = nil, end: Date? = nil,
                reportedMs: Int? = nil, usage: UsageTotals? = nil, costUsd: Double? = nil) {
        self.outcome = outcome; self.summary = summary; self.start = start; self.end = end
        self.reportedMs = reportedMs; self.usage = usage; self.costUsd = costUsd
    }

    /// Measured from the log when both ends are known; else what the agent reported.
    public var durationMs: Int? {
        if let start, let end, end >= start { return Int((end.timeIntervalSince(start) * 1000).rounded()) }
        return reportedMs
    }

    /// The line's words, durations written by `format`: "2m 14s", "Done in
    /// 2m 14s" after a summary, "Stopped after 1m 12s", "Failed after 40s",
    /// and "—" when nothing is known.
    public func label(_ format: (Int) -> String) -> String {
        let duration = durationMs.map(format)
        switch outcome {
        case .stopped: return duration.map { "Stopped after \($0)" } ?? "Stopped"
        case .failed: return duration.map { "Failed after \($0)" } ?? "Failed"
        case .done:
            switch (summary, duration) {
            case let (summary?, duration?): return "\(summary) · Done in \(duration)"
            case let (summary?, nil): return summary
            case let (nil, duration?): return duration
            case (nil, nil): return "—"
            }
        }
    }
}

/// How long a chat's agent worked: its turns added up, without the time
/// between them, while it waited for you.
public struct ChatTime: Sendable, Hashable {
    public var workingMs: Int
    public var turns: Int
    /// The chat's first logged line; nil for a log from before lines had times.
    public var started: Date?

    public init(workingMs: Int = 0, turns: Int = 0, started: Date? = nil) {
        self.workingMs = workingMs; self.turns = turns; self.started = started
    }

    /// The turns in `blocks`, those whose length isn't known counted but not timed.
    public init(blocks: [TimelineBlock], started: Date?) {
        var ms = 0, turns = 0
        for case let .turn(_, recap) in blocks {
            turns += 1
            ms += recap.durationMs ?? 0
        }
        self.init(workingMs: ms, turns: turns, started: started)
    }
}
