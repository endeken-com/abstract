import Darwin
import Foundation
import Synchronization

/// `abstract`: create and drive Abstract's sessions from scripts and other automations.
///
///     abstract session list     --project <p> [--include-archived]
///     abstract session create   --project <p> --name <n> --branch <b> --agent claude --prompt-file <path|->
///     abstract agent find       --session <id>
///     abstract agent send       --session <id> --agent <id> --text-file <path|->
///     abstract agent respawn    --session <id> --agent claude --prompt-file <path|->
///
/// `--project` takes a project's id, root path or name. Every command prints
/// one JSON value on stdout and nothing else; a failure prints
/// `{"code","message"}` (see `CLIError.Code`) and exits non-zero.
///
/// It reads and writes the app's own database and chat logs, so it works with
/// the app closed, and a session it creates is an ordinary chat there (the app
/// picks changes up live when it's open). With the app open, the app runs the
/// agent (`AppLink`), so the chat is the app's from its first second. With it
/// closed, the agent runs in a host process of its own (`AgentHost`) until
/// it exits, has sat idle for 10 minutes (`ABSTRACT_AGENT_IDLE_TIMEOUT`, in
/// seconds), or the chat is opened in the app; any approval it would ask for
/// there is denied, since nobody is there to answer.
///
/// `session create` starts the worktree from the project's base branch as
/// `origin` has it (fetched first), and runs the project's setup script in it
/// before the agent starts; while it runs the session shows as setting up.
public enum CommandLineTool {
    public static func main(_ arguments: [String]) async -> Int32 {
        let args = Array(arguments.dropFirst())
        if args.first == AgentHost.command { AgentHost.main(Array(args.dropFirst())) }
        do {
            emit(try await run(args))
            return 0
        } catch let error as CLIError {
            emit(ErrorJSON(code: error.code.rawValue, message: error.message))
            return error.exitStatus
        } catch {
            emit(ErrorJSON(code: CLIError.Code.internalError.rawValue, message: error.localizedDescription))
            return 1
        }
    }

    static let usage = """
        Usage: abstract session list --project <p> [--include-archived] | \
        session create --project <p> --name <n> --branch <b> --agent <agent> --prompt-file <path|-> | \
        agent find --session <id> | agent send --session <id> --agent <id> --text-file <path|-> | \
        agent respawn --session <id> --agent <agent> --prompt-file <path|->
        """

    private static func run(_ args: [String]) async throws -> any Encodable {
        guard args.count >= 2 else { throw CLIError(.invalidArguments, usage) }
        let rest = Array(args.dropFirst(2))
        let stdin = { FileHandle.standardInput.readDataToEndOfFile() }
        switch (args[0], args[1]) {
        case ("session", "list"):
            let a = try CLIArguments(rest, options: ["project"], switches: ["include-archived"])
            return try Commands.open().list(project: a.value("project"), includeArchived: a.isSet("include-archived"))
        case ("session", "create"):
            let a = try CLIArguments(rest, options: ["project", "name", "branch", "agent", "prompt-file"])
            let prompt = try readTextArgument(a.value("prompt-file"), option: "prompt-file", stdin: stdin)
            return try await Commands.open().create(project: a.value("project"), name: a.value("name"), branch: a.value("branch"),
                                                    agent: a.value("agent"), prompt: prompt)
        case ("agent", "find"):
            let a = try CLIArguments(rest, options: ["session"])
            return try Commands.open().find(session: a.value("session"))
        case ("agent", "send"):
            let a = try CLIArguments(rest, options: ["session", "agent", "text-file"])
            let text = try readTextArgument(a.value("text-file"), option: "text-file", stdin: stdin)
            return try Commands.open().send(session: a.value("session"), agent: a.value("agent"), text: text)
        case ("agent", "respawn"):
            let a = try CLIArguments(rest, options: ["session", "agent", "prompt-file"])
            let prompt = try readTextArgument(a.value("prompt-file"), option: "prompt-file", stdin: stdin)
            return try Commands.open().respawn(session: a.value("session"), agent: a.value("agent"), prompt: prompt)
        default:
            throw CLIError(.invalidArguments, "Unknown command “\(args.prefix(2).joined(separator: " "))”. \(usage)")
        }
    }

