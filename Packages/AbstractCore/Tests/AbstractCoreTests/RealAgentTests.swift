import Foundation
import Testing
@testable import AbstractCore

/// Runs the real `claude` CLI through the engine and parser. Opt-in because it
/// needs the binary and a signed-in subscription:
///   ABSTRACT_E2E=1 swift test --filter RealAgent
@Suite("Real agent", .serialized, .enabled(if: ProcessInfo.processInfo.environment["ABSTRACT_E2E"] != nil))
struct RealAgentTests {
    @Test(.timeLimit(.minutes(3)))
    func claudeCompletesATurnInAWorktreeAndStaysAliveForFollowUps() async throws {
        let exec = LocalExecutor.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("real-agent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "t"]] {
            _ = try await exec.run("git", args, cwd: root.path)
        }
        try "hello\n".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        _ = try await exec.run("git", ["add", "-A"], cwd: root.path)
        _ = try await exec.run("git", ["commit", "-qm", "init"], cwd: root.path)

        let project = Project(name: "real", rootPath: root.path, defaultBaseRef: "main")
        let ws = try await Workspace.provision(executor: exec, project: project, name: "Create hi file",
                                               baseRef: "main", template: root.path + "-wt/{slug}", prefix: "abstract/")
        defer { try? FileManager.default.removeItem(atPath: root.path + "-wt") }

        let provider = ClaudeProvider()
        let spec = provider.buildLaunch(LaunchContext(cwd: ws.path, prompt: "Create a file named hi.txt containing the word hi. Then stop.",
                                                      permissionPolicy: .autoEdits))
        let engine = SessionEngine(executor: exec, logDirectory: root.appendingPathComponent("logs"))
        try engine.launch(sessionId: "real", spec: spec)

        let parser = provider.makeParser()
        var timeline = Timeline()
        var idle = false
        var raw: [String] = []
        for await event in engine.events {
            guard case let .line(_, _, line) = event else { break }
            for e in parser.feed(line.line, stream: line.stream) {
                timeline.append(e)
                if case .status(.idle, _) = e { idle = true }
                if case let .raw(l, s) = e, s == .stdout { raw.append(l) }
            }
            if idle { break }
        }
        #expect(idle, "the turn finished and the agent is waiting for a follow-up")
        #expect(engine.isAlive("real"), "stdin stays open so follow-ups reuse the process")
        #expect(FileManager.default.fileExists(atPath: ws.path + "/hi.txt"), "the agent worked inside its worktree")
        #expect(!FileManager.default.fileExists(atPath: root.path + "/hi.txt"), "the main working tree was not touched")
        #expect(raw.isEmpty, "every stdout frame was understood: \(raw.prefix(3))")

        let files = try await Diff.collect(exec, worktree: ws.path, exclude: [])
        #expect(files.contains { $0.path == "hi.txt" && $0.status == .added }, "the new file shows up for review")

        engine.stop(sessionId: "real")
        for await event in engine.events { if case .exit = event { break } }
        #expect(!engine.isAlive("real"))
    }

    /// OpenCode runs a turn per process; the follow-up resumes its session.
    /// Uses OpenCode's free model unless ABSTRACT_OPENCODE_MODEL names another.
    @Test(.timeLimit(.minutes(3)))
    func openCodeRunsATurnAndResumesItsSession() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("real-opencode-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let provider = OpenCodeProvider()
        let model = ProcessInfo.processInfo.environment["ABSTRACT_OPENCODE_MODEL"] ?? "opencode/big-pickle"
        let engine = SessionEngine(executor: LocalExecutor.shared, logDirectory: dir.appendingPathComponent("logs"))

        func turn(_ spec: LaunchSpec) async throws -> (events: [AgentEvent], raw: [String]) {
            try engine.launch(sessionId: "opencode", spec: spec)
            let parser = provider.makeParser()
            var events: [AgentEvent] = [], raw: [String] = []
            for await event in engine.events {
                switch event {
                case let .line(_, _, line):
                    for e in parser.feed(line.line, stream: line.stream) {
                        events.append(e)
                        if case let .raw(l, s) = e, s == .stdout { raw.append(l) }
                    }
                case let .exit(_, code):
                    return (events + parser.onExit(code: code), raw)
                }
            }
            return (events, raw)
        }

        let context = LaunchContext(cwd: dir.path, prompt: "Create a file named hi.txt containing the word hi. Then stop.",
                                    permissionPolicy: .bypass, model: model)
        let first = try await turn(provider.buildLaunch(context))
        #expect(first.raw.isEmpty, "every stdout frame was understood: \(first.raw.prefix(3))")
        #expect(first.events.contains(.status(.finished, detail: nil)))
        #expect(FileManager.default.fileExists(atPath: dir.path + "/hi.txt"), "the agent worked in its own directory")
        let sessionId = try #require(first.events.lazy.compactMap { if case let .sessionId(id) = $0 { id } else { nil } }.first)

        var followUp = context
        followUp.prompt = "What is the name of the file you just created? Reply with the file name only."
        let second = try await turn(provider.buildResume(followUp, resumeId: sessionId))
        #expect(second.events.contains(.sessionId(sessionId)), "the follow-up continued the same session")
        #expect(second.events.contains { if case let .text(.assistant, text, _, _) = $0 { text.contains("hi.txt") } else { false } })
    }

