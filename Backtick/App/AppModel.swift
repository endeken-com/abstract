import AppKit
import Foundation
import Observation
import SwiftUI
import BacktickCore

/// Where the main area is pointed.
enum Destination: Hashable {
    case home
    case session(String)
    case automations
    case worktrees
}

enum ChatTab: String, Hashable { case chat, changes }

struct PendingPermission: Identifiable, Hashable {
    var id: String { requestId }
    let requestId: String
    let toolName: String
    let input: JSONValue
}

struct ProviderStatus: Hashable {
    var available: Bool
    var path: String?
    var version: String?
}

struct ProviderOverride: Codable, Hashable {
    var path: String?
    var extraArgs: [String]?
}

/// The app's single source of truth. Views read it; actions go through it;
/// it writes through to the store and drives the session engine.
@Observable
@MainActor
final class AppModel {
    // Services
    let store: Store
    let engine: SessionEngine
    let executor: any Executor
    let isDemo: Bool

    // Data
    var projects: [Project] = []
    var sessions: [Session] = []
    var automations: [Automation] = []
    var providerStatus: [String: ProviderStatus] = [:]
    private(set) var timelines: [String: Timeline] = [:]
    private(set) var permissions: [String: [PendingPermission]] = [:]
    private(set) var alive: Set<String> = []
    /// When each session's current turn started, for the "working for 12s" label.
    private(set) var turnStartedAt: [String: Date] = [:]

    // Navigation & transient UI
    var destination: Destination = .home
    var chatTab: ChatTab = .chat
    var collapsedProjects: Set<String> = []
    var showArchived = false
    var newChatProjectId: String?? = nil
    var isAddingProject = false
    var isPaletteOpen = false
    var toast: Toast?
    /// Bumped to pull keyboard focus into the New screen's prompt.
    var focusLauncherToken = 0

    /// "+ New": the New screen with its prompt focused.
    func startNew() {
        destination = .home
        isPaletteOpen = false
        focusLauncherToken += 1
    }

    // Settings
    var worktreeTemplate: String { didSet { save("worktreeTemplate", worktreeTemplate) } }
    var branchPrefix: String { didSet { save("branchPrefix", branchPrefix) } }
    var providerOverrides: [String: ProviderOverride] { didSet { save("providerOverrides", providerOverrides) } }
    var notifyAttention: Bool { didSet { save("notifyAttention", notifyAttention) } }
    var notifyFinished: Bool { didSet { save("notifyFinished", notifyFinished) } }
    var notifyAutomationFailed: Bool { didSet { save("notifyAutomationFailed", notifyAutomationFailed) } }
    var defaultTimezone: String { didSet { save("defaultTimezone", defaultTimezone) } }

    private var parsers: [String: any OutputParser] = [:]
    private var seenSeq: [String: Int] = [:]
    @ObservationIgnored var scheduler: AutomationScheduler?

    init(store: Store, engine: SessionEngine, executor: any Executor, isDemo: Bool = false) {
        self.store = store
        self.engine = engine
        self.executor = executor
        self.isDemo = isDemo
        worktreeTemplate = store.setting("worktreeTemplate", as: String.self) ?? WorktreeNaming.defaultTemplate
        branchPrefix = store.setting("branchPrefix", as: String.self) ?? WorktreeNaming.defaultBranchPrefix
        providerOverrides = store.setting("providerOverrides", as: [String: ProviderOverride].self) ?? [:]
        notifyAttention = store.setting("notifyAttention", as: Bool.self) ?? true
        notifyFinished = store.setting("notifyFinished", as: Bool.self) ?? true
        notifyAutomationFailed = store.setting("notifyAutomationFailed", as: Bool.self) ?? true
        defaultTimezone = store.setting("defaultTimezone", as: String.self) ?? TimeZone.current.identifier
    }

    private func save<T: Codable>(_ key: String, _ value: T) {
        try? store.setSetting(key, value)
    }

    // MARK: - Bootstrap

    func bootstrap() async {
        _ = try? store.reconcileInterruptedSessions()
        reload()
        Task { await listen() }
        Task { await detectProviders() }
        scheduler = AutomationScheduler(model: self)
        scheduler?.start()
        Notifier.shared.requestAuthorization()
    }

    func reload() {
        projects = (try? store.projects()) ?? []
        sessions = (try? store.sessions()) ?? []
        automations = (try? store.automations()) ?? []
        alive = engine.aliveSessionIds
    }

    func detectProviders() async {
        for provider in ProviderRegistry.all {
            let override = providerOverrides[provider.id]?.path
            let path: String? = if let override, !override.isEmpty { executor.fileExists(override) ? override : nil }
                else { await executor.which(provider.binary) }
            var version: String?
            if let path, let result = try? await executor.run(path, provider.detectArgs, cwd: nil), result.ok {
                version = result.stdout.split(separator: "\n").first.map { String($0).trimmingCharacters(in: .whitespaces) }
            }
            providerStatus[provider.id] = ProviderStatus(available: path != nil, path: path, version: version)
        }
    }

