import Foundation

public enum SchedulePreset: String, CaseIterable, Sendable { case hourly, daily, weekdays, weekly, custom }

/// Recurrence math for automations: a self-contained RFC 5545 RRULE subset.
///
/// Supported: FREQ = MINUTELY | HOURLY | DAILY | WEEKLY | MONTHLY, INTERVAL,
/// BYDAY (plain weekdays), BYMONTHDAY, BYHOUR, BYMINUTE, BYSECOND, COUNT,
/// UNTIL and WKST. Rules are evaluated in their IANA timezone:
/// - DAILY and coarser rules keep their wall-clock time across DST changes.
///   A local time that falls in a spring-forward gap moves forward by the
///   length of the gap (RFC 5545), a repeated local time uses its first instant.
/// - MINUTELY and HOURLY rules step in elapsed time (every 2 hours is always
///   7200 seconds apart); BYxxx filters are checked against local time.
/// Parts left out default to DTSTART's (truncated to whole seconds), and
/// occurrences before DTSTART are never produced. DTSTART itself is only an
/// occurrence when it matches the rule.
public enum Schedule {
    /// First occurrence strictly after `after`.
    public static func nextOccurrence(rrule: String, timezone: String, dtstart: Date, after: Date) throws -> Date? {
        var occurrences = try OccurrenceIterator(
            rule: RecurrenceRule(parsing: rrule), calendar: calendar(for: timezone), dtstart: dtstart, after: after)
        return occurrences.next()
    }

    /// The next `count` occurrences strictly after `from`, in order.
    public static func preview(rrule: String, timezone: String, dtstart: Date, count: Int, from: Date = Date()) throws -> [Date] {
        var occurrences = try OccurrenceIterator(
            rule: RecurrenceRule(parsing: rrule), calendar: calendar(for: timezone), dtstart: dtstart, after: from)
        var dates: [Date] = []
        while dates.count < count, let next = occurrences.next() { dates.append(next) }
        return dates
    }

    public static func validate(rrule: String, timezone: String) throws {
        let rule = try RecurrenceRule(parsing: rrule)
        let calendar = try calendar(for: timezone)
        if let until = rule.until, until.resolve(in: calendar) == nil {
            throw AbstractError.message("UNTIL does not exist in \(timezone)")
        }
    }

    /// weekday: 1 = Sunday … 7 = Saturday (Calendar convention), used by .weekly.
    public static func rule(for preset: SchedulePreset, hour: Int, minute: Int, weekday: Int = 2) -> String? {
        guard (0...59).contains(minute) else { return nil }
        if preset == .hourly { return "FREQ=HOURLY;BYMINUTE=\(minute);BYSECOND=0" }
        guard (0...23).contains(hour) else { return nil }
        let time = "BYHOUR=\(hour);BYMINUTE=\(minute);BYSECOND=0"
        switch preset {
        case .hourly, .custom:
            return nil
        case .daily:
            return "FREQ=DAILY;\(time)"
        case .weekdays:
            return "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR;\(time)"
        case .weekly:
            guard (1...7).contains(weekday) else { return nil }
            return "FREQ=WEEKLY;BYDAY=\(RuleWeekday.codes[weekday - 1]);\(time)"
        }
    }

