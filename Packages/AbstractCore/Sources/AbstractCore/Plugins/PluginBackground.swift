import Foundation

// A plugin's background script (ABS-93): the events it can hear, the jobs
// it can schedule, and the watchdog that stops it when it misbehaves. The
// host runs the script; every rule lives here, so it's testable.

/// An event a background script can subscribe to, and the read grant it
/// needs. Nothing is delivered for a type the plugin can't already read.
public enum PluginEventType: String, Sendable, Hashable, CaseIterable {
    case chatStatusChanged = "chat.statusChanged"
    case turnFinished = "turn.finished"
    case permissionRequested = "permission.requested"
    /// A request stopped waiting: answered anywhere, or its turn ended.
    case permissionResolved = "permission.resolved"
    case pullRequestUpdated = "pullRequest.updated"
    case automationRunFinished = "automation.runFinished"

    public var capability: PluginCapability {
        switch self {
        case .chatStatusChanged, .permissionRequested, .permissionResolved, .pullRequestUpdated: .chatsRead
        case .turnFinished: .turnsRead
        case .automationRunFinished: .automationsRead
        }
    }
}

/// One thing that happened, before it's cut down to what a plugin may see.
public enum PluginEvent: Sendable, Equatable {
    /// `status` is `needsYou`, `working`, `readyToReview`, `done` or
    /// `failed`; `previous` is nil for a chat that just appeared.
    case chatStatusChanged(chatId: String, status: String, previous: String?)
    /// `outcome` is `done`, `stopped` or `failed`, as in `getTurns`.
    case turnFinished(chatId: String, outcome: String, endedAt: Date)
    /// `kind` is `permission`, `question` or `plan`.
    case permissionRequested(chatId: String, requestId: String, kind: String, toolName: String, questions: [String])
    /// The request isn't waiting any more, however it ended (ABS-111).
    case permissionResolved(chatId: String, requestId: String)
    /// `changes` names what moved: `opened`, `state`, `checks`, `review`,
    /// `comments`.
    case pullRequestUpdated(chatId: String, pullRequest: PluginSnapshot.PullRequest, changes: [String])
    /// `outcome` is `done`, `stopped` or `failed`; `chatId` is the run's chat.
    case automationRunFinished(automationId: String, outcome: String, at: Date, chatId: String?)

    public var type: PluginEventType {
        switch self {
        case .chatStatusChanged: .chatStatusChanged
        case .turnFinished: .turnFinished
        case .permissionRequested: .permissionRequested
        case .permissionResolved: .permissionResolved
        case .pullRequestUpdated: .pullRequestUpdated
        case .automationRunFinished: .automationRunFinished
        }
    }

    /// The status an event reports for a snapshot row: its progress, or
    /// `failed` when its agent hit an error.
    public static func status(of chat: PluginSnapshot.Chat) -> String {
        chat.status == SessionStatus.errored.rawValue ? "failed" : chat.progress.rawValue
    }

    /// The event as this plugin may receive it, or nil when its grants
    /// don't cover it. Only fields its read grants already allow are
    /// included: a permission request's id and what it asks are there
    /// only for a plugin that may answer it.
    public func payload(capabilities: Set<PluginCapability>) -> JSONValue? {
        guard capabilities.contains(type.capability) else { return nil }
        var object: [String: JSONValue] = ["type": .string(type.rawValue)]
        switch self {
        case let .chatStatusChanged(chatId, status, previous):
            object["chatId"] = .string(chatId)
            object["status"] = .string(status)
            object["previous"] = previous.map(JSONValue.string) ?? .null
        case let .turnFinished(chatId, outcome, endedAt):
            object["chatId"] = .string(chatId)
            object["outcome"] = .string(outcome)
            object["endedAt"] = .string(PluginData.iso(endedAt))
        case let .permissionRequested(chatId, requestId, kind, toolName, questions):
            object["chatId"] = .string(chatId)
            object["kind"] = .string(kind)
            if capabilities.contains(.permissionsAnswer) {
                object["requestId"] = .string(requestId)
                object["toolName"] = .string(toolName)
                object["questions"] = .array(questions.map(JSONValue.string))
            }
        case let .permissionResolved(chatId, requestId):
            object["chatId"] = .string(chatId)
            if capabilities.contains(.permissionsAnswer) { object["requestId"] = .string(requestId) }
        case let .pullRequestUpdated(chatId, pullRequest, changes):
            object["chatId"] = .string(chatId)
            object["changes"] = .array(changes.map(JSONValue.string))
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            if let data = try? encoder.encode(pullRequest), let any = try? JSONSerialization.jsonObject(with: data) {
                object["pullRequest"] = JSONValue(any: any)
            }
        case let .automationRunFinished(automationId, outcome, at, chatId):
            object["automationId"] = .string(automationId)
            object["outcome"] = .string(outcome)
            object["at"] = .string(PluginData.iso(at))
            if let chatId { object["chatId"] = .string(chatId) }
        }
        return .object(object)
    }
}