    private static func emit(_ value: some Encodable) {
        var data = (try? CLIOutput.encode(value)) ?? Data(#"{"code":"internal","message":"Couldn't encode the result."}"#.utf8)
        data.append(0x0A)
        try? FileHandle.standardOutput.write(contentsOf: data)
    }
}

/// The commands themselves, over the app's store.
struct Commands {
    let store: Store
    let storePath: String
    let locks: URL
    /// This program, to run a host with.
    let executable: String
    /// Only asked for by what runs git: it starts a login shell to find its PATH.
    var executor: any Executor { LocalExecutor.shared }

    static func open() throws -> Commands {
        let path = Store.defaultPath()
        let store: Store
        do {
            // Before the app has ever run there's nothing to find, and the data
            // folder is left for the app to make (or to move over from Backtick).
            store = FileManager.default.fileExists(atPath: path) ? try Store(path: path) : try Store.inMemory()
        } catch {
            throw CLIError(.internalError, "Can't open Abstract's database at \(path): \(error.localizedDescription)")
        }
        let executable = Bundle.main.executablePath ?? CommandLine.arguments[0]
        return Commands(store: store, storePath: path, locks: SessionLock.defaultDirectory(),
                        executable: URL(fileURLWithPath: executable).resolvingSymlinksInPath().path)
    }

    // MARK: session list

    func list(project p: String, includeArchived: Bool) throws -> [SessionJSON] {
        let project = try resolveProject(p)
        return try store.sessions()
            .filter { $0.projectId == project.id && (includeArchived || $0.archivedAt == nil) }
            .map { SessionJSON(session: $0, agent: AgentJSON(sessionId: $0.id, locks: locks)) }
    }

    // MARK: session create

    func create(project p: String, name rawName: String, branch: String, agent providerId: String,
                prompt: String) async throws -> SessionJSON {
        let provider = try drivableProvider(providerId)
        let project = try resolveProject(p)
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw CLIError(.invalidArguments, "--name is empty.") }
        let check = try await executor.run("git", ["check-ref-format", "--branch", branch], cwd: project.rootPath)
        guard check.ok, GitText.trimmed(check.stdout) == branch else {
            throw CLIError(.invalidArguments, "“\(branch)” isn't a valid branch name.")
        }
        let siblings = try store.sessions().filter { $0.projectId == project.id }
        if siblings.contains(where: { $0.archivedAt == nil && $0.name == name }) { throw nameTaken(name) }
        if await Git.branchExists(executor, root: project.rootPath, branch: "refs/heads/\(branch)") {
            throw branchExists(branch, owner: siblings.first { $0.branch == branch })
        }

        // From here until the agent is up or everything is undone, an
        // interrupt waits: a session is never left half made.
        for sig in [SIGINT, SIGTERM, SIGHUP, SIGUSR1] { signal(sig, SIG_IGN) }
        let sessionId = UUID().uuidString
        var lock = try SessionLock.acquire(sessionId, as: .cli, in: locks)
        // Named like the app names a new chat's folder.
        let city = WorktreeNaming.cityName(avoiding: Set(siblings.compactMap {
            $0.worktreePath.map { URL(fileURLWithPath: $0).lastPathComponent }
        }))
        let base = await Workspace.freshBase(executor: executor, root: project.rootPath, base: project.defaultBaseRef)
        let workspace: Workspace.Provisioned
        do {
            workspace = try await Workspace.provision(
                executor: executor, project: project, name: name, baseRef: base.ref,
                template: project.worktreeTemplate ?? store.setting("worktreeTemplate", as: String.self) ?? WorktreeNaming.defaultTemplate,
                prefix: "", worktreeName: city, exactBranch: branch)
        } catch WorkspaceError.branchExists {
            lock.discard()
            throw branchExists(branch, owner: nil)
        } catch {
            lock.discard()
            throw CLIError(.worktreeFailed, "Couldn't create the worktree: \(error.localizedDescription)")
        }