    @Test(.timeLimit(.minutes(3)))
    func askModeRoutesAnApprovalThroughAbstractAndAllowRunsTheTool() async throws {
        let exec = LocalExecutor.shared
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("real-ask-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try await exec.run("git", ["init", "-q"], cwd: dir.path)

        let provider = ClaudeProvider()
        let spec = provider.buildLaunch(LaunchContext(cwd: dir.path, prompt: "Use the Bash tool to run exactly: touch probe.txt. Do nothing else.",
                                                      permissionPolicy: .ask))
        let engine = SessionEngine(executor: exec, logDirectory: dir.appendingPathComponent("logs"))
        try engine.launch(sessionId: "ask", spec: spec)
        let parser = provider.makeParser()
        var asked = false, idle = false
        for await event in engine.events {
            guard case let .line(_, _, line) = event else { break }
            for e in parser.feed(line.line, stream: line.stream) {
                if case let .permissionRequest(requestId, tool, input) = e, !asked {
                    asked = true
                    #expect(tool == "Bash")
                    try engine.write(sessionId: "ask", provider.buildPermissionResponse(requestId: requestId, allow: true, input: input)!)
                }
                if case .status(.idle, _) = e { idle = true }
            }
            if idle { break }
        }
        engine.stop(sessionId: "ask")
        #expect(asked, "claude asked Abstract instead of silently denying")
        #expect(FileManager.default.fileExists(atPath: dir.path + "/probe.txt"), "allowing ran the command")
    }

    /// Even with nothing else asking, a question waits for you, and the
    /// answer sent back as its allowed input is what the agent hears.
    @Test(.timeLimit(.minutes(3)))
    func claudeAsksItsQuestionsThroughAbstractAndHearsTheAnswer() async throws {
        let exec = LocalExecutor.shared
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("real-question-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let provider = ClaudeProvider()
        let prompt = "Use the AskUserQuestion tool to ask me which color I prefer, with the options Red and Blue. "
            + "Then reply with only the color I chose, in capitals."
        let spec = provider.buildLaunch(LaunchContext(cwd: dir.path, prompt: prompt, permissionPolicy: .bypass))
        let engine = SessionEngine(executor: exec, logDirectory: dir.appendingPathComponent("logs"))
        try engine.launch(sessionId: "question", spec: spec)
        let parser = provider.makeParser()
        var asked = false, idle = false, reply = ""
        for await event in engine.events {
            guard case let .line(_, _, line) = event else { break }
            for e in parser.feed(line.line, stream: line.stream) {
                switch e {
                case let .permissionRequest(requestId, tool, input) where !asked:
                    asked = true
                    #expect(AgentQuestion.isQuestion(tool))
                    let question = try #require(AgentQuestion.parse(input).first)
                    #expect(question.options.map(\.label).contains("Blue"))
                    let answered = AgentQuestion.answeredInput(input, answers: [question.question: "Blue"])
                    try engine.write(sessionId: "question", provider.buildPermissionResponse(requestId: requestId, allow: true, input: answered)!)
                case let .text(.assistant, text, _, false): reply = text
                case .status(.idle, _): idle = true
                default: break
                }
            }
            if idle { break }
        }
        engine.stop(sessionId: "question")
        #expect(asked, "the question came to Abstract, even with full autonomy")
        #expect(reply.contains("BLUE"), "the agent heard the answer")
    }

    /// A command the agent leaves running in the background is a task
    /// Abstract lists, with its output file, and can stop.
    @Test(.timeLimit(.minutes(3)))
    func claudeRunsABackgroundCommandThatAbstractCanStop() async throws {
        let (engine, provider, dir) = try launch("background", prompt: "Run the Bash command `sleep 120; echo late` with run_in_background set to true. "
            + "Then reply with only the word STARTED.")
        defer { try? FileManager.default.removeItem(at: dir) }
        let parser = provider.makeParser()
        var timeline = Timeline()
        var stopSent = false
        var ended: AgentTask?
        for await event in engine.events {
            guard case let .line(_, _, line) = event else { break }
            timeline.append(contentsOf: parser.feed(line.line, stream: line.stream))
            if !stopSent, let task = timeline.tasks.first(where: { $0.isBackgrounded && $0.kind == .shell }) {
                stopSent = true
                try engine.write(sessionId: "background", provider.buildStopTask(task.id, requestId: "stop-1")!)
            }
            if let task = timeline.tasks.first(where: { $0.kind == .shell && $0.status != .running }) { ended = task; break }
        }
        engine.stop(sessionId: "background")
        #expect(stopSent, "the command became a background task")
        #expect(ended?.status == .stopped, "stop_task ended it: \(String(describing: ended))")
        #expect(ended?.outputFile?.hasSuffix(".output") == true)
    }

    /// Ctrl+B over the control channel: a command working in the foreground
    /// moves to the background, and its call returns while it still runs.
    @Test(.timeLimit(.minutes(3)))
    func claudeMovesAForegroundCommandToTheBackground() async throws {
        // Not `sleep`: the CLI refuses a foreground sleep and says to use run_in_background.
        let (engine, provider, dir) = try launch("foreground", prompt: "Run the Bash command `ping -c 90 127.0.0.1 > /dev/null; echo done` in the foreground "
            + "(do not set run_in_background). Then reply with only the word FINISHED.")
        defer { try? FileManager.default.removeItem(at: dir) }
        let parser = provider.makeParser()
        var timeline = Timeline()
        var moved: AgentTask?
        var returnedWhileRunning = false
        loop: for await event in engine.events {
            guard case let .line(_, _, line) = event else { break }
            for e in parser.feed(line.line, stream: line.stream) {
                timeline.append(e)
                if case let .toolResult(toolUseId, _, _, _) = e, let moved, toolUseId == moved.toolUseId {
                    returnedWhileRunning = timeline.tasks.first { $0.id == moved.id }?.status == .running
                    break loop
                }
            }
            // It becomes a task after several seconds at work.
            if moved == nil, let task = timeline.tasks.first(where: { $0.kind == .shell && !$0.isBackgrounded && !$0.ownedBySubagent }) {
                moved = task
                try engine.write(sessionId: "foreground", provider.buildBackground(toolUseId: task.toolUseId, requestId: "bg-1")!)
            }
        }
        engine.stop(sessionId: "foreground")
        #expect(moved != nil, "the long command became a task that could be moved")
        #expect(timeline.tasks.first { $0.kind == .shell }?.isBackgrounded == true, "it is now a background task")
        #expect(returnedWhileRunning, "its call returned while the command carried on")
    }

    /// Claude in a fresh folder with full autonomy, on the smallest model.
    private func launch(_ id: String, prompt: String) throws -> (SessionEngine, ClaudeProvider, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("real-\(id)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let provider = ClaudeProvider()
        let spec = provider.buildLaunch(LaunchContext(cwd: dir.path, prompt: prompt, permissionPolicy: .bypass, model: "haiku"))
        let engine = SessionEngine(executor: LocalExecutor.shared, logDirectory: dir.appendingPathComponent("logs"))
        try engine.launch(sessionId: id, spec: spec)
        return (engine, provider, dir)
    }
}

/// Drafts an automation with the real `claude` CLI:
///   ABSTRACT_E2E=1 swift test --filter RealDrafting
@Suite("Real drafting", .enabled(if: ProcessInfo.processInfo.environment["ABSTRACT_E2E"] != nil))
struct RealDraftingTests {
    @Test(.timeLimit(.minutes(2)))
    func claudeDraftsAScheduleProjectAndInstructions() async throws {
        let proposal = try await AutomationDrafting.draft(
            executor: LocalExecutor.shared, binary: nil, providerId: "claude",
            description: "Every weekday at 9am, look at the issues opened in payments-api since yesterday, label them, and open a chat to fix each easy one.",
            projects: ["abstract", "payments-api"], timezone: "Europe/Lisbon")
        #expect(proposal.project == "payments-api")
        #expect(proposal.schedules.count == 1)
        #expect(proposal.schedules.first.map { Schedule.preset(of: $0).preset } == .weekdays)
        #expect(proposal.continuesOwnChat, "it coordinates other chats")
        #expect(proposal.instructions.count > 80)
        print("drafted:", proposal.name, proposal.schedules, proposal.policy, "\n", proposal.instructions)
    }
}
