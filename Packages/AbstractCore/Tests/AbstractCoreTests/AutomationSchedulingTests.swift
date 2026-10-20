import Foundation
import Testing
@testable import AbstractCore

@Suite struct AutomationSchedulingTests {
    static let start = Date(timeIntervalSince1970: 1_788_000_000)

    static func automation(mode: WorkspaceMode = .newWorktree,
                           concurrency: AutomationConcurrency? = nil,
                           missedRuns: AutomationMissedRuns? = nil,
                           onlyWhenChanged: Bool = false) -> Automation {
        Automation(id: "a1", name: "Nightly", prompt: "Run the tests", providerId: "claude", projectId: "p1",
                   triggers: [AutomationTrigger(id: "t1", rrule: "FREQ=MINUTELY;BYSECOND=0", timezone: "UTC", dtstart: start)],
                   workspaceMode: mode, createdAt: start, updatedAt: start,
                   concurrency: concurrency, missedRuns: missedRuns, onlyWhenChanged: onlyWhenChanged)
    }

    static func decide(_ a: Automation, dueCount: Int = 1, missed: Bool = false,
                       active: Bool = false, waiting: Bool = false,
                       baseMoved: Bool? = nil) -> AutomationScheduleDecision {
        AutomationScheduling.decision(for: a, dueCount: dueCount, missed: missed,
                                      lastRunActive: active, alreadyWaiting: waiting, baseMoved: baseMoved)
    }

    // MARK: - Defaults

    @Test func defaultsFollowWhereRunsHappen() {
        #expect(Self.automation(mode: .pinned).concurrency == .skipIfActive)
        #expect(Self.automation(mode: .newWorktree).concurrency == .startAnother)
        #expect(Self.automation().missedRuns == .skip && !Self.automation().onlyWhenChanged)
        #expect(Self.automation().missedRuns == .skip && !Self.automation().catchUp)
    }

    @Test func theOldCatchUpSwitchMapsToRunningOnce() throws {
        let on = Automation(id: "a1", name: "Nightly", prompt: "x", providerId: "claude", projectId: nil,
                            triggers: [], catchUp: true, createdAt: Self.start, updatedAt: Self.start)
        #expect(on.missedRuns == .runOnce && on.catchUp)
        var off = on
        off.catchUp = false
        #expect(off.missedRuns == .skip)

        // An older Mac's JSON: no new keys, only the switch.
        let data = try JSONEncoder().encode(Self.automation(mode: .pinned))
        var older = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        older["concurrency"] = nil
        older["missedRuns"] = nil
        older["onlyWhenChanged"] = nil
        older["catchUp"] = true
        let decoded = try JSONDecoder().decode(Automation.self, from: JSONSerialization.data(withJSONObject: older))
        #expect(decoded.missedRuns == .runOnce)
        #expect(decoded.concurrency == .skipIfActive)
        #expect(!decoded.onlyWhenChanged)
        // What this Mac writes still carries the switch, for older ones.
        let written = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(written["catchUp"] as? Bool == false)
        #expect(try JSONDecoder().decode(Automation.self, from: data) == Self.automation(mode: .pinned))
    }

    // MARK: - Still going

    @Test func aPinnedRunStillGoingSkipsAndNeverOverlaps() {
        let a = Self.automation(mode: .pinned)
        // Due every minute while a three-minute run works: two skips.
        var skips = 0
        for _ in 0..<2 {
            let d = Self.decide(a, active: true)
            #expect(d.fires == 0 && !d.runAfterCurrentFinishes)
            #expect(d.skips == [AutomationSkip(reason: .lastRunStillGoing, count: 1)])
            skips += d.skips.reduce(0) { $0 + $1.count }
        }
        #expect(skips == 2)
        #expect(Self.decide(a, active: false).fires == 1)
    }

    @Test func startingAnotherIgnoresAWorkingRunAndWaitingRunsOnceAfterIt() {
        #expect(Self.decide(Self.automation(), active: true).fires == 1)

        let waiter = Self.automation(concurrency: .runAfterActiveFinishes)
        let first = Self.decide(waiter, active: true)
        #expect(first.fires == 0 && first.runAfterCurrentFinishes && first.skips.isEmpty)
        // A second due run while one already waits is a recorded skip.
        let second = Self.decide(waiter, active: true, waiting: true)
        #expect(second.fires == 0 && !second.runAfterCurrentFinishes)
        #expect(second.skips == [AutomationSkip(reason: .lastRunStillGoing, count: 1)])
    }

    // MARK: - Missed while closed

    @Test func missedRunsFollowTheChosenRule() {
        let skip = Self.decide(Self.automation(missedRuns: .skip), dueCount: 3, missed: true)
        #expect(skip.fires == 0 && skip.skips == [AutomationSkip(reason: .missedWhileClosed, count: 3)])

        let once = Self.decide(Self.automation(missedRuns: .runOnce), dueCount: 3, missed: true)
        #expect(once.fires == 1 && once.skips == [AutomationSkip(reason: .missedWhileClosed, count: 2)])

        // Closed over three missed runs: all three run.
        let each = Self.decide(Self.automation(missedRuns: .runEach), dueCount: 3, missed: true)
        #expect(each.fires == 3 && each.skips.isEmpty)

        let capped = Self.decide(Self.automation(missedRuns: .runEach), dueCount: 7, missed: true)
        #expect(capped.fires == 5 && capped.skips == [AutomationSkip(reason: .missedWhileClosed, count: 2)])

        // A run due right now is not missed, whatever the missed rule says.
        #expect(Self.decide(Self.automation(missedRuns: .skip)).fires == 1)
    }

