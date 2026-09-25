// `abstract`, run as a user would: the built binary against a throwaway data
// folder and repository, with a stand-in for `claude` that speaks enough of
// its stream-json.

import Foundation
import Testing
@testable import AbstractCore

/// How the stand-in agent behaves.
private enum FakeAgent {
    /// Answers every message, and asks for Bash when a message says ASK.
    case responsive
    /// Answers the prompt, then exits.
    case exitsAfterTurn
    /// Complains on stderr and exits before saying anything.
    case failsToStart
    /// Starts up, then reports an error, as `claude` does when it isn't signed in; stays alive.
    case errorsAfterInit
    /// Takes three seconds over the prompt's turn, then answers every message.
    case slowTurn

    var script: String {
        let result = #"{"type":"result","subtype":"success","is_error":false,"result":"ok","session_id":"fake-session","usage":{"input_tokens":1,"output_tokens":1},"total_cost_usd":0,"duration_ms":1,"num_turns":1}"#
        let ask = #"{"type":"control_request","request_id":"req-1","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"ls"}}}"#
        switch self {
        case .responsive:
            return """
                #!/bin/sh
                printf '%s\\n' "$@" --- >> "$(dirname "$0")/args.log"
                env > "$(dirname "$0")/env.log"
                echo '{"type":"system","subtype":"init","session_id":"fake-session","model":"fake"}'
                while IFS= read -r line; do
                  case "$line" in
                    *control_response*) echo "$line" >> "$(dirname "$0")/answers.log"; echo '\(result)' ;;
                    *ASK*) echo '\(ask)' ;;
                    *) echo '\(result)' ;;
                  esac
                done
                """
        case .exitsAfterTurn:
            return """
                #!/bin/sh
                echo '{"type":"system","subtype":"init","session_id":"fake-session","model":"fake"}'
                read -r line
                echo '\(result)'
                """
        case .failsToStart:
            return "#!/bin/sh\necho 'not signed in' >&2\nexit 3\n"
        case .slowTurn:
            return """
                #!/bin/sh
                echo '{"type":"system","subtype":"init","session_id":"fake-session","model":"fake"}'
                read -r line
                echo '{"type":"stream_event","event":{"type":"message_start","message":{"id":"m1"}}}'
                sleep 3
                echo '\(result)'
                while IFS= read -r line; do echo '\(result)'; done
                """
        case .errorsAfterInit:
            let failed = #"{"type":"result","subtype":"success","is_error":true,"result":"Invalid API key · Please run /login","session_id":"fake-session","usage":{"input_tokens":0,"output_tokens":0},"total_cost_usd":0,"duration_ms":1,"num_turns":1}"#
            return """
                #!/bin/sh
                echo '{"type":"system","subtype":"init","session_id":"fake-session","model":"fake"}'
                read -r line
                echo '\(failed)'
                while IFS= read -r line; do :; done
                """
        }
    }
}

private struct Output {
    let status: Int32
    let stdout: String
    let json: Any?

    var object: [String: Any] { json as? [String: Any] ?? [:] }
    var code: String? { object["code"] as? String }
}

/// A data folder, a repository with one commit and a project for it, and the stand-in agent.
private final class Sandbox {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("abstract-cli-\(UUID().uuidString)")
    var data: URL { root.appendingPathComponent("data") }
    var repo: URL { root.appendingPathComponent("repo") }
    var locks: URL { data.appendingPathComponent("locks") }
    var storePath: String { data.appendingPathComponent("abstract.sqlite").path }
    let store: Store
    let project: Project