        let session = Session(id: sessionId, projectId: project.id, name: name, providerId: provider.id,
                              worktreePath: workspace.path, branch: workspace.branch, baseRef: project.defaultBaseRef,
                              status: .provisioning, permissionPolicy: project.defaultPermissionPolicy, prompt: prompt)
        func rollBack() async {
            try? store.deleteSession(sessionId)
            SessionEngine(executor: executor, logDirectory: SessionEngine.defaultLogDirectory()).deleteLog(sessionId: sessionId)
            try? await Git.removeWorktree(executor, root: project.rootPath, path: workspace.path)
            // Apart, so a worktree that won't go never keeps its branch.
            _ = try? await Git.git(executor, cwd: project.rootPath, ["branch", "-D", workspace.branch])
            lock.discard()
            // Handed to the app and back: take it once more to clear it away.
            (try? SessionLock.acquire(sessionId, as: .cli, in: locks))?.discard()
            StoreChanges.post(storePath: storePath)
        }
        let inserted: Bool
        do { inserted = try store.insertUniquelyNamed(session) } catch {
            await rollBack()
            throw CLIError(.internalError, "Couldn't save the session: \(error.localizedDescription)")
        }
        // Another command took the name since the check above.
        guard inserted else { await rollBack(); throw nameTaken(name) }
        StoreChanges.post(storePath: storePath)

        if let script = Project.nonBlank(project.setupScript) {
            try? store.updateSessionStatus(sessionId, .provisioning, detail: "Running the setup script")
            StoreChanges.post(storePath: storePath)
            let tail = Mutex<[String]>([])
            let run = Task {
                try await SetupScript.run(script, in: workspace.path, executor: executor) { line in
                    tail.withLock { $0 = Array(($0 + [line]).suffix(5)) }
                }
            }
            // Interrupting now stops the script, and everything is undone as below.
            let interrupts = [SIGINT, SIGTERM, SIGHUP].map { sig in
                let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
                source.setEventHandler { run.cancel() }
                source.resume()
                return source
            }
            let code = try? await run.value
            interrupts.forEach { $0.cancel() }
            if code != 0 {
                await rollBack()
                let lines = tail.withLock { $0 }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                let how = code.map { "exited with code \($0)" } ?? "was stopped"
                throw CLIError(.setupFailed, (["The project's setup script \(how)."] + lines).joined(separator: "\n"))
            }
        }

        do {
            let request = AppLink.StartRequest(sessionId: sessionId, prompt: prompt, replacing: nil, fresh: true)
            if let agent = try startInApp(request, lock: &lock) {
                return SessionJSON(session: (try? store.session(sessionId)) ?? session, agent: AgentJSON(agent, driver: .app))
            }
            let agent = try AgentHost.start(session, prompt: prompt, replacing: nil, lock: lock, executable: executable)
            return SessionJSON(session: (try? store.session(sessionId)) ?? session, agent: AgentJSON(agent, driver: .cli))
        } catch {
            await rollBack()
            throw error
        }
    }

    // MARK: agent find

    func find(session id: String) throws -> AgentJSON? {
        _ = try existingSession(id)
        return AgentJSON(sessionId: id, locks: locks)
    }

    // MARK: agent send

    func send(session id: String, agent agentId: String, text: String) throws -> AgentJSON {
        _ = try existingSession(id)
        guard let holder = SessionLock.holder(of: id, in: locks) else {
            throw CLIError(.agentNotRunning, "No agent is running in session \(id).")
        }
        guard holder.driver == .cli else { throw openInApp(id) }
        guard let agent = holder.agent else { throw busy(id) }
        guard agent.id == agentId else {
            throw CLIError(.agentNotRunning, "Agent \(agentId) isn't running; session \(id) now runs agent \(agent.id).")
        }
        guard let reply = try HostSocket.request(HostRequest(op: "send", agentId: agentId, text: text), sessionId: id, in: locks) else {
            throw CLIError(.agentNotRunning, "Agent \(agentId) has stopped.")
        }
        guard reply.ok else { throw CLIError(reply.code ?? .agentNotRunning, reply.message ?? "Agent \(agentId) has stopped.") }
        return AgentJSON(agent, driver: .cli)
    }

    // MARK: agent respawn

