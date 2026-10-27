import Foundation
import Testing
import AbstractCore

@Suite struct AutomationPresentationTests {
    /// A fixed Sunday, 12:00 UTC, so "tomorrow" and ages are exact.
    let now = Date(timeIntervalSince1970: 1_790_510_400) // 2026-09-27 12:00:00 UTC
    let utc = TimeZone(identifier: "UTC")!

    func run(status: RunStatus, firedAt: Date? = nil) -> AutomationRun {
        AutomationRun(automationId: "a1", firedAt: firedAt ?? now.addingTimeInterval(-7_200),
                      trigger: .schedule, status: status, sessionId: status == .created ? "s1" : nil)
    }

    func automation(enabled: Bool = true, triggers: [AutomationTrigger]? = nil, events: [AutomationEvent] = [],
                    nextRunAt: Date? = nil) -> Automation {
        var a = Automation(name: "Nightly", prompt: "Do it", providerId: "claude", projectId: "p1",
                           triggers: triggers ?? [AutomationTrigger(rrule: "FREQ=DAILY;BYDAY=MO,TU,WE,TH,FR;BYHOUR=9;BYMINUTE=0", timezone: "UTC")],
                           enabled: enabled, nextRunAt: nextRunAt)
        a.events = events
        return a
    }

    func summary(_ a: Automation, run: AutomationRun? = nil, status: SessionStatus? = nil) -> AutomationSummary {
        AutomationSummary(automation: a, latestRun: run, sessionStatus: status, now: now, timeZone: utc)
    }

    // MARK: - RunOutcome: every row of the table

    @Test func outcomeWords() {
        #expect(RunOutcome(run: run(status: .creating), sessionStatus: nil) == .starting)
        #expect(RunOutcome(run: run(status: .creating), sessionStatus: nil).word == "Starting…")
        #expect(RunOutcome(run: run(status: .failed), sessionStatus: nil) == .failed)
        #expect(RunOutcome(run: run(status: .skipped), sessionStatus: nil) == .skipped)
        #expect(RunOutcome(run: run(status: .created), sessionStatus: .waitingInput) == .needsYou)
        #expect(RunOutcome(run: run(status: .created), sessionStatus: .running) == .working)
        #expect(RunOutcome(run: run(status: .created), sessionStatus: .provisioning) == .working)
        #expect(RunOutcome(run: run(status: .created), sessionStatus: .idle) == .done)
        #expect(RunOutcome(run: run(status: .created), sessionStatus: .finished) == .done)
        #expect(RunOutcome(run: run(status: .created), sessionStatus: .errored) == .failed)
        #expect(RunOutcome(run: run(status: .created), sessionStatus: .created) == .ready)
        #expect(RunOutcome(run: run(status: .created), sessionStatus: nil) == .chatDeleted)
    }

    @Test func outcomeWordText() {
        #expect(RunOutcome.needsYou.word == "Needs you")
        #expect(RunOutcome.failed.word == "Failed")
        #expect(RunOutcome.skipped.word == "Skipped")
        #expect(RunOutcome.working.word == "Working")
        #expect(RunOutcome.done.word == "Done")
        #expect(RunOutcome.ready.word == "Ready")
        #expect(RunOutcome.chatDeleted.word == "Chat deleted")
    }

    @Test func onlyNeedsYouAndFailedWantAttention() {
        #expect(RunOutcome.needsYou.needsAttention)
        #expect(RunOutcome.failed.needsAttention)
        for outcome in [RunOutcome.starting, .working, .done, .skipped, .ready, .chatDeleted] {
            #expect(!outcome.needsAttention)
        }
    }

    @Test func attentionLineCountsNeedsYouAndFailed() {
        #expect(AutomationSummary.attentionLine(outcomes: [.done, .working]) == nil)
        #expect(AutomationSummary.attentionLine(outcomes: [.needsYou]) == "1 needs you")
        #expect(AutomationSummary.attentionLine(outcomes: [.needsYou, .needsYou, .failed, .done]) == "2 need you · 1 failed")
        #expect(AutomationSummary.attentionLine(outcomes: [.failed, .failed]) == "2 failed")
    }

