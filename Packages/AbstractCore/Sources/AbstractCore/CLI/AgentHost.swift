import Darwin
import Foundation

/// What `abstract` hands the host it starts, on the host's stdin.
struct HostStart: Codable {
    var agentId: String
    var prompt: String
    /// The chat's agent before a respawn switched agents: the log marks the change.
    var replacing: String?
}

/// The host's one line on stdout: the agent is up, or why it isn't.
struct HostStarted: Codable {
    var agent: AgentRecord?
    var message: String?
}

/// Runs one chat's agent for `abstract`, outside the app, and outlives the
/// command that started it (an agent takes follow-ups on its stdin, so
/// something must keep that open). An agent left idle for `idleTimeout`
/// (no output, no message) is stopped, as the app stops its agents when it
/// quits: the chat is finished, and `agent respawn` can start another.
///
/// It does what the app does for a chat it runs, through the same pieces:
/// `AgentLaunch` builds the launch, `SessionEngine` spawns the agent and
/// writes the chat's log, `ChatStream` reads its output, and status, the
/// agent's session id and usage go to the store. It holds the chat's
/// `SessionLock` until the agent exits, and takes messages for it on a
/// `HostSocket`. Nobody can answer the agent's questions from here, so any
/// tool call that needs approval is denied and the agent carries on, as a
/// headless agent would; the project's permission policy decides what that is.
final class AgentHost: @unchecked Sendable {
    /// The hidden command `abstract` runs a host as.
    static let command = "_host"
    /// How long an agent may sit idle before it's stopped: 10 minutes, or
    /// `ABSTRACT_AGENT_IDLE_TIMEOUT` seconds.
    static var idleTimeout: TimeInterval {
        ProcessInfo.processInfo.environment["ABSTRACT_AGENT_IDLE_TIMEOUT"].flatMap(TimeInterval.init) ?? 600
    }
    /// What a host passes on from the command that starts it: what the app's
    /// own agents would have too, and nothing of the caller's session (an
    /// `ANTHROPIC_API_KEY` or `CLAUDE_CONFIG_DIR` there must not change the
    /// account or billing the agent runs under).
    static func hostEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        let kept: Set<String> = ["HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG", "PATH", "SSH_AUTH_SOCK", "__CF_USER_TEXT_ENCODING"]
        return environment.filter { kept.contains($0.key) || $0.key.hasPrefix("LC_") || $0.key.hasPrefix("ABSTRACT_") }
    }

    private let queue = DispatchQueue(label: "sh.abstract.agent-host")
    private let socketQueue = DispatchQueue(label: "sh.abstract.agent-host.socket")
    private let storePath: String
    private let store: Store
    private let engine: SessionEngine
    private let lock: SessionLock
    private let session: Session
    private let provider: any ProviderDefinition
    private let agent: AgentRecord
    private let stream: ChatStream
    private let startSignal = DispatchSemaphore(value: 0)
    private let exitSignal = DispatchSemaphore(value: 0)
    private var sources: [any DispatchSourceProtocol] = []

    // On `queue`.
    /// The agent has shown it works: it answered, or started to.
    private var up = false
    /// It reported an error before it was up.
    private var startFailure: String?
    private var exited = false
    private var exitCode: Int32?
    private var stderrTail: [String] = []
    private var status: (SessionStatus, String?)?
    private var lastActivity = Date()
    private var stopRequested = false
    /// The app asked for the chat (SIGUSR1): it's the app's once the agent is idle.
    private var handOver = false

    private var sessionId: String { session.id }

    private init(sessionId: String, request: HostStart, lock: SessionLock) throws {
        self.lock = lock
        storePath = Store.defaultPath()
        store = try Store(path: storePath)
        guard let session = try store.session(sessionId) else { throw AbstractError.notFound("session \(sessionId)") }
        guard let provider = ProviderRegistry.provider(session.providerId) else {
            throw AbstractError.message("Unknown agent “\(session.providerId)”.")
        }
        self.session = session
        self.provider = provider
        agent = AgentRecord(id: request.agentId, sessionId: sessionId, providerId: provider.id)
        engine = SessionEngine(executor: LocalExecutor.shared, logDirectory: SessionEngine.defaultLogDirectory())
        stream = ChatStream(providerId: provider.id)
    }

    // MARK: - Starting one (the command's side)

    /// Starts `session`'s agent in a host process that outlives this command,
    /// handing it `lock`, and returns once the agent is up. When it fails the
    /// lock is still this process's, to clean up and release.
    static func start(_ session: Session, prompt: String, replacing: String?, lock: SessionLock,
                      executable: String) throws -> AgentRecord {
        let request = HostStart(agentId: UUID().uuidString, prompt: prompt, replacing: replacing)
        let child: Spawner.Child
        do {
            child = try Spawner.launch(executable: executable, arguments: [executable, command, "--session", session.id],
                                       environment: hostEnvironment(), cwd: nil,
                                       stdin: .pipe, stdout: .pipe, stderr: .null, inherit: [3: lock.descriptor])
        } catch {
            throw CLIError(.agentStartFailed, "Couldn't start the agent's host: \(error.localizedDescription)")
        }
        HostSocket.writeLine(child.stdin, (try? JSONEncoder().encode(request)) ?? Data())
        close(child.stdin)
        let line = HostSocket.readLine(child.stdout, timeoutMs: Int32((AgentStart.timeout + 90) * 1000))
        close(child.stdout)
        let reply = line.flatMap { try? JSONDecoder().decode(HostStarted.self, from: $0) }
        if let agent = reply?.agent {
            // The host has the lock now (the same open file); this process just lets go of its copy.
            lock.handOff()
            return agent
        }
        if line == nil { kill(child.pid, SIGTERM) }
        var status: Int32 = 0
        while waitpid(child.pid, &status, 0) == -1 && errno == EINTR {}
        throw CLIError(.agentStartFailed, reply?.message ?? "The agent's host stopped before the agent started.")
    }

    // MARK: - Running (the host's side)

    /// `abstract _host --session <id>`, started by `start`: the request on
    /// stdin, the chat's lock as fd 3.
    static func main(_ arguments: [String]) -> Never {
        signal(SIGPIPE, SIG_IGN)
        let lock: SessionLock
        let host: AgentHost
        let request: HostStart
        do {
            let sessionId = try CLIArguments(arguments, options: ["session"]).value("session")
            request = try JSONDecoder().decode(HostStart.self, from: FileHandle.standardInput.readDataToEndOfFile())
            lock = try SessionLock.inherited(3, sessionId: sessionId, driver: .cli)
            do {
                host = try AgentHost(sessionId: sessionId, request: request, lock: lock)
            } catch {
                lock.handOff()
                throw error
            }
        } catch {
            reply(HostStarted(agent: nil, message: error.localizedDescription))
            exit(1)
        }
        host.run(request)
    }

    private func run(_ request: HostStart) -> Never {
        let locks = lock.directory
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: queue)
            source.setEventHandler { [self] in
                stopRequested = true
                engine.stop(sessionId: sessionId)
            }
            source.resume()
            sources.append(source)
        }
        // The chat was opened in the app: the agent stops as soon as it's
        // idle (now, or when this turn ends), and the app resumes it from there.
        signal(SIGUSR1, SIG_IGN)
        let handOverSource = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: queue)
        handOverSource.setEventHandler { [self] in
            handOver = true
            stopIfHandedOver()
        }
        handOverSource.resume()
        sources.append(handOverSource)
        let listener: Int32
        do { listener = try HostSocket.listen(sessionId: sessionId, in: locks) } catch { fail(error.localizedDescription) }

        Task.detached { [self] in
            for await event in engine.events { queue.sync { handle(event) } }
        }
        // What the agent is told goes in the log first, as the app does it.
        if let replacing = request.replacing {
            engine.record(sessionId: sessionId, HandoffMarker(phase: .handoff, from: replacing, to: provider.id).line)
        }
        engine.recordInput(sessionId: sessionId, text: request.prompt)
        let executor = LocalExecutor.shared
        let settings = LaunchSettings(store: store, dataDirectory: URL(fileURLWithPath: storePath).deletingLastPathComponent())
        let spec = AgentLaunch.spec(for: session, provider: provider, prompt: request.prompt, resumeId: nil,
                                    settings: settings, home: executor.homeDirectory)
        do {
            try engine.launch(sessionId: sessionId, spec: spec,
                              enricher: provider.makeLineEnricher(executor: executor, cwd: spec.cwd))
        } catch {
            fail(error.localizedDescription)
        }
        queue.sync {
            setStatus(.running, nil)
            // Stopped before there was an agent to stop.
            if stopRequested { engine.stop(sessionId: sessionId) }
        }

        // Up once it answers or starts to. An agent prints its setup before it
        // ever reaches its model, so an error then (not signed in, a limit
        // reached) or an exit is a failed start.
        _ = startSignal.wait(timeout: .now() + AgentStart.timeout)
        let failure: String? = queue.sync {
            if let startFailure { return startFailure }
            guard exited, !up else { up = true; return nil }
            let tail = stderrTail.joined(separator: "\n")
            let code = "\(provider.name) exited with code \(exitCode.map(String.init) ?? "?")"
            return tail.isEmpty ? code : "\(code): \(tail)"
        }
        if let failure { fail(failure) }

        try? lock.setAgent(agent)
        StoreChanges.post(storePath: storePath)
        Self.reply(HostStarted(agent: agent, message: nil))
        let null = open("/dev/null", O_WRONLY)
        dup2(null, STDOUT_FILENO)
        close(null)
        serve(listener)
        stopWhenIdle()

        exitSignal.wait()
        // The socket first: once the lock is free, a respawn's host may make its own.
        unlink(HostSocket.name(sessionId))
        lock.release()
        StoreChanges.post(storePath: storePath)
        exit(0)
    }

    /// Before the agent is up: tell the command, give the lock back to it, and go.
    private func fail(_ message: String) -> Never {
        Self.reply(HostStarted(agent: nil, message: message))
        if engine.isAlive(sessionId) { engine.stop(sessionId: sessionId) }
        unlink(HostSocket.name(sessionId))
        lock.handOff()
        exit(1)
    }

    private func stopWhenIdle() {
        let timeout = Self.idleTimeout
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let every = max(0.2, min(30, timeout / 4))
        timer.schedule(deadline: .now() + every, repeating: every)
        timer.setEventHandler { [self] in
            guard status?.0 == .idle, !stopRequested, Date().timeIntervalSince(lastActivity) >= timeout else { return }
            stopRequested = true
            engine.stop(sessionId: sessionId)
        }
        timer.resume()
        sources.append(timer)
    }

    private static func reply(_ started: HostStarted) {
        guard let data = try? JSONEncoder().encode(started) else { return }
        HostSocket.writeLine(STDOUT_FILENO, data)
    }

    // MARK: Agent output (on `queue`)

    private func handle(_ event: EngineEvent) {
        switch event {
        case let .line(_, _, line):
            lastActivity = Date()
            if line.stream == .stderr { stderrTail = Array((stderrTail + [line.line]).suffix(5)) }
            let events = stream.feed(line)
            // Only the agent's own output says how it's doing, never the prompt logged for it.
            if !up, startFailure == nil, line.stream == .stdout,
               let outcome = AgentStart.outcome(of: events, agentName: provider.name) {
                switch outcome {
                case .up: up = true
                case let .failed(message): startFailure = message
                }
                startSignal.signal()
            }
            let asked = events.contains { if case .permissionRequest = $0 { true } else { false } }
            for event in events { apply(event, asked: asked) }
        case let .exit(_, code):
            exited = true
            exitCode = code
            // Never up: `abstract` cleans up after it.
            guard up else { startSignal.signal(); return }
            // As the app ends a chat's run (AppModel.handle).
            if status?.0 == .idle {
                setStatus(.finished, nil)
            } else {
                for event in stream.onExit(code: code) { apply(event, asked: false) }
                if status?.0.isActive ?? true {
                    setStatus(code == 0 ? .finished : .errored, code == 0 ? nil : "Exited with code \(code.map(String.init) ?? "?")")
                }
            }
            exitSignal.signal()
        }
    }

    private func apply(_ event: AgentEvent, asked: Bool) {
        switch event {
        case let .permissionRequest(requestId, _, _):
            if let line = provider.buildPermissionResponse(requestId: requestId, allow: false, input: nil) {
                try? engine.write(sessionId: sessionId, line)
            }
        case .status(.waitingInput, _) where asked:
            // Already answered: it carries on.
            setStatus(.running, nil)
        case let .status(status, detail):
            setStatus(status, detail)
        case let .sessionId(id):
            try? store.updateProviderSessionId(sessionId, id)
            StoreChanges.post(storePath: storePath)
        case let .usage(totals, cost, duration, turns):
            try? store.record(UsageRecord(sessionId: sessionId, projectId: session.projectId, providerId: provider.id,
                                          usage: totals, costUsd: cost ?? 0, durationMs: duration ?? 0, turns: turns ?? 1))
        default:
            break
        }
    }

    private func setStatus(_ new: SessionStatus, _ detail: String?) {
        if let status, status == (new, detail) { return }
        try? store.updateSessionStatus(sessionId, new, detail: detail)
        status = (new, detail)
        StoreChanges.post(storePath: storePath)
        stopIfHandedOver()
    }

    /// On `queue`: an idle agent the app has asked for stops, and the chat is the app's.
    private func stopIfHandedOver() {
        guard handOver, status?.0 == .idle, !stopRequested else { return }
        stopRequested = true
        engine.stop(sessionId: sessionId)
    }

    // MARK: Messages (`abstract agent send`)

    private func serve(_ listener: Int32) {
        let source = DispatchSource.makeReadSource(fileDescriptor: listener, queue: socketQueue)
        source.setEventHandler { [self] in
            let client = accept(listener, nil, nil)
            guard client >= 0 else { return }
            defer { close(client) }
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            guard let line = HostSocket.readLine(client, timeoutMs: 5_000),
                  let request = try? JSONDecoder().decode(HostRequest.self, from: line) else { return }
            let reply = queue.sync { perform(request) }
            HostSocket.writeLine(client, (try? JSONEncoder().encode(reply)) ?? Data())
        }
        source.resume()
        sources.append(source)
    }

    /// On `queue`.
    private func perform(_ request: HostRequest) -> HostReply {
        guard request.agentId == agent.id, !exited, engine.isAlive(sessionId) else {
            return .failed(CLIError(.agentNotRunning, "Agent \(request.agentId) isn't running."))
        }
        guard request.op == "send", let text = request.text, let line = provider.buildUserMessage(text) else {
            return .failed(CLIError(.invalidArguments, "The agent's host doesn't understand “\(request.op)”."))
        }
        lastActivity = Date()
        engine.recordInput(sessionId: sessionId, text: text)
        do {
            try engine.write(sessionId: sessionId, line)
        } catch {
            return .failed(CLIError(.agentNotRunning, "Agent \(agent.id) stopped taking messages."))
        }
        setStatus(.running, nil)
        return .ok
    }
}
