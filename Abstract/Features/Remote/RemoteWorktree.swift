import Foundation
import SwiftUI
import AbstractCore

// A chat on another Mac works here as it does there: its review, files,
// editor, git actions and pull request read and change its worktree on that
// Mac, through a `RemoteExecutor` that runs git, gh and revund and reads and
// writes files over the pairing link.

/// Runs commands and reads files in a paired Mac's worktrees.
final class RemoteExecutor: Executor, @unchecked Sendable {
    let device: String
    let homeDirectory: String
    private weak var service: RemoteService?

    init(device: String, home: String, service: RemoteService) {
        self.device = device; self.homeDirectory = home; self.service = service
    }

    @MainActor private func link() throws -> RemoteLink {
        guard let link = service?.links[device], link.state == .online else {
            throw AbstractError.message("That Mac isn't connected.")
        }
        return link
    }

    private func ask(_ request: RemoteRequest) async throws -> RemoteResponse {
        let link = try await MainActor.run { try self.link() }
        let response = try await link.request(request)
        if case .failed(let message) = response { throw AbstractError.message(message) }
        return response
    }

    func run(_ command: String, _ args: [String], cwd: String?) async throws -> ExecResult {
        guard case .exec(let result) = try await ask(.exec(command: command, args: args, cwd: cwd)) else {
            throw AbstractError.message("The other Mac didn't run \(command).")
        }
        return result
    }

    func spawn(_ spec: LaunchSpec, onLine: @escaping @Sendable (OutputLine) -> Void,
               onExit: @escaping @Sendable (Int32?) -> Void) throws -> RunningProcess {
        let process = RemoteProcess()
        Task { @MainActor in
            guard let link = try? self.link() else {
                onLine(OutputLine(stream: .stderr, line: "That Mac isn't connected."))
                onExit(-1)
                return
            }
            process.attach(link, id: link.spawn(spec, onLine: onLine, onExit: onExit))
        }
        return process
    }

    // The synchronous file calls serve provisioning, which happens on the host.
    func fileExists(_ path: String) -> Bool { false }
    func readFile(_ path: String) throws -> String { throw AbstractError.message("Files on another Mac are read with readData.") }
    func createDirectory(_ path: String) throws { throw AbstractError.message("Folders on another Mac are made there.") }
    func removeItem(_ path: String) throws { throw AbstractError.message("Files on another Mac are removed there.") }
    /// The commands that run on the other Mac, when they're there.
    func which(_ binary: String) async -> String? {
        guard ["git", "gh", "revund"].contains(binary), let out = try? await run(binary, ["--version"], cwd: nil), out.ok else { return nil }
        return binary
    }

    func readData(_ path: String) async throws -> Data {
        guard case .data(let data) = try await ask(.readFile(path: path)) else { throw AbstractError.message("Couldn't read \(path).") }
        return data
    }

    func writeData(_ data: Data, to path: String) async throws {
        _ = try await ask(.writeFile(path: path, data: data))
    }

    func fileInfo(_ path: String) async -> FileInfo? {
        guard case .fileInfo(let info)? = try? await ask(.fileInfo(path: path)) else { return nil }
        return info
    }

    /// Every file under a folder that isn't a repository.
    func listFiles(_ root: String) async throws -> ([String], Bool) {
        guard case let .files(paths, truncated) = try await ask(.listFiles(root: root)) else { return ([], false) }
        return (paths, truncated)
    }
}

/// A process on another Mac: its output arrives through the link; stopping
/// it asks that Mac to.
final class RemoteProcess: RunningProcess, @unchecked Sendable {
    private let lock = NSLock()
    private var target: (link: RemoteLink, id: Int)?
    private var stopped = false

    var pid: Int32 { 0 }

    @MainActor func attach(_ link: RemoteLink, id: Int) {
        let stop = lock.withLock { () -> Bool in
            target = (link, id)
            return stopped
        }
        if stop { link.stopProcess(id) }
    }

    func write(_ text: String) throws { throw AbstractError.message("A process on another Mac takes no input.") }
    func closeStdin() {}

    func terminate() {
        let target = lock.withLock { () -> (link: RemoteLink, id: Int)? in
            stopped = true
            return self.target
        }
        guard let target else { return }
        Task { @MainActor in target.link.stopProcess(target.id) }
    }
}