    /// Best-effort reverse mapping, `.custom` when the rule is not a preset.
    /// For `.custom` the hour, minute and weekday are still filled in when the
    /// rule names exactly one of each, so a form can start from them.
    public static func preset(of rrule: String) -> (preset: SchedulePreset, hour: Int, minute: Int, weekday: Int) {
        let (defaultHour, defaultMinute, defaultWeekday) = (9, 0, 2)
        guard let rule = try? RecurrenceRule(parsing: rrule) else {
            return (.custom, defaultHour, defaultMinute, defaultWeekday)
        }
        let hour = rule.byHour.flatMap { $0.count == 1 ? $0[0] : nil }
        let minute = rule.byMinute.flatMap { $0.count == 1 ? $0[0] : nil }
        let weekday = rule.byDay.flatMap { $0.count == 1 ? $0[0] : nil }
        let custom = (SchedulePreset.custom, hour ?? defaultHour, minute ?? defaultMinute, weekday ?? defaultWeekday)

        let simple = rule.interval == 1 && rule.count == nil && rule.until == nil && rule.byMonthDay == nil
            && (rule.bySecond == nil || rule.bySecond == [0])
        guard simple, let minute else { return custom }
        switch rule.frequency {
        case .hourly where rule.byHour == nil && rule.byDay == nil:
            return (.hourly, defaultHour, minute, defaultWeekday)
        case .daily where rule.byDay == nil:
            guard let hour else { return custom }
            return (.daily, hour, minute, defaultWeekday)
        case .weekly:
            guard let hour, let days = rule.byDay else { return custom }
            if days == RuleWeekday.weekdays { return (.weekdays, hour, minute, defaultWeekday) }
            if let weekday { return (.weekly, hour, minute, weekday) }
            return custom
        default:
            return custom
        }
    }

    /// Plain-language summary, e.g. "Every weekday at 09:00", "Every 2 minutes", "Mondays at 07:30".
    public static func describe(rrule: String) -> String {
        guard let rule = try? RecurrenceRule(parsing: rrule) else { return "Invalid schedule" }
        let n = rule.interval
        var text: String
        switch rule.frequency {
        case .minutely:
            text = n == 1 ? "Every minute" : "Every \(n) minutes"
            if let minutes = rule.byMinute { text += " at " + RulePhrase.list(minutes.map { String(format: ":%02d", $0) }) }
            text += RulePhrase.filters(days: rule.byDay, monthDays: rule.byMonthDay, hours: rule.byHour)
        case .hourly:
            text = n == 1 ? "Every hour" : "Every \(n) hours"
            if let minutes = rule.byMinute { text += " at " + RulePhrase.list(minutes.map { String(format: ":%02d", $0) }) }
            text += RulePhrase.filters(days: rule.byDay, monthDays: rule.byMonthDay, hours: rule.byHour)
        case .daily:
            if n == 1, let days = rule.byDay {
                text = RulePhrase.dayGroup(days)
            } else {
                text = n == 1 ? "Every day" : "Every \(n) days"
                if let days = rule.byDay { text += " on " + RulePhrase.pluralDays(days) }
            }
            if let monthDays = rule.byMonthDay { text += " on the " + RulePhrase.monthDays(monthDays) }
            text += RulePhrase.time(rule)
        case .weekly:
            if n == 1, let days = rule.byDay {
                text = RulePhrase.dayGroup(days)
            } else {
                text = n == 1 ? "Every week" : "Every \(n) weeks"
                if let days = rule.byDay { text += " on " + RulePhrase.pluralDays(days) }
            }
            text += RulePhrase.time(rule)
        case .monthly:
            text = n == 1 ? "Every month" : "Every \(n) months"
            if let monthDays = rule.byMonthDay { text += " on the " + RulePhrase.monthDays(monthDays) }
            if let days = rule.byDay {
                text += (rule.byMonthDay == nil ? " on " : " when it falls on ") + RulePhrase.pluralDays(days)
            }
            text += RulePhrase.time(rule)
        }
        if let count = rule.count { text += count == 1 ? ", once" : ", \(count) times" }
        if let until = rule.until {
            text += ", until " + String(format: "%04d-%02d-%02d", until.year, until.month, until.day)
        }
        return text
    }

    private static func calendar(for timezone: String) throws -> Calendar {
        guard !timezone.isEmpty, let zone = TimeZone(identifier: timezone) else {
            throw AbstractError.message("Unknown timezone \"\(timezone)\"")
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }
}

// MARK: - Rule

private struct RecurrenceRule: Sendable, Equatable {
    enum Frequency: String, Sendable { case minutely = "MINUTELY", hourly = "HOURLY", daily = "DAILY", weekly = "WEEKLY", monthly = "MONTHLY" }

    struct Until: Sendable, Equatable {
        enum Kind: Sendable { case utc, floating, date }
        var kind: Kind
        var year: Int, month: Int, day: Int
        var hour = 0, minute = 0, second = 0