    // MARK: - Models

    /// What the agent runs when no model is chosen, from its own config file.
    func defaultModel(for providerId: String) -> String? {
        ProviderRegistry.provider(providerId)?.configuredDefaultModel(home: executor.homeDirectory)
    }

    /// Human label for a chat's model, e.g. "Sonnet" or "Default (opus[1m])".
    func modelLabel(providerId: String, model: String?) -> String {
        if let model, !model.isEmpty {
            return ProviderRegistry.provider(providerId)?.models.first { $0.id == model }?.label ?? model
        }
        return defaultModel(for: providerId).map { "Default (\($0))" } ?? "Default model"
    }

    // MARK: - Lookups

    func project(_ id: String?) -> Project? { id.flatMap { id in projects.first { $0.id == id } } }
    func session(_ id: String?) -> Session? { id.flatMap { id in sessions.first { $0.id == id } } }
    func timeline(_ sessionId: String) -> Timeline { timelines[sessionId] ?? Timeline() }
    func pendingPermissions(_ sessionId: String) -> [PendingPermission] { permissions[sessionId] ?? [] }
    func isAlive(_ sessionId: String) -> Bool { alive.contains(sessionId) }

    var selectedSession: Session? {
        if case .session(let id) = destination { return session(id) }
        return nil
    }

    func sessions(in projectId: String?) -> [Session] {
        sessions.filter { $0.projectId == projectId && (showArchived || $0.archivedAt == nil) }
    }

    var needsYou: [Session] {
        sessions.filter { $0.status == .waitingInput && $0.archivedAt == nil }
    }

    // MARK: - Navigation

    func open(_ sessionId: String) {
        if case .session(let current) = destination, current == sessionId { return }
        destination = .session(sessionId)
        chatTab = .chat
        loadTimelineIfNeeded(sessionId)
    }

    func showNewChat(in projectId: String?) {
        isPaletteOpen = false
        newChatProjectId = .some(projectId)
    }

    // MARK: - Projects

    struct Probe: Sendable {
        var rootPath: String
        var name: String
        var isRoot: Bool
        var nestedRepos: [String]
        var defaultBranch: String
    }

    func probe(directory: String) async throws -> Probe {
        let root = try await Git.repoRoot(executor, dir: directory)
        let nested = (try? await Git.nestedRepos(executor, root: root)) ?? []
        let branch = ((try? await Git.currentBranch(executor, root: root)) ?? nil) ?? "HEAD"
        let rootURL = URL(fileURLWithPath: root).standardizedFileURL
        let dirURL = URL(fileURLWithPath: directory).standardizedFileURL
        return Probe(rootPath: root, name: rootURL.lastPathComponent, isRoot: rootURL.path == dirURL.path,
                     nestedRepos: nested, defaultBranch: branch)
    }

    func addProject(_ probe: Probe, name: String, baseRef: String, providerId: String, policy: PermissionPolicy) throws {
        if let existing = projects.first(where: { $0.rootPath == probe.rootPath }) {
            throw BacktickError.message("\(probe.rootPath) is already the project “\(existing.name)”.")
        }
        let project = Project(name: name.isEmpty ? probe.name : name, rootPath: probe.rootPath, defaultBaseRef: baseRef,
                              defaultProviderId: providerId, defaultPermissionPolicy: policy,
                              nestedRepos: probe.nestedRepos, sortOrder: projects.count)
        try store.save(project)
        reload()
        flash("\(project.name) added")
    }

    func removeProject(_ id: String) {
        for s in sessions where s.projectId == id { engine.stop(sessionId: s.id) }
        try? store.deleteProject(id)
        if case .session(let sid) = destination, session(sid)?.projectId == id { destination = .home }
        reload()
    }

    func updateProject(_ project: Project) {
        try? store.save(project)
        reload()
    }

    // MARK: - Chats

    func startChat(projectId: String, providerId: String, prompt: String, baseRef: String?, policy: PermissionPolicy,
                   model: String? = nil) async throws {
        guard let project = project(projectId) else { throw BacktickError.notFound("project") }
        let name = Workspace.title(fromPrompt: prompt)
        var session = Session(projectId: projectId, name: name, providerId: providerId, baseRef: baseRef,
                              status: .provisioning, permissionPolicy: policy, prompt: prompt, model: model)
        let workspace = try await Workspace.provision(
            executor: executor, project: project, name: name, baseRef: baseRef,
            template: project.worktreeTemplate ?? worktreeTemplate, prefix: project.branchPrefix ?? branchPrefix
        )
        session.worktreePath = workspace.path
        session.branch = workspace.branch
        try store.save(session)
        reload()
        timelines[session.id] = Timeline()
        destination = .session(session.id)
        chatTab = .chat
        try launch(session, prompt: prompt, resume: false)
    }

