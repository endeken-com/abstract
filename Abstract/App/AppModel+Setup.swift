import AppKit
import Foundation
import Synchronization
import AbstractCore

/// A new chat getting ready before its agent starts: its base fetched fresh
/// from `origin`, its worktree made from it, the project's setup script run
/// in it. The chat shows this in place of the agent at work (`ChatSetupCard`);
/// a step that fails waits there to be retried or skipped.
@Observable
@MainActor
final class ChatSetup {
    enum Step: CaseIterable { case fetch, worktree, script, agent }

    enum Phase: Equatable {
        case pending, running, done, skipped
        case failed(String)
    }

    private(set) var phases: [Step: Phase] = Dictionary(uniqueKeysWithValues: Step.allCases.map { ($0, .pending) })
    private(set) var startedAt: [Step: Date] = [:]
    private(set) var endedAt: [Step: Date] = [:]
    /// Where the worktree starts, once asked.
    var base: Workspace.Base?
    /// What the setup script printed: its latest `logLimit` lines.
    private(set) var log: [String] = []
    static let logLimit = 2_000

    // What running it (again) needs; nothing shows it.
    @ObservationIgnored let projectId: String
    @ObservationIgnored let baseRef: String?
    @ObservationIgnored let images: [String]
    /// The folder's name in the worktree template.
    @ObservationIgnored let worktreeName: String?
    /// The branch's name, when it's settled before the worktree is made.
    @ObservationIgnored var slug: String?
    /// The model's title and branch for the chat, still coming; the chat is
    /// renamed only if it still has `provisionalName`.
    @ObservationIgnored var naming: Task<ChatNaming.Suggestion?, Never>?
    @ObservationIgnored var provisionalName: String?
    @ObservationIgnored var task: Task<Void, Never>?
    /// Between asking for a run and its end, so it never runs twice at once.
    @ObservationIgnored var active = false
    /// Which run is the current one: a stopped run ending late leaves a newer one be.
    @ObservationIgnored var generation = 0

    init(projectId: String, baseRef: String?, images: [String] = [], worktreeName: String?, slug: String? = nil) {
        self.projectId = projectId
        self.baseRef = baseRef
        self.images = images
        self.worktreeName = worktreeName
        self.slug = slug
    }

    func phase(_ step: Step) -> Phase { phases[step] ?? .pending }
    var running: Step? { Step.allCases.first { phase($0) == .running } }
    var failure: (step: Step, message: String)? {
        for step in Step.allCases { if case .failed(let message) = phase(step) { return (step, message) } }
        return nil
    }

    func begin(_ step: Step) {
        phases[step] = .running
        startedAt[step] = Date()
        endedAt[step] = nil
        if step == .script { log = [] }
    }

    func finish(_ step: Step) {
        phases[step] = .done
        endedAt[step] = Date()
    }

    func skip(_ step: Step) {
        phases[step] = .skipped
        endedAt[step] = Date()
    }

    func fail(_ step: Step, _ message: String) {
        phases[step] = .failed(message)
        endedAt[step] = Date()
    }

    /// Trying again: the failed step waits its turn, its message gone at once.
    func clearFailure() {
        for step in Step.allCases { if case .failed = phase(step) { phases[step] = .pending } }
    }

    func append(_ lines: [String]) {
        guard !lines.isEmpty else { return }
        log.append(contentsOf: lines)
        if log.count > Self.logLimit { log.removeFirst(log.count - Self.logLimit) }
    }
}

/// Lines from a background queue, collected until the main actor takes them
/// in a batch: a chatty install then redraws a few times a second, not per line.
nonisolated private final class LineBuffer: Sendable {
    private let lines = Mutex<[String]>([])
    func append(_ line: String) { lines.withLock { $0.append(line) } }
    func drain() -> [String] { lines.withLock { l in defer { l = [] }; return l } }
}

extension AppModel {
    /// A project chat whose setup never finished (Abstract quit during it):
    /// no worktree and no branch yet, and its agent never ran.
    func neverSetUp(_ s: Session) -> Bool {
        s.projectId != nil && s.worktreePath == nil && s.branch == nil && s.providerSessionId == nil && s.handoffFrom == nil
    }

    /// A folder name for a project's next worktree, unlike its chats' others.
    func worktreeCityName(projectId: String) -> String {
        WorktreeNaming.cityName(avoiding: Set(sessions
            .filter { $0.projectId == projectId }
            .compactMap { $0.worktreePath.map { URL(fileURLWithPath: $0).lastPathComponent } }))
    }

    /// Chats caught mid-setup when Abstract last quit wait to be set up again.
    func restoreInterruptedSetups() {
        for s in sessions where neverSetUp(s) && setups[s.id] == nil && s.archivedAt == nil {
            guard let projectId = s.projectId else { continue }
            let setup = ChatSetup(projectId: projectId, baseRef: s.baseRef, worktreeName: worktreeCityName(projectId: projectId))
            setup.fail(.fetch, "Abstract quit before this chat was set up.")
            setups[s.id] = setup
        }
    }

    /// Set the chat up, then start its agent.
    func beginSetup(_ sessionId: String, _ setup: ChatSetup) {
        setups[sessionId] = setup
        runSetup(sessionId)
    }

    /// Runs every step not done yet: the first time, or again after one failed.
    func runSetup(_ sessionId: String) {
        guard let setup = setups[sessionId], !setup.active else { return }
        setup.active = true
        setup.clearFailure()
        setup.generation += 1
        let generation = setup.generation
        setup.task = Task { [weak self] in
            await self?.performSetup(sessionId, setup)
            if setup.generation == generation { setup.active = false }
        }
    }