    init(agent: FakeAgent = .responsive, baseRef: String = "main") async throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("repo"), withIntermediateDirectories: true)
        let repoPath = root.appendingPathComponent("repo").path
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "test@abstract.local"],
                     ["config", "user.name", "Abstract Test"], ["config", "commit.gpgsign", "false"],
                     ["commit", "-q", "--allow-empty", "-m", "init"]] {
            let out = try await LocalExecutor.shared.run("git", args, cwd: repoPath)
            try #require(out.ok, "git \(args): \(out.stderr)")
        }
        store = try Store(path: root.appendingPathComponent("data/abstract.sqlite").path)
        project = Project(name: "Sandbox", rootPath: repoPath, defaultBaseRef: baseRef, defaultPermissionPolicy: .autoEdits)
        try store.save(project)
        try store.setSetting("worktreeTemplate", root.path + "/worktrees/{slug}")
        try use(agent)
    }

    func use(_ agent: FakeAgent) throws {
        let url = root.appendingPathComponent("agents/\(agent)/claude")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try agent.script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        try store.setSetting("providerOverrides", ["claude": ProviderOverride(path: url.path)])
    }

    func useMissingAgent() throws {
        try store.setSetting("providerOverrides", ["claude": ProviderOverride(path: root.path + "/no-such-claude")])
    }

    var argsLog: String { (try? String(contentsOf: root.appendingPathComponent("agents/responsive/args.log"), encoding: .utf8)) ?? "" }
    var envLog: String { (try? String(contentsOf: root.appendingPathComponent("agents/responsive/env.log"), encoding: .utf8)) ?? "" }
    var answersLog: String { (try? String(contentsOf: root.appendingPathComponent("agents/responsive/answers.log"), encoding: .utf8)) ?? "" }

    /// Runs `abstract`, checking it printed exactly one JSON value. On a
    /// thread of its own: it waits seconds for an agent, and the test pool has
    /// few threads to spare for the other suites' processes.
    @discardableResult
    func run(_ args: [String], stdin: String? = nil, environment extra: [String: String] = [:]) async throws -> Output {
        var environment = ProcessInfo.processInfo.environment
        environment["ABSTRACT_DATA_DIR"] = data.path
        // The CLI and its host each look up the login shell's PATH; a plain
        // shell keeps that quick whatever the runner's own profile does.
        environment["SHELL"] = "/bin/sh"
        environment.merge(extra) { _, new in new }
        let (status, data) = try await withCheckedThrowingContinuation { (done: CheckedContinuation<(Int32, Data), any Error>) in
            Thread.detachNewThread { [environment] in
                done.resume(with: Result { try Self.runBlocking(args, stdin: stdin, environment: environment) })
            }
        }
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.split(separator: "\n")
        #expect(lines.count == 1, "stdout should be one JSON line: \(text)")
        let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        #expect(json != nil, "stdout isn't JSON: \(text)")
        return Output(status: status, stdout: text, json: json)
    }

    static func runBlocking(_ args: [String], stdin: String?, environment: [String: String]) throws -> (Int32, Data) {
        let process = Process()
        process.executableURL = binary
        process.arguments = args
        process.environment = environment
        let out = Pipe(), input = Pipe()
        process.standardOutput = out
        process.standardInput = input
        process.standardError = FileHandle.nullDevice
        try process.run()
        if let stdin { input.fileHandleForWriting.write(Data(stdin.utf8)) }
        try input.fileHandleForWriting.close()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, data)
    }

    /// `session create` with a prompt on stdin.
    func create(name: String = "Fix the login", branch: String = "fix/login", prompt: String = "Fix the login button",
                environment: [String: String] = [:]) async throws -> Output {
        try await run(["session", "create", "--project", project.id, "--name", name, "--branch", branch, "--agent", "claude",
                 "--prompt-file", "-"], stdin: prompt, environment: environment)
    }

    func file(_ text: String) throws -> String {
        let url = root.appendingPathComponent("text-\(UUID().uuidString).txt")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    func log(_ sessionId: String) -> [OutputLine] {
        SessionEngine(executor: LocalExecutor.shared, logDirectory: data.appendingPathComponent("sessions"))
            .replay(sessionId: sessionId).map(\.line)
    }

    func branches() async throws -> [String] {
        let out = try await LocalExecutor.shared.run("git", ["branch", "--format=%(refname)"], cwd: repo.path)
        return out.stdout.split(separator: "\n").map { String($0.dropFirst("refs/heads/".count)) }
    }

    /// Stops a running host as the app's Stop does, and waits until it's gone.
    func stopAgent(_ sessionId: String) async throws {
        guard let holder = SessionLock.holder(of: sessionId, in: locks) else { return }
        kill(holder.pid, SIGTERM)
        try await waitUntil { SessionLock.holder(of: sessionId, in: self.locks) == nil }
    }

    func tearDown() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: locks.path)) ?? []
        for name in names where name.hasSuffix(".json") {
            if let holder = SessionLock.holder(of: String(name.dropLast(5)), in: locks), holder.pid != getpid() {
                kill(holder.pid, SIGTERM)
            }
        }
        usleep(300_000)
        try? FileManager.default.removeItem(at: root)
    }

    /// The built `abstract`, beside this test bundle's resources.
    static var binary: URL { Bundle.module.bundleURL.deletingLastPathComponent().appendingPathComponent("abstract") }
}

private func waitUntil(timeout: TimeInterval = 10, _ condition: @escaping () throws -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if try condition() { return }
        try await Task.sleep(for: .milliseconds(50))
    }
    Issue.record("Timed out waiting")
}

@Suite("abstract command line", .serialized)
struct CommandLineTests {
    // MARK: session create