    /// Spawn (or respawn) the agent for a session.
    func launch(_ session: Session, prompt: String, resume: Bool) throws {
        guard let provider = ProviderRegistry.provider(session.providerId) else {
            throw BacktickError.message("Unknown agent “\(session.providerId)”.")
        }
        let override = providerOverrides[provider.id]
        let ctx = LaunchContext(cwd: session.worktreePath ?? executor.homeDirectory, prompt: prompt,
                                permissionPolicy: session.permissionPolicy, extraArgs: override?.extraArgs ?? [],
                                binaryOverride: override?.path.flatMap { $0.isEmpty ? nil : $0 }, model: session.model)
        var spec = resume && session.providerSessionId != nil
            ? provider.buildResume(ctx, resumeId: session.providerSessionId!)
            : provider.buildLaunch(ctx)
        if isDemo { spec = DemoAgent.wrap(spec, session: session, prompt: prompt, followUp: resume) }
        parsers[session.id] = provider.makeParser()
        if timelines[session.id] == nil { loadTimelineIfNeeded(session.id) }
        try engine.launch(sessionId: session.id, spec: spec)
        alive.insert(session.id)
        turnStartedAt[session.id] = Date()
        setStatus(session.id, .running)
    }

    func sendFollowUp(_ sessionId: String, text: String) throws {
        guard let session = session(sessionId), let provider = ProviderRegistry.provider(session.providerId) else { return }
        append(.text(role: .user, text: text, blockId: nil, partial: false), to: sessionId)
        if provider.followUpMode == .stdin, isAlive(sessionId), let line = provider.buildUserMessage(text) {
            try engine.write(sessionId: sessionId, isDemo ? DemoAgent.followUpLine(text) : line)
            turnStartedAt[sessionId] = Date()
            setStatus(sessionId, .running)
        } else {
            try launch(session, prompt: text, resume: true)
        }
    }

    func answerPermission(_ sessionId: String, requestId: String, allow: Bool) {
        guard let session = session(sessionId), let provider = ProviderRegistry.provider(session.providerId) else { return }
        let request = permissions[sessionId]?.first { $0.requestId == requestId }
        if let line = provider.buildPermissionResponse(requestId: requestId, allow: allow, input: request?.input) {
            do { try engine.write(sessionId: sessionId, line) } catch { flash(error.localizedDescription, isError: true) }
        }
        permissions[sessionId]?.removeAll { $0.requestId == requestId }
        setStatus(sessionId, .running)
    }

    func stop(_ sessionId: String) {
        engine.stop(sessionId: sessionId)
    }

    func resume(_ sessionId: String) {
        guard let session = session(sessionId) else { return }
        do {
            try launch(session, prompt: session.providerSessionId == nil ? (session.prompt ?? "") : "Continue where you left off.",
                       resume: session.providerSessionId != nil)
        } catch {
            flash(error.localizedDescription, isError: true)
        }
    }

    func rename(_ sessionId: String, to name: String) {
        guard var s = session(sessionId), !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        s.name = name.trimmingCharacters(in: .whitespaces)
        try? store.save(s)
        reload()
    }

    func setArchived(_ sessionId: String, _ archived: Bool) {
        guard var s = session(sessionId) else { return }
        s.archivedAt = archived ? Date() : nil
        try? store.save(s)
        if archived, case .session(let id) = destination, id == sessionId { destination = .home }
        reload()
    }

    func delete(_ sessionId: String, removeWorktree: Bool) async {
        guard let s = session(sessionId) else { return }
        engine.stop(sessionId: sessionId)
        if removeWorktree, let path = s.worktreePath, let project = project(s.projectId) {
            do {
                try await Git.removeWorktree(executor, root: project.rootPath, path: path, deleteBranch: nil)
            } catch {
                flash("Worktree not removed: \(error.localizedDescription)", isError: true)
            }
        }
        engine.deleteLog(sessionId: sessionId)
        try? store.deleteSession(sessionId)
        timelines[sessionId] = nil
        permissions[sessionId] = nil
        parsers[sessionId] = nil
        if case .session(let id) = destination, id == sessionId { destination = .home }
        reload()
    }

    // MARK: - Engine events

    private func listen() async {
        for await event in engine.events {
            handle(event)
        }
    }

