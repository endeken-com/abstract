import Foundation

/// The end of one turn, as its line between turns reads: how it ended, how
/// long it took, and what it used.
public struct TurnInfo: Sendable, Hashable {
    public enum Ending: Sendable, Hashable {
        case done
        /// You pressed Stop.
        case stopped
        /// The agent reported an error, or its process ended unexpectedly.
        case failed
    }

    public var ending: Ending
    /// What the agent says it did, when it says (Claude's turn summary).
    public var summary: String?
    /// Your message, or the agent's first step in a turn it took on its own.
    public var startedAt: Date?
    public var endedAt: Date?
    /// How long the agent says it took, when it says (Claude).
    public var reportedMs: Int?
    public var usage: UsageTotals?
    public var costUsd: Double?
    public var launch: LaunchRecord?

    public init(ending: Ending = .done, summary: String? = nil, startedAt: Date? = nil, endedAt: Date? = nil,
                reportedMs: Int? = nil, usage: UsageTotals? = nil, costUsd: Double? = nil) {
        self.ending = ending; self.summary = summary; self.startedAt = startedAt; self.endedAt = endedAt
        self.reportedMs = reportedMs; self.usage = usage; self.costUsd = costUsd
    }

    /// From its start to its end, as Abstract saw them.
    public var measuredMs: Int? {
        guard let startedAt, let endedAt, endedAt >= startedAt else { return nil }
        return Int((endedAt.timeIntervalSince(startedAt) * 1000).rounded())
    }

    /// Abstract's own measure, the same for every agent; the agent's report
    /// only where the log has no times (before they were kept).
    public var durationMs: Int? { measuredMs ?? reportedMs }
}

/// How long a chat's agent worked: its turns added up, without the time
/// between them spent waiting for you.
public struct ChatTime: Sendable, Hashable {
    public var workingMs: Int
    public var turns: Int

    public init(workingMs: Int = 0, turns: Int = 0) { self.workingMs = workingMs; self.turns = turns }

    public init(_ blocks: [TimelineBlock]) {
        self.init()
        for case let .turn(_, info) in blocks {
            turns += 1
            workingMs += info.durationMs ?? 0
        }
    }
}

/// Follows a chat's turns as its entries are read. A turn runs from your
/// message (or, for one the agent takes on its own, its first step) to its
/// end: the chat going idle, stopped or failed, or your next message.
/// Every turn gets one line, however many steps the agent reports.
struct TurnTracker {
    /// A turn is under way.
    private(set) var active = false
    /// When the turn under way started; nil when that isn't known.
    private(set) var startedAt: Date?
    /// The agent did something in it, beyond your message arriving.
    private var worked = false
    private var lastAt: Date?
    /// What its line says so far, once the agent reported its end or usage.
    private var info: TurnInfo?
    private var lineId: Int?
    private var launch: LaunchRecord?
    private var lastLaunch: LaunchRecord?

    /// Reads one entry. Returns a turn line that ended before this entry's
    /// own block, or with it.
    mutating func read(_ entry: TimelineEntry) -> TimelineBlock? {
        let at = entry.at
        switch entry.event {
        case let .launch(record):
            if launch == nil { launch = record }
            lastLaunch = record
        case let .system(model, _, _, _):
            if let model {
                launch?.model = model
                lastLaunch?.model = model
            }
        case .handoff:
            let ended = close(id: -entry.id, implicitly: true)
            lastLaunch = nil
            return ended
        case .text(.user, _, _, _):
            // Your message logged, then echoed by the agent: still one turn.
            if active, !worked, info == nil { return nil }
            let ended = close(id: -entry.id, implicitly: true)
            begin(at)
            return ended
        case let .text(.assistant, text, _, _), let .thinking(text, _, _):
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { step(at) }
        case .toolUse:
            step(at)
        // Part of a turn under way; between turns (a refused request) not one of its own.
        case .toolResult, .toolImages, .error:
            if active { step(at) }
        case let .turnEnd(duration, cost, usage, summary):
            report(entry, durationMs: duration, usage: usage, costUsd: cost)
            if entry.event == TurnStop.rule { info?.ending = .stopped } else if let summary { info?.summary = summary }
        case let .usage(usage, cost, duration, _):
            report(entry, durationMs: duration, usage: usage, costUsd: cost)
        case let .status(status, _) where status == .idle || status == .finished || status == .errored:
            guard active else { return nil }
            lastAt = at ?? lastAt
            if status == .errored {
                if info == nil { info = TurnInfo() }
                info?.ending = .failed
            }
            return close(id: entry.id, implicitly: false)
        case .notice, .raw, .task, .subagent:
            if active { lastAt = at ?? lastAt }
        default:
            break
        }
        return nil
    }

    /// The line of a turn still under way that already has one (an agent
    /// that reports usage per step), placed after everything so far.
    var pendingLine: TimelineBlock? {
        guard active, let info, let lineId else { return nil }
        return .turn(id: lineId, finished(info))
    }

    private mutating func begin(_ at: Date?) {
        active = true
        startedAt = at
        lastAt = at
        worked = false
        info = nil
        lineId = nil
        launch = nil
    }

    private mutating func step(_ at: Date?) {
        if !active { begin(at) }
        worked = true
        lastAt = at ?? lastAt
    }

    private mutating func report(_ entry: TimelineEntry, durationMs: Int?, usage: UsageTotals?, costUsd: Double?) {
        // An end with nothing before it: the turn's start isn't known.
        if !active { begin(nil) }
        lastAt = entry.at ?? lastAt
        var i = info ?? TurnInfo()
        i.reportedMs = durationMs ?? i.reportedMs
        if let usage { i.usage = (i.usage ?? .zero) + usage }
        if let costUsd { i.costUsd = (i.costUsd ?? 0) + costUsd }
        info = i
        lineId = lineId ?? entry.id
    }

    /// Ends the turn under way. One that ended without a word from the agent
    /// (its process stopped or crashed before a relaunch) still gets a line
    /// when its length is known.
    private mutating func close(id: Int, implicitly: Bool) -> TimelineBlock? {
        guard active else { return nil }
        defer { active = false; info = nil; lineId = nil; worked = false; launch = nil }
        if let info { return .turn(id: lineId ?? id, finished(info)) }
        guard worked else { return nil }
        let line = finished(TurnInfo())
        if implicitly, line.measuredMs == nil { return nil }
        return .turn(id: id, line)
    }

    private func finished(_ info: TurnInfo) -> TurnInfo {
        var info = info
        info.startedAt = startedAt
        info.endedAt = lastAt
        info.launch = launch ?? lastLaunch
        return info
    }
}