    @Test func createMakesAnOrdinaryChat() async throws {
        let box = try await Sandbox()
        defer { box.tearDown() }
        let out = try await box.create()
        #expect(out.status == 0)
        let id = try #require(out.object["id"] as? String)
        let agent = try #require(out.object["agent"] as? [String: Any])
        #expect(agent["driver"] as? String == "cli")
        #expect(agent["provider"] as? String == "claude")

        let session = try #require(try box.store.session(id))
        #expect(session.projectId == box.project.id)
        #expect(session.name == "Fix the login")
        #expect(session.branch == "fix/login")
        #expect(session.providerId == "claude")
        #expect(session.prompt == "Fix the login button")
        #expect(session.baseRef == "main")
        #expect(session.permissionPolicy == .autoEdits)
        let path = try #require(session.worktreePath)
        #expect(path.hasPrefix(box.root.path + "/worktrees/"))
        #expect(try await Git.currentBranch(LocalExecutor.shared, root: path) == "fix/login")
        #expect(try await box.branches().contains("fix/login"))
        // The prompt opens the chat's log, then the agent's output, as when the app starts a chat.
        try await waitUntil { box.log(id).count >= 3 }
        #expect(box.log(id).first == OutputLine(stream: .user, line: "Fix the login button"))
        try await waitUntil { try box.store.session(id)?.status == .idle }
        #expect(try box.store.session(id)?.providerSessionId == "fake-session")
        #expect(!box.argsLog.contains("--resume"))
    }