    private func handle(_ event: EngineEvent) {
        switch event {
        case let .line(sessionId, seq, line):
            guard seq > (seenSeq[sessionId] ?? 0) else { return }
            seenSeq[sessionId] = seq
            guard let parser = parser(for: sessionId) else { return }
            for e in parser.feed(line.line, stream: line.stream) { apply(e, to: sessionId) }
        case let .exit(sessionId, code):
            alive.remove(sessionId)
            if let parser = parsers[sessionId] {
                for e in parser.onExit(code: code) { apply(e, to: sessionId) }
            }
            if let s = session(sessionId), s.status.isActive {
                setStatus(sessionId, code == 0 ? .finished : .errored, detail: code == 0 ? nil : "Exited with code \(code.map(String.init) ?? "?")")
            }
            permissions[sessionId] = nil
        }
    }

    private func parser(for sessionId: String) -> (any OutputParser)? {
        if let p = parsers[sessionId] { return p }
        guard let s = session(sessionId), let provider = ProviderRegistry.provider(s.providerId) else { return nil }
        let p = provider.makeParser()
        parsers[sessionId] = p
        return p
    }

    private func apply(_ event: AgentEvent, to sessionId: String) {
        switch event {
        case .sessionId(let id):
            if var s = session(sessionId), s.providerSessionId != id {
                s.providerSessionId = id
                try? store.save(s)
                replaceSession(s)
            }
        case let .status(status, detail):
            setStatus(sessionId, status, detail: detail)
            if status == .idle { notify(sessionId, .finished) }
            if status == .waitingInput || status == .errored { notify(sessionId, status, detail: detail) }
        case let .permissionRequest(requestId, toolName, input):
            permissions[sessionId, default: []].append(PendingPermission(requestId: requestId, toolName: toolName, input: input))
            setStatus(sessionId, .waitingInput, detail: "\(toolName) needs approval")
            notify(sessionId, .waitingInput, detail: "\(ProviderRegistry.name(session(sessionId)?.providerId ?? "")) wants to use \(toolName)")
        case let .usage(totals, cost, duration, turns):
            let s = session(sessionId)
            try? store.record(UsageRecord(sessionId: sessionId, projectId: s?.projectId, providerId: s?.providerId ?? "unknown",
                                          usage: totals, costUsd: cost ?? 0, durationMs: duration ?? 0, turns: turns ?? 1))
        default:
            break
        }
        append(event, to: sessionId)
    }

    private func append(_ event: AgentEvent, to sessionId: String) {
        var t = timelines[sessionId] ?? Timeline()
        t.append(event)
        timelines[sessionId] = t
    }

    func setStatus(_ sessionId: String, _ status: SessionStatus, detail: String? = nil) {
        try? store.updateSessionStatus(sessionId, status, detail: detail)
        guard var s = session(sessionId) else { return }
        s.status = status
        s.statusDetail = detail
        s.lastEventAt = Date()
        replaceSession(s)
    }

    private func replaceSession(_ s: Session) {
        if let i = sessions.firstIndex(where: { $0.id == s.id }) { sessions[i] = s }
    }

    private func loadTimelineIfNeeded(_ sessionId: String) {
        guard timelines[sessionId] == nil, let s = session(sessionId), let provider = ProviderRegistry.provider(s.providerId) else { return }
        let parser = provider.makeParser()
        var t = Timeline()
        var maxSeq = 0
        for (seq, line) in engine.replay(sessionId: sessionId) {
            maxSeq = seq
            for e in parser.feed(line.line, stream: line.stream) {
                if case .permissionRequest = e { continue }
                t.append(e)
            }
        }
        timelines[sessionId] = t
        seenSeq[sessionId] = max(seenSeq[sessionId] ?? 0, maxSeq)
        if isAlive(sessionId) { parsers[sessionId] = parsers[sessionId] ?? parser }
    }

    // MARK: - Feedback

    struct Toast: Identifiable, Equatable {
        let id = UUID()
        let message: String
        let isError: Bool
    }

    func flash(_ message: String, isError: Bool = false) {
        toast = Toast(message: message, isError: isError)
        let id = toast?.id
        Task {
            try? await Task.sleep(for: .seconds(isError ? 5 : 2.5))
            if self.toast?.id == id { withAnimation(.snappy) { self.toast = nil } }
        }
    }

    private func notify(_ sessionId: String, _ status: SessionStatus, detail: String? = nil) {
        guard let s = session(sessionId) else { return }
        switch status {
        case .waitingInput where !notifyAttention: return
        case .finished where !notifyFinished: return
        default: break
        }
        if NSApp.isActive, case .session(let id) = destination, id == sessionId { return }
        let title = status == .waitingInput ? "\(s.name) needs you" : status == .errored ? "\(s.name) hit an error" : "\(s.name) is done"
        Notifier.shared.post(title: title, body: detail ?? project(s.projectId)?.name ?? "", sessionId: sessionId)
    }
}