        /// The last instant an occurrence may have. A date-only UNTIL includes
        /// its whole local day.
        func resolve(in calendar: Calendar) -> Date? {
            switch kind {
            case .utc:
                var utc = Calendar(identifier: .gregorian)
                utc.timeZone = TimeZone(identifier: "UTC")!
                return utc.date(from: DateComponents(
                    year: year, month: month, day: day, hour: hour, minute: minute, second: second))
            case .floating:
                return calendar.date(from: DateComponents(
                    year: year, month: month, day: day, hour: hour, minute: minute, second: second))
            case .date:
                let next = GregorianDays.date(ofDay: GregorianDays.day(year: year, month: month, day: day) + 1)
                return calendar.date(from: DateComponents(year: next.year, month: next.month, day: next.day))?
                    .addingTimeInterval(-1)
            }
        }
    }

    var frequency: Frequency
    var interval = 1
    /// Calendar weekdays (1 = Sunday … 7 = Saturday), sorted, unique.
    var byDay: [Int]?
    /// 1…31 or -31…-1 (counted from the end of the month).
    var byMonthDay: [Int]?
    var byHour: [Int]?
    var byMinute: [Int]?
    var bySecond: [Int]?
    var count: Int?
    var until: Until?
    /// WKST as a Calendar weekday; Monday unless the rule says otherwise.
    var weekStart = 2

    init(parsing text: String) throws {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.uppercased().hasPrefix("RRULE:") { body = String(body.dropFirst("RRULE:".count)) }
        let parts = body.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !parts.isEmpty else { throw Self.error("The schedule is empty") }

        var frequency: Frequency?
        var seen = Set<String>()
        for part in parts {
            let pieces = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pieces.count == 2 else { throw Self.error("Malformed rule part \(part)") }
            let key = pieces[0].trimmingCharacters(in: .whitespaces).uppercased()
            let value = pieces[1].trimmingCharacters(in: .whitespaces).uppercased()
            guard !key.isEmpty else { throw Self.error("Malformed rule part \(part)") }
            guard seen.insert(key).inserted else { throw Self.error("Duplicate rule part \(key)") }
            guard !value.isEmpty else { throw Self.error("Rule part \(key) has no value") }
            switch key {
            case "FREQ":
                guard let parsed = Frequency(rawValue: value) else { throw Self.error("Unsupported frequency \(value)") }
                frequency = parsed
            case "INTERVAL": interval = try Self.number(value, key, in: 1...10_000)
            case "COUNT": count = try Self.number(value, key, in: 1...Int(Int32.max))
            case "UNTIL": until = try Self.until(value)
            case "BYDAY": byDay = try Self.weekdays(value)
            case "WKST":
                guard let day = RuleWeekday.parse(value) else { throw Self.error("Invalid WKST value \(value)") }
                weekStart = day
            case "BYMONTHDAY":
                let days = try Self.list(value, key, in: -31...31)
                if days.contains(0) { throw Self.error("Invalid BYMONTHDAY value 0") }
                byMonthDay = days
            case "BYHOUR": byHour = try Self.list(value, key, in: 0...23)
            case "BYMINUTE": byMinute = try Self.list(value, key, in: 0...59)
            case "BYSECOND": bySecond = try Self.list(value, key, in: 0...59)
            default: throw Self.error("Unsupported rule part \(key)")
            }
        }
        guard let frequency else { throw Self.error("The schedule has no FREQ") }
        self.frequency = frequency
        if count != nil && until != nil { throw Self.error("COUNT and UNTIL cannot both be set") }
        if frequency == .weekly && byMonthDay != nil { throw Self.error("BYMONTHDAY cannot be used with FREQ=WEEKLY") }
    }

    private static func error(_ message: String) -> AbstractError { .message(message) }

    private static func number(_ text: String, _ key: String, in range: ClosedRange<Int>) throws -> Int {
        guard let value = Int(text), range.contains(value) else {
            throw error("Invalid \(key) value \(text) (expected \(range.lowerBound)…\(range.upperBound))")
        }
        return value
    }

