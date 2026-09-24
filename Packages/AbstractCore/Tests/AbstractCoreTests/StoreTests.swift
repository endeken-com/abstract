import Foundation
import Testing
import AbstractCore

@Suite struct StoreTests {
    let store: Store

    init() throws { store = try Store.inMemory() }

    /// Whole-second dates: the store keeps millisecond precision.
    static func at(_ offset: TimeInterval) -> Date { Date(timeIntervalSince1970: 1_790_000_000 + offset) }

    static func project(_ id: String = UUID().uuidString, sortOrder: Int = 0, createdAt: Date = at(0)) -> Project {
        Project(id: id, name: "Project \(id)", rootPath: "/repos/\(id)", sortOrder: sortOrder, createdAt: createdAt)
    }

    static func session(_ id: String = UUID().uuidString, projectId: String?, status: SessionStatus = .created,
                        createdAt: Date = at(0), lastEventAt: Date? = nil, automationId: String? = nil) -> Session {
        Session(id: id, projectId: projectId, name: "Chat \(id)", providerId: "claude", status: status,
                automationId: automationId, createdAt: createdAt, lastEventAt: lastEventAt)
    }

    static func automation(_ id: String = UUID().uuidString, projectId: String?) -> Automation {
        Automation(id: id, name: "Nightly \(id)", prompt: "Run the tests", providerId: "codex", projectId: projectId,
                   rrule: "FREQ=DAILY;BYHOUR=9;BYMINUTE=0;BYSECOND=0", timezone: "America/Sao_Paulo",
                   dtstart: at(0), createdAt: at(0), updatedAt: at(0))
    }

    // MARK: - Projects

    @Test func projectRoundTripsEveryField() throws {
        let project = Project(
            id: "p1", name: "Abstract", rootPath: "/Users/me/Abstract", defaultBaseRef: "origin/main",
            defaultProviderId: "codex", defaultPermissionPolicy: .autoEdits, nestedRepos: ["vendor/a", "libs/b c"],
            worktreeTemplate: "~/wt/{project}/{branch}", branchPrefix: "wes/", sortOrder: 3,
            createdAt: Self.at(0), archivedAt: Self.at(60))
        try store.save(project)
        #expect(try store.project("p1") == project)
        #expect(try store.projects() == [project])
        #expect(try store.project("missing") == nil)
    }

    @Test func savingAnExistingProjectUpdatesItInPlace() throws {
        var project = Project(id: "p1", name: "Old", rootPath: "/r", worktreeTemplate: "t", branchPrefix: "x/",
                              createdAt: Self.at(0), archivedAt: Self.at(5))
        try store.save(project)
        project.name = "New"
        project.defaultPermissionPolicy = .bypass
        project.nestedRepos = ["one"]
        project.worktreeTemplate = nil
        project.branchPrefix = nil
        project.archivedAt = nil
        try store.save(project)
        #expect(try store.projects() == [project])
    }

    @Test func projectsAreOrderedBySortOrderThenCreation() throws {
        let c = Self.project("c", sortOrder: 1, createdAt: Self.at(0))
        let a = Self.project("a", sortOrder: 0, createdAt: Self.at(20))
        let b = Self.project("b", sortOrder: 0, createdAt: Self.at(10))
        for p in [c, a, b] { try store.save(p) }
        #expect(try store.projects().map(\.id) == ["b", "a", "c"])
    }

    // MARK: - Sessions

    @Test func sessionRoundTripsEveryField() throws {
        try store.save(Self.project("p1"))
        let session = Session(
            id: "s1", projectId: "p1", name: "Fix the build", providerId: "claude", providerSessionId: "abc-123",
            worktreePath: "/wt/s1", branch: "wes/fix-build", baseRef: "main", status: .waitingInput,
            statusDetail: "Approve Bash?", permissionPolicy: .autoEdits, prompt: "fix it", automationId: "a1",
            createdAt: Self.at(0), lastEventAt: Self.at(30), archivedAt: Self.at(90))
        try store.save(session)
        #expect(try store.session("s1") == session)
        #expect(try store.session("missing") == nil)

        var updated = session
        updated.status = .finished
        updated.statusDetail = nil
        updated.providerSessionId = nil
        updated.archivedAt = nil
        try store.save(updated)
        #expect(try store.sessions() == [updated])
    }

