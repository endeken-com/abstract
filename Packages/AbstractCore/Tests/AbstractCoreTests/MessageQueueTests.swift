import Foundation
import Testing
@testable import AbstractCore

@Suite("Messages sent while the agent works")
struct MessageQueueTests {
    @Test func midTurnMessagesWaitForEachAgentsTurnToEnd() {
        // Claude reads stdin: mid-turn while it runs or asks; between turns while idle.
        #expect(FollowUp.route(.stdin, alive: true, status: .running) == .queue)
        #expect(FollowUp.route(.stdin, alive: true, status: .waitingInput) == .queue)
        #expect(FollowUp.route(.stdin, alive: true, status: .idle) == .send)
        #expect(FollowUp.route(.stdin, alive: false, status: .finished) == .send)
        // Codex and OpenCode: one process per turn, so mid-turn while it lives.
        #expect(FollowUp.route(.respawn, alive: true, status: .running) == .queue)
        #expect(FollowUp.route(.respawn, alive: true, status: .idle) == .queue)
        #expect(FollowUp.route(.respawn, alive: false, status: .running) == .queue)
        #expect(FollowUp.route(.respawn, alive: false, status: .finished) == .send)
        #expect(FollowUp.route(.respawn, alive: false, status: .errored) == .send)
        // A handover in progress is a turn too.
        #expect(FollowUp.route(.stdin, alive: false, status: .idle, handingOff: true) == .queue)
    }

    @Test func onlyClaudeCanBeSteeredAndTheOthersSayWhy() {
        #expect(FollowUp.canSteer(.stdin, alive: true, status: .running))
        #expect(FollowUp.canSteer(.stdin, alive: true, status: .waitingInput))
        #expect(!FollowUp.canSteer(.stdin, alive: true, status: .idle))
        #expect(!FollowUp.canSteer(.respawn, alive: true, status: .running))
        #expect(FollowUp.steerUnavailable(ClaudeProvider()) == nil)
        #expect(FollowUp.steerUnavailable(CodexProvider()) == "Codex reads messages between turns")
        #expect(FollowUp.steerUnavailable(OpenCodeProvider()) == "OpenCode reads messages between turns")
    }

    @Test func theQueueGoesAfterAFinishedOrInterruptedTurnOnly() {
        for status in [SessionStatus.idle, .finished] {
            #expect(FollowUp.sendsQueue(after: status, stopped: false, interrupting: false))
            #expect(FollowUp.sendsQueue(after: status, stopped: true, interrupting: true))
            #expect(!FollowUp.sendsQueue(after: status, stopped: true, interrupting: false))
        }
        #expect(!FollowUp.sendsQueue(after: .errored, stopped: false, interrupting: false))
        #expect(!FollowUp.sendsQueue(after: .running, stopped: false, interrupting: false))
    }

    @Test func queuedMessagesJoinIntoOneInOrder() {
        let file = PromptAttachment(id: "a", kind: .file, title: "notes.md", path: "/tmp/notes.md")
        let joined = FollowUp.joined([QueuedMessage(text: "also update the README\n"),
                                      QueuedMessage(text: "  "),
                                      QueuedMessage(text: "and the changelog", attachments: [file])])
        #expect(joined.text == "also update the README\n\nand the changelog")
        #expect(joined.attachments == [file])
    }

