import Foundation

/// How one run turned out, in one word a person can act on: the run's own
/// status, and its chat's status once there is a chat.
public enum RunOutcome: String, Sendable, Hashable, CaseIterable {
    case starting
    case needsYou
    case working
    case done
    case failed
    case skipped
    case ready
    case chatDeleted

    /// `sessionStatus` is the status of the run's chat, or nil when the
    /// chat is gone (or the run never made one).
    public init(run: AutomationRun, sessionStatus: SessionStatus?) {
        switch run.status {
        case .creating: self = .starting
        case .failed: self = .failed
        case .skipped: self = .skipped
        case .created:
            switch sessionStatus {
            case .waitingInput: self = .needsYou
            case .running, .provisioning: self = .working
            case .idle, .finished: self = .done
            case .errored: self = .failed
            case .created: self = .ready
            case nil: self = .chatDeleted
            }
        }
    }

    public var word: String {
        switch self {
        case .starting: "Starting…"
        case .needsYou: "Needs you"
        case .working: "Working"
        case .done: "Done"
        case .failed: "Failed"
        case .skipped: "Skipped"
        case .ready: "Ready"
        case .chatDeleted: "Chat deleted"
        }
    }

    /// The two outcomes a person should look at first.
    public var needsAttention: Bool { self == .needsYou || self == .failed }

    /// Still under way, so an age next to the word says nothing yet.
    var isInProgress: Bool { self == .starting || self == .working || self == .needsYou }
}

/// An automation read back in words: its schedule, when it next runs, and
/// how the last run went. The list row and the page header both render
/// this, so the words agree.
public struct AutomationSummary: Sendable, Hashable {
    /// "Every weekday at 09:00", "When a chat is archived", or "Runs only
    /// when started by hand".
    public var schedule: String
    /// "Next tomorrow, 09:00", "Paused", "Runs by hand only", "Runs on
    /// events", "No more runs" or "Due now".
    public var next: String
    /// The latest run's outcome; nil when it has never run.
    public var outcome: RunOutcome?
    /// "Done · 2h ago", "Needs you", or "No runs yet": the list's right side.
    public var lastRun: String
    /// The page header's one breath: schedule, next run, last run.
    public var header: String

    public init(automation: Automation, latestRun: AutomationRun?, sessionStatus: SessionStatus?,
                now: Date = Date(), timeZone: TimeZone = .current) {
        schedule = Self.schedule(automation, localTimeZone: timeZone)
        next = Self.next(automation, now: now, timeZone: timeZone)
        outcome = latestRun.map { RunOutcome(run: $0, sessionStatus: sessionStatus) }
        if let latestRun, let outcome {
            let age = Self.age(of: latestRun.firedAt, now: now)
            lastRun = outcome.isInProgress ? outcome.word : "\(outcome.word) · \(age)"
            header = "\(schedule) · \(next) · Last run \(outcome.word), \(age)"
        } else {
            lastRun = "No runs yet"
            header = "\(schedule) · \(next) · No runs yet"
        }
    }

    /// "2 need you · 1 failed" over a set of latest outcomes; nil when
    /// nothing is waiting on anyone.
    public static func attentionLine(outcomes: [RunOutcome]) -> String? {
        let needs = outcomes.count(where: { $0 == .needsYou })
        let failed = outcomes.count(where: { $0 == .failed })
        var parts: [String] = []
        if needs > 0 { parts.append(needs == 1 ? "1 needs you" : "\(needs) need you") }
        if failed > 0 { parts.append("\(failed) failed") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The first trigger in words, with its city when it isn't the given
    /// zone, and how many more there are.
    static func schedule(_ a: Automation, localTimeZone: TimeZone) -> String {
        let events = AutomationEvents.summary(a.events)
        guard let first = a.triggers.first else { return events ?? "Runs only when started by hand" }
        var text = Schedule.describe(rrule: first.rrule)
        // Zones are compared after normalising ("UTC" reads back as "GMT").
        if (TimeZone(identifier: first.timezone)?.identifier ?? first.timezone) != localTimeZone.identifier {
            text += " · \(city(first.timezone))"
        }
        if a.triggers.count > 1 { text += " · +\(a.triggers.count - 1) more" }
        if !a.events.isEmpty { text += " · and on \(a.events.count == 1 ? "an event" : "events")" }
        return text
    }

    static func next(_ a: Automation, now: Date, timeZone: TimeZone) -> String {
        guard a.enabled else { return "Paused" }
        guard !a.triggers.isEmpty else { return a.events.isEmpty ? "Runs by hand only" : "Runs on events" }
        guard let next = a.nextRunAt else { return "No more runs" }
        return next <= now ? "Due now" : "Next \(moment(next, now: now, timeZone: timeZone))"
    }

    /// "New York" for "America/New_York".
    static func city(_ identifier: String) -> String {
        (identifier.split(separator: "/").last.map(String.init) ?? identifier).replacingOccurrences(of: "_", with: " ")
    }

    /// "2h ago", or "just now".
    static func age(of date: Date, now: Date) -> String {
        let short = RelativeAge.short(date, now: now)
        return short == "now" ? "just now" : "\(short) ago"
    }

    /// "today, 21:00", "tomorrow, 09:00" or "Thu, Sep 24, 09:00", read
    /// against `now` in the given zone.
    static func moment(_ date: Date, now: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now),
                                           to: calendar.startOfDay(for: date)).day ?? 0
        let lead: String = switch days {
        case 0: "today"
        case 1: "tomorrow"
        case -1: "yesterday"
        default: date.formatted(dateStyle(in: timeZone))
        }
        let time = date.formatted(Date.VerbatimFormatStyle(
            format: "\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)",
            timeZone: timeZone, calendar: Calendar(identifier: .gregorian)))
        return "\(lead), \(time)"
    }

    private static func dateStyle(in timeZone: TimeZone) -> Date.FormatStyle {
        var style = Date.FormatStyle.dateTime.weekday(.abbreviated).month(.abbreviated).day()
        style.timeZone = timeZone
        style.locale = Locale(identifier: "en_US_POSIX")
        return style
    }
}