/// Watches folders on another Mac while it's kept.
final class RemoteWatch {
    private let stop: @MainActor () -> Void
    init(stop: @escaping @MainActor () -> Void) { self.stop = stop }
    deinit { Task { @MainActor [stop] in stop() } }
}

// MARK: - The link, from here

extension RemoteLink {
    func spawn(_ spec: LaunchSpec, onLine: @escaping @Sendable (OutputLine) -> Void, onExit: @escaping @Sendable (Int32?) -> Void) -> Int {
        let id = nextRequestId()
        processes[id] = (onLine, onExit)
        send(.request(id: id, .spawn(spec)))
        return id
    }

    func stopProcess(_ id: Int) {
        guard processes[id] != nil else { return }
        fire(.stopProcess(id: id))
    }

    func watch(_ paths: [String], onChange: @escaping () -> Void) -> RemoteWatch {
        let id = nextRequestId()
        watchers[id] = onChange
        fire(.watch(id: id, paths: paths))
        return RemoteWatch { [weak self] in
            guard let self, self.watchers.removeValue(forKey: id) != nil else { return }
            self.fire(.unwatch(id: id))
        }
    }

    /// A spawn the other Mac refused ends here with its reason.
    func spawnAnswered(_ id: Int, _ response: RemoteResponse) {
        guard case .failed(let message) = response else { return }
        if let process = processes.removeValue(forKey: id) {
            process.line(OutputLine(stream: .stderr, line: message))
            process.exit(-1)
        }
        if let terminal = terminals.removeValue(forKey: id) {
            terminal.output(Data((message + "\r\n").utf8))
            terminal.exit(-1)
        }
    }

    func received(_ event: RemoteEvent) {
        switch event {
        case let .process(id, line): processes[id]?.line(line)
        case let .processExit(id, code): processes.removeValue(forKey: id)?.exit(code)
        case .changed(let id): watchers[id]?()
        case let .terminalOutput(id, data): terminals[id]?.output(data)
        case let .terminalExit(id, code): terminals.removeValue(forKey: id)?.exit(code)
        default: break
        }
    }

    /// The link went down: what was running there is gone from here.
    func dropStreams() {
        for (_, process) in processes { process.exit(nil) }
        processes = [:]
        for (_, terminal) in terminals { terminal.exit(nil) }
        terminals = [:]
    }
}

// MARK: - This Mac, for the other

extension HostedPeer {
    /// Inside one of this Mac's projects or its chats' worktrees.
    func allowed(_ path: String?) -> Bool {
        guard let path, let model = service?.model else { return false }
        let target = AppModel.canonical(path)
        let roots = model.projects.map(\.rootPath) + model.sessions.compactMap(\.worktreePath)
        return roots.contains { root in
            let r = AppModel.canonical(root)
            return target == r || target.hasPrefix(r + "/")
        }
    }

    func refusal(_ command: String, _ args: [String], cwd: String?) -> String? {
        RemoteAccess.refusal(command, args, cwd: cwd, allowed: allowed)
    }

    func exec(_ command: String, _ args: [String], cwd: String?) async -> RemoteResponse {
        if let why = refusal(command, args, cwd: cwd) { return .failed(why) }
        guard let model = service?.model else { return .failed("This Mac stopped sharing its agents.") }
        do { return .exec(try await model.executor.run(command, args, cwd: cwd)) } catch { return .failed(error.localizedDescription) }
    }

