import Foundation

/// How long a working chat may go without output before it reads as quiet,
/// and then as stalled. Set in Settings → Notifications.
public struct StallThresholds: Sendable, Hashable, Codable {
    public var quietMinutes: Int
    public var stalledMinutes: Int

    public init(quietMinutes: Int = 5, stalledMinutes: Int = 15) {
        self.quietMinutes = min(max(quietMinutes, 1), 120)
        self.stalledMinutes = min(max(stalledMinutes, self.quietMinutes + 1), 240)
    }

    public static let `default` = StallThresholds()

    public var quiet: TimeInterval { TimeInterval(quietMinutes) * 60 }
    public var stalled: TimeInterval { TimeInterval(stalledMinutes) * 60 }
}

/// How a chat mid-turn stands, by how long its agent has been silent.
/// `since` is when output last arrived (the turn's start until it does),
/// with any paused time already taken out.
public enum StallState: Sendable, Hashable {
    case working
    case quiet(since: Date)
    case stalled(since: Date)

    public var isStalled: Bool { if case .stalled = self { true } else { false } }

    /// Whole minutes without output, for "No output for 5 min".
    public func quietMinutes(at now: Date) -> Int? {
        switch self {
        case .working: nil
        case .quiet(let since), .stalled(let since): max(0, Int(now.timeIntervalSince(since) / 60))
        }
    }
}

/// Watches one chat's output for silence. The clock pauses while the chat
/// waits on a permission or a question, or on a task running in the
/// background: neither is the agent stuck. Nothing here acts on its own;
/// the app asks, and a stall asks for one notification, once.
public struct StallWatch: Sendable, Hashable {
    /// When output last arrived in the turn under way; its start until it
    /// does. nil between turns.
    public private(set) var lastOutputAt: Date?
    private var pausedSince: Date?
    private var notified = false

    public init() {}

    public mutating func beginTurn(at: Date) {
        lastOutputAt = at
        pausedSince = nil
        notified = false
    }

    public mutating func endTurn() {
        lastOutputAt = nil
        pausedSince = nil
        notified = false
    }

    /// Output arrived: the clock restarts, and a later stall may notify again.
    public mutating func noteOutput(at: Date) {
        if let lastOutputAt, at <= lastOutputAt, pausedSince == nil { return }
        lastOutputAt = max(at, lastOutputAt ?? at)
        if pausedSince != nil { pausedSince = at }
        notified = false
    }

    /// "Keep waiting": the stall is cleared and the clock restarts, so a
    /// chat silent for another whole threshold is flagged again.
    public mutating func keepWaiting(at: Date) {
        lastOutputAt = at
        if pausedSince != nil { pausedSince = at }
        notified = false
    }

    public mutating func setPaused(_ paused: Bool, at: Date) {
        if paused {
            if pausedSince == nil { pausedSince = at }
        } else if let since = pausedSince {
            pausedSince = nil
            // The paused stretch doesn't count as silence.
            if let last = lastOutputAt { lastOutputAt = last.addingTimeInterval(at.timeIntervalSince(since)) }
        }
    }

    public func state(at now: Date, thresholds: StallThresholds) -> StallState {
        guard let lastOutputAt else { return .working }
        // While paused the clock stands still where it stopped.
        let silence = (pausedSince ?? now).timeIntervalSince(lastOutputAt)
        if silence >= thresholds.stalled { return .stalled(since: lastOutputAt) }
        if silence >= thresholds.quiet { return .quiet(since: lastOutputAt) }
        return .working
    }

    /// True once per stall: the moment to post its one notification.
    public mutating func consumeStallNotification(at now: Date, thresholds: StallThresholds) -> Bool {
        guard !notified, state(at: now, thresholds: thresholds).isStalled else { return false }
        notified = true
        return true
    }
}

extension Timeline {
    /// When the chat's newest logged event arrived: its last output line,
    /// as far as the log's times say. Stall detection reads it, so it
    /// survives a relaunch.
    public var lastOutputAt: Date? {
        entries.last { $0.at != nil }?.at
    }

    /// Your newest message in the chat: what "Stop and retry" sends again.
    public var lastUserMessage: String? {
        for entry in entries.reversed() {
            if case let .text(.user, text, _, _) = entry.event { return text }
        }
        return nil
    }
}