    @Test func sessionWithoutProjectIsAllowed() throws {
        let session = Self.session("s1", projectId: nil)
        try store.save(session)
        #expect(try store.session("s1") == session)
    }

    @Test func sessionForAMissingProjectIsRejected() {
        #expect(throws: (any Error).self) { try store.save(Self.session(projectId: "nope")) }
    }

    @Test func sessionsAreOrderedByLastEventFallingBackToCreation() throws {
        try store.save(Self.project("p1"))
        try store.save(Self.session("older-event", projectId: "p1", createdAt: Self.at(0), lastEventAt: Self.at(10)))
        try store.save(Self.session("no-event", projectId: "p1", createdAt: Self.at(5)))
        try store.save(Self.session("newest-event", projectId: "p1", createdAt: Self.at(1), lastEventAt: Self.at(20)))
        #expect(try store.sessions().map(\.id) == ["newest-event", "older-event", "no-event"])
    }

    @Test func updatingStatusSetsDetailAndBumpsLastEvent() throws {
        try store.save(Self.session("s1", projectId: nil, status: .running, lastEventAt: Self.at(0)))
        let before = Date().addingTimeInterval(-0.01)
        try store.updateSessionStatus("s1", .errored, detail: "boom")
        var session = try #require(try store.session("s1"))
        #expect(session.status == .errored)
        #expect(session.statusDetail == "boom")
        #expect(try #require(session.lastEventAt) >= before)

        try store.updateSessionStatus("s1", .idle, detail: nil)
        session = try #require(try store.session("s1"))
        #expect(session.status == .idle)
        #expect(session.statusDetail == nil)
    }

    @Test func touchingBumpsLastEvent() throws {
        try store.save(Self.session("s1", projectId: nil, createdAt: Self.at(0)))
        let before = Date().addingTimeInterval(-0.01)
        try store.touchSession("s1")
        let session = try #require(try store.session("s1"))
        #expect(try #require(session.lastEventAt) >= before)
        #expect(session.status == .created)
    }

    @Test func deletingASession() throws {
        try store.save(Self.session("s1", projectId: nil))
        try store.save(Self.session("s2", projectId: nil))
        try store.deleteSession("s1")
        #expect(try store.sessions().map(\.id) == ["s2"])
    }

    @Test func reconcileMarksOnlyActiveSessionsInterrupted() throws {
        for status in SessionStatus.allCases {
            try store.save(Self.session(status.rawValue, projectId: nil, status: status, lastEventAt: Self.at(42)))
        }
        #expect(try store.reconcileInterruptedSessions() == 4)
        for status in SessionStatus.allCases {
            let session = try #require(try store.session(status.rawValue))
            #expect(session.lastEventAt == Self.at(42))
            if status.isActive {
                #expect(session.status == .errored)
                #expect(session.statusDetail == "Interrupted when Abstract quit")
            } else {
                #expect(session.status == status)
                #expect(session.statusDetail == nil)
            }
        }
        #expect(try store.reconcileInterruptedSessions() == 0)
    }

    // MARK: - Automations and runs

    @Test func automationRoundTripsEveryField() throws {
        try store.save(Self.project("p1"))
        let automation = Automation(
            id: "a1", name: "Triage", prompt: "Look at new issues", providerId: "claude", projectId: "p1",
            rrule: "FREQ=WEEKLY;BYDAY=MO;BYHOUR=7;BYMINUTE=30;BYSECOND=0", timezone: "Europe/Lisbon",
            dtstart: Self.at(0), workspaceMode: .pinned, pinnedSessionId: "s9", continueAgentSession: true,
            permissionPolicy: .bypass, catchUp: true, enabled: false, nextRunAt: Self.at(3600),
            createdAt: Self.at(1), updatedAt: Self.at(2))
        try store.save(automation)
        #expect(try store.automation("a1") == automation)
        #expect(try store.automation("missing") == nil)

        var updated = automation
        updated.enabled = true
        updated.catchUp = false
        updated.continueAgentSession = false
        updated.workspaceMode = .newWorktree
        updated.pinnedSessionId = nil
        updated.nextRunAt = nil
        updated.projectId = nil
        updated.updatedAt = Self.at(100)
        try store.save(updated)
        #expect(try store.automations() == [updated])
    }