    func spawn(_ id: Int, _ spec: LaunchSpec) -> RemoteResponse {
        if let why = refusal(spec.command, spec.args, cwd: spec.cwd) { return .failed(why) }
        guard let model = service?.model else { return .failed("This Mac stopped sharing its agents.") }
        // Variables like GIT_SSH_COMMAND or DYLD_* would run programs; only a Revund key comes across.
        var spec = spec
        spec.env = RemoteAccess.environment(spec.env)
        spec.stdinInitial = nil
        do {
            processes[id] = try model.executor.spawn(spec, onLine: { [weak self] line in
                Task { @MainActor in self?.post(.event(.process(id: id, line))) }
            }, onExit: { [weak self] code in
                Task { @MainActor in
                    self?.processes[id] = nil
                    self?.post(.event(.processExit(id: id, code: code)))
                }
            })
            return .ok
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    func readFile(_ path: String) async -> RemoteResponse {
        guard allowed(path) else { return .failed("That file isn't in one of this Mac's projects.") }
        guard let info = FileInfo.local(path), !info.isDirectory else { return .failed("No file at \(path).") }
        guard info.size <= 12 << 20 else { return .failed("That file is too big to open from another Mac.") }
        do { return .data(try Data(contentsOf: URL(fileURLWithPath: path))) } catch { return .failed(error.localizedDescription) }
    }

    func writeFile(_ path: String, _ data: Data) -> RemoteResponse {
        guard allowed(path) else { return .failed("That file isn't in one of this Mac's projects.") }
        do {
            try data.write(to: URL(fileURLWithPath: path))
            return .ok
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    func fileInfo(_ path: String) -> RemoteResponse {
        allowed(path) ? .fileInfo(FileInfo.local(path)) : .fileInfo(nil)
    }

    func listFiles(_ root: String) async -> RemoteResponse {
        guard allowed(root) else { return .failed("That folder isn't one of this Mac's projects.") }
        let (paths, truncated) = await Task.detached { FileIndex.walk(root) }.value
        return .files(paths, truncated: truncated)
    }

    func watch(_ id: Int, _ paths: [String]) -> RemoteResponse {
        let paths = paths.filter { allowed($0) }
        guard !paths.isEmpty else { return .failed("Those folders aren't in this Mac's projects.") }
        watchers[id] = WorktreeWatcher(paths: paths) { [weak self] in self?.post(.event(.changed(watchId: id))) }
        return .ok
    }

    /// The other Mac went: what it started here stops.
    func endStreams() {
        for process in processes.values { process.terminate() }
        processes = [:]
        watchers = [:]
        for terminal in terminals.values { terminal.close() }
        terminals = [:]
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

// MARK: - Which Mac a chat's work happens on

extension RemoteService {
    /// Runs commands and reads files on the paired Mac.
    func executor(for device: String) -> RemoteExecutor {
        let home = links[device]?.snapshot?.home ?? "/"
        if let existing = executors[device], existing.homeDirectory == home { return existing }
        let executor = RemoteExecutor(device: device, home: home, service: self)
        executors[device] = executor
        return executor
    }

    /// A project on a paired Mac.
    func project(_ id: String) -> Project? {
        for link in links.values { if let p = link.snapshot?.projects.first(where: { $0.id == id }) { return p } }
        return nil
    }

    /// The paired Mac a project lives on.
    func device(ofProject id: String) -> String? {
        links.first { $0.value.snapshot?.projects.contains { $0.id == id } == true }?.key
    }
}

extension AppModel {
    /// Where a chat's commands and files are: this Mac, or the Mac a chat
    /// from another device runs on.
    func executor(for sessionId: String?) -> any Executor {
        guard let sessionId, let (device, _) = RemoteService.split(sessionId) else { return executor }
        return remote.executor(for: device)
    }

    /// Where a project's commands run: here, or on the Mac it lives on.
    func executor(forProject id: String?) -> any Executor {
        guard let id, !projects.contains(where: { $0.id == id }), let device = remote.device(ofProject: id) else { return executor }
        return remote.executor(for: device)
    }

    /// The link to the Mac a chat runs on, for a chat from another device.
    func remoteLink(for sessionId: String?) -> RemoteLink? {
        guard let sessionId, RemoteService.split(sessionId) != nil else { return nil }
        return remote.link(for: sessionId)
    }

    /// Calls `onChange` when something under `paths` changes, wherever the
    /// chat's worktree is. Kept alive by holding the returned object.
    func watch(_ paths: [String], for sessionId: String, onChange: @escaping () -> Void) -> AnyObject? {
        if let link = remoteLink(for: sessionId) { return link.watch(paths, onChange: onChange) }
        return WorktreeWatcher(paths: paths, onChange: onChange)
    }
}

extension EnvironmentValues {
    /// The worktree shown is on another Mac: Finder and apps here can't open its files.
    @Entry var worktreeIsRemote = false
}
