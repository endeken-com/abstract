import Foundation
import Testing
@testable import AbstractCore

@Suite("Session lock", .serialized)
struct SessionLockTests {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("locks-\(UUID().uuidString)")

    @Test func oneDriverAtATime() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let cli = try SessionLock.acquire("s1", as: .cli, in: dir)
        #expect(throws: SessionLockError.self) { try SessionLock.acquire("s1", as: .app, in: dir) }
        #expect(SessionLock.holder(of: "s1", in: dir)?.driver == .cli)
        #expect(SessionLock.holder(of: "s1", in: dir)?.pid == getpid())
        // Other chats are unaffected.
        let other = try SessionLock.acquire("s2", as: .app, in: dir)
        other.release()

        cli.release()
        #expect(SessionLock.holder(of: "s1", in: dir) == nil)
        let app = try SessionLock.acquire("s1", as: .app, in: dir)
        #expect(SessionLock.holder(of: "s1", in: dir)?.driver == .app)
        app.release()
    }

    @Test func theRefusalSaysWhoHoldsIt() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let app = try SessionLock.acquire("s1", as: .app, in: dir)
        defer { app.release() }
        do {
            _ = try SessionLock.acquire("s1", as: .cli, in: dir)
            Issue.record("acquired a held lock")
        } catch SessionLockError.held(let info) {
            #expect(info?.driver == .app)
        }
    }

    @Test func theHolderPublishesItsAgent() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let lock = try SessionLock.acquire("s1", as: .cli, in: dir)
        defer { lock.release() }
        #expect(SessionLock.holder(of: "s1", in: dir)?.agent == nil)
        let agent = AgentRecord(id: "a1", sessionId: "s1", providerId: "claude", startedAt: Date(timeIntervalSince1970: 1_790_000_000))
        try lock.setAgent(agent)
        #expect(SessionLock.holder(of: "s1", in: dir)?.agent == agent)
        try lock.setAgent(nil)
        #expect(SessionLock.holder(of: "s1", in: dir)?.agent == nil)
    }

    @Test func aCrashedHoldersInfoIsIgnored() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        // A holder that died: its info stays behind, but the kernel dropped its lock.
        let child = try Spawner.launch(executable: "/usr/bin/true", arguments: ["true"], environment: [:], cwd: nil,
                                       stdin: .null, stdout: .null, stderr: .null)
        var status: Int32 = 0
        waitpid(child.pid, &status, 0)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stale = SessionLockInfo(driver: .cli, pid: child.pid, pidStartedAt: 1, agent: nil)
        try JSONEncoder().encode(stale).write(to: dir.appendingPathComponent("s1.json"))
        #expect(SessionLock.holder(of: "s1", in: dir) == nil)
        let lock = try SessionLock.acquire("s1", as: .app, in: dir)
        lock.release()
    }

    @Test func aChildHandedTheLockKeepsItAfterTheParentLetsGo() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let lock = try SessionLock.acquire("s1", as: .cli, in: dir)
        let child = try Spawner.launch(executable: "/bin/sleep", arguments: ["sleep", "30"], environment: [:], cwd: nil,
                                       stdin: .null, stdout: .null, stderr: .null, inherit: [3: lock.descriptor])
        lock.handOff()
        #expect(throws: SessionLockError.self) { try SessionLock.acquire("s1", as: .app, in: dir) }

        kill(child.pid, SIGKILL)
        var status: Int32 = 0
        waitpid(child.pid, &status, 0)
        let app = try SessionLock.acquire("s1", as: .app, in: dir)
        app.release()
    }
}