    @Test func dueOccurrencesCountEachMissedFireOnce() {
        let a = Self.automation()
        let due = Self.start
        #expect(a.dueOccurrences(from: due, through: due) == [due])
        #expect(a.dueOccurrences(from: due, through: due.addingTimeInterval(180)).count == 4)
        #expect(a.dueOccurrences(from: due, through: due.addingTimeInterval(3_600)).count
                == AutomationScheduling.missedOccurrenceLimit)
        #expect(a.dueOccurrences(from: due.addingTimeInterval(60), through: due).isEmpty)
    }

    // MARK: - Only when changed

    @Test func anUnchangedBaseSkipsWhenTheAutomationAsksForIt() {
        let a = Self.automation(onlyWhenChanged: true)
        let still = Self.decide(a, baseMoved: AutomationScheduling.baseMoved(lastRunCommit: "abc", currentCommit: "abc"))
        #expect(still.fires == 0 && still.skips == [AutomationSkip(reason: .projectUnchanged, count: 1)])
        #expect(Self.decide(a, baseMoved: AutomationScheduling.baseMoved(lastRunCommit: "abc", currentCommit: "def")).fires == 1)
        // No last run to compare with: the run happens and sets the mark.
        #expect(Self.decide(a, baseMoved: AutomationScheduling.baseMoved(lastRunCommit: nil, currentCommit: "abc")).fires == 1)
        // Off means the base never blocks a run.
        #expect(Self.decide(Self.automation(), baseMoved: false).fires == 1)
    }

    // MARK: - Run history and storage

    @Test func skippedRunsRecordTheirReason() throws {
        let store = try Store.inMemory()
        var a = Self.automation(mode: .pinned, missedRuns: .runEach, onlyWhenChanged: true)
        a.projectId = nil
        try store.save(a)
        #expect(try store.automation("a1") == a)

        let skipped = AutomationRun.skipped(automationId: "a1", reason: .lastRunStillGoing, at: Self.start)
        #expect(skipped.status == .skipped && skipped.trigger == .schedule && skipped.sessionId == nil)
        #expect(skipped.reason == "skipped: last run still going")
        try store.save(skipped)
        var ran = AutomationRun(id: "r1", automationId: "a1", firedAt: Self.start, trigger: .schedule, status: .created, sessionId: "s1")
        ran.baseCommit = "abc123"
        try store.save(ran)
        let runs = try store.runs(automationId: "a1", limit: 10)
        #expect(runs.contains(skipped) && runs.contains(ran))
    }

    @Test func migrationMapsCatchUpAndWorkspaceMode() throws {
        let store = try Store.inMemory(migratedTo: "v12-automation-device", thenRunning: """
            INSERT INTO automations (id, name, prompt, provider_id, project_id, rrule, timezone, dtstart,
                                     workspace_mode, pinned_session_id, continue_agent_session, permission_policy,
                                     catch_up, enabled, next_run_at, created_at, updated_at, triggers)
            VALUES ('a1', 'Pinned', 'x', 'claude', NULL, 'FREQ=DAILY;BYHOUR=9;BYMINUTE=0', 'UTC',
                    '2026-09-01 12:00:00.000', 'pinned', 's1', 1, 'auto-edits', 1, 1, NULL,
                    '2026-09-01 12:00:00.000', '2026-09-01 12:00:00.000', '[]'),
                   ('a2', 'Fresh', 'x', 'claude', NULL, 'FREQ=DAILY;BYHOUR=9;BYMINUTE=0', 'UTC',
                    '2026-09-01 12:00:00.000', 'new_worktree', NULL, 0, 'auto-edits', 0, 1, NULL,
                    '2026-09-01 12:00:00.000', '2026-09-01 12:00:00.000', '[]');
            INSERT INTO automation_runs (id, automation_id, fired_at, "trigger", status)
            VALUES ('r1', 'a1', '2026-09-01 12:00:00.000', 'schedule', 'created');
            """)
        let pinned = try #require(try store.automation("a1"))
        #expect(pinned.missedRuns == .runOnce && pinned.catchUp)
        #expect(pinned.concurrency == .skipIfActive && !pinned.onlyWhenChanged)
        let fresh = try #require(try store.automation("a2"))
        #expect(fresh.missedRuns == .skip && fresh.concurrency == .startAnother)
        let oldRun = try #require(try store.runs(automationId: "a1", limit: 1).first)
        #expect(oldRun.reason == nil && oldRun.baseCommit == nil)

        var edited = pinned
        edited.missedRuns = .runEach
        edited.concurrency = .runAfterActiveFinishes
        edited.onlyWhenChanged = true
        try store.save(edited)
        #expect(try store.automation("a1") == edited)
        // The old switch column follows, for builds from before missed runs.
        #expect(try store.automation("a1")?.catchUp == true)
    }
}