    @Test func automationsAreOrderedByCreation() throws {
        var late = Self.automation("late", projectId: nil)
        late.createdAt = Self.at(50)
        var early = Self.automation("early", projectId: nil)
        early.createdAt = Self.at(10)
        try store.save(late)
        try store.save(early)
        #expect(try store.automations().map(\.id) == ["early", "late"])
    }

    @Test func runsRoundTripNewestFirstWithLimit() throws {
        try store.save(Self.automation("a1", projectId: nil))
        try store.save(Self.automation("other", projectId: nil))
        let first = AutomationRun(id: "r1", automationId: "a1", firedAt: Self.at(10), trigger: .schedule)
        let second = AutomationRun(id: "r2", automationId: "a1", firedAt: Self.at(20), trigger: .manual,
                                   status: .failed, error: "No such branch")
        let third = AutomationRun(id: "r3", automationId: "a1", firedAt: Self.at(30), trigger: .schedule,
                                  status: .created, sessionId: "s1")
        let elsewhere = AutomationRun(id: "rx", automationId: "other", firedAt: Self.at(99), trigger: .manual)
        for run in [second, third, first, elsewhere] { try store.save(run) }

        #expect(try store.runs(automationId: "a1", limit: 10) == [third, second, first])
        #expect(try store.runs(automationId: "a1", limit: 2).map(\.id) == ["r3", "r2"])
        #expect(try store.lastRun(automationId: "a1") == third)
        #expect(try store.lastRun(automationId: "none") == nil)

        var finished = first
        finished.status = .created
        finished.sessionId = "s7"
        try store.save(finished)
        #expect(try store.runs(automationId: "a1", limit: 10).last == finished)
        #expect(try store.runs(automationId: "a1", limit: 10).count == 3)
    }

    // MARK: - Cascades

    @Test func deletingAProjectCascadesToItsSessionsAndAutomations() throws {
        try store.save(Self.project("doomed"))
        try store.save(Self.project("kept"))
        try store.save(Self.session("s-doomed", projectId: "doomed"))
        try store.save(Self.session("s-kept", projectId: "kept"))
        try store.save(Self.session("s-none", projectId: nil))
        try store.save(Self.automation("a-doomed", projectId: "doomed"))
        try store.save(Self.automation("a-kept", projectId: "kept"))
        try store.save(AutomationRun(id: "r-doomed", automationId: "a-doomed", trigger: .manual))

        try store.deleteProject("doomed")

        #expect(try store.projects().map(\.id) == ["kept"])
        #expect(try Set(store.sessions().map(\.id)) == ["s-kept", "s-none"])
        #expect(try store.automations().map(\.id) == ["a-kept"])
        #expect(try store.runs(automationId: "a-doomed", limit: 10).isEmpty)
    }

    @Test func deletingAnAutomationCascadesToRunsButNeverSessions() throws {
        try store.save(Self.project("p1"))
        try store.save(Self.automation("a1", projectId: "p1"))
        try store.save(Self.session("s1", projectId: "p1", automationId: "a1"))
        try store.save(AutomationRun(id: "r1", automationId: "a1", trigger: .schedule, status: .created, sessionId: "s1"))

        try store.deleteAutomation("a1")

        #expect(try store.automation("a1") == nil)
        #expect(try store.runs(automationId: "a1", limit: 10).isEmpty)
        let session = try #require(try store.session("s1"))
        #expect(session.automationId == "a1")
        #expect(try store.project("p1") != nil)
    }

    // MARK: - Usage

    static func usage(_ session: String, _ project: String?, _ provider: String, at offset: TimeInterval,
                      input: Int, output: Int, cost: Double, duration: Int = 1000, turns: Int = 1) -> UsageRecord {
        UsageRecord(sessionId: session, projectId: project, providerId: provider, at: at(offset),
                    usage: UsageTotals(inputTokens: input, outputTokens: output, cacheRead: input / 10, cacheWrite: 1),
                    costUsd: cost, durationMs: duration, turns: turns)
    }