    private static func list(_ text: String, _ key: String, in range: ClosedRange<Int>) throws -> [Int] {
        let values = try text.split(separator: ",", omittingEmptySubsequences: false).map {
            try number($0.trimmingCharacters(in: .whitespaces), key, in: range)
        }
        return Array(Set(values)).sorted()
    }

    private static func weekdays(_ text: String) throws -> [Int] {
        let values = try text.split(separator: ",", omittingEmptySubsequences: false).map { raw -> Int in
            let token = raw.trimmingCharacters(in: .whitespaces)
            if let day = RuleWeekday.parse(token) { return day }
            if token.count > 2, RuleWeekday.parse(String(token.suffix(2))) != nil, Int(token.dropLast(2)) != nil {
                throw error("Unsupported BYDAY value \(token): numbered weekdays are not supported")
            }
            throw error("Invalid BYDAY value \(token)")
        }
        return Array(Set(values)).sorted()
    }

    private static func until(_ text: String) throws -> Until {
        let invalid = error("Invalid UNTIL value \(text) (expected YYYYMMDD, YYYYMMDDTHHMMSS or YYYYMMDDTHHMMSSZ)")
        var body = Substring(text)
        let utc = body.hasSuffix("Z")
        if utc { body = body.dropLast() }
        func digits(_ s: Substring) -> Int? { s.allSatisfy(\.isASCII) && s.allSatisfy(\.isNumber) ? Int(s) : nil }

        let datePart: Substring
        var timePart: Substring?
        if let t = body.firstIndex(of: "T") {
            datePart = body[..<t]
            timePart = body[body.index(after: t)...]
        } else {
            datePart = body
        }
        guard datePart.count == 8, let date = digits(datePart) else { throw invalid }
        let (year, month, day) = (date / 10_000, date / 100 % 100, date % 100)
        guard (1...12).contains(month), (1...GregorianDays.daysInMonth(year: year, month: month)).contains(day) else {
            throw invalid
        }
        guard let timePart else {
            if utc { throw invalid }
            return Until(kind: .date, year: year, month: month, day: day)
        }
        guard timePart.count == 6, let time = digits(timePart) else { throw invalid }
        let (hour, minute, second) = (time / 10_000, time / 100 % 100, time % 100)
        guard hour <= 23, minute <= 59, second <= 59 else { throw invalid }
        return Until(kind: utc ? .utc : .floating, year: year, month: month, day: day,
                     hour: hour, minute: minute, second: second)
    }
}

// MARK: - Evaluation

private struct WallTime {
    var day: Int
    var hour: Int
    var minute: Int
    var second: Int
}

/// Occurrences strictly after `after`, in increasing order.
private struct OccurrenceIterator: IteratorProtocol {
    /// Give up after this many consecutive periods without an occurrence: the
    /// rule can (practically) never match again.
    private static let maxIdlePeriods = 50_000
    private static let maxPeriods = 2_000_000
    private static let maxYear = 9999

    private let rule: RecurrenceRule
    private let calendar: Calendar
    private let start: Date
    private let startLocal: WallTime
    private let until: Date?
    private let after: Date
    private let hours: [Int]
    private let minutes: [Int]
    private let seconds: [Int]
    /// MINUTELY/HOURLY: DTSTART truncated to its local minute/hour.
    private let base: Date
    /// WEEKLY: first day of DTSTART's week.
    private let firstWeekDay: Int
    /// MONTHLY: DTSTART's month as `year * 12 + month - 1`.
    private let firstMonth: Int

    private var period = 0
    private var buffer: [Date] = []
    private var index = 0
    private var emitted = 0
    private var last: Date?
    private var idle = 0
    private var scanned = 0
    private var done = false