    func respawn(session id: String, agent providerId: String, prompt: String) throws -> AgentJSON {
        let provider = try drivableProvider(providerId)
        var session = try existingSession(id)
        var lock: SessionLock
        do {
            lock = try SessionLock.acquire(id, as: .cli, in: locks)
        } catch SessionLockError.held(let holder) {
            if holder?.driver == .app { throw openInApp(id) }
            if let agent = holder?.agent {
                throw CLIError(.agentAlreadyRunning, "Session \(id) is still running agent \(agent.id).")
            }
            throw busy(id)
        }
        for sig in [SIGINT, SIGTERM, SIGHUP, SIGUSR1] { signal(sig, SIG_IGN) }
        guard let path = session.worktreePath, FileManager.default.fileExists(atPath: path) else {
            lock.release()
            throw CLIError(.worktreeMissing, "Session \(id) has no worktree to run an agent in.")
        }

        // A new agent in the same worktree and branch, with none of the old conversation.
        let previous = session.providerId
        if previous != provider.id { session.model = nil; session.effort = nil }
        session.providerId = provider.id
        session.providerSessionId = nil
        session.handoffFrom = nil
        session.prompt = prompt
        session.status = .provisioning
        session.statusDetail = nil
        session.lastEventAt = Date()
        do { try store.save(session) } catch {
            lock.release()
            throw CLIError(.internalError, "Couldn't save the session: \(error.localizedDescription)")
        }
        StoreChanges.post(storePath: storePath)
        do {
            let replacing = previous == provider.id ? nil : previous
            let request = AppLink.StartRequest(sessionId: id, prompt: prompt, replacing: replacing, fresh: false)
            if let agent = try startInApp(request, lock: &lock) { return AgentJSON(agent, driver: .app) }
            let agent = try AgentHost.start(session, prompt: prompt, replacing: replacing, lock: lock, executable: executable)
            return AgentJSON(agent, driver: .cli)
        } catch {
            let failure = error as? CLIError ?? CLIError(.agentStartFailed, error.localizedDescription)
            try? store.updateSessionStatus(id, .errored, detail: failure.message)
            lock.release()
            StoreChanges.post(storePath: storePath)
            throw failure
        }
    }

    /// With the app open, the app runs the agent: the chat is the app's from
    /// its first second, like one started there. Gives the app the chat's lock
    /// to do it; nil, with the lock taken back, when no app answers.
    private func startInApp(_ request: AppLink.StartRequest, lock: inout SessionLock) throws -> AgentRecord? {
        guard FileManager.default.fileExists(atPath: AppLink.socketPath(storePath: storePath)) else { return nil }
        lock.release()
        guard let reply = try AppLink.start(request, storePath: storePath) else {
            // Nobody there after all: the agent runs here, as with the app closed.
            do { lock = try SessionLock.acquire(request.sessionId, as: .cli, in: locks) } catch { throw busy(request.sessionId) }
            return nil
        }
        guard let agent = reply.agent else {
            throw CLIError(.agentStartFailed, reply.message ?? "Abstract couldn't start the agent.")
        }
        return agent
    }

    // MARK: Lookups

    func resolveProject(_ p: String) throws -> Project {
        let projects = try store.projects()
        if let match = projects.first(where: { $0.id == p }) { return match }
        let path = Self.canonical(p)
        if let match = projects.first(where: { Self.canonical($0.rootPath) == path }) { return match }
        let named = projects.filter { $0.name == p }
        if named.count == 1 { return named[0] }
        if named.count > 1 { throw CLIError(.invalidArguments, "Several projects are called “\(p)”; use its id or root path.") }
        throw CLIError(.projectNotFound, "No project “\(p)”. Use a project's id, root path or name.")
    }

    private func existingSession(_ id: String) throws -> Session {
        guard let session = try store.session(id) else { throw CLIError(.sessionNotFound, "No session \(id).") }
        return session
    }

    /// An agent that takes messages while it runs, which `agent send` needs.
    private func drivableProvider(_ id: String) throws -> any ProviderDefinition {
        let drivable = ProviderRegistry.all.filter { $0.followUpMode == .stdin }
        guard let provider = drivable.first(where: { $0.id == id }) else {
            throw CLIError(.unknownAgent, "“\(id)” isn't an agent abstract can drive. Use: \(drivable.map(\.id).joined(separator: ", ")).")
        }
        return provider
    }

    private func nameTaken(_ name: String) -> CLIError {
        CLIError(.nameTaken, "A session in this project is already called “\(name)”.")
    }

    private func branchExists(_ branch: String, owner: Session?) -> CLIError {
        let whose = owner.map { " It belongs to session “\($0.name)” (\($0.id))." } ?? ""
        return CLIError(.branchExists, "The branch “\(branch)” already exists.\(whose)")
    }

    private func openInApp(_ id: String) -> CLIError {
        CLIError(.sessionLocked, "Abstract is using session \(id): it's open there, or the app runs its agent.")
    }

    private func busy(_ id: String) -> CLIError {
        CLIError(.sessionLocked, "Another abstract command is working on session \(id).")
    }

    /// Paths compared as the file system sees them (/var and /private/var, trailing slashes).
    static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).resolvingSymlinksInPath().standardizedFileURL.path
    }
}