/// Turns successive snapshots into status and pull-request events. The
/// first snapshot only sets the baseline: starting up isn't news.
public struct PluginEventDetector: Sendable {
    private var last: [String: PluginSnapshot.Chat]?
    private var lastPending: Set<PluginAction.Target>?

    public init() {}

    public mutating func events(from chats: [PluginSnapshot.Chat]) -> [PluginEvent] {
        let current = Dictionary(chats.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        defer { last = current }
        guard let last else { return [] }
        var events: [PluginEvent] = []
        for chat in chats {
            let before = last[chat.id]
            let status = PluginEvent.status(of: chat)
            let previous = before.map(PluginEvent.status(of:))
            if status != previous {
                events.append(.chatStatusChanged(chatId: chat.id, status: status, previous: previous))
            }
            if let pr = chat.pullRequest, let before, pr != before.pullRequest {
                var changes: [String] = []
                if before.pullRequest?.number != pr.number {
                    changes = ["opened"]
                } else if let old = before.pullRequest {
                    if old.state != pr.state || old.isDraft != pr.isDraft { changes.append("state") }
                    if old.checks != pr.checks || old.failedChecks != pr.failedChecks { changes.append("checks") }
                    if old.changesRequested != pr.changesRequested { changes.append("review") }
                    if old.comments != pr.comments { changes.append("comments") }
                }
                events.append(.pullRequestUpdated(chatId: chat.id, pullRequest: pr, changes: changes))
            }
        }
        return events
    }

    /// A `permission.resolved` for each request that was waiting last time
    /// and isn't now, whoever answered it. New requests are announced
    /// where they arrive, so they aren't repeated here.
    public mutating func resolved(pending: Set<PluginAction.Target>) -> [PluginEvent] {
        defer { lastPending = pending }
        guard let lastPending else { return [] }
        return lastPending.subtracting(pending)
            .sorted { ($0.chatId, $0.requestId) < ($1.chatId, $1.requestId) }
            .map { .permissionResolved(chatId: $0.chatId, requestId: $0.requestId) }
    }
}

/// A background script's scheduled jobs. RRULEs are Abstract's own
/// automation rules (`Schedule`). A job never overlaps itself: if it's
/// still running when it's due again, that run is skipped. A run missed
/// while the Mac slept or Abstract was closed is skipped too, not caught up.
public struct PluginJobs: Sendable {
    public static let limit = 16
    /// No two runs of a job closer than this.
    public static let minimumGap: TimeInterval = 60
    /// How late a run may start and still count as on time.
    public static let grace: TimeInterval = 30

    public struct Job: Sendable, Equatable {
        public var id: String
        public var rrule: String
        public var timezone: String
        public var dtstart: Date
        public var next: Date?
        public var running = false
    }

    public private(set) var jobs: [String: Job] = [:]
    /// Runs skipped because the previous one was still going, or missed.
    public private(set) var skipped: [String: Int] = [:]

    public init() {}