    init(rule: RecurrenceRule, calendar: Calendar, dtstart: Date, after: Date) throws {
        self.rule = rule
        self.calendar = calendar
        self.after = after
        start = Date(timeIntervalSince1970: dtstart.timeIntervalSince1970.rounded(.down))
        let startLocal = Self.localTime(start, calendar)
        self.startLocal = startLocal
        if let until = rule.until {
            guard let resolved = until.resolve(in: calendar) else {
                throw AbstractError.message("UNTIL does not exist in \(calendar.timeZone.identifier)")
            }
            self.until = resolved
        } else {
            until = nil
        }
        hours = rule.byHour ?? [startLocal.hour]
        minutes = rule.byMinute ?? [startLocal.minute]
        seconds = rule.bySecond ?? [startLocal.second]
        switch rule.frequency {
        case .minutely: base = start.addingTimeInterval(-Double(startLocal.second))
        case .hourly: base = start.addingTimeInterval(-Double(startLocal.minute * 60 + startLocal.second))
        default: base = start
        }
        let startWeekday = GregorianDays.weekday(ofDay: startLocal.day)
        firstWeekDay = startLocal.day - (startWeekday - rule.weekStart + 7) % 7
        let startDate = GregorianDays.date(ofDay: startLocal.day)
        firstMonth = startDate.year * 12 + startDate.month - 1

        // COUNT has to be counted from DTSTART; otherwise jump straight to
        // the period that contains `after`.
        if rule.count == nil && after > start {
            period = GregorianDays.floorDiv(periodIndex(containing: after), rule.interval) * rule.interval
        }
    }

    mutating func next() -> Date? {
        while !done {
            while index < buffer.count {
                let candidate = buffer[index]
                index += 1
                guard candidate >= start else { continue }
                if let last, candidate <= last { continue }
                if let until, candidate > until { done = true; return nil }
                if let count = rule.count, emitted >= count { done = true; return nil }
                emitted += 1
                last = candidate
                idle = 0
                if candidate > after { return candidate }
            }
            idle += 1
            scanned += 1
            guard idle <= Self.maxIdlePeriods, scanned <= Self.maxPeriods,
                  let expansion = expand(period) else {
                done = true
                return nil
            }
            buffer = expansion.dates
            index = 0
            period = expansion.next
        }
        return nil
    }

    // MARK: Periods

    private func periodIndex(containing date: Date) -> Int {
        switch rule.frequency {
        case .minutely: return Int((date.timeIntervalSince(base) / 60).rounded(.down))
        case .hourly: return Int((date.timeIntervalSince(base) / 3600).rounded(.down))
        case .daily: return Self.localTime(date, calendar).day - startLocal.day
        case .weekly: return GregorianDays.floorDiv(Self.localTime(date, calendar).day - firstWeekDay, 7)
        case .monthly:
            let local = GregorianDays.date(ofDay: Self.localTime(date, calendar).day)
            return local.year * 12 + local.month - 1 - firstMonth
        }
    }

    /// The first period at or after `index` that the interval lands on.
    private func alignedPeriod(atOrAfter index: Int) -> Int {
        guard index > 0 else { return 0 }
        return (index + rule.interval - 1) / rule.interval * rule.interval
    }

