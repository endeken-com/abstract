import Foundation
import Synchronization
import Testing
@testable import AbstractCore

/// An automation that runs on a paired Mac: its Mac is stored with it, the
/// scheduler's plan for a run there (or the reason it can't start), and the
/// request that crosses the remote channel to start it.
@Suite struct AutomationDeviceTests {
    static let created = Date(timeIntervalSince1970: 1_790_000_000)

    static func automation(deviceId: String? = "mac-studio", projectId: String? = "p1") -> Automation {
        Automation(id: "a1", name: "Nightly", prompt: "Run the tests", providerId: "claude", projectId: projectId,
                   triggers: [], createdAt: created, updatedAt: created, deviceId: deviceId)
    }

    static let here = Project(id: "p1", name: "api", rootPath: "/r/api", createdAt: created)

    static func snapshot(automationDevice: Bool? = true, providers: [String] = ["claude"],
                         projects: [Project] = [Project(id: "p9", name: "api", rootPath: "/other/api", createdAt: created)]) -> RemoteSnapshot {
        RemoteSnapshot(projects: projects, sessions: [], providers: providers, alive: [], automationDevice: automationDevice)
    }

    static func plan(_ a: Automation, snapshot: RemoteSnapshot?, localProject: Project? = here) throws -> RemoteRunStart {
        try AutomationDeviceRun.plan(a, deviceName: "Mac Studio", snapshot: snapshot, localProject: localProject,
                                     name: "Nightly · Sep 22", nameSource: .fallback, slug: "nightly-sep-22")
    }

    // MARK: - Stored with the automation

    @Test func theChosenMacRoundTrips() throws {
        let store = try Store.inMemory()
        try store.save(Self.here)
        let a = Self.automation()
        try store.save(a)
        #expect(try store.automation("a1") == a)

        var local = a
        local.deviceId = nil
        try store.save(local)
        #expect(try store.automation("a1")?.deviceId == nil)
    }

    @Test func automationsFromBeforeTheMigrationRunOnThisMac() throws {
        let store = try Store.inMemory(migratedTo: "v11-default-device", thenRunning: """
            INSERT INTO automations (id, name, prompt, provider_id, project_id, rrule, timezone, dtstart,
                                     workspace_mode, pinned_session_id, continue_agent_session, permission_policy,
                                     catch_up, enabled, next_run_at, created_at, updated_at, model, effort, triggers)
            VALUES ('a1', 'Nightly', 'Run the tests', 'claude', NULL, 'FREQ=DAILY;BYHOUR=9;BYMINUTE=0', 'UTC',
                    '2026-09-01 12:00:00.000', 'new_worktree', NULL, 0, 'auto-edits', 0, 1, NULL,
                    '2026-09-01 12:00:00.000', '2026-09-01 12:00:00.000', NULL, NULL, '[]');
            """)
        let a = try #require(try store.automation("a1"))
        #expect(a.deviceId == nil && a.name == "Nightly")

        var edited = a
        edited.deviceId = "mac-mini"
        try store.save(edited)
        #expect(try store.automation("a1") == edited)
    }

    @Test func anAutomationFromAnOlderMacDecodesWithoutAMac() throws {
        let a = Self.automation()
        let data = try JSONEncoder().encode(a)
        #expect(try JSONDecoder().decode(Automation.self, from: data) == a)
        var older = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        older["deviceId"] = nil
        let decoded = try JSONDecoder().decode(Automation.self, from: JSONSerialization.data(withJSONObject: older))
        #expect(decoded.deviceId == nil && decoded.name == "Nightly")
    }

    // MARK: - The scheduler's plan for a run on another Mac