    @Test func createTellsARunningAppAboutIt() async throws {
        let box = try await Sandbox()
        defer { box.tearDown() }
        let heard = Heard()
        let token = try #require(StoreChanges.observe(storePath: box.data.appendingPathComponent("abstract.sqlite").path,
                                                      queue: .global()) { heard.mark() })
        defer { StoreChanges.stop(token) }
        #expect(try await box.create().status == 0)
        try await waitUntil { heard.count > 0 }
    }

    @Test func nameTaken() async throws {
        let box = try await Sandbox()
        defer { box.tearDown() }
        #expect(try await box.create(name: "Nightly", branch: "one").status == 0)
        let out = try await box.create(name: "Nightly", branch: "two")
        #expect(out.status != 0)
        #expect(out.code == "name_taken")
        #expect(try await !box.branches().contains("two"))
    }

    @Test func anArchivedSessionsNameIsFree() async throws {
        let box = try await Sandbox()
        defer { box.tearDown() }
        var old = Session(projectId: box.project.id, name: "Nightly", providerId: "claude")
        old.archivedAt = Date()
        try box.store.save(old)
        #expect(try await box.create(name: "Nightly", branch: "nightly").status == 0)
    }

    @Test func branchExists() async throws {
        let box = try await Sandbox()
        defer { box.tearDown() }
        _ = try await LocalExecutor.shared.run("git", ["branch", "stray"], cwd: box.repo.path)
        let stray = try await box.create(branch: "stray")
        #expect(stray.status != 0)
        #expect(stray.code == "branch_exists")

        #expect(try await box.create(name: "First", branch: "mine").status == 0)
        let owned = try await box.create(name: "Second", branch: "mine")
        #expect(owned.code == "branch_exists")
        #expect(try box.store.sessions().count == 1)
    }

    @Test func theBranchIsUsedExactlyAsGiven() async throws {
        let box = try await Sandbox()
        defer { box.tearDown() }
        try box.store.setSetting("branchPrefix", "abstract/")
        let out = try await box.create(branch: "Team/ABC-123_fix")
        #expect(out.object["branch"] as? String == "Team/ABC-123_fix")
        #expect(try await box.branches().contains("Team/ABC-123_fix"))
    }

    @Test func aFailedStartLeavesNothingBehind() async throws {
        let box = try await Sandbox(agent: .failsToStart)
        defer { box.tearDown() }
        let out = try await box.create(branch: "doomed")
        #expect(out.status != 0)
        #expect(out.code == "agent_start_failed")
        #expect((out.object["message"] as? String)?.contains("not signed in") == true)
        try expectNothingLeft(box, branch: "doomed")
        #expect(try await !box.branches().contains("doomed"))

        // The same when the agent's binary isn't there at all.
        try box.useMissingAgent()
        #expect(try await box.create(branch: "doomed").code == "agent_start_failed")
        try expectNothingLeft(box, branch: "doomed")
        #expect(try await !box.branches().contains("doomed"))
    }

    @Test func anAgentThatCantWorkIsAFailedStart() async throws {
        let box = try await Sandbox(agent: .errorsAfterInit)
        defer { box.tearDown() }
        let out = try await box.create(branch: "unsigned")
        #expect(out.code == "agent_start_failed")
        #expect((out.object["message"] as? String)?.contains("Invalid API key") == true)
        try expectNothingLeft(box, branch: "unsigned")
        #expect(try await !box.branches().contains("unsigned"))
    }

    @Test func theCallersEnvironmentStaysOut() async throws {
        let box = try await Sandbox()
        defer { box.tearDown() }
        let out = try await box.create(environment: ["ANTHROPIC_API_KEY": "sk-leak", "CLAUDE_CONFIG_DIR": "/tmp/elsewhere",
                                               "CLAUDECODE": "1"])
        #expect(out.status == 0)
        try await waitUntil { !box.envLog.isEmpty }
        #expect(!box.envLog.contains("sk-leak"))
        #expect(!box.envLog.contains("/tmp/elsewhere"))
        #expect(!box.envLog.contains("CLAUDECODE"))
        #expect(box.envLog.contains("HOME="))
    }

    @Test func anIdleAgentStopsSoItCanBeRespawned() async throws {
        let box = try await Sandbox()
        defer { box.tearDown() }
        let idle = ["ABSTRACT_AGENT_IDLE_TIMEOUT": "1"]
        let id = try #require(try await box.create(environment: idle).object["id"] as? String)
        try await waitUntil { SessionLock.holder(of: id, in: box.locks) == nil }
        #expect(try box.store.session(id)?.status == .finished)
        #expect(try await box.run(["agent", "find", "--session", id]).json is NSNull)
        let out = try await box.run(["agent", "respawn", "--session", id, "--agent", "claude", "--prompt-file", box.file("Again")],
                              environment: idle)
        #expect(out.status == 0)
    }

    @Test func aTagOfTheSameNameIsNotABranch() async throws {
        let box = try await Sandbox()
        defer { box.tearDown() }
        _ = try await LocalExecutor.shared.run("git", ["tag", "release"], cwd: box.repo.path)
        #expect(try await box.create(branch: "release").status == 0)
        #expect(try await box.branches().contains("release"))
    }

    @Test func theSetupScriptRunsInTheWorktreeBeforeTheAgent() async throws {
        let box = try await Sandbox()
        defer { box.tearDown() }
        var project = box.project
        // The agent's arguments log doesn't exist yet when setup runs.
        project.setupScript = "pwd -P > setup-ran.txt\ntest ! -e '\(box.root.path)/agents/responsive/args.log' && echo first >> setup-ran.txt"
        try box.store.save(project)
        let out = try await box.create()
        #expect(out.status == 0)
        let id = try #require(out.object["id"] as? String)
        let path = try #require(try box.store.session(id)?.worktreePath)
        let ran = try String(contentsOfFile: path + "/setup-ran.txt", encoding: .utf8)
        #expect(ran.contains(URL(fileURLWithPath: path).lastPathComponent))
        #expect(ran.contains("first"))
    }

    @Test func aFailedSetupScriptLeavesNothingBehind() async throws {
        let box = try await Sandbox()
        defer { box.tearDown() }
        var project = box.project
        project.setupScript = "echo 'npm ERR! missing script'\nexit 7"
        try box.store.save(project)
        let out = try await box.create(branch: "set-up")
        #expect(out.code == "setup_failed")
        #expect((out.object["message"] as? String)?.contains("code 7") == true)
        #expect((out.object["message"] as? String)?.contains("npm ERR! missing script") == true)
        try expectNothingLeft(box, branch: "set-up")
        #expect(box.argsLog.isEmpty, "the agent never started")
    }

    @Test func interruptingTheSetupScriptLeavesNothingBehind() async throws {
        let box = try await Sandbox()
        defer { box.tearDown() }
        var project = box.project
        // The script's shell is the command's child: it says whose, then waits.
        let pidFile = box.root.path + "/cli.pid"
        project.setupScript = "echo $PPID > '\(pidFile)'\nsleep 30"
        try box.store.save(project)
        let started = Date()
        var environment = ProcessInfo.processInfo.environment
        environment["ABSTRACT_DATA_DIR"] = box.data.path
        environment["SHELL"] = "/bin/sh"
        let args = ["session", "create", "--project", box.project.id, "--name", "Interrupted", "--branch", "interrupted",
                    "--agent", "claude", "--prompt-file", "-"]
        let create = Task.detached { [environment] in try Sandbox.runBlocking(args, stdin: "Fix it", environment: environment) }
        try await waitUntil { FileManager.default.fileExists(atPath: pidFile) }
        try await waitUntil { try box.store.sessions().first?.statusDetail == "Running the setup script" }
        let pid = try #require(Int32(try String(contentsOfFile: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        kill(pid, SIGTERM)
        let (_, data) = try await create.value
        let out = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(out["code"] as? String == "setup_failed")
        #expect((out["message"] as? String)?.contains("was stopped") == true)
        #expect(Date().timeIntervalSince(started) < 20)
        try expectNothingLeft(box, branch: "interrupted")
    }

    @Test func worktreeFailedLeavesNothingBehind() async throws {
        let box = try await Sandbox(baseRef: "no-such-ref")
        defer { box.tearDown() }
        let out = try await box.create(branch: "based")
        #expect(out.code == "worktree_failed")
        try expectNothingLeft(box, branch: "based")
    }

    private func expectNothingLeft(_ box: Sandbox, branch: String) throws {
        #expect(try box.store.sessions().isEmpty)
        let worktrees = (try? FileManager.default.contentsOfDirectory(atPath: box.root.path + "/worktrees")) ?? []
        #expect(worktrees.isEmpty)
        let logs = (try? FileManager.default.contentsOfDirectory(atPath: box.data.path + "/sessions")) ?? []
        #expect(logs.isEmpty)
        let locks = (try? FileManager.default.contentsOfDirectory(atPath: box.locks.path)) ?? []
        #expect(locks.isEmpty)
    }

    // MARK: session list

    @Test func listShowsTheProjectsSessionsAndTheirAgents() async throws {
        let box = try await Sandbox()
        defer { box.tearDown() }
        let created = try await box.create()
        var archived = Session(projectId: box.project.id, name: "Old", providerId: "claude")
        archived.archivedAt = Date()
        try box.store.save(archived)
        try box.store.save(Session(projectId: nil, name: "Elsewhere", providerId: "claude"))

        let list = try await box.run(["session", "list", "--project", box.project.rootPath])
        let sessions = try #require(list.json as? [[String: Any]])
        #expect(sessions.map { $0["name"] as? String } == ["Fix the login"])
        let agent = try #require(sessions.first?["agent"] as? [String: Any])
        #expect(agent["id"] as? String == (created.object["agent"] as? [String: Any])?["id"] as? String)

        let all = try await box.run(["session", "list", "--project", "Sandbox", "--include-archived"])
        #expect(Set((all.json as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }) == ["Fix the login", "Old"])
    }

    @Test func projectNotFound() async throws {
        let box = try await Sandbox()
        defer { box.tearDown() }
        let out = try await box.run(["session", "list", "--project", "nope"])
        #expect(out.status != 0)
        #expect(out.code == "project_not_found")
        #expect(try await box.create().status == 0) // the real one still works
        #expect(try await box.run(["session", "create", "--project", "nope", "--name", "n", "--branch", "b", "--agent", "claude",
                             "--prompt-file", box.file("p")]).code == "project_not_found")
    }

    // MARK: agent find / send

    @Test func findReportsTheRunningAgentOrNull() async throws {
        let box = try await Sandbox()
        defer { box.tearDown() }
        let created = try await box.create()
        let id = try #require(created.object["id"] as? String)
        let found = try await box.run(["agent", "find", "--session", id])
        #expect(found.object["id"] as? String == (created.object["agent"] as? [String: Any])?["id"] as? String)
        try await box.stopAgent(id)
        let none = try await box.run(["agent", "find", "--session", id])
        #expect(none.status == 0)
        #expect(none.json is NSNull)
    }

    @Test func sendReachesTheAgentAndTheLog() async throws {
        let box = try await Sandbox()
        defer { box.tearDown() }
        let created = try await box.create()
        let id = try #require(created.object["id"] as? String)
        let agentId = try #require((created.object["agent"] as? [String: Any])?["id"] as? String)
        try await waitUntil { try box.store.session(id)?.status == .idle }

        let out = try await box.run(["agent", "send", "--session", id, "--agent", agentId, "--text-file", box.file("Now add a test\n")])
        #expect(out.status == 0)
        #expect(out.object["id"] as? String == agentId)
        try await waitUntil { box.log(id).contains(OutputLine(stream: .user, line: "Now add a test")) }
        // Two answers: the prompt's and the message's.
        try await waitUntil { box.log(id).filter { $0.line.contains(#""type":"result""#) }.count == 2 }
    }

    @Test func questionsAreDeniedSoTheAgentCarriesOn() async throws {
        let box = try await Sandbox()
        defer { box.tearDown() }
        let created = try await box.run(["session", "create", "--project", box.project.id, "--name", "Ask", "--branch", "ask",
                                   "--agent", "claude", "--prompt-file", "-"], stdin: "Please ASK first")
        let id = try #require(created.object["id"] as? String)
        try await waitUntil { box.answersLog.contains(#""behavior":"deny""#) }
        try await waitUntil { try box.store.session(id)?.status == .idle }
    }

    @Test func agentNotRunning() async throws {
        let box = try await Sandbox(agent: .exitsAfterTurn)
        defer { box.tearDown() }
        let created = try await box.create()
        let id = try #require(created.object["id"] as? String)
        let agentId = try #require((created.object["agent"] as? [String: Any])?["id"] as? String)
        try await waitUntil { SessionLock.holder(of: id, in: box.locks) == nil }
        #expect(try box.store.session(id)?.status == .finished)

        let out = try await box.run(["agent", "send", "--session", id, "--agent", agentId, "--text-file", box.file("hello")])
        #expect(out.status != 0)
        #expect(out.code == "agent_not_running")
    }

    @Test func aMessageForAnotherAgentIsRefused() async throws {
        let box = try await Sandbox()
        defer { box.tearDown() }
        let id = try #require(try await box.create().object["id"] as? String)
        let out = try await box.run(["agent", "send", "--session", id, "--agent", "someone-else", "--text-file", box.file("hi")])
        #expect(out.code == "agent_not_running")
    }

    @Test func sessionNotFound() async throws {
        let box = try await Sandbox()
        defer { box.tearDown() }
        let text = try box.file("hi")
        for args in [["agent", "find", "--session", "nope"],
                     ["agent", "send", "--session", "nope", "--agent", "a", "--text-file", text],
                     ["agent", "respawn", "--session", "nope", "--agent", "claude", "--prompt-file", text]] {
            let out = try await box.run(args)
            #expect(out.status != 0)
            #expect(out.code == "session_not_found", "\(args)")
        }
    }

    // MARK: agent respawn

    @Test func respawnStartsAFreshAgentInTheSameWorktree() async throws {
        let box = try await Sandbox()
        defer { box.tearDown() }
        let created = try await box.create()
        let id = try #require(created.object["id"] as? String)
        let first = try #require((created.object["agent"] as? [String: Any])?["id"] as? String)
        try await waitUntil { try box.store.session(id)?.providerSessionId != nil }
        let before = try #require(try box.store.session(id))
        try await box.stopAgent(id)

        let out = try await box.run(["agent", "respawn", "--session", id, "--agent", "claude", "--prompt-file", box.file("Start over")])
        #expect(out.status == 0)
        let second = try #require(out.object["id"] as? String)
        #expect(second != first)
        let after = try #require(try box.store.session(id))
        #expect(after.worktreePath == before.worktreePath)
        #expect(after.branch == before.branch)
        #expect(after.prompt == "Start over")
        // No earlier context: launched fresh, never resumed.
        #expect(!box.argsLog.contains("--resume"))
        try await waitUntil { box.log(id).contains(OutputLine(stream: .user, line: "Start over")) }
    }

    @Test func agentAlreadyRunning() async throws {
        let box = try await Sandbox()
        defer { box.tearDown() }
        let id = try #require(try await box.create().object["id"] as? String)
        let out = try await box.run(["agent", "respawn", "--session", id, "--agent", "claude", "--prompt-file", box.file("again")])
        #expect(out.status != 0)
        #expect(out.code == "agent_already_running")
    }

    @Test func worktreeMissing() async throws {
        let box = try await Sandbox()
        defer { box.tearDown() }
        let id = try #require(try await box.create().object["id"] as? String)
        try await box.stopAgent(id)
        try FileManager.default.removeItem(atPath: try #require(try box.store.session(id)?.worktreePath))
        let out = try await box.run(["agent", "respawn", "--session", id, "--agent", "claude", "--prompt-file", box.file("again")])
        #expect(out.code == "worktree_missing")
        #expect(SessionLock.holder(of: id, in: box.locks) == nil)
    }

    @Test func unknownAgent() async throws {
        let box = try await Sandbox()
        defer { box.tearDown() }
        let prompt = try box.file("p")
        for agent in ["codex", "nobody"] {
            let out = try await box.run(["session", "create", "--project", box.project.id, "--name", "n", "--branch", "b",
                                   "--agent", agent, "--prompt-file", prompt])
            #expect(out.code == "unknown_agent")
        }
        let id = try #require(try await box.create().object["id"] as? String)
        try await box.stopAgent(id)
        #expect(try await box.run(["agent", "respawn", "--session", id, "--agent", "codex", "--prompt-file", prompt]).code == "unknown_agent")
    }

    // MARK: With the app open

    @Test func withTheAppOpenTheAppRunsTheNewChatsAgent() async throws {
        let box = try await Sandbox()
        defer { box.tearDown() }
        let app = try #require(FakeApp(box))
        defer { app.stop() }
        let out = try await box.create()
        #expect(out.status == 0)
        let id = try #require(out.object["id"] as? String)
        #expect((out.object["agent"] as? [String: Any])?["driver"] as? String == "app")
        #expect(app.requests.map(\.sessionId) == [id])
        #expect(app.requests.first?.fresh == true)
        #expect(app.requests.first?.prompt == "Fix the login button")
        // The app holds the chat; nothing ran the agent from the command line.
        #expect(SessionLock.holder(of: id, in: box.locks)?.driver == .app)
        #expect(box.argsLog.isEmpty)
        #expect(try box.store.session(id)?.branch == "fix/login")
    }

    @Test func anAppThatCantStartTheAgentLeavesNothingBehind() async throws {
        let box = try await Sandbox()
        defer { box.tearDown() }
        let app = try #require(FakeApp(box, failing: "Not signed in"))
        defer { app.stop() }
        let out = try await box.create(branch: "unstarted")
        #expect(out.code == "agent_start_failed")
        #expect((out.object["message"] as? String)?.contains("Not signed in") == true)
        try expectNothingLeft(box, branch: "unstarted")
        #expect(try await !box.branches().contains("unstarted"))
    }

    @Test func respawnGoesToTheOpenAppToo() async throws {
        let box = try await Sandbox()
        defer { box.tearDown() }
        let id = try #require(try await box.create().object["id"] as? String)
        try await box.stopAgent(id)
        let app = try #require(FakeApp(box))
        defer { app.stop() }
        let out = try await box.run(["agent", "respawn", "--session", id, "--agent", "claude", "--prompt-file", box.file("Again")])
        #expect(out.object["driver"] as? String == "app")
        #expect(app.requests.first?.fresh == false)
        #expect(app.requests.first?.prompt == "Again")
    }

    @Test func aDeadAppSocketFallsBackToTheCommandLine() async throws {
        let box = try await Sandbox()
        defer { box.tearDown() }
        // What an app that crashed leaves behind: the socket's file, and nobody listening.
        let path = AppLink.socketPath(storePath: box.storePath)
        close(try HostSocket.listen(path: path))
        defer { unlink(path) }
        let out = try await box.create()
        #expect(out.status == 0)
        #expect((out.object["agent"] as? [String: Any])?["driver"] as? String == "cli")
    }

    // MARK: Handing a chat to the app

    @Test func openingTheChatInTheAppTakesItOverOnceIdle() async throws {
        let box = try await Sandbox()
        defer { box.tearDown() }
        let id = try #require(try await box.create().object["id"] as? String)
        try await waitUntil { try box.store.session(id)?.status == .idle }
        // What the app does when the chat shows.
        let host = try #require(SessionLock.holder(of: id, in: box.locks))
        kill(host.pid, SIGUSR1)
        try await waitUntil { SessionLock.holder(of: id, in: box.locks) == nil }
        let session = try #require(try box.store.session(id))
        #expect(session.status == .finished)
        // Where the app's next message resumes the conversation.
        #expect(session.providerSessionId == "fake-session")
        let app = try SessionLock.acquire(id, as: .app, in: box.locks)
        app.release()
    }

    @Test func aTurnUnderWayFinishesBeforeTheAppTakesOver() async throws {
        let box = try await Sandbox(agent: .slowTurn)
        defer { box.tearDown() }
        let id = try #require(try await box.create().object["id"] as? String)
        let host = try #require(SessionLock.holder(of: id, in: box.locks))
        kill(host.pid, SIGUSR1)
        try await Task.sleep(for: .milliseconds(800))
        #expect(SessionLock.holder(of: id, in: box.locks) != nil, "still at work on its turn")
        try await waitUntil(timeout: 15) { SessionLock.holder(of: id, in: box.locks) == nil }
        #expect(box.log(id).contains { $0.line.contains(#""type":"result""#) }, "the turn ran to its end")
        #expect(try box.store.session(id)?.status == .finished)
    }

    // MARK: The lock, both ways

    @Test func aSessionOpenInTheAppIsLockedToTheCommandLine() async throws {
        let box = try await Sandbox()
        defer { box.tearDown() }
        let created = try await box.create()
        let id = try #require(created.object["id"] as? String)
        let agentId = try #require((created.object["agent"] as? [String: Any])?["id"] as? String)
        try await box.stopAgent(id)

        // The app shows the chat: it holds the chat's lock.
        let app = try SessionLock.acquire(id, as: .app, in: box.locks)
        let text = try box.file("hi")
        let send = try await box.run(["agent", "send", "--session", id, "--agent", agentId, "--text-file", text])
        #expect(send.status != 0)
        #expect(send.code == "session_locked")
        let respawn = try await box.run(["agent", "respawn", "--session", id, "--agent", "claude", "--prompt-file", text])
        #expect(respawn.code == "session_locked")
        #expect(try box.store.session(id)?.prompt == "Fix the login button")

        // Closed in the app: the command line may drive it again.
        app.release()
        #expect(try await box.run(["agent", "respawn", "--session", id, "--agent", "claude", "--prompt-file", text]).status == 0)
    }

    @Test func aSessionDrivenFromTheCommandLineIsReadOnlyInTheApp() async throws {
        let box = try await Sandbox()
        defer { box.tearDown() }
        let created = try await box.create()
        let id = try #require(created.object["id"] as? String)
        let agentId = try #require((created.object["agent"] as? [String: Any])?["id"] as? String)

        // What the app does when it shows the chat: it can't take the lock, and learns who has it.
        do {
            _ = try SessionLock.acquire(id, as: .app, in: box.locks)
            Issue.record("The app took a chat the command line drives")
        } catch SessionLockError.held(let holder) {
            #expect(holder?.driver == .cli)
            #expect(holder?.agent?.id == agentId)
        }

        // Once the agent stops, the app can have it.
        try await box.stopAgent(id)
        let app = try SessionLock.acquire(id, as: .app, in: box.locks)
        app.release()
    }

    // MARK: Command line

    @Test func invalidArguments() async throws {
        let box = try await Sandbox()
        defer { box.tearDown() }
        let prompt = try box.file("p")
        let empty = try box.file("  \n")
        let cases: [[String]] = [
            [],
            ["session"],
            ["session", "delete", "--session", "x"],
            ["session", "list"],
            ["session", "list", "--project"],
            ["session", "list", "--project", "a", "--project", "b"],
            ["session", "list", "--project", box.project.id, "stray"],
            ["session", "create", "--project", box.project.id, "--name", "n", "--branch", "b", "--agent", "claude",
             "--prompt", "inline text"],
            ["agent", "send", "--session", "s", "--agent", "a", "--text", "inline text"],
            ["session", "create", "--project", box.project.id, "--name", "n", "--branch", "b", "--agent", "claude",
             "--prompt-file", empty],
            ["session", "create", "--project", box.project.id, "--name", "n", "--branch", "b", "--agent", "claude",
             "--prompt-file", box.root.path + "/missing.txt"],
            ["session", "create", "--project", box.project.id, "--name", "n", "--branch", "bad..branch", "--agent", "claude",
             "--prompt-file", prompt],
            ["session", "create", "--project", box.project.id, "--name", "  ", "--branch", "b", "--agent", "claude",
             "--prompt-file", prompt],
        ]
        for args in cases {
            let out = try await box.run(args)
            #expect(out.code == "invalid_arguments", "\(args)")
            #expect(out.status == 2, "\(args)")
        }
        #expect(try box.store.sessions().isEmpty)
    }
}

private final class Heard: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var count: Int { lock.withLock { n } }
    func mark() { lock.withLock { n += 1 } }
}

/// Stands in for the open app: takes each chat's lock and says its agent is
/// up, as the app does once it runs it, or turns it down with `failing`.
private final class FakeApp: @unchecked Sendable {
    private let server: AppLink.Server
    private let log: Log

    private final class Log: @unchecked Sendable {
        let mutex = NSLock()
        var requests: [AppLink.StartRequest] = []
        var locks: [SessionLock] = []
    }

    init?(_ box: Sandbox, failing message: String? = nil) {
        let log = Log()
        let locks = box.locks
        guard let server = AppLink.Server(storePath: box.storePath, handler: { request in
            log.mutex.withLock { log.requests.append(request) }
            if let message { return AppLink.StartReply(agent: nil, message: message) }
            let agent = AgentRecord(sessionId: request.sessionId, providerId: "claude")
            guard let lock = try? SessionLock.acquire(request.sessionId, as: .app, in: locks) else {
                return AppLink.StartReply(agent: nil, message: "The chat's lock wasn't free.")
            }
            try? lock.setAgent(agent)
            log.mutex.withLock { log.locks.append(lock) }
            return AppLink.StartReply(agent: agent, message: nil)
        }) else { return nil }
        self.server = server
        self.log = log
    }

    var requests: [AppLink.StartRequest] { log.mutex.withLock { log.requests } }

    func stop() {
        server.stop()
        log.mutex.withLock { log.locks.forEach { $0.release() } }
    }
}