    /// Candidate instants in period `p`, plus the next period worth looking
    /// at. nil once the period is past the supported horizon.
    private func expand(_ p: Int) -> (dates: [Date], next: Int)? {
        let step = p + rule.interval
        switch rule.frequency {
        case .minutely, .hourly:
            let unit = rule.frequency == .minutely ? 60.0 : 3600.0
            let periodStart = base.addingTimeInterval(Double(p) * unit)
            let local = Self.localTime(periodStart, calendar)
            guard GregorianDays.date(ofDay: local.day).year <= Self.maxYear else { return nil }
            if !dayMatches(local.day) {
                let nextDay = calendar.dateInterval(of: .day, for: periodStart)?.end
                    ?? periodStart.addingTimeInterval(86_400)
                return ([], max(step, alignedPeriod(atOrAfter: periodIndex(containing: nextDay))))
            }
            if let byHour = rule.byHour, !byHour.contains(local.hour) {
                guard rule.frequency == .minutely else { return ([], step) }
                let nextHour = calendar.dateInterval(of: .hour, for: periodStart)?.end
                    ?? periodStart.addingTimeInterval(3600)
                return ([], max(step, alignedPeriod(atOrAfter: periodIndex(containing: nextHour))))
            }
            if rule.frequency == .minutely {
                if let byMinute = rule.byMinute, !byMinute.contains(local.minute) { return ([], step) }
                return (seconds.map { periodStart.addingTimeInterval(Double($0)) }, step)
            }
            let dates = minutes.flatMap { minute in
                seconds.map { periodStart.addingTimeInterval(Double(minute * 60 + $0)) }
            }
            return (dates, step)

        case .daily:
            let day = startLocal.day + p
            guard GregorianDays.date(ofDay: day).year <= Self.maxYear else { return nil }
            return (dayMatches(day) ? instants(on: [day]) : [], step)

        case .weekly:
            let first = firstWeekDay + 7 * p
            guard GregorianDays.date(ofDay: first).year <= Self.maxYear else { return nil }
            let wanted = rule.byDay ?? [GregorianDays.weekday(ofDay: startLocal.day)]
            let days = (first..<first + 7).filter { wanted.contains(GregorianDays.weekday(ofDay: $0)) }
            return (instants(on: days), step)

        case .monthly:
            let month = firstMonth + p
            let year = GregorianDays.floorDiv(month, 12)
            let monthNumber = month - year * 12 + 1
            guard year <= Self.maxYear else { return nil }
            let firstDay = GregorianDays.day(year: year, month: monthNumber, day: 1)
            let length = GregorianDays.daysInMonth(year: year, month: monthNumber)
            var monthDays: [Int]
            if let byMonthDay = rule.byMonthDay {
                monthDays = byMonthDay.map { $0 > 0 ? $0 : length + $0 + 1 }.filter { (1...length).contains($0) }
                if let byDay = rule.byDay {
                    monthDays = monthDays.filter { byDay.contains(GregorianDays.weekday(ofDay: firstDay + $0 - 1)) }
                }
            } else if let byDay = rule.byDay {
                monthDays = (1...length).filter { byDay.contains(GregorianDays.weekday(ofDay: firstDay + $0 - 1)) }
            } else {
                let startDay = GregorianDays.date(ofDay: startLocal.day).day
                monthDays = startDay <= length ? [startDay] : []
            }
            return (instants(on: Set(monthDays).sorted().map { firstDay + $0 - 1 }), step)
        }
    }

    /// BYDAY and BYMONTHDAY as filters (MINUTELY, HOURLY, DAILY).
    private func dayMatches(_ day: Int) -> Bool {
        if let byDay = rule.byDay, !byDay.contains(GregorianDays.weekday(ofDay: day)) { return false }
        if let byMonthDay = rule.byMonthDay {
            let date = GregorianDays.date(ofDay: day)
            let length = GregorianDays.daysInMonth(year: date.year, month: date.month)
            return byMonthDay.contains { $0 > 0 ? $0 == date.day : length + $0 + 1 == date.day }
        }
        return true
    }

    /// Every BYHOUR × BYMINUTE × BYSECOND wall-clock time on each local day.
    private func instants(on days: [Int]) -> [Date] {
        var dates: [Date] = []
        for day in days {
            let date = GregorianDays.date(ofDay: day)
            for hour in hours {
                for minute in minutes {
                    for second in seconds {
                        let components = DateComponents(
                            year: date.year, month: date.month, day: date.day,
                            hour: hour, minute: minute, second: second)
                        if let instant = calendar.date(from: components) { dates.append(instant) }
                    }
                }
            }
        }
        return dates.sorted()
    }

    private static func localTime(_ date: Date, _ calendar: Calendar) -> WallTime {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return WallTime(
            day: GregorianDays.day(year: c.year ?? 1970, month: c.month ?? 1, day: c.day ?? 1),
            hour: c.hour ?? 0, minute: c.minute ?? 0, second: c.second ?? 0)
    }
}

// MARK: - Calendar arithmetic

/// Proleptic Gregorian day numbers (days since 1970-01-01), so period
/// arithmetic is plain integer math. Time zones stay with `Calendar`.
private enum GregorianDays {
    static func floorDiv(_ a: Int, _ b: Int) -> Int {
        a >= 0 ? a / b : -((-a + b - 1) / b)
    }

