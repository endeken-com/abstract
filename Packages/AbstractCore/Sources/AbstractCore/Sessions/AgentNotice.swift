import Foundation

/// What an agent says about how its work is going, beside the conversation:
/// a request it is trying again, a usage limit near or reached, a problem it
/// carries on past.
public enum AgentNotice: Sendable, Hashable {
    /// A request failed and the agent is trying it again. The chat shows it
    /// only until output resumes.
    case retrying(attempt: Int, maxAttempts: Int?, httpStatus: Int?)
    /// The plan's usage limit is close.
    case nearLimit(resetsAt: Date?)
    /// The plan's usage limit is reached.
    case limitReached(resetsAt: Date?)
    /// A problem the agent reported and carries on past.
    case warning(String)

    /// The notice as one sentence. `agent` names who is retrying; reset
    /// times are read in `calendar`'s time zone.
    public func message(agent: String, now: Date = Date(), calendar: Calendar = .autoupdatingCurrent,
                        locale: Locale = .autoupdatingCurrent) -> String {
        switch self {
        case let .retrying(attempt, maxAttempts, httpStatus):
            let count = maxAttempts.map { "attempt \(attempt) of \($0)" } ?? "attempt \(attempt)"
            return "\(agent) is retrying (\(count)\(httpStatus.map { ", HTTP \($0)" } ?? ""))"
        case let .nearLimit(resetsAt):
            guard let resetsAt else { return "You're close to your usage limit." }
            let when = Self.resetTime(resetsAt, now: now, calendar: calendar, locale: locale)
            return "You're close to your usage limit; it resets \(when.sameDay ? "at " : "")\(when.text)"
        case let .limitReached(resetsAt):
            guard let resetsAt else { return "You've hit your usage limit." }
            return "You've hit your usage limit until \(Self.resetTime(resetsAt, now: now, calendar: calendar, locale: locale).text)"
        case let .warning(message):
            return message
        }
    }

    /// "3:40 PM" today, "tomorrow at 3:40 PM", or "Oct 9 at 3:40 PM".
    static func resetTime(_ date: Date, now: Date, calendar: Calendar, locale: Locale) -> (text: String, sameDay: Bool) {
        let time = date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale,
                                                   calendar: calendar, timeZone: calendar.timeZone))
        if calendar.isDate(date, inSameDayAs: now) { return (time, true) }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return ("tomorrow at \(time)", false)
        }
        let day = date.formatted(Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).month(.abbreviated).day())
        return ("\(day) at \(time)", false)
    }
}