    @Test func usageSummaryGroupsByProviderAndFilters() throws {
        try store.record(Self.usage("s1", "p1", "claude", at: 0, input: 100, output: 10, cost: 0.5, duration: 1000, turns: 1))
        try store.record(Self.usage("s1", "p1", "claude", at: 100, input: 200, output: 20, cost: 1.25, duration: 2000, turns: 2))
        try store.record(Self.usage("s2", "p2", "claude", at: 200, input: 400, output: 40, cost: 2, duration: 4000, turns: 4))
        try store.record(Self.usage("s3", "p1", "codex", at: 300, input: 50, output: 5, cost: 0.25, duration: 500, turns: 1))
        try store.record(Self.usage("s4", nil, "codex", at: 400, input: 10, output: 1, cost: 0.125, duration: 100, turns: 1))

        let all = try store.usageSummary(since: nil, projectId: nil)
        #expect(all == [
            UsageSummary(providerId: "claude", sessions: 2, turns: 7,
                         usage: UsageTotals(inputTokens: 700, outputTokens: 70, cacheRead: 70, cacheWrite: 3),
                         costUsd: 3.75, durationMs: 7000),
            UsageSummary(providerId: "codex", sessions: 2, turns: 2,
                         usage: UsageTotals(inputTokens: 60, outputTokens: 6, cacheRead: 6, cacheWrite: 2),
                         costUsd: 0.375, durationMs: 600),
        ])

        let recent = try store.usageSummary(since: Self.at(150), projectId: nil)
        #expect(recent.map(\.providerId) == ["claude", "codex"])
        #expect(recent[0].usage.inputTokens == 400)
        #expect(recent[0].sessions == 1)
        #expect(recent[1].turns == 2)

        let p1 = try store.usageSummary(since: nil, projectId: "p1")
        #expect(p1.map(\.providerId) == ["claude", "codex"])
        #expect(p1[0].sessions == 1)
        #expect(p1[0].usage.outputTokens == 30)
        #expect(p1[0].costUsd == 1.75)
        #expect(p1[1].usage.inputTokens == 50)

        let p1Recent = try store.usageSummary(since: Self.at(50), projectId: "p1")
        #expect(p1Recent.map(\.providerId) == ["claude", "codex"])
        #expect(p1Recent[0].usage.inputTokens == 200)
        #expect(p1Recent[0].durationMs == 2000)

        #expect(try store.usageSummary(since: Self.at(10_000), projectId: nil).isEmpty)
        #expect(try store.usageSummary(since: nil, projectId: "nope").isEmpty)
    }

    @Test func usageByDayGroupsByLocalDayAndProvider() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        func local(_ day: Int, _ hour: Int) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 5, day: day, hour: hour))!
        }
        func record(_ provider: String, _ date: Date, output: Int, cost: Double) throws {
            try store.record(UsageRecord(sessionId: "s", projectId: nil, providerId: provider, at: date,
                                         usage: UsageTotals(inputTokens: 1, outputTokens: output),
                                         costUsd: cost, durationMs: 1, turns: 1))
        }
        try record("codex", local(11, 12), output: 7, cost: 0.25)
        try record("claude", local(10, 9), output: 10, cost: 0.5)
        try record("claude", local(10, 22), output: 5, cost: 0.25)
        try record("claude", local(11, 1), output: 3, cost: 1)

        #expect(try store.usageByDay(since: nil) == [
            UsageDay(day: "2026-05-10", providerId: "claude", outputTokens: 15, costUsd: 0.75),
            UsageDay(day: "2026-05-11", providerId: "claude", outputTokens: 3, costUsd: 1),
            UsageDay(day: "2026-05-11", providerId: "codex", outputTokens: 7, costUsd: 0.25),
        ])
        #expect(try store.usageByDay(since: local(11, 0)) == [
            UsageDay(day: "2026-05-11", providerId: "claude", outputTokens: 3, costUsd: 1),
            UsageDay(day: "2026-05-11", providerId: "codex", outputTokens: 7, costUsd: 0.25),
        ])
    }

    // MARK: - Settings

    struct Layout: Codable, Equatable { var sidebarWidth: Double; var collapsed: Bool }

    @Test func settingsRoundTripAnyCodableValue() throws {
        try store.setSetting("theme", "dark")
        try store.setSetting("fontSize", 13)
        try store.setSetting("telemetry", false)
        let groups: [String: [String]] = ["favorites": ["p1", "p2"], "archived": []]
        try store.setSetting("groups", groups)
        try store.setSetting("layout", Layout(sidebarWidth: 240.5, collapsed: true))

        #expect(store.setting("theme", as: String.self) == "dark")
        #expect(store.setting("fontSize", as: Int.self) == 13)
        #expect(store.setting("telemetry", as: Bool.self) == false)
        #expect(store.setting("groups", as: [String: [String]].self) == groups)
        #expect(store.setting("layout", as: Layout.self) == Layout(sidebarWidth: 240.5, collapsed: true))

        #expect(store.setting("missing", as: String.self) == nil)
        #expect(store.setting("theme", as: Int.self) == nil)
    }

    @Test func settingsOverwriteAndNilDeletes() throws {
        try store.setSetting("groups", ["a": ["1"]])
        try store.setSetting("groups", ["b": ["2", "3"]])
        #expect(store.setting("groups", as: [String: [String]].self) == ["b": ["2", "3"]])

        try store.setSetting("groups", nil as [String: [String]]?)
        #expect(store.setting("groups", as: [String: [String]].self) == nil)
        // Deleting a missing key is fine.
        try store.setSetting("never-set", nil as String?)
    }

    // MARK: - Files

    @Test func fileStoreCreatesItsDirectoryAndPersistsAcrossReopen() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("abstract-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("nested/dir/abstract.sqlite").path

        do {
            let store = try Store(path: path)
            try store.save(Self.project("p1"))
            try store.setSetting("theme", "light")
            #expect(FileManager.default.fileExists(atPath: path))
            #expect(FileManager.default.fileExists(atPath: path + "-wal"))
        }
        let reopened = try Store(path: path)
        #expect(try reopened.projects().map(\.id) == ["p1"])
        #expect(reopened.setting("theme", as: String.self) == "light")
    }

    @Test func defaultPathEndsInAbstractSqlite() {
        let path = Store.defaultPath()
        if let dir = ProcessInfo.processInfo.environment["ABSTRACT_DATA_DIR"], !dir.isEmpty {
            #expect(path.hasSuffix("/abstract.sqlite"))
        } else {
            #expect(path.hasSuffix("/Library/Application Support/Abstract/abstract.sqlite"))
        }
    }
}