    static func day(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = floorDiv(y, 400)
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * ((month + 9) % 12) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    static func date(ofDay dayNumber: Int) -> (year: Int, month: Int, day: Int) {
        let z = dayNumber + 719_468
        let era = floorDiv(z, 146_097)
        let dayOfEra = z - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let mp = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        return (yearOfEra + era * 400 + (month <= 2 ? 1 : 0), month, day)
    }

    /// 1 = Sunday … 7 = Saturday. Day 0 (1970-01-01) was a Thursday.
    static func weekday(ofDay dayNumber: Int) -> Int {
        (dayNumber % 7 + 7 + 4) % 7 + 1
    }

    static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 2: (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
        case 4, 6, 9, 11: 30
        default: 31
        }
    }
}

// MARK: - Wording

private enum RuleWeekday {
    /// Indexed by Calendar weekday - 1.
    static let codes = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"]
    static let names = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
    static let weekdays = [2, 3, 4, 5, 6]
    static let weekend = [1, 7]

    static func parse(_ code: String) -> Int? {
        codes.firstIndex(of: code).map { $0 + 1 }
    }
}

private enum RulePhrase {
    static func list(_ items: [String]) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + items.last!
    }

    /// Monday-first, as people read a week.
    static func pluralDays(_ days: [Int]) -> String {
        list(days.sorted { ($0 + 5) % 7 < ($1 + 5) % 7 }.map { RuleWeekday.names[$0 - 1] + "s" })
    }

    /// "Every day", "Every weekday", "Weekends", or "Mondays and Thursdays".
    static func dayGroup(_ days: [Int]) -> String {
        switch days {
        case [1, 2, 3, 4, 5, 6, 7]: "Every day"
        case RuleWeekday.weekdays: "Every weekday"
        case RuleWeekday.weekend: "Weekends"
        default: pluralDays(days)
        }
    }

    static func ordinal(_ n: Int) -> String {
        let suffix = switch (n % 10, n % 100) {
        case (_, 11...13): "th"
        case (1, _): "st"
        case (2, _): "nd"
        case (3, _): "rd"
        default: "th"
        }
        return "\(n)\(suffix)"
    }

    static func monthDays(_ values: [Int]) -> String {
        let positive = values.filter { $0 > 0 }.sorted().map(ordinal)
        let negative = values.filter { $0 < 0 }.sorted(by: >).map { $0 == -1 ? "last day" : "\(ordinal(-$0)) to last day" }
        return list(positive + negative)
    }

    /// Wall-clock times for DAILY and coarser rules.
    static func time(_ rule: RecurrenceRule) -> String {
        switch (rule.byHour, rule.byMinute) {
        case (nil, nil):
            return ""
        case (let hours?, nil):
            return " during hour" + (hours.count == 1 ? " " : "s ") + list(hours.map { String(format: "%02d", $0) })
        case (nil, let minutes?):
            return " at " + list(minutes.map { String(format: ":%02d", $0) })
        case (let hours?, let minutes?):
            let seconds = rule.bySecond ?? [0]
            let showSeconds = seconds != [0]
            var times: [String] = []
            for h in hours {
                for m in minutes {
                    for s in seconds {
                        times.append(showSeconds ? String(format: "%02d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", h, m))
                    }
                }
            }
            return times.count > 6 ? ", \(times.count) times a day" : " at " + list(times)
        }
    }

    /// BYxxx filters on MINUTELY and HOURLY rules.
    static func filters(days: [Int]?, monthDays: [Int]?, hours: [Int]?) -> String {
        var text = ""
        if let days {
            switch days {
            case [1, 2, 3, 4, 5, 6, 7]: break
            case RuleWeekday.weekdays: text += " on weekdays"
            case RuleWeekday.weekend: text += " on weekends"
            default: text += " on " + pluralDays(days)
            }
        }
        if let monthDays { text += " on the " + Self.monthDays(monthDays) }
        if let hours {
            let contiguous = hours.count > 1 && hours.last! - hours.first! == hours.count - 1
            if contiguous {
                text += String(format: " between %02d:00 and %02d:59", hours.first!, hours.last!)
            } else {
                text += " during hour" + (hours.count == 1 ? " " : "s ") + list(hours.map { String(format: "%02d", $0) })
            }
        }
        return text
    }
}
