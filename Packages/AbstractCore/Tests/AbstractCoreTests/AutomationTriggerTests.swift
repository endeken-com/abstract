import Foundation
import Testing
@testable import AbstractCore

@Suite struct AutomationTriggerTests {
    static func utc(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0, _ s: Double = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: mi))!.addingTimeInterval(s)
    }

    /// Tuesday, 13:00 UTC (10:00 in São Paulo, 14:00 in Lisbon).
    static let now = utc(2026, 9, 22, 13, 0)
    static let start = utc(2026, 9, 1)

    /// 18:00 in São Paulo = 21:00 UTC, so today at 21:00 UTC.
    static let evenings = AutomationTrigger(id: "t1", rrule: "FREQ=DAILY;BYHOUR=18;BYMINUTE=0;BYSECOND=0",
                                            timezone: "America/Sao_Paulo", dtstart: start)
    /// Mondays 07:30 in Lisbon (UTC+1 in September) = next Monday 06:30 UTC.
    static let mondays = AutomationTrigger(id: "t2", rrule: "FREQ=WEEKLY;BYDAY=MO;BYHOUR=7;BYMINUTE=30;BYSECOND=0",
                                           timezone: "Europe/Lisbon", dtstart: start)
    /// Quarter past every hour = 13:15 UTC.
    static let hourly = AutomationTrigger(id: "t3", rrule: "FREQ=HOURLY;BYMINUTE=15;BYSECOND=0",
                                          timezone: "UTC", dtstart: start)

    static func automation(_ id: String = "a1", triggers: [AutomationTrigger]) -> Automation {
        Automation(id: id, name: "Nightly", prompt: "Run the tests", providerId: "claude", projectId: nil,
                   triggers: triggers, createdAt: start, updatedAt: start)
    }

    // MARK: - Next run

    @Test func nextRunIsTheEarliestOccurrenceAcrossTriggers() {
        #expect(Self.automation(triggers: [Self.evenings]).nextOccurrence(after: Self.now) == Self.utc(2026, 9, 22, 21, 0))
        #expect(Self.automation(triggers: [Self.mondays]).nextOccurrence(after: Self.now) == Self.utc(2026, 9, 28, 6, 30))
        #expect(Self.automation(triggers: [Self.evenings, Self.mondays]).nextOccurrence(after: Self.now)
                == Self.utc(2026, 9, 22, 21, 0))
        #expect(Self.automation(triggers: [Self.mondays, Self.evenings, Self.hourly]).nextOccurrence(after: Self.now)
                == Self.utc(2026, 9, 22, 13, 15))
    }

    @Test func triggersFiringAtTheSameInstantMakeOneRun() {
        var twin = Self.evenings
        twin.id = "twin"
        let a = Self.automation(triggers: [Self.evenings, twin])
        #expect(a.nextOccurrence(after: Self.now) == Self.utc(2026, 9, 22, 21, 0))
        #expect(a.nextOccurrence(after: Self.utc(2026, 9, 22, 21, 0)) == Self.utc(2026, 9, 23, 21, 0))
    }

    @Test func aTriggerThatCannotBeEvaluatedDoesNotStopTheOthers() throws {
        let broken = AutomationTrigger(id: "bad", rrule: "FREQ=DAILY", timezone: "Mars/Olympus", dtstart: Self.start)
        let a = Self.automation(triggers: [broken, Self.evenings])
        #expect(a.nextOccurrence(after: Self.now) == Self.utc(2026, 9, 22, 21, 0))
        #expect(throws: AbstractError.self) { try a.validateTriggers() }
        try Self.automation(triggers: [Self.evenings, Self.mondays]).validateTriggers()
    }

    @Test func noTriggersMeansNoNextRun() throws {
        let a = Self.automation(triggers: [])
        #expect(a.nextOccurrence(after: Self.now) == nil)
        try a.validateTriggers()
    }

    @Test func addingAndRemovingTriggersMovesTheNextRunAndPersists() throws {
        let store = try Store.inMemory()
        var a = Self.automation(triggers: [Self.evenings])
        try store.save(a)
        #expect(a.nextOccurrence(after: Self.now) == Self.utc(2026, 9, 22, 21, 0))

        a.triggers.append(Self.hourly)
        try store.save(a)
        #expect(try store.automation("a1")?.triggers.map(\.id) == ["t1", "t3"])
        #expect(try store.automation("a1")?.nextOccurrence(after: Self.now) == Self.utc(2026, 9, 22, 13, 15))

        a.triggers.removeAll { $0.id == "t1" }
        try store.save(a)
        #expect(try store.automation("a1")?.triggers == [Self.hourly])
        // The old columns follow the first trigger.
        let legacy = try #require(try store.legacySchedule(automationId: "a1"))
        #expect(legacy.rrule == Self.hourly.rrule && legacy.timezone == "UTC" && legacy.dtstart == Self.start)

        a.triggers.removeAll()
        try store.save(a)
        #expect(a.nextOccurrence(after: Self.now) == nil)
        // Empty stays empty: it doesn't fall back to a stale old-column rule.
        #expect(try store.automation("a1")?.triggers == [])
        #expect(try store.legacySchedule(automationId: "a1")?.rrule == "")
    }

    // MARK: - Storage

    @Test func severalTriggersRoundTripInOrder() throws {
        let store = try Store.inMemory()
        // Milliseconds survive, as they do for every other stored date.
        let precise = AutomationTrigger(id: "t4", rrule: "FREQ=MINUTELY;INTERVAL=5", timezone: "Asia/Kolkata",
                                        dtstart: Self.utc(2026, 9, 1, 8, 0, 12.5))
        let a = Self.automation(triggers: [Self.mondays, precise, Self.evenings, Self.hourly])
        try store.save(a)
        #expect(try store.automation("a1") == a)
        #expect(try store.automations() == [a])
        let legacy = try #require(try store.legacySchedule(automationId: "a1"))
        #expect(legacy.rrule == Self.mondays.rrule && legacy.timezone == "Europe/Lisbon")
    }

    @Test func migrationGivesEachExistingAutomationOneTriggerFromItsSchedule() throws {
        let store = try Store.inMemory(migratedTo: "v3-effort", thenRunning: """
            INSERT INTO projects (id, name, root_path, created_at) VALUES ('p1', 'abstract', '/r', '2026-09-01 00:00:00.000');
            INSERT INTO automations (id, name, prompt, provider_id, project_id, rrule, timezone, dtstart, workspace_mode,
                                     permission_policy, catch_up, enabled, next_run_at, created_at, updated_at, model, effort)
            VALUES ('a1', 'Nightly', 'Bump deps', 'claude', 'p1', 'FREQ=DAILY;BYHOUR=9;BYMINUTE=0;BYSECOND=0',
                    'America/Sao_Paulo', '2026-09-01 12:00:00.000', 'new_worktree', 'bypass', 1, 1,
                    '2026-09-23 12:00:00.000', '2026-09-01 12:00:00.000', '2026-09-02 12:00:00.000', 'opus', 'high'),
                   ('a2', 'Triage', 'Label issues', 'codex', NULL, 'FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR;BYHOUR=8;BYMINUTE=30',
                    'Europe/Lisbon', '2026-09-05 07:30:00.250', 'new_worktree', 'auto-edits', 0, 0,
                    NULL, '2026-09-05 00:00:00.000', '2026-09-05 00:00:00.000', NULL, NULL);
            INSERT INTO automation_runs (id, automation_id, fired_at, "trigger", status, session_id)
            VALUES ('r1', 'a1', '2026-09-21 12:00:00.000', 'schedule', 'created', 's1');
            """)

        let nightly = try #require(try store.automation("a1"))
        #expect(nightly.triggers.count == 1)
        let trigger = try #require(nightly.triggers.first)
        #expect(trigger.rrule == "FREQ=DAILY;BYHOUR=9;BYMINUTE=0;BYSECOND=0")
        #expect(trigger.timezone == "America/Sao_Paulo")
        #expect(trigger.dtstart == Self.utc(2026, 9, 1, 12, 0))
        #expect(!trigger.id.isEmpty)
        // Everything else came through untouched.
        #expect(nightly.name == "Nightly" && nightly.prompt == "Bump deps" && nightly.projectId == "p1")
        #expect(nightly.permissionPolicy == .bypass && nightly.catchUp && nightly.enabled)
        #expect(nightly.model == "opus" && nightly.effort == "high")
        #expect(nightly.nextRunAt == Self.utc(2026, 9, 23, 12, 0))
        #expect(nightly.nextOccurrence(after: Self.now) == Self.utc(2026, 9, 23, 12, 0))
        #expect(try store.runs(automationId: "a1", limit: 10).map(\.id) == ["r1"])

        let triage = try #require(try store.automation("a2"))
        #expect(triage.triggers.map(\.rrule) == ["FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR;BYHOUR=8;BYMINUTE=30"])
        #expect(triage.triggers.first?.dtstart == Self.utc(2026, 9, 5, 7, 30, 0.25))
        #expect(!triage.enabled && triage.projectId == nil)

        // The backfill is stored, not re-derived on every read: the id holds.
        #expect(try store.automation("a1")?.triggers == nightly.triggers)
        #expect(nightly.triggers.first?.id != triage.triggers.first?.id)

        // And it saves back the same way.
        var edited = nightly
        edited.triggers.append(Self.hourly)
        try store.save(edited)
        #expect(try store.automation("a1") == edited)
    }

    @Test func aRowWrittenByAnOlderBuildReadsItsOldSchedule() throws {
        // After the migration, a build from before triggers inserts a row
        // without the new column: it defaults to [] and the old rule applies.
        let store = try Store.inMemory(migratedTo: "v4-triggers", thenRunning: """
            INSERT INTO automations (id, name, prompt, provider_id, rrule, timezone, dtstart, created_at, updated_at)
            VALUES ('old', 'Old', 'x', 'claude', 'FREQ=DAILY;BYHOUR=9;BYMINUTE=0', 'UTC', '2026-09-01 00:00:00.000',
                    '2026-09-01 00:00:00.000', '2026-09-01 00:00:00.000');
            """)
        let a = try #require(try store.automation("old"))
        #expect(a.triggers == [AutomationTrigger(id: "old-legacy", rrule: "FREQ=DAILY;BYHOUR=9;BYMINUTE=0",
                                                  timezone: "UTC", dtstart: Self.utc(2026, 9, 1))])
        #expect(try store.automation("old")?.triggers.first?.id == "old-legacy")
    }
}