@Suite struct LegacyDataMigrationTests {
    @Test func movesTheBacktickFolderAndRepointsIconPaths() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("migrate-\(UUID().uuidString)")
        let old = base.appendingPathComponent("Backtick"), new = base.appendingPathComponent("Abstract")
        try fm.createDirectory(at: old.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        do { // closed again before the move, as when the old app has quit
            let store = try Store(path: old.appendingPathComponent("backtick.sqlite").path)
            var project = Project(name: "p", rootPath: "/tmp/p")
            project.iconImagePath = old.appendingPathComponent("ProjectIcons/p.png").path
            try store.save(project)
        }
        try "log".write(to: old.appendingPathComponent("sessions/s.jsonl"), atomically: true, encoding: .utf8)

        Store.migrateLegacyData(from: old, to: new)

        #expect(fm.fileExists(atPath: new.appendingPathComponent("abstract.sqlite").path))
        #expect(fm.fileExists(atPath: new.appendingPathComponent("sessions/s.jsonl").path))
        #expect(!fm.fileExists(atPath: old.appendingPathComponent("backtick.sqlite").path))
        let moved = try Store(path: new.appendingPathComponent("abstract.sqlite").path)
        #expect(try moved.projects().first?.iconImagePath == new.appendingPathComponent("ProjectIcons/p.png").path)

        // A second launch finds nothing to do and leaves the new data alone.
        Store.migrateLegacyData(from: old, to: new)
        #expect(try moved.projects().count == 1)
    }
}
