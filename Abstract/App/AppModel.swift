import AppKit
import Foundation
import Observation
import SwiftUI
import AbstractCore

/// Where the main area is pointed.
enum Destination: Hashable {
    case home
    case session(String)
    case automations
    case worktrees
    case pullRequests
    /// A project's settings page, by project id.
    case projectSettings(String)
}

/// What a tab shows of a chat: it changes when the chat is renamed, not
/// as its agent works.
struct ChatSummary: Equatable {
    var name: String
    var providerId: String
    var worktreePath: String?

    init(_ session: Session) { name = session.name; providerId = session.providerId; worktreePath = session.worktreePath }
}

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
    var sessions: [Session] = [] { didSet { updateChatNames() } }
    /// Chats' names by id, changed only when a chat comes, goes or is renamed:
    /// what the window's title and routing read, so a status changing mid-turn
    /// redraws only what shows status, not the whole window.
    private(set) var chatNames: [String: String] = [:]
    /// The same for what tabs show: a chat's agent and worktree.
    private(set) var chatSummaries: [String: ChatSummary] = [:]
    /// Unarchived chats, most recently active first; changes only when the order does.
    private(set) var recentChats: [String] = []
    var automations: [Automation] = []
    var providerStatus: [String: ProviderStatus] = [:]
    /// Each agent's models: the copy cached at the last launch until the CLI
    /// has been asked again. See `refreshModels`.
    private(set) var modelCatalogs: [String: ModelCatalog] = [:]
    @ObservationIgnored private var feeds: [String: ChatFeed] = [:]
    private(set) var permissions: [String: [PendingPermission]] = [:]
    private(set) var alive: Set<String> = []
    /// Chats mid-turn. An idle chat's agent is alive too, awaiting a follow-up,
    /// but stopping it loses nothing.
    var workingSessionIds: [String] {
        alive.filter { id in session(id).map { $0.status.isActive && $0.status != .idle } ?? false }
    }
    /// When each session's current turn started, for the "working for 12s" label.
    private(set) var turnStartedAt: [String: Date] = [:]
    /// Panel layouts by chat id; see AppModel+Panes.
    var layouts: [String: PanelLayout] = [:]
    /// Where each local model server is reached, and whether this Mac shares its own; see AppModel+LocalModels.
    var localModelSources: [LocalModelKind: LocalModelSource] = [:] { didSet { save("localModelSources", localModelSources) } }
    var shareLocalModels = true { didSet { save("shareLocalModels", shareLocalModels) } }
    /// What each server said the last time it was asked.
    var localModelStatus: [LocalModelKind: LocalModelServerStatus] = [:]
    /// Relays to a paired Mac's servers, by kind.
    @ObservationIgnored var localRelays: [LocalModelKind: LocalModelRelay] = [:]
    /// A chat waiting on "Archive?" (⇧⌘⌫, or the git actions menu).
    var requestArchive: String?
    /// The background tasks list showing, and the task open in it; see AppModel+Tasks.
    var tasksOpen: TasksFocus?
    /// The main pane's tabs: chats, files and changes; see AppModel+MainTabs.
    var mainTabs = MainTabs() { didSet { if mainTabs != oldValue { save("mainTabs", mainTabs) } } }
    /// The side panel's width on screen, per chat, so its tabs can sit in the
    /// title band above it. Transient.
    var sidePanelWidth: [String: CGFloat] = [:]
    /// The main pane's width on screen, so its tabs can sit in the title band
    /// above it. Transient.
    var mainColumnWidth: CGFloat = 0
    /// Chats whose agent restarts before its next message: the agent, model
    /// or effort changed while it was running.
    var needsRelaunch: Set<String> = []
    /// Attachments waiting in each chat's composer, kept while you look at other tabs.
    var draftAttachments: [String: [PromptAttachment]] = [:]
    /// Chats being restarted on purpose; their exit is not an error.
    private var relaunching: Set<String> = []
    /// Tool names to approve without asking, per chat.
    var autoContinueTools: [String: Set<String>] = [:]
    /// A file the Changes pane should select next time it loads, per chat.
    var pendingChangeSelection: [String: String] = [:]
    /// The agents' accounts and their limits, and token use from their logs.
    let accounts = AccountsStore()
    let usage = UsageLedger()
    /// Other Macs on the network: pairing, and driving their agents or letting them drive these.
    let remote: RemoteService
    /// The Claude profile (a `CLAUDE_CONFIG_DIR`) new chats sign in with; nil is `~/.claude`.
    var claudeProfile: String? { didSet { save("claudeProfile", claudeProfile) } }
    /// Which profile each running Claude chat was started with, for its limit reports.
    @ObservationIgnored private var sessionProfiles: [String: String] = [:]

    /// Line comments waiting to go to each chat's agent, by chat id.
    var lineComments: [String: [LineComment]] = [:]
    /// Each chat's pull request, by chat id: the list's summary, or the full
    /// detail once its tab has loaded it.
    var pullRequests: [String: PullRequest] = [:]
    /// Recent pull requests of each GitHub project, by project id.
    var projectPullRequests: [String: [PullRequest]] = [:]
    var githubAccess: GitHubAccess?
    var githubViewer: String?
    /// Whether each project's origin is on GitHub, by project id.
    @ObservationIgnored var githubProjects: [String: Bool] = [:]

    // Navigation & transient UI
    var destination: Destination = .home
    var collapsedProjects: Set<String> = []
    var showArchived = false
    var newChatProjectId: String?? = nil
    /// A worktree the next New Chat should start in, from "New Chat Here".
    var newChatWorktree: String?
    var isAddingProject = false
    var isPaletteOpen = false
    var isSettingsOpen = false
    /// Bumped by the toolbar's + on the Automations screen, which then opens a new draft.
    var newAutomationRequest = 0
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
    /// How agents write their answers. Running chats pick it up from their
    /// next message, by restarting into the same conversation.
    var outputStyle: OutputStyle {
        didSet {
            save("outputStyle", outputStyle)
            if outputStyle != oldValue { needsRelaunch.formUnion(alive) }
        }
    }

    @ObservationIgnored private var parsers: [String: any OutputParser] = [:]
    @ObservationIgnored private var seenSeq: [String: Int] = [:]
    @ObservationIgnored private var configuredModels: [String: (model: String?, read: Date)] = [:]
    @ObservationIgnored var scheduler: AutomationScheduler?

    init(store: Store, engine: SessionEngine, executor: any Executor, isDemo: Bool = false) {
        self.store = store
        self.engine = engine
        self.executor = executor
        self.isDemo = isDemo
        remote = RemoteService(dataDirectory: engine.logsURL.deletingLastPathComponent())
        AttachmentStore.root = engine.logsURL.deletingLastPathComponent().appendingPathComponent("attachments")
        AttachmentStore.prune()
        worktreeTemplate = store.setting("worktreeTemplate", as: String.self) ?? WorktreeNaming.defaultTemplate
        branchPrefix = store.setting("branchPrefix", as: String.self) ?? WorktreeNaming.defaultBranchPrefix
        providerOverrides = store.setting("providerOverrides", as: [String: ProviderOverride].self) ?? [:]
        notifyAttention = store.setting("notifyAttention", as: Bool.self) ?? true
        notifyFinished = store.setting("notifyFinished", as: Bool.self) ?? true
        notifyAutomationFailed = store.setting("notifyAutomationFailed", as: Bool.self) ?? true
        defaultTimezone = store.setting("defaultTimezone", as: String.self) ?? TimeZone.current.identifier
        outputStyle = store.setting("outputStyle", as: OutputStyle.self) ?? .default
        claudeProfile = store.setting("claudeProfile", as: String.self)
        modelCatalogs = store.setting("modelCatalogs", as: [String: ModelCatalog].self) ?? [:]
        mainTabs = store.setting("mainTabs", as: MainTabs.self) ?? MainTabs()
        localModelSources = store.setting("localModelSources", as: [LocalModelKind: LocalModelSource].self) ?? [:]
        shareLocalModels = store.setting("shareLocalModels", as: Bool.self) ?? true
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
        Task { await refreshModels() }
        scheduler = AutomationScheduler(model: self)
        scheduler?.start()
        Task { await watchPullRequests() }
        if !isDemo { Task { await accounts.seedFromLogs(engine.logsURL) } }
        if !isDemo { remote.start(model: self) }
        if !isDemo { Task { await watchLocalModels() } }
        Notifier.shared.requestAuthorization()
    }

    private func updateChatNames() {
        let names = Dictionary(sessions.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        if names != chatNames { chatNames = names }
        let summaries = Dictionary(sessions.map { ($0.id, ChatSummary($0)) }, uniquingKeysWith: { first, _ in first })
        if summaries != chatSummaries { chatSummaries = summaries }
        let recent = sessions.filter { $0.archivedAt == nil }
            .sorted { ($0.lastEventAt ?? $0.createdAt) > ($1.lastEventAt ?? $1.createdAt) }.map(\.id)
        if recent != recentChats { recentChats = recent }
    }

    /// A chat's summary, here or on another Mac.
    func chatSummary(_ id: String) -> ChatSummary? {
        id.hasPrefix(RemoteService.mirrorPrefix) ? remote.mirror(id).map(ChatSummary.init) : chatSummaries[id]
    }

    /// A chat's name, here or on another Mac; nil when there's no such chat.
    func chatName(_ id: String) -> String? {
        id.hasPrefix(RemoteService.mirrorPrefix) ? remote.mirror(id)?.name : chatNames[id]
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
        // Local models also need their server: available only when it answers.
        await refreshLocalModels()
    }

    // MARK: - Models

    /// What the agent runs when no model is chosen, from its own config file.
    func defaultModel(for providerId: String) -> String? {
        // Menus ask on every redraw; the agent's settings file is read at most every few seconds.
        if let cached = configuredModels[providerId], cached.read.timeIntervalSinceNow > -5 { return cached.model }
        let model = ProviderRegistry.provider(providerId)?.configuredDefaultModel(home: executor.homeDirectory)
        configuredModels[providerId] = (model, Date())
        return model
    }

    /// The agent's models: discovered, else its built-in suggestions.
    func models(for providerId: String) -> ModelCatalog {
        modelCatalogs[providerId] ?? ProviderRegistry.provider(providerId)?.fallbackModels ?? .empty
    }

    /// The agent's models on a paired Mac (nil: this one), as that Mac last said.
    func models(for providerId: String, on device: String?) -> ModelCatalog {
        guard let device, let catalog = remote.links[device]?.snapshot?.modelCatalogs?[providerId] else { return models(for: providerId) }
        return catalog
    }

    func defaultModelName(for providerId: String, on device: String?) -> String? {
        guard device != nil else { return defaultModelName(for: providerId) }
        let catalog = models(for: providerId, on: device)
        return catalog.defaultOption(configured: nil).map { catalog.resolvedLabel($0) }
    }

    func efforts(providerId: String, model: String?, on device: String?) -> (levels: [String], defaultLevel: String?) {
        guard device != nil else { return efforts(providerId: providerId, model: model) }
        let catalog = models(for: providerId, on: device)
        guard let option = model.flatMap(catalog.option) ?? catalog.defaultOption(configured: nil), !option.efforts.isEmpty else { return ([], nil) }
        return (option.efforts, option.defaultEffort)
    }

    /// The model that runs when none is chosen.
    func defaultModelOption(for providerId: String) -> ModelOption? {
        models(for: providerId).defaultOption(configured: defaultModel(for: providerId))
    }

    /// Name of the model that runs when none is chosen, e.g. "Opus 5.5 · 1M context".
    func defaultModelName(for providerId: String) -> String? {
        defaultModelOption(for: providerId).map { models(for: providerId).resolvedLabel($0) }
    }

    /// Human label for a chat's model, e.g. "Sonnet" or "Default (Opus 5.5 · 1M context)".
    func modelLabel(providerId: String, model: String?) -> String {
        if let model, !model.isEmpty { return models(for: providerId).option(model)?.label ?? model }
        return defaultModelName(for: providerId).map { "Default (\($0))" } ?? "Default model"
    }

    /// The model label, plus the effort when one is set: "Sonnet · High".
    func modelSummary(_ session: Session) -> String {
        let label = modelLabel(providerId: session.providerId, model: session.model)
        return session.effort.map { "\(label) · \(ModelOption.effortTitle($0))" } ?? label
    }

    /// The effort levels a model takes (none for a name typed in that the
    /// catalogue doesn't know), and the one it runs at by default when known.
    func efforts(providerId: String, model: String?) -> (levels: [String], defaultLevel: String?) {
        let option = if let model { models(for: providerId).option(model) } else { defaultModelOption(for: providerId) }
        guard let option, !option.efforts.isEmpty else { return ([], nil) }
        let configured = ProviderRegistry.provider(providerId)?.configuredDefaultEffort(home: executor.homeDirectory)
        return (option.efforts, configured.flatMap { option.efforts.contains($0) ? $0 : nil } ?? option.defaultEffort)
    }

    /// `effort` if the model takes it, else nil (the agent's default).
    func supportedEffort(_ effort: String?, providerId: String, model: String?) -> String? {
        effort.flatMap { efforts(providerId: providerId, model: model).levels.contains($0) ? $0 : nil }
    }

    /// Asks each agent's CLI for the account's models and caches them for
    /// the next launch. An agent that can't tell keeps what it had.
    func updateModelCatalog(_ catalog: ModelCatalog, for providerId: String) {
        modelCatalogs[providerId] = catalog
    }

    func refreshModels() async {
        guard !isDemo else { return }
        for provider in ProviderRegistry.all {
            let override = providerOverrides[provider.id]?.path.flatMap { $0.isEmpty ? nil : $0 }
            guard let found = await provider.discoverModels(executor: executor, binary: override) else { continue }
            modelCatalogs[provider.id] = found
        }
        save("modelCatalogs", modelCatalogs)
    }

    // MARK: - Lookups

    /// A project here, or on a paired Mac.
    func project(_ id: String?) -> Project? { id.flatMap { id in projects.first { $0.id == id } ?? remote.project(id) } }
    func session(_ id: String?) -> Session? {
        guard let id else { return nil }
        if id.hasPrefix(RemoteService.mirrorPrefix) { return remote.mirror(id) }
        return sessions.first { $0.id == id }
    }
    /// The chat's timeline for its views. Stable per chat, so a view keeps
    /// observing the same one from before its log loads.
    func feed(_ sessionId: String) -> ChatFeed {
        if let feed = feeds[sessionId] { return feed }
        let feed = ChatFeed()
        feeds[sessionId] = feed
        return feed
    }
    func pendingPermissions(_ sessionId: String) -> [PendingPermission] { permissions[sessionId] ?? [] }
    func isAlive(_ sessionId: String) -> Bool {
        sessionId.hasPrefix(RemoteService.mirrorPrefix) ? remote.isAlive(sessionId) : alive.contains(sessionId)
    }

    var selectedSession: Session? {
        if case .session(let id) = destination { return session(id) }
        return nil
    }

    /// The chat showing, by id: reading it doesn't redraw a view whenever any chat's status changes.
    var selectedSessionId: String? {
        if case .session(let id) = destination { return id }
        return nil
    }

    func sessions(in projectId: String?) -> [Session] {
        sessions.filter { $0.projectId == projectId && (showArchived || $0.archivedAt == nil) }
    }

    var needsYou: [Session] {
        sessions.filter { $0.status == .waitingInput && $0.archivedAt == nil }
    }

    // MARK: - Navigation

    /// Show a chat: its tab, or in place of the chat showing (a new tab when asked).
    func open(_ sessionId: String, newTab: Bool = false) {
        mainTabs.openChat(sessionId, newTab: newTab)
        if case .session(let current) = destination, current == sessionId { return }
        destination = .session(sessionId)
        // A chat on another Mac streams its transcript from there.
        if sessionId.hasPrefix(RemoteService.mirrorPrefix) { remote.subscribe(sessionId); return }
        loadTimelineIfNeeded(sessionId)
    }

    func showNewChat(in projectId: String?, worktree: String? = nil) {
        isPaletteOpen = false
        newChatWorktree = worktree
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
            throw AbstractError.message("\(probe.rootPath) is already the project “\(existing.name)”.")
        }
        let project = Project(name: name.isEmpty ? probe.name : name, rootPath: probe.rootPath, defaultBaseRef: baseRef,
                              defaultProviderId: providerId, defaultPermissionPolicy: policy,
                              nestedRepos: probe.nestedRepos, sortOrder: projects.count)
        try store.save(project)
        reload()
        flash("\(project.name) added")
    }

    /// Drag and drop in the rail: put a project just before or after another.
    func moveProject(_ id: String, relativeTo target: String, after: Bool) {
        let order = Ordering.move(id, in: projects.map(\.id), to: target, after: after)
        guard order != projects.map(\.id) else { return }
        for (index, pid) in order.enumerated() {
            guard var p = project(pid), p.sortOrder != index else { continue }
            p.sortOrder = index
            try? store.save(p)
        }
        reload()
    }

    func removeProject(_ id: String) {
        for s in sessions where s.projectId == id { engine.stop(sessionId: s.id) }
        try? store.deleteProject(id)
        if case .session(let sid) = destination, session(sid)?.projectId == id { destination = .home }
        if destination == .projectSettings(id) { destination = .home }
        reload()
    }

    func updateProject(_ project: Project) {
        try? store.save(project)
        reload()
    }

    // MARK: - Chats

    /// Start a chat: in a fresh worktree from `baseRef`, or in `existing`, which
    /// it takes over from any chat using it.
    /// `select` opens the new chat here; a chat started from another device doesn't take over this screen.
    @discardableResult
    func startChat(projectId: String, providerId: String, prompt text: String, attachments: [PromptAttachment] = [], baseRef: String?,
                   policy: PermissionPolicy, model: String? = nil, effort: String? = nil, existing: WorktreeInfo? = nil,
                   select: Bool = true) async throws -> String {
        guard let project = project(projectId) else { throw AbstractError.notFound("project") }
        let prompt = PromptAttachments.message(text, attachments)
        // Named for what was asked, or for what was attached when nothing was typed.
        let gist = text.isEmpty ? attachments.map(\.label).joined(separator: ", ") : text
        // A new worktree in a project with naming instructions: a quick model call names it.
        let naming = existing == nil ? await suggestedNaming(project, prompt: gist) : nil
        let name = naming?.title ?? Workspace.title(fromPrompt: gist)
        var session = Session(projectId: projectId, name: name, providerId: providerId, baseRef: existing == nil ? baseRef : nil,
                              status: .provisioning, permissionPolicy: policy, prompt: prompt, model: model, effort: effort)
        if let existing {
            guard FileManager.default.fileExists(atPath: existing.path) else {
                throw AbstractError.message("That worktree's folder no longer exists.")
            }
            let previous = takeOverWorktree(existing.path, for: session.id)
            if let first = previous.first { flash("Took the worktree over from “\(first)”") }
            session.worktreePath = existing.path
            session.branch = existing.branch
        } else {
            let workspace = try await Workspace.provision(
                executor: executor, project: project, name: name, baseRef: baseRef,
                template: project.worktreeTemplate ?? worktreeTemplate, prefix: project.branchPrefix ?? branchPrefix,
                slug: naming?.branch
            )
            session.worktreePath = workspace.path
            session.branch = workspace.branch
        }
        try store.save(session)
        reload()
        feed(session.id).reset()
        if select { open(session.id, newTab: true) }
        // In a terminal under the chat, beside the agent, never before it.
        if existing == nil { runSetupScript(project, in: session) }
        engine.recordInput(sessionId: session.id, text: prompt)
        try launch(session, prompt: prompt, resume: false, images: PromptAttachments.images(attachments))
        return session.id
    }

    // MARK: - Reusing worktrees

    /// The chat currently holding a worktree, if any.
    func chat(usingWorktree path: String) -> Session? {
        let key = Self.canonical(path)
        return sessions.first { $0.worktreePath.map(Self.canonical) == key }
    }

    /// One worktree, one agent: a chat starting in `path` stops the agent of
    /// whichever chat had it and detaches that chat, so deleting it later
    /// can never remove a folder another chat now works in.
    @discardableResult
    private func takeOverWorktree(_ path: String, for newSessionId: String) -> [String] {
        let key = Self.canonical(path)
        var names: [String] = []
        for var other in sessions where other.id != newSessionId && other.worktreePath.map(Self.canonical) == key {
            engine.stop(sessionId: other.id)
            other.worktreePath = nil
            try? store.save(other)
            names.append(other.name)
        }
        return names
    }

    /// The project's linked worktrees a chat can start in: not the main
    /// working tree (accepted changes land there), and only folders that exist.
    func reusableWorktrees(projectId: String?) async -> [WorktreeInfo] {
        guard let project = project(projectId) else { return [] }
        // A project on another Mac: its worktrees are listed there.
        let local = projects.contains { $0.id == project.id }
        let all = (try? await Git.worktrees(executor(forProject: project.id), root: project.rootPath)) ?? []
        let root = local ? Self.canonical(project.rootPath) : project.rootPath
        return all.filter { !$0.isBare && (local ? Self.canonical($0.path) : $0.path) != root
            && (!local || FileManager.default.fileExists(atPath: $0.path)) }
    }

    /// Paths compared as the file system sees them (/var and /private/var, trailing slashes).
    static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Spawn (or respawn) the agent for a session.
    func launch(_ session: Session, prompt: String, resume: Bool, images: [String] = []) throws {
        // A project chat always works in its worktree, never a fallback folder.
        if session.projectId != nil, session.worktreePath == nil {
            throw AbstractError.message("This chat handed its worktree to a newer chat, so its agent can't run here again.")
        }
        guard let provider = ProviderRegistry.provider(session.providerId) else {
            throw AbstractError.message("Unknown agent “\(session.providerId)”.")
        }
        let override = providerOverrides[provider.id]
        let ctx = LaunchContext(cwd: session.worktreePath ?? executor.homeDirectory, prompt: prompt,
                                permissionPolicy: session.permissionPolicy, extraArgs: override?.extraArgs ?? [],
                                binaryOverride: override?.path.flatMap { $0.isEmpty ? nil : $0 }, model: session.model,
                                effort: session.effort, outputStyle: outputStyle, images: images,
                                readableDirs: [AttachmentStore.root.path])
        var resumeId = resume ? session.providerSessionId : nil
        // A chat started under another Claude account resumes under the one
        // chosen now: its conversation is copied across first. When no
        // account has it, the agent starts over rather than fail each time.
        if let id = resumeId, session.providerId == "claude", !isDemo {
            let target = claudeProfile ?? accounts.standardProfilePath
            let profiles = ClaudeAccounts.profiles(home: executor.homeDirectory).map(\.path)
            if !ClaudeAccounts.carryConversation(id, into: target, from: profiles) {
                resumeId = nil
                flash("The earlier conversation wasn't found, so the agent starts fresh in this worktree.")
            }
        }
        var spec = resumeId.map { provider.buildResume(ctx, resumeId: $0) } ?? provider.buildLaunch(ctx)
        if isDemo { spec = DemoAgent.wrap(spec, session: session, prompt: prompt, followUp: resume) }
        if session.providerId == "claude" {
            if let profile = claudeProfile, profile != accounts.standardProfilePath { spec.env["CLAUDE_CONFIG_DIR"] = profile }
            sessionProfiles[session.id] = claudeProfile ?? accounts.standardProfilePath
        }
        parsers[session.id] = provider.makeParser()
        loadTimelineIfNeeded(session.id)
        try engine.launch(sessionId: session.id, spec: spec)
        alive.insert(session.id)
        turnStartedAt[session.id] = Date()
        setStatus(session.id, .running)
    }

    func sendFollowUp(_ sessionId: String, text: String, attachments: [PromptAttachment] = []) throws {
        // On another Mac, your message comes back with its output.
        if sessionId.hasPrefix(RemoteService.mirrorPrefix) { try remote.send(sessionId, text: text, attachments: attachments); return }
        guard let session = session(sessionId), let provider = ProviderRegistry.provider(session.providerId) else { return }
        let message = PromptAttachments.message(text, attachments)
        let images = PromptAttachments.images(attachments)
        engine.recordInput(sessionId: sessionId, text: message)
        // A new agent, model or effort takes effect by restarting between
        // turns, once no background task would end with the old process.
        if needsRelaunch.contains(sessionId), isAlive(sessionId), session.status != .running, runningBackgroundTasks(sessionId) == 0 {
            needsRelaunch.remove(sessionId)
            setStatus(sessionId, .running)
            Task { await relaunch(session, prompt: message, images: images) }
            return
        }
        if provider.followUpMode == .stdin, isAlive(sessionId), let line = provider.buildUserMessage(message, images: images) {
            try engine.write(sessionId: sessionId, isDemo ? DemoAgent.followUpLine(message) : line)
            turnStartedAt[sessionId] = Date()
            setStatus(sessionId, .running)
        } else {
            try launch(session, prompt: message, resume: true, images: images)
        }
    }

    /// Switch a chat's agent, model or effort. The next message uses them: a
    /// running agent restarts (resuming its conversation when the agent is the
    /// same; a different agent starts fresh, as they can't share one).
    func setAgent(_ sessionId: String, providerId: String, model: String?, effort: String?) {
        if let (_, host) = RemoteService.split(sessionId) {
            remote.onlineLink(for: sessionId)?.fire(.setAgent(sessionId: host, providerId: providerId, model: model, effort: effort))
            return
        }
        guard var s = session(sessionId), (s.providerId, s.model, s.effort) != (providerId, model, effort) else { return }
        if s.providerId != providerId {
            s.providerSessionId = nil
            parsers[sessionId] = nil
        }
        s.providerId = providerId
        s.model = model
        s.effort = effort
        try? store.save(s)
        reload()
        if isAlive(sessionId) { needsRelaunch.insert(sessionId) }
    }

    /// Change how much a chat's agent may do on its own. A running Claude
    /// switches at once over its control channel; agents that start a process
    /// per turn (Codex) pick it up with the next message.
    func setPolicy(_ sessionId: String, _ policy: PermissionPolicy) {
        if let (_, host) = RemoteService.split(sessionId) {
            remote.onlineLink(for: sessionId)?.fire(.setPolicy(sessionId: host, policy: policy))
            return
        }
        guard var s = session(sessionId), s.permissionPolicy != policy,
              let provider = ProviderRegistry.provider(s.providerId) else { return }
        s.permissionPolicy = policy
        try? store.save(s)
        reload()
        guard isAlive(sessionId), !isDemo,
              let line = provider.buildPermissionModeChange(policy, requestId: "mode-\(UUID().uuidString.prefix(8))") else { return }
        do { try engine.write(sessionId: sessionId, line) } catch { needsRelaunch.insert(sessionId) }
    }

    /// Stop the agent, wait for it to go, and start it again with `prompt`.
    private func relaunch(_ session: Session, prompt: String, images: [String] = []) async {
        relaunching.insert(session.id)
        engine.stop(sessionId: session.id)
        for _ in 0..<60 where engine.isAlive(session.id) { try? await Task.sleep(for: .milliseconds(100)) }
        relaunching.remove(session.id)
        guard let current = self.session(session.id) else { return }
        do {
            try launch(current, prompt: prompt, resume: current.providerSessionId != nil, images: images)
        } catch {
            flash(error.localizedDescription, isError: true)
            setStatus(session.id, .errored, detail: error.localizedDescription)
        }
    }

    func answerPermission(_ sessionId: String, requestId: String, allow: Bool) {
        if sessionId.hasPrefix(RemoteService.mirrorPrefix) {
            // Only once the other Mac has it: offline, the question stays.
            if remote.answer(sessionId, requestId: requestId, allow: allow) { permissions[sessionId]?.removeAll { $0.requestId == requestId } }
            return
        }
        respond(sessionId, requestId: requestId, allow: allow, input: permissions[sessionId]?.first { $0.requestId == requestId }?.input)
    }

    /// Answers the agent's questions (AskUserQuestion), by question text. The
    /// agent hears them as its question tool's input, allowed.
    func answerQuestion(_ sessionId: String, requestId: String, answers: [String: String]) {
        if sessionId.hasPrefix(RemoteService.mirrorPrefix) {
            if remote.answerQuestion(sessionId, requestId: requestId, answers: answers) { permissions[sessionId]?.removeAll { $0.requestId == requestId } }
            return
        }
        guard let request = permissions[sessionId]?.first(where: { $0.requestId == requestId }) else { return }
        respond(sessionId, requestId: requestId, allow: true, input: AgentQuestion.answeredInput(request.input, answers: answers))
    }

    private func respond(_ sessionId: String, requestId: String, allow: Bool, input: JSONValue?) {
        guard let session = session(sessionId), let provider = ProviderRegistry.provider(session.providerId) else { return }
        if let line = provider.buildPermissionResponse(requestId: requestId, allow: allow, input: input) {
            do { try engine.write(sessionId: sessionId, line) } catch { flash(error.localizedDescription, isError: true) }
        }
        permissions[sessionId]?.removeAll { $0.requestId == requestId }
        setStatus(sessionId, .running)
    }

    /// Opens a terminal under the chat that signs its Claude account in again.
    func signInToClaude(for sessionId: String) {
        let path = sessionProfiles[sessionId] ?? claudeProfile ?? accounts.standardProfilePath
        let profile = ClaudeAccounts.profiles(home: executor.homeDirectory).first { $0.path == path }
            ?? ClaudeAccounts.Profile(path: path, isStandard: path == accounts.standardProfilePath)
        let paneId = UUID().uuidString
        updateLayout(sessionId) { _ = $0.add(.terminal, to: .bottom, id: paneId) }
        TerminalRegistry.shared.host(for: paneId, directory: session(sessionId)?.worktreePath ?? executor.homeDirectory)
            .run(ClaudeAccounts.loginCommand(profile), label: "Sign in")
    }

    func stop(_ sessionId: String) {
        if sessionId.hasPrefix(RemoteService.mirrorPrefix) { remote.stop(sessionId); return }
        engine.stop(sessionId: sessionId)
    }

    // MARK: Chats on other Macs

    /// Output from a chat on another Mac, parsed here: questions for you
    /// wait like local ones; the rest joins its transcript.
    func applyRemote(_ events: [AgentEvent], to mirrorId: String) {
        for event in events {
            switch event {
            case let .permissionRequest(requestId, toolName, input):
                permissions[mirrorId, default: []].append(PendingPermission(requestId: requestId, toolName: toolName, input: input))
            case .status, .sessionId, .usage:
                continue
            default:
                feed(mirrorId).append(event)
            }
        }
    }

    /// A question answered on the other Mac itself leaves nothing to answer here.
    func remoteSnapshotChanged(device: String, _ snapshot: RemoteSnapshot) {
        for session in snapshot.sessions where session.status != .waitingInput {
            let id = RemoteService.mirrorId(device: device, session: session.id)
            if permissions[id]?.isEmpty == false { permissions[id] = nil }
        }
    }

    func resume(_ sessionId: String) {
        if let (_, host) = RemoteService.split(sessionId) { remote.onlineLink(for: sessionId)?.fire(.resume(sessionId: host)); return }
        guard let session = session(sessionId) else { return }
        do {
            try launch(session, prompt: session.providerSessionId == nil ? (session.prompt ?? "") : "Continue where you left off.",
                       resume: session.providerSessionId != nil)
        } catch {
            flash(error.localizedDescription, isError: true)
        }
    }

    func rename(_ sessionId: String, to name: String) {
        if let (_, host) = RemoteService.split(sessionId) { remote.onlineLink(for: sessionId)?.fire(.rename(sessionId: host, name: name)); return }
        guard var s = session(sessionId), !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        s.name = name.trimmingCharacters(in: .whitespaces)
        try? store.save(s)
        reload()
    }

    func setArchived(_ sessionId: String, _ archived: Bool) {
        if let (_, host) = RemoteService.split(sessionId) {
            remote.onlineLink(for: sessionId)?.fire(.setArchived(sessionId: host, archived: archived))
            return
        }
        guard var s = session(sessionId) else { return }
        s.archivedAt = archived ? Date() : nil
        try? store.save(s)
        if archived {
            mainTabs.removeSession(sessionId)
            syncDestinationWithTabs(leaving: sessionId)
        }
        reload()
    }

    func delete(_ sessionId: String, removeWorktree: Bool) async {
        guard let s = session(sessionId) else { return }
        engine.stop(sessionId: sessionId)
        if removeWorktree, let path = s.worktreePath, let project = project(s.projectId) {
            await runTeardownScript(project, worktree: path)
            do {
                try await Git.removeWorktree(executor, root: project.rootPath, path: path, deleteBranch: nil)
            } catch {
                flash("Worktree not removed: \(error.localizedDescription)", isError: true)
            }
        }
        engine.deleteLog(sessionId: sessionId)
        discardLayout(sessionId)
        mainTabs.removeSession(sessionId)
        try? store.deleteSession(sessionId)
        feeds[sessionId] = nil
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
            // Claude reports its account's limits as it goes; Usage shows the latest.
            if line.line.contains("rate_limit_event"), let quota = ClaudeAccounts.quota(fromLine: line.line) {
                accounts.record(quota, profile: sessionProfiles[sessionId] ?? accounts.standardProfilePath)
            }
            guard let parser = parser(for: sessionId) else { return }
            for e in Self.events(line, parser) { apply(e, to: sessionId) }
            remote.forward(sessionId: sessionId, seq: seq, line: line)
        case let .exit(sessionId, code):
            alive.remove(sessionId)
            // Stopped only to start again with a new model or agent: not an ending.
            if relaunching.contains(sessionId) { permissions[sessionId] = nil; return }
            // Stopped between turns (quit, stop): the turn was over, nothing failed.
            if session(sessionId)?.status == .idle {
                setStatus(sessionId, .finished)
                remote.forwardExit(sessionId: sessionId, code: code)
                permissions[sessionId] = nil
                return
            }
            if let parser = parsers[sessionId] {
                for e in parser.onExit(code: code) { apply(e, to: sessionId) }
            }
            remote.forwardExit(sessionId: sessionId, code: code)
            if let s = session(sessionId), s.status.isActive {
                setStatus(sessionId, code == 0 ? .finished : .errored, detail: code == 0 ? nil : "Exited with code \(code.map(String.init) ?? "?")")
                // An agent that runs a process per turn (Codex) ends its turn by exiting.
                if code == 0, ProviderRegistry.provider(s.providerId)?.followUpMode != .stdin {
                    RevundService.shared.turnEnded(sessionId, model: self)
                }
            }
            permissions[sessionId] = nil
        }
    }

    /// A logged line as timeline events: what you sent reads as your message;
    /// the agent's own output goes through its parser.
    static func events(_ line: OutputLine, _ parser: any OutputParser) -> [AgentEvent] {
        line.stream == .user ? [.text(role: .user, text: line.line, blockId: nil, partial: false)] : parser.feed(line.line, stream: line.stream)
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
            if status == .idle {
                // Still at work in the background: not done yet. The agent
                // takes another turn as each task ends.
                if runningBackgroundTasks(sessionId) == 0 { notify(sessionId, .finished) }
                RevundService.shared.turnEnded(sessionId, model: self)
            }
            if status == .waitingInput || status == .errored { notify(sessionId, status, detail: detail) }
        case let .permissionRequest(requestId, toolName, input) where AgentQuestion.isQuestion(toolName):
            // Never answered for you, whatever else is allowed: it needs your choice.
            permissions[sessionId, default: []].append(PendingPermission(requestId: requestId, toolName: toolName, input: input))
            setStatus(sessionId, .waitingInput, detail: "Question for you")
            notify(sessionId, .waitingInput, detail: AgentQuestion.parse(input).first?.question
                ?? "\(ProviderRegistry.name(session(sessionId)?.providerId ?? "")) has a question")
        case let .permissionRequest(requestId, toolName, input):
            if shouldAutoContinue(toolName, in: sessionId) {
                permissions[sessionId, default: []].append(PendingPermission(requestId: requestId, toolName: toolName, input: input))
                answerPermission(sessionId, requestId: requestId, allow: true)
                return
            }
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
        feed(sessionId).append(event)
    }

    func setStatus(_ sessionId: String, _ status: SessionStatus, detail: String? = nil) {
        // Claude repeats "running" on every message; rewriting the chat for it
        // would redraw every view that shows chats, and hit the disk, each time.
        if let s = session(sessionId), (s.status, s.statusDetail) == (status, detail) { return }
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

    func loadTimelineIfNeeded(_ sessionId: String) {
        guard !feed(sessionId).isLoaded, let s = session(sessionId), let provider = ProviderRegistry.provider(s.providerId) else { return }
        let parser = provider.makeParser()
        var t = Timeline()
        var maxSeq = 0
        for (seq, line) in engine.replay(sessionId: sessionId) {
            maxSeq = seq
            for e in Self.events(line, parser) {
                if case .permissionRequest = e { continue }
                t.append(e)
            }
        }
        feed(sessionId).reset(t)
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