    /// Adds a job, or replaces the one with this id.
    public mutating func schedule(id: String, rrule: String, timezone: String, now: Date = Date()) throws {
        guard !id.isEmpty, id.count <= 60 else { throw AbstractError.message("A job needs a short id.") }
        guard jobs[id] != nil || jobs.count < Self.limit else {
            throw AbstractError.message("A plugin can schedule at most \(Self.limit) jobs.")
        }
        try Schedule.validate(rrule: rrule, timezone: timezone)
        let upcoming = try Schedule.preview(rrule: rrule, timezone: timezone, dtstart: now, count: 6, from: now)
        guard let first = upcoming.first else { throw AbstractError.message("That schedule never runs.") }
        for (a, b) in zip(upcoming, upcoming.dropFirst()) where b.timeIntervalSince(a) < Self.minimumGap {
            throw AbstractError.message("A job can run at most once a minute.")
        }
        let running = jobs[id]?.running ?? false
        jobs[id] = Job(id: id, rrule: rrule, timezone: timezone, dtstart: now, next: first, running: running)
    }

    public mutating func cancel(id: String) {
        jobs[id] = nil
    }

    /// The jobs to start now. Each is marked running until `finished`.
    public mutating func due(now: Date = Date()) -> [String] {
        var start: [String] = []
        for id in jobs.keys.sorted() {
            guard var job = jobs[id], let next = job.next, next <= now else { continue }
            if job.running || now.timeIntervalSince(next) > Self.grace {
                skipped[id, default: 0] += 1
            } else {
                job.running = true
                start.append(id)
            }
            job.next = try? Schedule.nextOccurrence(rrule: job.rrule, timezone: job.timezone,
                                                     dtstart: job.dtstart, after: now)
            jobs[id] = job
        }
        return start
    }

    public mutating func finished(id: String) {
        jobs[id]?.running = false
    }

    /// When the next job is due, to sleep until.
    public var nextDue: Date? {
        jobs.values.compactMap(\.next).min()
    }
}

/// Stops a background script that's stuck, busy, too big, or keeps
/// throwing. Fed by the host: heartbeats it sends and hears back, errors
/// the script reports, and samples of its web process's CPU and memory.
public struct PluginWatchdog: Sendable {
    /// A heartbeat unanswered this long means the script is stuck in a loop.
    public static let stuckAfter: TimeInterval = 3
    public static let errorLimit = 5
    public static let errorWindow: TimeInterval = 60
    public static let memoryLimit: UInt64 = 512 * 1024 * 1024
    /// More than this share of one core, averaged over the window, is busy.
    public static let cpuLimit = 0.5
    public static let cpuWindow: TimeInterval = 10

    public enum Verdict: Sendable, Equatable {
        case fine
        case stopped(String)
    }

    private var heartbeatSentAt: Date?
    private var errors: [Date] = []
    private var cpuSamples: [(at: Date, seconds: Double)] = []

    public init() {}

    /// Whether to send a heartbeat now: not while one is still unanswered.
    public mutating func shouldSendHeartbeat(now: Date = Date()) -> Bool {
        guard heartbeatSentAt == nil else { return false }
        heartbeatSentAt = now
        return true
    }

    public mutating func heartbeatAnswered() {
        heartbeatSentAt = nil
    }

    public func check(now: Date = Date()) -> Verdict {
        if let sent = heartbeatSentAt, now.timeIntervalSince(sent) > Self.stuckAfter {
            return .stopped("It stopped responding, so Abstract stopped it.")
        }
        return .fine
    }

    public mutating func scriptThrew(now: Date = Date()) -> Verdict {
        errors.append(now)
        errors.removeAll { now.timeIntervalSince($0) > Self.errorWindow }
        return errors.count >= Self.errorLimit
            ? .stopped("It kept hitting errors, so Abstract stopped it.")
            : .fine
    }

    /// One reading of the script's web process: total CPU seconds used so
    /// far, and its memory footprint.
    public mutating func sample(cpuSeconds: Double, footprint: UInt64, now: Date = Date()) -> Verdict {
        if footprint > Self.memoryLimit {
            return .stopped("It used too much memory, so Abstract stopped it.")
        }
        cpuSamples.append((now, cpuSeconds))
        cpuSamples.removeAll { now.timeIntervalSince($0.at) > Self.cpuWindow }
        guard let first = cpuSamples.first, now.timeIntervalSince(first.at) >= Self.cpuWindow * 0.8 else { return .fine }
        let share = (cpuSeconds - first.seconds) / now.timeIntervalSince(first.at)
        return share > Self.cpuLimit ? .stopped("It kept your Mac busy, so Abstract stopped it.") : .fine
    }
}
