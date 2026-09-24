import Foundation
import Testing
import AbstractCore

@Suite struct RecurrenceTests {
    static func utc(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0, _ s: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: mi, second: s))!
    }

    static func iso(_ text: String) throws -> Date { try Date(text, strategy: .iso8601) }

    static func next(_ rrule: String, _ tz: String = "UTC", start: Date, after: Date) throws -> Date? {
        try Schedule.nextOccurrence(rrule: rrule, timezone: tz, dtstart: start, after: after)
    }

    // MARK: - Ported from the Rust scheduler

    @Test func dailyFiresAtTheConfiguredLocalHour() throws {
        let next = try Schedule.nextOccurrence(
            rrule: "FREQ=DAILY;BYHOUR=9;BYMINUTE=0;BYSECOND=0", timezone: "America/Sao_Paulo",
            dtstart: Self.iso("2026-01-01T09:00:00-03:00"), after: Self.utc(2026, 3, 10, 13, 0))
        // 09:00 in Sao Paulo (UTC-3) is 12:00 UTC, so the next fire is the following day.
        #expect(next == Self.utc(2026, 3, 11, 12, 0))
    }

    @Test func dstChangeKeepsTheLocalWallClockTime() throws {
        // New York moves to DST on 2026-03-08. 09:00 local is 14:00 UTC before
        // the change and 13:00 UTC after it.
        let before = try Schedule.nextOccurrence(
            rrule: "FREQ=DAILY;BYHOUR=9;BYMINUTE=0;BYSECOND=0", timezone: "America/New_York",
            dtstart: Self.iso("2026-01-01T09:00:00-05:00"), after: Self.utc(2026, 3, 6, 15, 0))
        #expect(before == Self.utc(2026, 3, 7, 14, 0))

        let after = try Schedule.nextOccurrence(
            rrule: "FREQ=DAILY;BYHOUR=9;BYMINUTE=0;BYSECOND=0", timezone: "America/New_York",
            dtstart: Self.iso("2026-01-01T09:00:00-05:00"), after: Self.utc(2026, 3, 9, 15, 0))
        #expect(after == Self.utc(2026, 3, 10, 13, 0))
    }

    @Test func weekdaysPresetSkipsTheWeekend() throws {
        let body = try #require(Schedule.rule(for: .weekdays, hour: 9, minute: 0))
        // 2026-09-25 is a Friday; the next weekday fire is Monday the 28th.
        let next = try Schedule.nextOccurrence(
            rrule: body, timezone: "UTC", dtstart: Self.iso("2026-01-01T09:00:00+00:00"),
            after: Self.utc(2026, 9, 25, 10, 0))
        #expect(next == Self.utc(2026, 9, 28, 9, 0))
    }

    @Test func previewReturnsDistinctIncreasingTimes() throws {
        let times = try Schedule.preview(
            rrule: "FREQ=MINUTELY;INTERVAL=2", timezone: "UTC", dtstart: Self.iso("2026-01-01T00:00:00+00:00"), count: 3)
        #expect(times.count == 3)
        #expect(times[0] < times[1] && times[1] < times[2])
        #expect(times[1].timeIntervalSince(times[0]) == 120)
        #expect(times[2].timeIntervalSince(times[1]) == 120)
    }

    @Test func invalidInputIsAnErrorNotAPanic() throws {
        #expect(throws: AbstractError.self) {
            try Schedule.nextOccurrence(rrule: "FREQ=NONSENSE", timezone: "UTC",
                                        dtstart: Self.iso("2026-01-01T00:00:00+00:00"), after: Date())
        }
        #expect(throws: AbstractError.self) {
            try Schedule.nextOccurrence(rrule: "FREQ=DAILY", timezone: "Mars/Olympus",
                                        dtstart: Self.iso("2026-01-01T00:00:00+00:00"), after: Date())
        }
        // dtstart is a typed Date here, so the Rust "not-a-date" case becomes a bad UNTIL.
        #expect(throws: AbstractError.self) {
            try Schedule.nextOccurrence(rrule: "FREQ=DAILY;UNTIL=not-a-date", timezone: "UTC",
                                        dtstart: Self.iso("2026-01-01T00:00:00+00:00"), after: Date())
        }
    }

    // MARK: - Semantics

    @Test func nextOccurrenceIsStrictlyAfterTheGivenInstant() throws {
        let rule = "FREQ=DAILY;BYHOUR=9;BYMINUTE=0;BYSECOND=0"
        let start = Self.utc(2026, 1, 1, 9)
        #expect(try Self.next(rule, start: start, after: Self.utc(2026, 3, 10, 9)) == Self.utc(2026, 3, 11, 9))
        #expect(try Self.next(rule, start: start, after: Self.utc(2026, 3, 10, 8, 59, 59)) == Self.utc(2026, 3, 10, 9))
        #expect(try Self.next(rule, start: start, after: Self.utc(2026, 3, 10, 9).addingTimeInterval(-0.001))
                == Self.utc(2026, 3, 10, 9))
        // A preview that starts on an occurrence never repeats it.
        let preview = try Schedule.preview(rrule: rule, timezone: "UTC", dtstart: start, count: 2,
                                           from: Self.utc(2026, 3, 10, 9))
        #expect(preview == [Self.utc(2026, 3, 11, 9), Self.utc(2026, 3, 12, 9)])
    }

    @Test func dtstartIsTheLowerBound() throws {
        let rule = "FREQ=DAILY;BYHOUR=9;BYMINUTE=0;BYSECOND=0"
        // Created at 10:00, so today's 09:00 has already gone.
        #expect(try Self.next(rule, start: Self.utc(2026, 5, 1, 10), after: Self.utc(2026, 4, 1))
                == Self.utc(2026, 5, 2, 9))
    }

    @Test func hourlyByMinute() throws {
        let rule = "FREQ=HOURLY;BYMINUTE=15;BYSECOND=0"
        let start = Self.utc(2026, 1, 1)
        #expect(try Self.next(rule, start: start, after: Self.utc(2026, 3, 10, 10, 20)) == Self.utc(2026, 3, 10, 11, 15))
        #expect(try Self.next(rule, start: start, after: Self.utc(2026, 3, 10, 10, 10)) == Self.utc(2026, 3, 10, 10, 15))
        #expect(try Self.next(rule, start: start, after: Self.utc(2026, 3, 10, 23, 30)) == Self.utc(2026, 3, 11, 0, 15))
        // BYMINUTE is local: :15 in Kolkata (UTC+05:30) is :45 UTC.
        #expect(try Self.next(rule, "Asia/Kolkata", start: start, after: Self.utc(2026, 3, 10, 10, 0))
                == Self.utc(2026, 3, 10, 10, 45))
    }

    @Test func hourlyIntervalAndByHourFilter() throws {
        let start = Self.utc(2026, 1, 1, 0, 30)
        // Every 3 hours from 00:30: 00:30, 03:30, 06:30, ...
        #expect(try Self.next("FREQ=HOURLY;INTERVAL=3", start: start, after: Self.utc(2026, 6, 1, 4))
                == Self.utc(2026, 6, 1, 6, 30))
        // Hourly on weekdays between 09:00 and 17:59 only. 2026-09-25 is a Friday.
        let workHours = "FREQ=HOURLY;BYDAY=MO,TU,WE,TH,FR;BYHOUR=9,10,11,12,13,14,15,16,17;BYMINUTE=0;BYSECOND=0"
        #expect(try Self.next(workHours, start: start, after: Self.utc(2026, 9, 25, 17, 1)) == Self.utc(2026, 9, 28, 9))
    }

    @Test func weeklyWithSeveralDays() throws {
        let rule = "FREQ=WEEKLY;BYDAY=MO,WE,FR;BYHOUR=9;BYMINUTE=0;BYSECOND=0"
        let start = Self.utc(2026, 1, 1)
        // 2026-09-22 is a Tuesday.
        let times = try Schedule.preview(rrule: rule, timezone: "UTC", dtstart: start, count: 4,
                                         from: Self.utc(2026, 9, 22, 10))
        #expect(times == [Self.utc(2026, 9, 23, 9), Self.utc(2026, 9, 25, 9), Self.utc(2026, 9, 28, 9),
                          Self.utc(2026, 9, 30, 9)])
    }

    @Test func weeklyIntervalCountsWeeksFromDtstart() throws {
        // Every other Monday starting Monday 2026-09-07.
        let rule = "FREQ=WEEKLY;INTERVAL=2;BYDAY=MO;BYHOUR=9;BYMINUTE=0;BYSECOND=0"
        let start = Self.utc(2026, 9, 7, 8)
        let times = try Schedule.preview(rrule: rule, timezone: "UTC", dtstart: start, count: 3,
                                         from: Self.utc(2026, 9, 10))
        #expect(times == [Self.utc(2026, 9, 21, 9), Self.utc(2026, 10, 5, 9), Self.utc(2026, 10, 19, 9)])
    }

    @Test func weeklyWithoutByDayUsesTheDtstartWeekday() throws {
        // 2026-09-22 is a Tuesday.
        let start = Self.utc(2026, 9, 22, 7, 30)
        #expect(try Self.next("FREQ=WEEKLY", start: start, after: Self.utc(2026, 9, 24))
                == Self.utc(2026, 9, 29, 7, 30))
    }

    @Test func monthlyByMonthDay31SkipsShortMonths() throws {
        let rule = "FREQ=MONTHLY;BYMONTHDAY=31;BYHOUR=9;BYMINUTE=0;BYSECOND=0"
        let times = try Schedule.preview(rrule: rule, timezone: "UTC", dtstart: Self.utc(2026, 1, 1), count: 4,
                                         from: Self.utc(2026, 1, 1))
        #expect(times == [Self.utc(2026, 1, 31, 9), Self.utc(2026, 3, 31, 9), Self.utc(2026, 5, 31, 9),
                          Self.utc(2026, 7, 31, 9)])
    }

    @Test func monthlyLastDayAndWeekdays() throws {
        let lastDay = try Schedule.preview(
            rrule: "FREQ=MONTHLY;BYMONTHDAY=-1;BYHOUR=18;BYMINUTE=0;BYSECOND=0", timezone: "UTC",
            dtstart: Self.utc(2026, 1, 1), count: 3, from: Self.utc(2026, 1, 1))
        #expect(lastDay == [Self.utc(2026, 1, 31, 18), Self.utc(2026, 2, 28, 18), Self.utc(2026, 3, 31, 18)])

        // Every Monday of the month; 2026-09-28 is the last Monday of September.
        let mondays = try Schedule.preview(
            rrule: "FREQ=MONTHLY;BYDAY=MO;BYHOUR=9;BYMINUTE=0;BYSECOND=0", timezone: "UTC",
            dtstart: Self.utc(2026, 1, 1), count: 2, from: Self.utc(2026, 9, 22))
        #expect(mondays == [Self.utc(2026, 9, 28, 9), Self.utc(2026, 10, 5, 9)])
    }

    @Test func countStopsTheSeries() throws {
        let rule = "FREQ=DAILY;COUNT=3"
        let start = Self.utc(2026, 1, 1, 9)
        let all = try Schedule.preview(rrule: rule, timezone: "UTC", dtstart: start, count: 10, from: Self.utc(2025, 12, 1))
        #expect(all == [Self.utc(2026, 1, 1, 9), Self.utc(2026, 1, 2, 9), Self.utc(2026, 1, 3, 9)])
        // Counted from dtstart, not from `after`.
        #expect(try Self.next(rule, start: start, after: Self.utc(2026, 1, 1, 9)) == Self.utc(2026, 1, 2, 9))
        #expect(try Self.next(rule, start: start, after: Self.utc(2026, 1, 3, 9)) == nil)
        #expect(try Self.next(rule, start: start, after: Self.utc(2027, 1, 1)) == nil)
    }

    @Test func untilIsInclusiveAndStopsTheSeries() throws {
        let rule = "FREQ=DAILY;BYHOUR=9;BYMINUTE=0;BYSECOND=0;UNTIL=20260105T090000Z"
        let start = Self.utc(2026, 1, 1)
        let all = try Schedule.preview(rrule: rule, timezone: "UTC", dtstart: start, count: 10, from: start)
        #expect(all.count == 5)
        #expect(all.last == Self.utc(2026, 1, 5, 9))
        #expect(try Self.next(rule, start: start, after: Self.utc(2026, 1, 5, 9)) == nil)

        // A date-only UNTIL covers that whole local day.
        let dateOnly = "FREQ=DAILY;BYHOUR=21;BYMINUTE=0;BYSECOND=0;UNTIL=20260105"
        let ny = try Schedule.preview(rrule: dateOnly, timezone: "America/New_York", dtstart: start, count: 10, from: start)
        #expect(ny.last == Self.utc(2026, 1, 6, 2)) // 21:00 EST on the 5th
    }

    @Test func intervalOnDailyIsAlignedToDtstart() throws {
        let rule = "FREQ=DAILY;INTERVAL=3;BYHOUR=9;BYMINUTE=0;BYSECOND=0"
        let start = Self.utc(2026, 1, 1, 9)
        #expect(try Self.next(rule, start: start, after: Self.utc(2026, 1, 2)) == Self.utc(2026, 1, 4, 9))
        #expect(try Self.next(rule, start: start, after: Self.utc(2026, 1, 4, 9)) == Self.utc(2026, 1, 7, 9))
        // Far from dtstart: Mar 1 is day 59, so the next multiple of 3 is day 60, Mar 2.
        #expect(try Self.next(rule, start: start, after: Self.utc(2026, 3, 1)) == Self.utc(2026, 3, 2, 9))
    }

    @Test func minutelyIntervalIsAlignedToDtstart() throws {
        // Every 15 minutes from 00:05: :05, :20, :35, :50.
        let start = Self.utc(2026, 1, 1, 0, 5)
        #expect(try Self.next("FREQ=MINUTELY;INTERVAL=15", start: start, after: Self.utc(2026, 9, 22, 10))
                == Self.utc(2026, 9, 22, 10, 5))
        #expect(try Self.next("FREQ=MINUTELY;INTERVAL=15", start: start, after: Self.utc(2026, 9, 22, 10, 5))
                == Self.utc(2026, 9, 22, 10, 20))
        // Sub-second dtstart is truncated to its whole second.
        let fractional = Self.utc(2026, 1, 1, 0, 0, 30).addingTimeInterval(0.75)
        #expect(try Self.next("FREQ=MINUTELY", start: fractional, after: Self.utc(2026, 2, 1))
                == Self.utc(2026, 2, 1, 0, 0, 30))
    }

    @Test func springForwardGapMovesForward() throws {
        // 02:30 does not exist in New York on 2026-03-08; it becomes 03:30 EDT.
        let rule = "FREQ=DAILY;BYHOUR=2;BYMINUTE=30;BYSECOND=0"
        let start = Self.utc(2026, 1, 1)
        let times = try Schedule.preview(rrule: rule, timezone: "America/New_York", dtstart: start, count: 3,
                                         from: Self.utc(2026, 3, 7, 12))
        #expect(times == [Self.utc(2026, 3, 8, 7, 30), Self.utc(2026, 3, 9, 6, 30), Self.utc(2026, 3, 10, 6, 30)])
    }

    @Test func fallBackRepeatedTimeFiresOnce() throws {
        // 01:30 happens twice in New York on 2026-11-01; only the first (EDT) fires.
        let rule = "FREQ=DAILY;BYHOUR=1;BYMINUTE=30;BYSECOND=0"
        let times = try Schedule.preview(rrule: rule, timezone: "America/New_York", dtstart: Self.utc(2026, 1, 1),
                                         count: 2, from: Self.utc(2026, 10, 31, 12))
        #expect(times == [Self.utc(2026, 11, 1, 5, 30), Self.utc(2026, 11, 2, 6, 30)])
    }

    @Test func weeklyPresetKeepsLocalTimeAcrossDst() throws {
        let rule = try #require(Schedule.rule(for: .weekly, hour: 7, minute: 30, weekday: 2))
        let times = try Schedule.preview(rrule: rule, timezone: "Europe/Berlin", dtstart: Self.utc(2026, 1, 1),
                                         count: 2, from: Self.utc(2026, 3, 24))
        // Berlin switches to CEST on 2026-03-29.
        #expect(times == [Self.utc(2026, 3, 30, 5, 30), Self.utc(2026, 4, 6, 5, 30)])
        let winter = try Schedule.nextOccurrence(rrule: rule, timezone: "Europe/Berlin", dtstart: Self.utc(2026, 1, 1),
                                                 after: Self.utc(2026, 3, 17))
        #expect(winter == Self.utc(2026, 3, 23, 6, 30))
    }

    @Test func aRuleThatCanNeverMatchReturnsNil() throws {
        // Every 7 days from a Monday never lands on a Tuesday.
        #expect(try Self.next("FREQ=DAILY;INTERVAL=7;BYDAY=TU", start: Self.utc(2026, 9, 21, 9),
                              after: Self.utc(2026, 9, 22)) == nil)
        // Every 12 months from February never has a 30th.
        #expect(try Self.next("FREQ=MONTHLY;INTERVAL=12;BYMONTHDAY=30", start: Self.utc(2026, 2, 1),
                              after: Self.utc(2026, 2, 1)) == nil)
        // Every other hour from an even hour never hits an odd one (UTC has no DST).
        #expect(try Self.next("FREQ=HOURLY;INTERVAL=2;BYHOUR=1", start: Self.utc(2026, 1, 1),
                              after: Self.utc(2026, 1, 1)) == nil)
    }

    @Test func previewHonoursCount() throws {
        #expect(try Schedule.preview(rrule: "FREQ=HOURLY", timezone: "UTC", dtstart: Self.utc(2026, 1, 1), count: 0).isEmpty)
        #expect(try Schedule.preview(rrule: "FREQ=HOURLY", timezone: "UTC", dtstart: Self.utc(2026, 1, 1), count: 25,
                                     from: Self.utc(2026, 1, 1)).count == 25)
    }

    // MARK: - Validation

    @Test func validateAcceptsWellFormedRules() throws {
        try Schedule.validate(rrule: "FREQ=DAILY;BYHOUR=9;BYMINUTE=0", timezone: "America/Sao_Paulo")
        try Schedule.validate(rrule: "RRULE:FREQ=WEEKLY;BYDAY=MO,FR;WKST=SU", timezone: "UTC")
        try Schedule.validate(rrule: " rrule:freq=monthly;bymonthday=1,-1;count=12 ", timezone: "Europe/Lisbon")
        try Schedule.validate(rrule: "FREQ=MINUTELY;INTERVAL=5;UNTIL=20261231T235959Z", timezone: "UTC")
        for preset in SchedulePreset.allCases {
            if let rule = Schedule.rule(for: preset, hour: 9, minute: 0) {
                try Schedule.validate(rrule: rule, timezone: "UTC")
            }
        }
    }

    @Test func validateRejectsBadRulesWithADescriptiveError() {
        #expect(throws: AbstractError.message("Unsupported rule part BYSETPOS")) {
            try Schedule.validate(rrule: "FREQ=MONTHLY;BYDAY=MO;BYSETPOS=1", timezone: "UTC")
        }
        #expect(throws: AbstractError.message("Unsupported frequency YEARLY")) {
            try Schedule.validate(rrule: "FREQ=YEARLY", timezone: "UTC")
        }
        #expect(throws: AbstractError.message("Unknown timezone \"Mars/Olympus\"")) {
            try Schedule.validate(rrule: "FREQ=DAILY", timezone: "Mars/Olympus")
        }
        let invalid = [
            "", "garbage", "BYHOUR=9", "FREQ=DAILY;FREQ=HOURLY", "FREQ=DAILY;BYHOUR=24", "FREQ=DAILY;BYMINUTE=60",
            "FREQ=DAILY;BYSECOND=-1", "FREQ=DAILY;INTERVAL=0", "FREQ=DAILY;INTERVAL=two", "FREQ=DAILY;COUNT=0",
            "FREQ=DAILY;BYDAY=XX", "FREQ=MONTHLY;BYDAY=1MO", "FREQ=MONTHLY;BYMONTHDAY=0", "FREQ=MONTHLY;BYMONTHDAY=32",
            "FREQ=WEEKLY;BYMONTHDAY=1", "FREQ=DAILY;COUNT=2;UNTIL=20260101", "FREQ=DAILY;UNTIL=20260231",
            "FREQ=DAILY;UNTIL=20260101Z", "FREQ=DAILY;BYHOUR=", "FREQ=DAILY;BYHOUR=9,,10", "FREQ=DAILY;BYMONTH=1",
            "FREQ=DAILY;WKST=XX",
        ]
        for rule in invalid {
            #expect(throws: AbstractError.self, "\(rule)") { try Schedule.validate(rrule: rule, timezone: "UTC") }
        }
        #expect(throws: AbstractError.self) { try Schedule.validate(rrule: "FREQ=DAILY", timezone: "") }
    }

    // MARK: - Presets and wording

    @Test func presetRules() {
        #expect(Schedule.rule(for: .hourly, hour: 9, minute: 15) == "FREQ=HOURLY;BYMINUTE=15;BYSECOND=0")
        #expect(Schedule.rule(for: .daily, hour: 9, minute: 0) == "FREQ=DAILY;BYHOUR=9;BYMINUTE=0;BYSECOND=0")
        #expect(Schedule.rule(for: .weekdays, hour: 9, minute: 0)
                == "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR;BYHOUR=9;BYMINUTE=0;BYSECOND=0")
        #expect(Schedule.rule(for: .weekly, hour: 7, minute: 30)
                == "FREQ=WEEKLY;BYDAY=MO;BYHOUR=7;BYMINUTE=30;BYSECOND=0")
        #expect(Schedule.rule(for: .weekly, hour: 7, minute: 30, weekday: 1)
                == "FREQ=WEEKLY;BYDAY=SU;BYHOUR=7;BYMINUTE=30;BYSECOND=0")
        #expect(Schedule.rule(for: .custom, hour: 9, minute: 0) == nil)
        #expect(Schedule.rule(for: .daily, hour: 24, minute: 0) == nil)
        #expect(Schedule.rule(for: .weekly, hour: 9, minute: 0, weekday: 8) == nil)
    }

    @Test func presetOfRoundTripsEveryPreset() throws {
        let hourly = Schedule.preset(of: try #require(Schedule.rule(for: .hourly, hour: 9, minute: 45)))
        #expect(hourly.preset == .hourly)
        #expect(hourly.minute == 45)

        let daily = Schedule.preset(of: try #require(Schedule.rule(for: .daily, hour: 18, minute: 5)))
        #expect(daily.preset == .daily && daily.hour == 18 && daily.minute == 5)

        let weekdays = Schedule.preset(of: try #require(Schedule.rule(for: .weekdays, hour: 8, minute: 30)))
        #expect(weekdays.preset == .weekdays && weekdays.hour == 8 && weekdays.minute == 30)

        for weekday in 1...7 {
            let weekly = Schedule.preset(of: try #require(Schedule.rule(for: .weekly, hour: 7, minute: 15, weekday: weekday)))
            #expect(weekly.preset == .weekly && weekly.hour == 7 && weekly.minute == 15 && weekly.weekday == weekday)
        }

        #expect(Schedule.preset(of: "FREQ=MINUTELY;INTERVAL=2").preset == .custom)
        let custom = Schedule.preset(of: "FREQ=DAILY;INTERVAL=2;BYHOUR=6;BYMINUTE=10")
        #expect(custom.preset == .custom && custom.hour == 6 && custom.minute == 10 && custom.weekday == 2)
        #expect(Schedule.preset(of: "FREQ=WEEKLY;BYDAY=MO,WE;BYHOUR=9;BYMINUTE=0").preset == .custom)
        #expect(Schedule.preset(of: "not a rule").preset == .custom)
    }

    @Test func describePresets() throws {
        #expect(Schedule.describe(rrule: try #require(Schedule.rule(for: .hourly, hour: 0, minute: 15))) == "Every hour at :15")
        #expect(Schedule.describe(rrule: try #require(Schedule.rule(for: .daily, hour: 9, minute: 0))) == "Every day at 09:00")
        #expect(Schedule.describe(rrule: try #require(Schedule.rule(for: .weekdays, hour: 9, minute: 0)))
                == "Every weekday at 09:00")
        #expect(Schedule.describe(rrule: try #require(Schedule.rule(for: .weekly, hour: 7, minute: 30, weekday: 2)))
                == "Mondays at 07:30")
    }

    @Test func describeCustomRules() {
        #expect(Schedule.describe(rrule: "FREQ=MINUTELY;INTERVAL=2") == "Every 2 minutes")
        #expect(Schedule.describe(rrule: "FREQ=MINUTELY") == "Every minute")
        #expect(Schedule.describe(rrule: "FREQ=HOURLY;INTERVAL=4") == "Every 4 hours")
        #expect(Schedule.describe(rrule: "FREQ=MINUTELY;INTERVAL=15;BYDAY=MO,TU,WE,TH,FR;BYHOUR=9,10,11,12,13,14,15,16,17")
                == "Every 15 minutes on weekdays between 09:00 and 17:59")
        #expect(Schedule.describe(rrule: "FREQ=DAILY;BYHOUR=9,17;BYMINUTE=0") == "Every day at 09:00 and 17:00")
        #expect(Schedule.describe(rrule: "FREQ=DAILY;INTERVAL=3;BYHOUR=6;BYMINUTE=0") == "Every 3 days at 06:00")
        #expect(Schedule.describe(rrule: "FREQ=WEEKLY;BYDAY=SA,SU;BYHOUR=10;BYMINUTE=0") == "Weekends at 10:00")
        #expect(Schedule.describe(rrule: "FREQ=WEEKLY;BYDAY=FR,MO,WE;BYHOUR=9;BYMINUTE=0")
                == "Mondays, Wednesdays and Fridays at 09:00")
        #expect(Schedule.describe(rrule: "FREQ=WEEKLY;INTERVAL=2;BYDAY=MO;BYHOUR=9;BYMINUTE=0")
                == "Every 2 weeks on Mondays at 09:00")
        #expect(Schedule.describe(rrule: "FREQ=MONTHLY;BYMONTHDAY=1,15;BYHOUR=9;BYMINUTE=0")
                == "Every month on the 1st and 15th at 09:00")
        #expect(Schedule.describe(rrule: "FREQ=MONTHLY;BYMONTHDAY=-1;BYHOUR=18;BYMINUTE=0")
                == "Every month on the last day at 18:00")
        #expect(Schedule.describe(rrule: "FREQ=DAILY;BYHOUR=9;BYMINUTE=0;COUNT=3") == "Every day at 09:00, 3 times")
        #expect(Schedule.describe(rrule: "FREQ=DAILY;BYHOUR=9;BYMINUTE=0;UNTIL=20261231T000000Z")
                == "Every day at 09:00, until 2026-12-31")
        #expect(Schedule.describe(rrule: "FREQ=NONSENSE") == "Invalid schedule")
    }
}