    /// Stop: whatever step is running ends, and the chat waits to be retried.
    func cancelSetup(_ sessionId: String) {
        guard let setup = setups[sessionId], setup.active else { return }
        setup.task?.cancel()
        setup.active = false
        if let step = setup.running { setup.fail(step, "Stopped.") }
        setStatus(sessionId, .errored, detail: "Setup stopped")
    }

    /// Start the agent without the setup script, or without waiting for it to end.
    func skipSetupScript(_ sessionId: String) {
        guard let setup = setups[sessionId], session(sessionId)?.worktreePath != nil else { return }
        setup.task?.cancel()
        setup.active = false
        if setup.phase(.script) != .done { setup.skip(.script) }
        startAgent(sessionId, setup)
    }

    private func performSetup(_ id: String, _ setup: ChatSetup) async {
        guard let project = project(setup.projectId) else {
            failSetup(id, setup, .fetch, "The chat's project is no longer in Abstract.")
            return
        }

        if setup.phase(.fetch) != .done {
            let base = setup.baseRef.flatMap { $0.isEmpty ? nil : $0 } ?? project.defaultBaseRef
            setup.begin(.fetch)
            setStatus(id, .provisioning, detail: "Fetching \(base)")
            let fresh = await Workspace.freshBase(executor: executor, root: project.rootPath, base: base)
            guard !Task.isCancelled else { return }
            setup.base = fresh
            setup.finish(.fetch)
        }

        // Named by the model while fetching; the branch takes its name from it.
        if let naming = setup.naming {
            let suggestion = await naming.value
            setup.naming = nil
            if setup.slug == nil { setup.slug = suggestion?.branch }
            if let title = suggestion?.title, var s = session(id), s.name == setup.provisionalName {
                s.name = title
                try? store.save(s)
                reload()
            }
            guard !Task.isCancelled else { return }
        }

        if let s = session(id), s.worktreePath == nil {
            setup.begin(.worktree)
            setStatus(id, .provisioning, detail: "Creating the worktree")
            let provisioned: Workspace.Provisioned
            do {
                provisioned = try await Workspace.provision(
                    executor: executor, project: project, name: s.name, baseRef: setup.base?.ref,
                    template: project.worktreeTemplate ?? worktreeTemplate, prefix: project.branchPrefix ?? branchPrefix,
                    slug: setup.slug, worktreeName: setup.worktreeName)
            } catch {
                if !Task.isCancelled { failSetup(id, setup, .worktree, error.localizedDescription) }
                return
            }
            // Deleted meanwhile: its worktree goes too.
            guard var current = session(id) else {
                try? await Git.removeWorktree(executor, root: project.rootPath, path: provisioned.path, deleteBranch: provisioned.branch)
                return
            }
            // Kept even when stopped meanwhile, so trying again reuses it.
            current.worktreePath = provisioned.path
            current.branch = provisioned.branch
            try? store.save(current)
            reload()
            guard !Task.isCancelled else { return }
            setup.finish(.worktree)
        } else if setup.phase(.worktree) != .done {
            setup.finish(.worktree)
        }

        if setup.phase(.script) != .done, setup.phase(.script) != .skipped {
            if let script = Project.nonBlank(project.setupScript), let path = session(id)?.worktreePath {
                guard await runSetupScript(id, setup, script: script, in: path) else { return }
            } else {
                setup.skip(.script)
            }
        }
        guard !Task.isCancelled else { return }
        startAgent(id, setup)
    }

    /// Runs the setup script, its output coming into the card. False when it
    /// failed or was stopped.
    private func runSetupScript(_ id: String, _ setup: ChatSetup, script: String, in path: String) async -> Bool {
        setup.begin(.script)
        setStatus(id, .provisioning, detail: "Running the setup script")
        let buffer = LineBuffer()
        let pump = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(150))
                setup.append(buffer.drain())
            }
        }
        defer { pump.cancel() }
        let code: Int32?
        do {
            code = try await SetupScript.run(script, in: path, executor: executor) { buffer.append($0) }
        } catch {
            setup.append(buffer.drain())
            if !(error is CancellationError), !Task.isCancelled {
                failSetup(id, setup, .script, "The setup script didn't run: \(error.localizedDescription)")
            }
            return false
        }
        setup.append(buffer.drain())
        guard !Task.isCancelled else { return false }
        guard code == 0 else {
            failSetup(id, setup, .script, code.map { "The setup script exited with code \($0)." } ?? "The setup script was stopped.")
            return false
        }
        setup.finish(.script)
        return true
    }

    private func startAgent(_ id: String, _ setup: ChatSetup) {
        guard let session = session(id) else { return }
        setup.begin(.agent)
        do {
            try launch(session, prompt: session.prompt ?? "", resume: false, images: setup.images)
            setups[id] = nil
        } catch {
            failSetup(id, setup, .agent, error.localizedDescription)
        }
    }

    private func failSetup(_ id: String, _ setup: ChatSetup, _ step: ChatSetup.Step, _ message: String) {
        setup.fail(step, message)
        setStatus(id, .errored, detail: "Setup failed")
        guard notifyAttention, let s = session(id) else { return }
        if NSApp.isActive, case .session(let shown) = destination, shown == id { return }
        Notifier.shared.post(title: "\(s.name) couldn't be set up", body: message, sessionId: id)
    }
}
