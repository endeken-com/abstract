import Foundation

/// Why a due run didn't start, as the run history shows it.
public enum AutomationSkipReason: String, Sendable, Codable, CaseIterable {
    case lastRunStillGoing = "last_run_still_going"
    case missedWhileClosed = "missed_while_closed"
    case projectUnchanged = "project_unchanged"

    public var text: String {
        switch self {
        case .lastRunStillGoing: "skipped: last run still going"
        case .missedWhileClosed: "skipped: missed while Abstract was closed"
        case .projectUnchanged: "skipped: project hasn't changed since the last run"
        }
    }
}

/// Due runs that won't start, counted per reason.
public struct AutomationSkip: Sendable, Hashable {
    public var reason: AutomationSkipReason
    public var count: Int

    public init(reason: AutomationSkipReason, count: Int) {
        self.reason = reason
        self.count = count
    }
}

/// What the scheduler does with everything one automation has due.
public struct AutomationScheduleDecision: Sendable, Hashable {
    /// Runs to start now.
    public var fires: Int
    /// Start one run when the run still going finishes.
    public var runAfterCurrentFinishes: Bool
    /// Runs to record in the history as skipped.
    public var skips: [AutomationSkip]

    public init(fires: Int = 0, runAfterCurrentFinishes: Bool = false, skips: [AutomationSkip] = []) {
        self.fires = fires
        self.runAfterCurrentFinishes = runAfterCurrentFinishes
        self.skips = skips
    }
}

/// The rules an automation's "when it runs" sentences make, apart from
/// starting chats: the app's scheduler feeds them what is due, whether
/// the last run is still going, and whether the project's base moved.
public enum AutomationScheduling {
    /// Most due occurrences one look counts. A Mac closed for a month
    /// over a minutely automation records at most this many of them;
    /// the rest are simply gone, as they were before skips were kept.
    public static let missedOccurrenceLimit = 25

    /// Whether the base moved since the last run; nil when there is
    /// nothing to compare (no earlier run, or no commit could be read).
    public static func baseMoved(lastRunCommit: String?, currentCommit: String?) -> Bool? {
        guard let lastRunCommit, let currentCommit else { return nil }
        return lastRunCommit != currentCommit
    }

    public static func decision(
        for automation: Automation, dueCount: Int, missed: Bool,
        lastRunActive: Bool, alreadyWaiting: Bool, baseMoved: Bool?
    ) -> AutomationScheduleDecision {
        guard dueCount > 0 else { return AutomationScheduleDecision() }
        var decision = AutomationScheduleDecision()
        func skip(_ reason: AutomationSkipReason, _ count: Int) {
            if count > 0 { decision.skips.append(AutomationSkip(reason: reason, count: count)) }
        }

        // Missed runs first: they decide how much of what is due is
        // still wanted at all. A run due right now was not missed.
        var candidates = dueCount
        if missed {
            switch automation.missedRuns {
            case .skip: candidates = 0
            case .runOnce: candidates = 1
            case .runEach: candidates = min(dueCount, AutomationMissedRuns.runEachLimit)
            }
            skip(.missedWhileClosed, dueCount - candidates)
        }

        // Then the activity gate: scheduled runs only, and only when the
        // base is known not to have moved.
        if automation.onlyWhenChanged, baseMoved == false {
            skip(.projectUnchanged, candidates)
            candidates = 0
        }

        // Then the run still going.
        if lastRunActive, candidates > 0 {
            switch automation.concurrency {
            case .startAnother:
                break
            case .skipIfActive:
                skip(.lastRunStillGoing, candidates)
                candidates = 0
            case .runAfterActiveFinishes:
                if alreadyWaiting {
                    skip(.lastRunStillGoing, candidates)
                } else {
                    decision.runAfterCurrentFinishes = true
                    skip(.lastRunStillGoing, candidates - 1)
                }
                candidates = 0
            }
        }

        decision.fires = candidates
        return decision
    }
}

extension Automation {
    /// The occurrences due from `due` (itself an occurrence) up to and
    /// including `now`, earliest first, at most `limit` of them.
    public func dueOccurrences(from due: Date, through now: Date,
                               limit: Int = AutomationScheduling.missedOccurrenceLimit) -> [Date] {
        guard due <= now, limit > 0 else { return [] }
        var occurrences = [due]
        while occurrences.count < limit, let next = nextOccurrence(after: occurrences[occurrences.count - 1]), next <= now {
            occurrences.append(next)
        }
        return occurrences
    }
}