    @Test func aLineThatDeliversNoQueueIsLoggedAsBefore() throws {
        let data = try JSONEncoder().encode(OutputLine(stream: .user, line: "hi"))
        #expect(!String(decoding: data, as: UTF8.self).contains("queued"))
        let old = try JSONDecoder().decode(OutputLine.self, from: Data(#"{"stream":"user","line":"hi"}"#.utf8))
        #expect(old.queued == nil)
    }
}

extension GitHeavy {
    @Suite("Session engine: queue, steer and interrupt", .serialized)
    struct SessionEngineQueueTests {
        private func makeEngine(_ dir: URL? = nil) -> (SessionEngine, URL) {
            let dir = dir ?? FileManager.default.temporaryDirectory.appendingPathComponent("queue-\(UUID().uuidString)")
            return (SessionEngine(executor: LocalExecutor.shared, logDirectory: dir), dir)
        }

        private func waitForExit(_ engine: SessionEngine, _ id: String) async {
            for _ in 0..<200 where engine.isAlive(id) { try? await Task.sleep(for: .milliseconds(25)) }
        }

        private func waitForLine(_ engine: SessionEngine, _ id: String, _ text: String) async -> Bool {
            for _ in 0..<200 {
                if engine.replay(sessionId: id).contains(where: { $0.line.line == text }) { return true }
                try? await Task.sleep(for: .milliseconds(25))
            }
            return false
        }

        /// What the app does when a turn ends: the queue goes as one message, once.
        private func deliver(_ engine: SessionEngine, _ id: String) -> String? {
            let queue = engine.queued(sessionId: id)
            guard !queue.isEmpty else { return nil }
            let message = PromptAttachments.message(FollowUp.joined(queue).text, FollowUp.joined(queue).attachments)
            engine.recordInput(sessionId: id, text: message, queued: queue.map(\.id))
            return message
        }

        @Test func perTurnAgentGetsTwoQueuedMessagesTogetherWhenItsTurnEnds() async throws {
            let (engine, dir) = makeEngine()
            defer { try? FileManager.default.removeItem(at: dir) }
            // Codex's turn: a process that runs, then exits.
            try engine.launch(sessionId: "codex", spec: LaunchSpec(command: "/bin/sh", args: ["-c", "sleep 0.3; echo turn one"],
                                                                   cwd: dir.path, keepStdinOpen: false))
            #expect(FollowUp.route(.respawn, alive: engine.isAlive("codex"), status: .running) == .queue)
            engine.enqueue(sessionId: "codex", QueuedMessage(text: "also update the README"))
            engine.enqueue(sessionId: "codex", QueuedMessage(text: "and the changelog"))
            #expect(engine.queued(sessionId: "codex").count == 2)
            await waitForExit(engine, "codex")
            #expect(FollowUp.route(.respawn, alive: engine.isAlive("codex"), status: .finished) == .send)

            let message = try #require(deliver(engine, "codex"))
            #expect(message == "also update the README\n\nand the changelog")
            // The next turn starts with it as its prompt.
            try engine.launch(sessionId: "codex", spec: LaunchSpec(command: "/bin/echo", args: ["got: " + message], cwd: dir.path, keepStdinOpen: false))
            #expect(await waitForLine(engine, "codex", "got: also update the README"))
            #expect(await waitForLine(engine, "codex", "and the changelog"))
            #expect(engine.queued(sessionId: "codex").isEmpty)
            #expect(deliver(engine, "codex") == nil)
            let users = engine.replay(sessionId: "codex").filter { $0.line.stream == .user }
            #expect(users.map(\.line.line) == [message])
        }

        @Test func steerReachesAStdinAgentMidTurn() async throws {
            let (engine, dir) = makeEngine()
            defer { try? FileManager.default.removeItem(at: dir) }
            // Claude's turn: a process that reads what it's sent while it works.
            try engine.launch(sessionId: "claude", spec: LaunchSpec(command: "/bin/sh", args: ["-c", "read line; echo heard: $line; sleep 5"],
                                                                    cwd: dir.path, keepStdinOpen: true))
            defer { engine.stop(sessionId: "claude") }
            #expect(FollowUp.canSteer(.stdin, alive: engine.isAlive("claude"), status: .running))
            engine.enqueue(sessionId: "claude", QueuedMessage(text: "use the new API"))
            let message = try #require(deliver(engine, "claude"))
            try engine.write(sessionId: "claude", message + "\n")
            #expect(await waitForLine(engine, "claude", "heard: use the new API"))
            #expect(engine.isAlive("claude"))
            #expect(engine.queued(sessionId: "claude").isEmpty)
        }

        @Test func interruptEndsTheTurnAndTheQueueGoesAtOnce() async throws {
            let (engine, dir) = makeEngine()
            defer { try? FileManager.default.removeItem(at: dir) }
            try engine.launch(sessionId: "s", spec: LaunchSpec(command: "/bin/sh", args: ["-c", "sleep 30"], cwd: dir.path, keepStdinOpen: false))
            engine.enqueue(sessionId: "s", QueuedMessage(text: "stop, do this instead"))
            engine.stop(sessionId: "s")
            await waitForExit(engine, "s")
            #expect(!engine.isAlive("s"))
            #expect(FollowUp.sendsQueue(after: .idle, stopped: true, interrupting: true))
            #expect(deliver(engine, "s") == "stop, do this instead")
            #expect(engine.queued(sessionId: "s").isEmpty)
        }

        @Test func queuedMessagesCanBeEditedOrRemovedUntilTheyGo() throws {
            let (engine, dir) = makeEngine()
            defer { try? FileManager.default.removeItem(at: dir) }
            let a = QueuedMessage(text: "frist"), b = QueuedMessage(text: "second")
            engine.enqueue(sessionId: "s", a)
            engine.enqueue(sessionId: "s", b)
            #expect(engine.editQueued(sessionId: "s", id: a.id, text: "first"))
            #expect(engine.removeQueued(sessionId: "s", id: b.id)?.text == "second")
            #expect(engine.queued(sessionId: "s").map(\.text) == ["first"])
            _ = deliver(engine, "s")
            #expect(!engine.editQueued(sessionId: "s", id: a.id, text: "too late"))
            #expect(engine.removeQueued(sessionId: "s", id: a.id) == nil)
        }

        @Test func theQueueSurvivesARelaunch() throws {
            let (engine, dir) = makeEngine()
            defer { try? FileManager.default.removeItem(at: dir) }
            let file = PromptAttachment(id: "f", kind: .file, title: "a.txt", path: "/tmp/a.txt")
            engine.enqueue(sessionId: "s", QueuedMessage(text: "one"))
            engine.enqueue(sessionId: "s", QueuedMessage(text: "two", attachments: [file]))
            let (relaunched, _) = makeEngine(dir)
            #expect(relaunched.queued(sessionId: "s").map(\.text) == ["one", "two"])
            #expect(relaunched.queued(sessionId: "s").last?.attachments == [file])
            // Sent: gone for good, and the file beside the log with it.
            _ = deliver(relaunched, "s")
            #expect(makeEngine(dir).0.queued(sessionId: "s").isEmpty)
            #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("s.queue.json").path))
        }

        @Test func aRelaunchMidSendNeitherLosesNorRepeatsAMessage() throws {
            let (_, dir) = makeEngine()
            defer { try? FileManager.default.removeItem(at: dir) }
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let logged = QueuedMessage(id: "logged", text: "made it into the log")
            let notLogged = QueuedMessage(id: "not-logged", text: "never written")
            let waiting = QueuedMessage(id: "waiting", text: "still waiting")
            // The app stopped after marking two as sending and logging one of them.
            var marked = [logged, notLogged, waiting]
            marked[0].sending = true
            marked[1].sending = true
            try JSONEncoder().encode(marked).write(to: dir.appendingPathComponent("s.queue.json"))
            let line = OutputLine(stream: .user, line: logged.text, at: Date(), queued: ["logged"])
            try (JSONEncoder().encode(line) + Data([0x0A])).write(to: dir.appendingPathComponent("s.jsonl"))

            let (engine, _) = makeEngine(dir)
            let queue = engine.queued(sessionId: "s")
            #expect(queue.map(\.id) == ["not-logged", "waiting"])
            #expect(queue.allSatisfy { $0.sending == nil })
            // Settled on disk too.
            #expect(makeEngine(dir).0.queued(sessionId: "s").map(\.id) == ["not-logged", "waiting"])
        }

        @Test func deletingAChatsLogDropsItsQueue() throws {
            let (engine, dir) = makeEngine()
            defer { try? FileManager.default.removeItem(at: dir) }
            engine.enqueue(sessionId: "s", QueuedMessage(text: "one"))
            engine.deleteLog(sessionId: "s")
            #expect(engine.queued(sessionId: "s").isEmpty)
            #expect(makeEngine(dir).0.queued(sessionId: "s").isEmpty)
        }
    }
}