    @Test func aRunInAProjectStartsInThatMacsOwnRecordOfIt() throws {
        let start = try Self.plan(Self.automation(), snapshot: Self.snapshot())
        #expect(start == RemoteRunStart(projectId: "p9", providerId: "claude", prompt: "Run the tests",
                                        policy: .autoEdits, model: nil, effort: nil,
                                        name: "Nightly · Sep 22", nameSource: .fallback,
                                        slug: "nightly-sep-22", automationId: "a1"))
    }

    @Test func aRunWithNoProjectStartsAStandaloneChatThere() throws {
        let start = try Self.plan(Self.automation(projectId: nil), snapshot: Self.snapshot(), localProject: nil)
        #expect(start.projectId == nil && start.automationId == "a1")
    }

    @Test func aMacThatIsntConnectedFailsTheRunWithThatReason() {
        #expect(throws: AbstractError.message("Mac Studio isn't connected, so this run didn't start.")) {
            try Self.plan(Self.automation(), snapshot: nil)
        }
    }

    @Test func anOlderMacFailsTheRunWithThatReason() {
        #expect(throws: AbstractError.message("Mac Studio needs a newer version of Abstract to run an automation started from here.")) {
            try Self.plan(Self.automation(), snapshot: Self.snapshot(automationDevice: nil))
        }
    }

    @Test func aProjectThatMacDoesntHaveFailsTheRunWithThatReason() {
        let projects = [Project(id: "p9", name: "web", rootPath: "/r/web", createdAt: Self.created)]
        #expect(throws: AbstractError.message("Mac Studio doesn't have a project called “api”, so this run didn't start.")) {
            try Self.plan(Self.automation(), snapshot: Self.snapshot(projects: projects))
        }
    }

    @Test func anAgentThatMacCantRunFailsTheRunWithThatReason() {
        #expect(throws: AbstractError.message("\(ProviderRegistry.name("claude")) isn't available on Mac Studio, so this run didn't start.")) {
            try Self.plan(Self.automation(), snapshot: Self.snapshot(providers: ["codex"]))
        }
    }

    // MARK: - Run history keeps the reason

    @Test func aFailedRunKeepsItsReasonForTheHistory() throws {
        let store = try Store.inMemory()
        try store.save(Self.here)
        try store.save(Self.automation())
        let run = AutomationRun(id: "r1", automationId: "a1", firedAt: Self.created, trigger: .schedule,
                                status: .failed, error: "Mac Studio isn't connected, so this run didn't start.")
        try store.save(run)
        #expect(try store.runs(automationId: "a1", limit: 10) == [run])
        #expect(try store.lastRun(automationId: "a1")?.error == "Mac Studio isn't connected, so this run didn't start.")
    }

    // MARK: - Over a fake remote channel

    @Test func theRunStartCrossesAChannelAndNamesItsChat() async throws {
        let host = DeviceIdentity.generate(name: "Mac Studio")
        let controller = DeviceIdentity.generate(name: "MacBook")
        let (mine, theirs) = MemoryTransport.pair()
        let here = RemoteChannel(transport: mine)
        let there = RemoteChannel(transport: theirs)
        defer { here.close(); there.close() }

        async let accepted: Void = { _ = try await there.accept(as: host, lookup: { _ in controller.peer }) }()
        _ = try await here.handshake(as: controller, pairing: false, expected: host.peer)
        try await accepted

        let start = try Self.plan(Self.automation(), snapshot: Self.snapshot())
        async let served: RemoteMessage = {
            let message = try await there.receive()
            try await there.send(.response(id: 7, .started(sessionId: "chat-9")))
            return message
        }()
        try await here.send(.request(id: 7, .startRun(start)))
        guard case .response(7, .started("chat-9")) = try await here.receive() else {
            Issue.record("the host didn't say which chat it started")
            return
        }
        guard case .request(7, .startRun(let asked)) = try await served else {
            Issue.record("the run start didn't arrive")
            return
        }
        #expect(asked == start)
    }
}

/// Two ends of a remote channel in memory: what one writes, the other reads.
private final class MemoryTransport: RemoteTransport, @unchecked Sendable {
    /// The one reader's place in the stream, passed in and out of the lock.
    private final class IteratorBox: @unchecked Sendable {
        var iterator: AsyncStream<Data>.Iterator
        init(_ chunks: AsyncStream<Data>) { iterator = chunks.makeAsyncIterator() }
    }

    private let chunks: AsyncStream<Data>
    private let emit: @Sendable (Data) -> Void
    private let finish: @Sendable () -> Void
    private let state = Mutex((buffer: Data(), box: nil as IteratorBox?))

    private init(chunks: AsyncStream<Data>, emit: @escaping @Sendable (Data) -> Void, finish: @escaping @Sendable () -> Void) {
        self.chunks = chunks; self.emit = emit; self.finish = finish
    }

    static func pair() -> (MemoryTransport, MemoryTransport) {
        let oneWay = AsyncStream<Data>.makeStream()
        let otherWay = AsyncStream<Data>.makeStream()
        return (MemoryTransport(chunks: otherWay.stream, emit: { oneWay.continuation.yield($0) }, finish: { oneWay.continuation.finish() }),
                MemoryTransport(chunks: oneWay.stream, emit: { otherWay.continuation.yield($0) }, finish: { otherWay.continuation.finish() }))
    }

    func open() async throws {}
    func close() { finish() }

    func write(_ data: Data, completion: @escaping @Sendable ((any Error)?) -> Void) {
        emit(data)
        completion(nil)
    }

    func read(_ count: Int) async throws -> Data {
        while true {
            if let data = state.withLock({ s -> Data? in
                guard s.buffer.count >= count else { return nil }
                defer { s.buffer.removeFirst(count) }
                return Data(s.buffer.prefix(count))
            }) { return data }
            let box = state.withLock { s -> IteratorBox in
                if let taken = s.box { s.box = nil; return taken }
                return IteratorBox(chunks)
            }
            guard let chunk = await box.iterator.next() else { throw RemoteChannel.Failure.closed }
            state.withLock { s in s.buffer += chunk; s.box = box }
        }
    }
}