    // MARK: - AutomationSummary strings

    @Test func summaryForScheduledWithDoneRun() {
        let a = automation(nextRunAt: now.addingTimeInterval(21 * 3_600)) // tomorrow 09:00 UTC
        let s = summary(a, run: run(status: .created), status: .finished)
        #expect(s.schedule == "Every weekday at 09:00")
        #expect(s.next == "Next tomorrow, 09:00")
        #expect(s.outcome == .done)
        #expect(s.lastRun == "Done · 2h ago")
        #expect(s.header == "Every weekday at 09:00 · Next tomorrow, 09:00 · Last run Done, 2h ago")
    }

    @Test func summaryForPaused() {
        let s = summary(automation(enabled: false))
        #expect(s.next == "Paused")
        #expect(s.lastRun == "No runs yet")
        #expect(s.header == "Every weekday at 09:00 · Paused · No runs yet")
    }

    @Test func summaryForByHandOnly() {
        let s = summary(automation(triggers: []))
        #expect(s.schedule == "Runs only when started by hand")
        #expect(s.next == "Runs by hand only")
        #expect(s.header == "Runs only when started by hand · Runs by hand only · No runs yet")
    }

    @Test func summaryForOnEvents() {
        let s = summary(automation(triggers: [], events: [.chatArchived]))
        #expect(s.schedule == "When a chat is archived")
        #expect(s.next == "Runs on events")
    }

    @Test func summaryForFinishedSchedule() {
        let s = summary(automation(nextRunAt: nil), run: run(status: .skipped), status: nil)
        #expect(s.next == "No more runs")
        #expect(s.lastRun == "Skipped · 2h ago")
    }

    @Test func summaryForNoRuns() {
        let s = summary(automation(nextRunAt: now.addingTimeInterval(3_600)))
        #expect(s.outcome == nil)
        #expect(s.lastRun == "No runs yet")
        #expect(s.next == "Next today, 13:00")
    }

    @Test func summaryForNeedsYouHasNoAgeInTheListLine() {
        let s = summary(automation(), run: run(status: .created), status: .waitingInput)
        #expect(s.lastRun == "Needs you")
        #expect(s.header.hasSuffix("Last run Needs you, 2h ago"))
    }

    @Test func summaryForDueRun() {
        let s = summary(automation(nextRunAt: now.addingTimeInterval(-60)))
        #expect(s.next == "Due now")
    }

    @Test func summaryScheduleCountsExtraTriggersAndEvents() {
        let two = [AutomationTrigger(rrule: "FREQ=DAILY;BYHOUR=9;BYMINUTE=0", timezone: "UTC"),
                   AutomationTrigger(rrule: "FREQ=DAILY;BYHOUR=19;BYMINUTE=0", timezone: "UTC")]
        let s = summary(automation(triggers: two, events: [.chatArchived]))
        #expect(s.schedule == "Every day at 09:00 · +1 more · and on an event")
    }

    // MARK: - Latest runs batch

    @Test func latestRunsPicksTheNewestPerAutomation() throws {
        let store = try Store.inMemory()
        func at(_ offset: TimeInterval) -> Date { Date(timeIntervalSince1970: 1_790_000_000 + offset) }
        for id in ["a1", "a2"] {
            try store.save(Automation(id: id, name: id, prompt: "", providerId: "claude", projectId: nil,
                                      triggers: [AutomationTrigger(rrule: "FREQ=DAILY", timezone: "UTC")]))
        }
        try store.save(AutomationRun(id: "r1", automationId: "a1", firedAt: at(10), trigger: .schedule))
        try store.save(AutomationRun(id: "r2", automationId: "a1", firedAt: at(30), trigger: .manual))
        try store.save(AutomationRun(id: "r3", automationId: "a1", firedAt: at(20), trigger: .schedule))
        try store.save(AutomationRun(id: "r4", automationId: "a2", firedAt: at(5), trigger: .schedule))
        let latest = try store.latestRuns()
        #expect(latest.count == 2)
        #expect(latest["a1"]?.id == "r2")
        #expect(latest["a2"]?.id == "r4")
        #expect(latest["none"] == nil)
    }
}
