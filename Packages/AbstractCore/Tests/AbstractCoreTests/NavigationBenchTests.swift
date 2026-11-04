import Foundation
import Testing
@testable import AbstractCore

/// What opening a chat and sending a message cost below the views, on
/// ABS-159's synthetic profile with long chats (ABS-184). Each step has a
/// budget, mostly against the machine's own timing of the slow way, so a
/// regression fails while a busy CI machine doesn't. Kept small: the suite
/// runs beside tests that time real processes, and mustn't starve them.
/// Timings: `swift test --filter NavigationBench` (and `-c release`).
@Suite(.serialized) struct NavigationBench {
    static let longChat = 2_000
    /// The newest page, smaller than the app's so the logs here can be too.
    static let page = 32 << 10

    @Test func savingOneChatInsteadOfReloading() throws {
        let store = try Self.profileStore()
        let reload = Self.time("reload: every table, rules and servers per project", runs: 3) {
            let projects = (try? store.projects()) ?? []
            var n = projects.count + ((try? store.sessions()) ?? []).count
            n += ((try? store.automations()) ?? []).count + ((try? store.latestRuns()) ?? [:]).count
            n += ((try? store.profiles()) ?? []).count + ((try? store.workflows()) ?? []).count
            for project in projects {
                n += ((try? store.permissionRules(projectId: project.id)) ?? []).count
                n += ((try? store.toolServers(projectId: project.id)) ?? []).count
            }
            return n
        }
        var sessions = try store.sessions()
        var session = try #require(sessions.first { $0.id == "bench-3" })
        let save = Self.time("save one chat and update its entry") {
            session.name = "Renamed \(Int.random(in: 0..<1000))"
            try? store.save(session)
            sessions = StoreOrder.saving(session, in: sessions, precedes: StoreOrder.sessionPrecedes)
            return sessions.count
        }
        #expect(save * 10 < reload)
        #expect(save < 20)
    }

    @Test func openingALongChat() throws {
        let (engine, dir) = try Self.engine(lines: Self.longChat)
        let (longer, longerDir) = try Self.engine(lines: Self.longChat, copies: 4)
        defer { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: longerDir) }
        let whole = Self.time("open, whole log (read + replay)", runs: 3) {
            TimelinePage.whole(engine: engine, sessionId: "long", providerId: "claude").timeline.entries.count
        }
        let page = Self.time("open, newest page (read + replay)") {
            TimelinePage.newest(engine: engine, sessionId: "long", providerId: "claude", bytes: Self.page)?.entries.count ?? 0
        }
        let longerPage = Self.time("open, newest page of a log 4× as long") {
            TimelinePage.newest(engine: longer, sessionId: "long", providerId: "claude", bytes: Self.page)?.entries.count ?? 0
        }
        // Budgets against the same machine's own timings, so a loaded CI
        // runner doesn't fail them: what shows at once is a small part of a
        // long chat, and costs the same however long the chat grows.
        #expect(page * 4 < whole)
        #expect(longerPage < page * 2)
    }

    @Test func sendingToALongChat() throws {
        let (engine, dir) = try Self.engine(lines: Self.longChat)
        defer { try? FileManager.default.removeItem(at: dir) }
        // A chat whose agent isn't running logs your message before starting it.
        let ms = Self.time("send: log the message", runs: 10) {
            engine.record(sessionId: "long", OutputLine(stream: .user, line: "Again"))
        }
        #expect(ms < 15)
    }

    // MARK: Profile

    static func profileStore() throws -> Store {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nav-bench-\(UUID().uuidString)")
        let store = try Store(path: dir.appendingPathComponent("abstract.sqlite").path)
        let (projects, sessions) = SyntheticChats.profile()
        for project in projects { try store.save(project) }
        for session in sessions { try store.save(session) }
        for (i, project) in projects.prefix(10).enumerated() {
            try store.save(Automation(name: "Nightly \(i)", prompt: "Bump", providerId: "claude", projectId: project.id,
                                      triggers: [AutomationTrigger(rrule: "FREQ=DAILY;BYHOUR=9", timezone: "UTC")]))
        }
        return store
    }

    /// A chat's log of `lines` lines, written `copies` times over.
    static func engine(lines: Int, copies: Int = 1) throws -> (SessionEngine, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nav-bench-\(UUID().uuidString)")
        let engine = SessionEngine(executor: LocalExecutor.shared, logDirectory: dir)
        let encoder = JSONEncoder()
        let text = SyntheticChats.log(lines: lines).map { String(decoding: try! encoder.encode($0), as: UTF8.self) }.joined(separator: "\n") + "\n"
        try String(repeating: text, count: copies).write(to: dir.appendingPathComponent("long.jsonl"), atomically: true, encoding: .utf8)
        return (engine, dir)
    }

    /// Milliseconds for the fastest of `runs` runs of `body`, after one to
    /// warm up: a run the machine held up doesn't count against it.
    @discardableResult
    static func time(_ label: String, runs: Int = 10, _ body: () -> Int) -> Double {
        var acc = body()
        var fastest = Double.infinity
        for _ in 0..<runs {
            let start = ContinuousClock.now
            acc &+= body()
            let elapsed = ContinuousClock.now - start
            fastest = min(fastest, Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)
        }
        report("\(label): \((fastest * 100).rounded() / 100) ms (\(acc))")
        return fastest
    }

    static func report(_ line: String) {
        FileHandle.standardError.write(Data("BENCH \(line)\n".utf8))
    }
}
