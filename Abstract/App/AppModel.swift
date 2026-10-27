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
    /// A plugin's screen, by plugin id and view id.
    case plugin(String, String)
}

/// What a tab shows of a chat: it changes when the chat is renamed, not
/// as its agent works.
struct ChatSummary: Equatable {
    var name: String
    var providerId: String
    var worktreePath: String?
    /// The profile it started from, shown in its tab (ABS-101).
    var profileName: String?

    init(_ session: Session) {
        name = session.name; providerId = session.providerId; worktreePath = session.worktreePath
        profileName = session.profileName
    }
}

struct PendingPermission: Identifiable, Hashable {
    var id: String { requestId }
    let requestId: String
    let toolName: String
    let input: JSONValue
    /// When it started waiting, so a queue reads oldest first (ABS-111).
    var requestedAt = Date()
}

/// A permission request a project rule answered, so its tool row can name
/// the rule. See AppModel+Permissions.
struct RuleAnswer: Hashable {
    let toolName: String
    let input: JSONValue
    let note: String
}

struct ProviderStatus: Hashable {
    var available: Bool
    var path: String?
    var version: String?
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
    /// Keeps what each turn changed and why (`TurnRecord`).
    let turnRecorder: TurnRecorder
    /// Installed plugins and their host state; see Features/Plugins.
    let plugins: PluginService
    /// How links in chats stand, from plugins' link decorators (ABS-126).
    let pluginLinks = PluginLinkStatuses()

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
    /// Each automation's newest run, for the list's last-run outcome.
    var latestAutomationRuns: [String: AutomationRun] = [:]
    /// The named setups chats and automations can start from (ABS-101).
    var profiles: [AgentProfile] = []
    /// Profiles taking turns on a chat; see AppModel+Workflows.
    var workflows: [Workflow] = []
    /// The automations that led to each chat's latest turn, so an event in
    /// it never starts them again; a message you send clears it.
    @ObservationIgnored var eventChains: [String: Set<String>] = [:]
    /// What "Pause everything" turned off, kept across launches so Resume
    /// restores it; see AppModel+Pause.
    var pauseState: PauseState { didSet { save("pauseState", pauseState) } }
    var providerStatus: [String: ProviderStatus] = [:]
    /// Each agent's models: the copy cached at the last launch until the CLI
    /// has been asked again. See `refreshModels`.
    private(set) var modelCatalogs: [String: ModelCatalog] = [:]
    @ObservationIgnored private var feeds: [String: ChatFeed] = [:]
    /// What each paired Mac's chats have notified here, by device.
    @ObservationIgnored private var remoteNotices: [String: RemoteNotices] = [:]
    private(set) var permissions: [String: [PendingPermission]] = [:]
    /// Each chat's plan awaiting your decision, revision by revision (ABS-104).
    private(set) var plans: [String: PlanState] = [:]
    /// The autonomy level a chat was at before Plan or Ask, to return to
    /// when its plan is approved.
    @ObservationIgnored private var normalPolicies: [String: PermissionPolicy] = [:]
    /// Each chat's latest finished reply: a Plan-mode turn's is its plan.
    @ObservationIgnored private var lastReplies: [String: String] = [:]
    private(set) var alive: Set<String> = []
    /// New chats still being set up, or whose setup failed; see AppModel+Setup.
    var setups: [String: ChatSetup] = [:]
    /// Chats mid-turn, or compacting beside their agent. An idle chat's agent
    /// is alive too, awaiting a follow-up, but stopping it loses nothing.
    var workingSessionIds: [String] {
        alive.filter { id in session(id).map { $0.status.isActive && $0.status != .idle } ?? false }
            + compactions.keys.filter { !alive.contains($0) }
    }
    /// When each session's current turn started, for the "working for 12s"
    /// label, as this app saw it. The chat's log says too: see `turnStarts`.
    private(set) var turnStartedAt: [String: Date] = [:]
    func markTurnStarted(_ id: String) { turnStartedAt[id] = Date() }
    /// When each chat's current turn started: from its log where it says
    /// (after a relaunch, for chats `abstract` runs), else when it was sent here.
    var turnStarts: [String: Date] {
        var out = turnStartedAt
        for (id, feed) in feeds { if let start = feed.turnStartedAt { out[id] = start } }
        return out
    }
    /// Panel layouts by chat id; see AppModel+Panes.
    var layouts: [String: PanelLayout] = [:]
    /// A plugin menu item or ⌘K command waiting to be handed to that
    /// plugin's screen, by plugin id; see AppModel+Plugins.
    var pluginInvocations: [String: PluginInvocation] = [:]
    /// A chat waiting on "Archive?" (⇧⌘⌫, or the git actions menu).
    var requestArchive: String?
    /// The background tasks list showing, and the task open in it; see AppModel+Tasks.
    var tasksOpen: TasksFocus?
    /// A chat whose sidebar row should start renaming, from `/rename`.
    var renamingSessionId: String?
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
    private(set) var relaunching: Set<String> = []
    /// Chats passing to another agent: the outgoing one's summary turn is
    /// running, and its exit is not an ending.
    private(set) var handingOff: Set<String> = []
    /// Chats whose agent is compacting its context; a message waits for it.
    private(set) var compacting: Set<String> = []
    /// A side channel's compaction, cancelled by Stop.
    @ObservationIgnored var compactions: [String: Task<Void, Never>] = [:]
    /// The status and detail to restore once a compaction ends, captured
    /// before it's overwritten with "Compacting…".
    @ObservationIgnored var compactionReturnStatus: [String: (SessionStatus, String?)] = [:]
    func beginCompacting(_ id: String) { compacting.insert(id) }
    func endCompacting(_ id: String) { compacting.remove(id); compactions[id] = nil; compactionReturnStatus[id] = nil }
    /// Chats whose current turn is a `/compact` you asked for: its end is no
    /// finished work to announce or review.
    @ObservationIgnored var manualCompactionTurns: Set<String> = []
    /// Chats you pressed Stop in, until the turn or the process ends: neither
    /// is a failure. The token tells this press's fallback from a later one's.
    private(set) var stopRequests: [String: UUID] = [:]
    /// Each chat's messages sent while its agent worked, as the engine keeps
    /// them; only chats with some. See AppModel+Queue.
    var queues: [String: [QueuedMessage]] = [:]
    /// Chats you pressed Interrupt in: their queue goes once the turn ends.
    var interrupting: Set<String> = []
    /// Tool names to approve without asking, per chat.
    var autoContinueTools: [String: Set<String>] = [:]
    /// Remembered permission answers, by project id; see AppModel+Permissions.
    var permissionRules: [String: [PermissionRule]] = [:]
    /// Each project's MCP servers, by project id; see AppModel+ToolServers.
    var toolServers: [String: [ProjectToolServer]] = [:]
    /// Requests a rule answered, by chat: the note for a tool row, by the
    /// call's id (or the request's, when the call has no row of its own).
    var ruleNotes: [String: [String: String]] = [:]
    /// The same answers by tool and input, for a call that reaches its row
    /// after the answer (the feed batches rows behind the request).
    var ruleAnswers: [String: [RuleAnswer]] = [:]
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
    /// detail once its tab has loaded it. A chat takes its title as its name.
    var pullRequests: [String: PullRequest] = [:] { didSet { nameChatsForPullRequests(); notePullRequestEvents() } }
    /// Recent pull requests of each project, from its code host, by project id.
    var projectPullRequests: [String: [PullRequest]] = [:]
    /// A failed list stays visible with the last successful list.
    var projectPullRequestErrors: [String: String] = [:]
    /// Whether each code host plugin's tool is there and signed in, and
    /// when that was asked, by plugin id (ABS-139).
    var codeHostAccess: [String: (access: CodeHostAccess, at: ContinuousClock.Instant)] = [:]
    /// Each project's `origin`, by project id; empty when it has none.
    @ObservationIgnored var projectOrigins: [String: String] = [:]
    /// Whether you can push to each GitHub repository, by `owner/name`, once asked.
    @ObservationIgnored var repoAccess: [String: RepoAccess] = [:]
    /// When each project's pull requests were last listed, by project id.
    @ObservationIgnored var pullRequestsListedAt: [String: ContinuousClock.Instant] = [:]
    @ObservationIgnored var pullRequestsListedDate: [String: Date] = [:]
    @ObservationIgnored var pullRequestRetryAt: [String: ContinuousClock.Instant] = [:]
    @ObservationIgnored var pullRequestFailureCount: [String: Int] = [:]
    @ObservationIgnored var pullRequestLookupsAt: [String: ContinuousClock.Instant] = [:]
    /// A pull request picked by hand for a chat (by its id: repository and
    /// number), which a newer one won't replace.
    @ObservationIgnored var pinnedPullRequests: [String: String] = [:]
    /// Each project's repositories (its own, nested ones, submodules) and
    /// their origins, read once per run, by project id (ABS-163).
    @ObservationIgnored var projectRepos: [String: [ProjectRepo]] = [:]
    /// Where each chat's branch stands, by chat id: for its git actions and its Pull Request tab.
    var branchStates: [String: BranchState] = [:]
    /// When origin was last fetched, by project id (a chat id, without one);
    /// a chat's current submodule fetches under its own folder instead.
    @ObservationIgnored var originFetchedAt: [String: ContinuousClock.Instant] = [:]
    /// Bumped per chat at each branch read, so a slow read can't overwrite a newer one.
    @ObservationIgnored var branchReads: [String: Int] = [:]
    /// The repository each chat is working in, by chat id: a submodule's
    /// path, or absent for the worktree's own. The review and the git actions
    /// button act on it.
    var currentRepo: [String: String] = [:]
    /// Where the current submodule's branch stands, by chat id (absent while
    /// the worktree's own is current). `branchStates` stays the worktree's own.
    var currentRepoStates: [String: RepoBranchState] = [:]

    // Navigation & transient UI
    var destination: Destination = .home { didSet { if destination != oldValue { syncLocks(); followCLIChat() } } }
    var collapsedProjects: Set<String> = []
    /// Archived chats show in the sidebar too, dimmed. Kept across launches.
    var showArchived = UserDefaults.standard.bool(forKey: "sidebar.showArchived") {
        didSet { UserDefaults.standard.set(showArchived, forKey: "sidebar.showArchived") }
    }
    var newChatProjectId: String?? = nil
    /// What the next New Chat's prompt starts with, from asking about some lines.
    var newChatPrompt: String?
    /// Reply-box text waiting for a chat, from asking the chat that wrote some lines.
    var pendingDrafts: [String: String] = [:]
    /// A line above a chat's reply box, until its next message is sent.
    var composerNotices: [String: String] = [:]
    /// Each turn line's commits, by chat then turn-block id; see AppModel+AskAuthor.
    var turnCommits: [String: [Int: [String]]] = [:]
    /// Who to ask about lines already looked up, by where they are.
    var askTargets: [AskAuthorKey: AskAuthor.Target] = [:]
    @ObservationIgnored var turnHistories: [String: TurnHistory] = [:]
    @ObservationIgnored var askInFlight: Set<AskAuthorKey> = []
    /// The next New Chat starts with no project.
    var newChatStandalone = false
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
    /// Where the skill library comes from (ABS-122); see AppModel+Skills.
    var skillSources: [SkillSource] { didSet { save(SkillLibrary.sourcesKey, skillSources) } }
    /// The library's skills as last read from its sources.
    var librarySkills: [LibrarySkill] = []
    var agentDefaults: [String: AgentDefaults] {
        didSet {
            save("agentDefaults", agentDefaults)
            // An idle stdin agent needs a fresh process before its next turn
            // to pick up a changed default.
            for session in sessions where alive.contains(session.id)
                && (session.model == nil || session.effort == nil)
                && agentDefaults[session.providerId] != oldValue[session.providerId] {
                needsRelaunch.insert(session.id)
            }
        }
    }
    var notifyAttention: Bool { didSet { save("notifyAttention", notifyAttention) } }
    var notifyFinished: Bool { didSet { save("notifyFinished", notifyFinished) } }
    var notifyAutomationFailed: Bool { didSet { save("notifyAutomationFailed", notifyAutomationFailed) } }
    var notifyStalled: Bool { didSet { save("notifyStalled", notifyStalled) } }
    /// How long a working chat may go without output before it reads as
    /// quiet, then stalled; see AppModel+Stalls.
    var stallThresholds: StallThresholds { didSet { save("stallThresholds", stallThresholds) } }
    /// Chats gone quiet or stalled right now, by chat id. Working chats
    /// with recent output aren't in here. Written only in AppModel+Stalls.
    var stallStates: [String: StallState] = [:]
    @ObservationIgnored var stallWatches: [String: StallWatch] = [:]
    var defaultTimezone: String { didSet { save("defaultTimezone", defaultTimezone) } }
    /// How agents write their answers. Running chats pick it up from their
    /// next message, by restarting into the same conversation.
    var outputStyle: OutputStyle {
        didSet {
            save("outputStyle", outputStyle)
            if outputStyle != oldValue { needsRelaunch.formUnion(alive) }
        }
    }

    /// Each chat's output as events, for whichever agent wrote it.
    @ObservationIgnored private var streams: [String: ChatStream] = [:]
    /// Per chat and agent, kept across relaunches: Codex remembers each file
    /// as its last edit left it, so the next edit's diff is its own.
    @ObservationIgnored private var enrichers: [String: any LineEnricher] = [:]
    @ObservationIgnored private var seenSeq: [String: Int] = [:]
    /// Chats being named, for their agent's first reply or its report.
    @ObservationIgnored private var namingRuns: Set<String> = []
    /// Chats whose prompt is still being asked about.
    @ObservationIgnored var namingRequests: Set<String> = []
    /// How far each chat's naming from its agent's words got.
    @ObservationIgnored private var runNamings: [String: RunNaming] = [:]
    /// Chats `abstract` drives, and what it says about them; see AppModel+SessionLocks.
    var cliDriven: [String: SessionLockInfo] = [:]
    /// The chats' locks the app holds: the chat showing, and those whose agent it runs.
    @ObservationIgnored var heldLocks: [String: SessionLock] = [:]
    /// The agent the app runs in each chat, as its lock publishes it.
    @ObservationIgnored var appAgents: [String: AgentRecord] = [:]
    /// Where following each chat's log got to: the byte after the last line read, and its number.
    @ObservationIgnored private var tailPositions: [String: (byte: UInt64, seq: Int)] = [:]
    @ObservationIgnored var storeObserver: Int32?
    /// Where `abstract` hands the app the agents of chats it makes; see AppModel+SessionLocks.
    @ObservationIgnored var appLink: AppLink.Server?
    /// Chats whose agent was just started for `abstract`, waiting to be up.
    @ObservationIgnored var startWaits: [String: CheckedContinuation<AgentStart.Outcome, Never>] = [:]
    @ObservationIgnored private var configuredModels: [String: (model: String?, read: Date)] = [:]
    @ObservationIgnored var scheduler: AutomationScheduler?
    /// Plugins' background scripts (ABS-93), started at launch.
    @ObservationIgnored var pluginBackground: PluginBackgroundHost?
    /// Where agents' plugin tool calls reach the app (ABS-97); see AppModel+PluginTools.
    @ObservationIgnored var pluginToolLink: PluginToolLink.Server?
    /// Plugin tool calls waiting on an Ask first card, by request id.
    @ObservationIgnored private var pluginToolAsks: [String: CheckedContinuation<Bool, Never>] = [:]
    /// Automation chats whose run was already reported to plugins.
    @ObservationIgnored private var reportedAutomationRuns: Set<String> = []

    init(store: Store, engine: SessionEngine, executor: any Executor, isDemo: Bool = false) {
        self.store = store
        self.engine = engine
        self.executor = executor
        self.isDemo = isDemo
        turnRecorder = TurnRecorder(store: store)
        plugins = PluginService(store: store)
        remote = RemoteService(dataDirectory: engine.logsURL.deletingLastPathComponent())
        AttachmentStore.root = engine.logsURL.deletingLastPathComponent().appendingPathComponent("attachments")
        AttachmentStore.prune()
        worktreeTemplate = store.setting("worktreeTemplate", as: String.self) ?? WorktreeNaming.defaultTemplate
        branchPrefix = store.setting("branchPrefix", as: String.self) ?? WorktreeNaming.defaultBranchPrefix
        providerOverrides = store.setting("providerOverrides", as: [String: ProviderOverride].self) ?? [:]
        skillSources = store.setting(SkillLibrary.sourcesKey, as: [SkillSource].self) ?? []
        agentDefaults = store.setting("agentDefaults", as: [String: AgentDefaults].self) ?? [:]
        notifyAttention = store.setting("notifyAttention", as: Bool.self) ?? true
        notifyFinished = store.setting("notifyFinished", as: Bool.self) ?? true
        notifyAutomationFailed = store.setting("notifyAutomationFailed", as: Bool.self) ?? true
        notifyStalled = store.setting("notifyStalled", as: Bool.self) ?? true
        stallThresholds = store.setting("stallThresholds", as: StallThresholds.self) ?? .default
        defaultTimezone = store.setting("defaultTimezone", as: String.self) ?? TimeZone.current.identifier
        outputStyle = store.setting("outputStyle", as: OutputStyle.self) ?? .default
        claudeProfile = store.setting("claudeProfile", as: String.self)
        modelCatalogs = store.setting("modelCatalogs", as: [String: ModelCatalog].self) ?? [:]
        mainTabs = store.setting("mainTabs", as: MainTabs.self) ?? MainTabs()
        pauseState = store.setting("pauseState", as: PauseState.self) ?? PauseState()
    }

    private func save<T: Codable>(_ key: String, _ value: T) {
        try? store.setSetting(key, value)
    }

    // MARK: - Bootstrap

    func bootstrap() async {
        try? store.seedStarterProfilesIfNeeded()
        // A chat whose agent still runs from the command line wasn't interrupted.
        refreshCLIDriven()
        // Chats caught setting up, before they're marked interrupted below.
        let unfinished = ((try? store.sessions()) ?? []).filter { setupUnfinished($0) && cliDriven[$0.id] == nil }.map(\.id)
        _ = try? store.reconcileInterruptedSessions(excluding: Set(cliDriven.keys))
        reload()
        if store.databasePath == Store.defaultPath() {
            ProjectIconStore.sweep(keeping: store.managedIconPaths())
        }
        loadQueues()
        restoreInterruptedSetups(unfinished)
        Task { await listen() }
        watchCommandLine()
        serveCommandLine()
        Task { await detectProviders() }
        Task { await refreshModels() }
        scheduler = AutomationScheduler(model: self)
        scheduler?.start()
        pluginBackground = PluginBackgroundHost(model: self)
        pluginLinks.lookUp = { [weak self] match in
            await self?.pluginBackground?.lookUpLink(match) ?? .failed
        }
        plugins.onChange = { [weak self] in
            self?.pluginBackground?.reconcile()
            if let self { pluginLinks.keep(pluginIds: Set(plugins.usable.map(\.id))) }
            if let self { PluginToolLabels.shared.update(PluginTools.all(pluginToolOffers(), project: nil)) }
            self?.refreshTrackerIcons()
        }
        refreshTrackerIcons()
        pluginBackground?.reconcile()
        Task { await adoptLinearPlugin() }
        servePluginTools()
        Task { await watchForStalls() }
        Task { await watchPullRequests() }
        Task { await watchCodeHostActivation() }
        Task { await readEveryBranch() }
        if !isDemo { Task { await accounts.seedFromLogs(engine.logsURL) } }
        if !isDemo { remote.start(model: self) }
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
        latestAutomationRuns = (try? store.latestRuns()) ?? [:]
        profiles = (try? store.profiles()) ?? []
        workflows = (try? store.workflows()) ?? []
        reloadSkills()
        permissionRules = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, (try? store.permissionRules(projectId: $0.id)) ?? []) })
        toolServers = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, (try? store.toolServers(projectId: $0.id)) ?? []) })
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

    /// The agents a picker offers: those installed on the Mac a chat runs on
    /// (all of them until detection says otherwise), plus `current`, so a
    /// choice already made never disappears.
    func pickableAgents(on device: String? = nil, keeping current: String? = nil) -> [any ProviderDefinition] {
        ProviderRegistry.all.filter { p in
            if p.id == current { return true }
            if let device { return remote.links[device]?.snapshot?.providers.contains(p.id) ?? true }
            return providerStatus[p.id]?.available != false
        }
    }

    // MARK: - Models

    /// The agent's own model choice, from its config file.
    func configuredModel(for providerId: String) -> String? {
        // Menus ask on every redraw; the agent's settings file is read at most every few seconds.
        if let cached = configuredModels[providerId], cached.read.timeIntervalSinceNow > -5 { return cached.model }
        let model = ProviderRegistry.provider(providerId)?.configuredDefaultModel(home: executor.homeDirectory)
        configuredModels[providerId] = (model, Date())
        return model
    }

    /// What runs when a chat doesn't select a model explicitly.
    func defaultModel(for providerId: String) -> String? {
        agentDefaults[providerId]?.model ?? configuredModel(for: providerId)
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
        let configured = agentDefaults[providerId]?.effort
            ?? ProviderRegistry.provider(providerId)?.configuredDefaultEffort(home: executor.homeDirectory)
        return (option.efforts, configured.flatMap { option.efforts.contains($0) ? $0 : nil } ?? option.defaultEffort)
    }

    /// `effort` if the model takes it, else nil (the agent's default).
    func supportedEffort(_ effort: String?, providerId: String, model: String?) -> String? {
        effort.flatMap { efforts(providerId: providerId, model: model).levels.contains($0) ? $0 : nil }
    }

    /// The same, for a model on a paired Mac (nil: this one).
    func supportedEffort(_ effort: String?, providerId: String, model: String?, on device: String?) -> String? {
        guard device != nil else { return supportedEffort(effort, providerId: providerId, model: model) }
        return effort.flatMap { efforts(providerId: providerId, model: model, on: device).levels.contains($0) ? $0 : nil }
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
    /// What the chat's agent says it understands. Until it has said (a new
    /// chat's agent starts with its first message), what the same agent said
    /// in another loaded chat of the project.
    func agentCommands(_ session: Session) -> [AgentCommand] {
        let own = feed(session.id).commands?.commands(for: session.providerId) ?? []
        guard own.isEmpty, let projectId = session.projectId else { return own }
        for other in sessions where other.id != session.id && other.projectId == projectId {
            if let list = feeds[other.id]?.commands?.commands(for: session.providerId), !list.isEmpty { return list }
        }
        return []
    }
    func pendingPermissions(_ sessionId: String) -> [PendingPermission] { permissions[sessionId] ?? [] }
    func isAlive(_ sessionId: String) -> Bool {
        sessionId.hasPrefix(RemoteService.mirrorPrefix) ? remote.isAlive(sessionId)
            : alive.contains(sessionId) || cliDriven[sessionId]?.agent != nil
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
        Ordering.pinnedFirst(sessions.filter { $0.projectId == projectId && (showArchived || $0.archivedAt == nil) })
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

    /// The New Chat sheet, for `projectId`, or for a standalone chat (one
    /// with no project) when `standalone`.
    func showNewChat(in projectId: String?, worktree: String? = nil, standalone: Bool = false) {
        isPaletteOpen = false
        newChatWorktree = worktree
        newChatStandalone = standalone && projectId == nil
        newChatProjectId = .some(projectId)
    }

    /// A new chat like the one showing: in its project, or standalone too.
    func showNewChatLikeCurrent() {
        let current = selectedSession
        showNewChat(in: current?.projectId, standalone: current != nil && current?.projectId == nil)
    }

    // MARK: - Projects

    struct Probe: Sendable {
        var rootPath: String
        var name: String
        var isRoot: Bool
        var nestedRepos: [String]
        /// What `.gitmodules` registers; the rest of `nestedRepos` git doesn't know about.
        var submodules: [String]
        var defaultBranch: String
    }

    func probe(directory: String) async throws -> Probe {
        let root = try await Git.repoRoot(executor, dir: directory)
        let nested = (try? await Git.nestedRepos(executor, root: root)) ?? []
        let submodules = await Submodules.registered(executor, root: root)
        let branch = ((try? await Git.currentBranch(executor, root: root)) ?? nil) ?? "HEAD"
        let rootURL = URL(fileURLWithPath: root).standardizedFileURL
        let dirURL = URL(fileURLWithPath: directory).standardizedFileURL
        return Probe(rootPath: root, name: rootURL.lastPathComponent, isRoot: rootURL.path == dirURL.path,
                     nestedRepos: nested, submodules: submodules, defaultBranch: branch)
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
        for s in sessions where s.projectId == id { stopAgent(s.id) }
        try? store.deleteProject(id)
        if case .session(let sid) = destination, session(sid)?.projectId == id { destination = .home }
        if destination == .projectSettings(id) { destination = .home }
        reload()
    }

    func updateProject(_ project: Project) {
        try? store.save(project)
        reload()
    }

    // MARK: - Profiles

    func profile(_ id: String?) -> AgentProfile? {
        id.flatMap { wanted in profiles.first { $0.id == wanted } }
    }

    /// Saved in place, so editing a profile in Settings doesn't reload
    /// every chat under the text being typed.
    func saveProfile(_ profile: AgentProfile) {
        let oldImage = self.profile(profile.id)?.iconImagePath
        do { try store.save(profile) }
        catch { flash(error.localizedDescription, isError: true); return }
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
            profiles.sort { ($0.sortOrder, $0.createdAt) < ($1.sortOrder, $1.createdAt) }
        }
        if oldImage != profile.iconImagePath { ProjectIconStore.discard(oldImage) }
    }

    func deleteProfile(_ id: String) {
        let image = profile(id)?.iconImagePath
        do {
            try store.deleteProfile(id)
            profiles.removeAll { $0.id == id }
            ProjectIconStore.discard(image)
        } catch { flash(error.localizedDescription, isError: true) }
    }

    @discardableResult
    func addProfile() -> AgentProfile {
        let profile = AgentProfile(name: "New profile", sortOrder: (profiles.map(\.sortOrder).max() ?? -1) + 1)
        saveProfile(profile)
        return profile
    }

    // MARK: - Chats

    /// Start a chat: in a fresh worktree from `baseRef`, or in `existing`, which
    /// it takes over from any chat using it. The chat exists at once, named
    /// for its prompt until the model names it; a fresh worktree's chat is
    /// set up first (see AppModel+Setup) and its agent starts after.
    /// With no project it's a standalone chat, working in a folder of its own.
    /// `name` and `slug`, when given, name the chat and its branch instead;
    /// `nameSource` says whether a better name may replace it.
    /// `select` opens the new chat here; a chat started from another device doesn't take over this screen.
    /// `reviewing` makes it that chat's reviewer (ABS-112): it reads `existing`
    /// alongside the chat that has it, instead of taking it over.
    @discardableResult
    func startChat(projectId: String?, providerId: String, prompt text: String, attachments: [PromptAttachment] = [], baseRef: String?,
                   policy: PermissionPolicy, model: String? = nil, effort: String? = nil, existing: WorktreeInfo? = nil,
                   name: String? = nil, nameSource: ChatNameSource = .manual, slug: String? = nil, automationId: String? = nil,
                   profile: ProfileSnapshot? = nil, workflow: WorkflowProgress? = nil, reviewing: String? = nil,
                   select: Bool = true) async throws -> String {
        let project = project(projectId)
        if projectId != nil, project == nil { throw AbstractError.notFound("project") }
        // A workflow's first step has the chat from the start, with its
        // prompt ahead of the task.
        let firstStep = workflow?.current?.resolve(in: profiles)
        if workflow != nil, firstStep == nil { throw AbstractError.message("The workflow's first step has no profile.") }
        let asked = text
        let text = workflow.map { WorkflowEngine.firstMessage($0.workflow, task: text) } ?? text
        let providerId = firstStep?.providerId ?? providerId
        let model = firstStep != nil ? firstStep?.model : model
        let prompt = PromptAttachments.message(text, attachments)
        let images = PromptAttachments.images(attachments)
        // Named for what was asked, or for what was attached when nothing was typed.
        let gist = asked.isEmpty ? attachments.map(\.label).joined(separator: ", ") : asked
        let provisional = name ?? Workspace.title(fromPrompt: gist)
        let naming: Task<Result<ChatNaming.Suggestion, ChatNaming.Failure>, Never>? = name != nil ? nil : Task {
            await suggestedNaming(instructions: project?.namingInstructions, providerId: providerId,
                                  model: model ?? defaultModel(for: providerId), prompt: gist)
        }
        var session = Session(projectId: projectId, name: provisional, providerId: providerId,
                              baseRef: existing == nil ? baseRef : nil, status: .provisioning, permissionPolicy: policy,
                              prompt: prompt, automationId: automationId, model: model, effort: effort)
        // The profile it starts from, as it is now; editing the profile
        // later changes later chats, never this one (ABS-101).
        if let profile { session.apply(profile) }
        if let firstStep, let workflow { session.takeStep(firstStep, in: workflow) }
        session.reviewsSessionId = reviewing
        session.nameSource = name == nil ? .fallback : nameSource
        if naming != nil { namingRequests.insert(session.id) }
        // Its agent's first replies may still name it; an older chat's never do.
        runNamings[session.id] = RunNaming()
        if project == nil {
            session.baseRef = nil
            session.worktreePath = try Workspace.standaloneFolder(home: executor.homeDirectory)
        } else if let existing {
            guard FileManager.default.fileExists(atPath: existing.path) else {
                throw AbstractError.message("That worktree's folder no longer exists.")
            }
            if reviewing == nil {
                let previous = takeOverWorktree(existing.path, for: session.id)
                if let first = previous.first { flash("Took the worktree over from “\(first)”") }
            }
            session.worktreePath = existing.path
            session.branch = existing.branch
        }
        try store.save(session)
        reload()
        feed(session.id).reset()
        if select { open(session.id, newTab: true) }
        engine.recordInput(sessionId: session.id, text: prompt)
        if let projectId, existing == nil {
            let setup = ChatSetup(projectId: projectId, baseRef: baseRef, images: images,
                                  worktreeName: worktreeCityName(projectId: projectId), slug: slug)
            setup.naming = naming
            setup.provisionalName = provisional
            beginSetup(session.id, setup)
            return session.id
        }
        do {
            try launch(session, prompt: prompt, resume: false, images: images)
        } catch {
            // Saved already: it says why, rather than seem to be starting forever.
            setStatus(session.id, .errored, detail: error.localizedDescription)
            throw error
        }
        if let naming {
            Task {
                let result = await naming.value
                if case .failure(let failure) = result, let note = namingFailureNote(failure, project: project) {
                    engine.record(sessionId: session.id, OutputLine(stream: .note, line: note))
                }
                namingRequests.remove(session.id)
                rename(session.id, from: provisional, to: try? result.get().title, source: .request)
            }
        }
        return session.id
    }

    /// A name for the chat from `source`, unless it was renamed meanwhile or
    /// has a better one. The ticket its prompt names stays in front.
    func rename(_ sessionId: String, from current: String, to title: String?, source: ChatNameSource) {
        guard let title, var s = session(sessionId), s.name == current, s.nameSource.mayBeReplaced(by: source) else { return }
        s.name = ChatNaming.withTicket(title, from: [s.prompt.map { PromptAttachments.split($0).text }])
        s.nameSource = source
        try? store.save(s)
        reload()
    }

    /// Chats take their pull request's title, as its line in the release
    /// notes, and follow it when it's renamed; never a name you typed.
    private func nameChatsForPullRequests() {
        guard !isDemo else { return }
        var renamed = false
        for (id, pr) in pullRequests where !id.hasPrefix(RemoteService.mirrorPrefix) && !pr.title.isEmpty {
            guard var s = sessions.first(where: { $0.id == id }), s.nameSource.mayBeReplaced(by: .pullRequest) else { continue }
            let name = ChatNaming.pullRequestName(pr.title, ticketFrom: [s.name, pr.body, s.prompt.map { PromptAttachments.split($0).text }])
            guard name != s.name || s.nameSource != .pullRequest else { continue }
            s.name = name
            s.nameSource = .pullRequest
            try? store.save(s)
            renamed = true
        }
        if renamed { reload() }
    }

    /// How far a chat-title naming from its agent's words got, for chats
    /// started since Abstract opened.
    struct RunNaming {
        /// Naming calls made on the agent's first replies.
        var replyCalls = 0
        /// The reply it was named from, which the report's naming reads too.
        var firstReply: String?
    }

    /// The fresh-worktree automation a chat is a run of.
    private func freshRunAutomation(_ s: Session) -> Automation? {
        guard let id = s.automationId, let automation = try? store.automation(id),
              automation.workspaceMode == .newWorktree else { return nil }
        return automation
    }

    /// A chat whose prompt said too little to name it can take a title from
    /// the agent's reply. Branch naming is the agent's explicit choice.
    private func nameFromReply(_ sessionId: String, _ text: String) {
        guard !namingRuns.contains(sessionId), !sessionId.hasPrefix(RemoteService.mirrorPrefix), let s = session(sessionId),
              ChatNaming.namesFromFirstReply(source: s.nameSource, weakPrompt: ChatNaming.isWeakPrompt(s.prompt),
                                             requestPending: namingRequests.contains(sessionId)),
              let run = runNamings[sessionId], run.replyCalls < 3, AutomationRunNaming.canName(fromReply: text) else { return }
        let isRun = freshRunAutomation(s) != nil
        runNamings[sessionId, default: RunNaming()].replyCalls += 1
        runNamings[sessionId, default: RunNaming()].firstReply = text
        namingRuns.insert(sessionId)
        Task {
            // One try: an answer with no title means the agent hasn't said yet.
            let naming = try? await suggestedNaming(instructions: project(s.projectId)?.namingInstructions, providerId: s.providerId,
                                                    model: s.model ?? defaultModel(for: s.providerId),
                                                    prompt: text, focus: AutomationRunNaming.firstReplyFocus, attempts: 1).get()
            namingRuns.remove(sessionId)
            if let naming {
                rename(sessionId, from: s.name, to: naming.title, source: .work)
            }
            guard isRun else { return }
            // The turn ended while this was being asked: its own naming comes now.
            if let status = session(sessionId)?.status, status != .running, status != .waitingInput {
                nameAutomationRun(sessionId)
            }
        }
    }

    /// A turn of a fresh-worktree run ended. Still named for its automation,
    /// the chat is named from what the agent says it worked on, read with
    /// what it was asked and first said; a name from its first reply or its
    /// pull request is never replaced by the report's.
    private func nameAutomationRun(_ sessionId: String) {
        guard !namingRuns.contains(sessionId), let s = session(sessionId), let automation = freshRunAutomation(s) else { return }
        let run = runNamings[sessionId, default: RunNaming()]
        let refine = AutomationRunNaming.namesFromReport(s.name, source: s.nameSource, automationName: automation.name)
        let report = feed(sessionId).timeline.lastReply
        guard refine, report != nil else { return }
        namingRuns.insert(sessionId)
        Task {
            var naming: ChatNaming.Suggestion?
            if let report {
                let task = AutomationRunNaming.reportTask(request: s.prompt, firstReply: run.firstReply, report: report)
                naming = try? await suggestedNaming(instructions: project(s.projectId)?.namingInstructions, providerId: s.providerId,
                                                    model: s.model ?? defaultModel(for: s.providerId),
                                                    prompt: task, focus: AutomationRunNaming.reportFocus).get()
            }
            namingRuns.remove(sessionId)
            if refine, let title = naming?.title {
                rename(sessionId, from: s.name, to: title, source: .work)
            }
        }
    }

    /// A run's agent names its own still-provisional branch. The requesting
    /// worktree must be the chat's, even if the caller supplied its chat id.
    func renameRunBranch(_ sessionId: String, from cwd: String, to name: String) async throws -> String {
        guard let s = session(sessionId), freshRunAutomation(s) != nil,
              let branch = s.branch, let worktree = s.worktreePath, let project = project(s.projectId),
              Self.canonical(cwd) == Self.canonical(worktree) else {
            throw AbstractError.message("This request did not come from this automation chat's worktree.")
        }
        guard pullRequests[sessionId] == nil else { throw AbstractError.message("This branch already has a pull request.") }
        let exec = executor(for: sessionId)
        let host = await codeHost(for: project, chatId: sessionId)
        let renamed = await AutomationRunNaming.renameBranch(
            exec, worktree: worktree, from: branch, name: name, prefix: project.branchPrefix ?? branchPrefix
        ) { branch in
            guard let host else { return false }
            // Unknown counts as having one: a pull request's branch is never renamed under it.
            do { return try await host.pullRequest(branch: branch) != nil } catch { return true }
        }
        let result = try renamed.get()
        if let head = result.head { followBranch(sessionId, to: head) }
        guard result.head == result.name else {
            throw AbstractError.message("A concurrent git operation changed HEAD to “\(result.head ?? "detached")”. Abstract followed that branch.")
        }
        engine.record(sessionId: sessionId, OutputLine(stream: .note, line: "Branch renamed to `\(result.name)`"))
        return result.name
    }

    // MARK: - Reusing worktrees

    /// The chat currently holding a worktree, if any. A reviewer only
    /// reads one (ABS-112), so it never holds it.
    func chat(usingWorktree path: String) -> Session? {
        let key = Self.canonical(path)
        return sessions.first { $0.reviewsSessionId == nil && $0.worktreePath.map(Self.canonical) == key }
    }

    /// One worktree, one agent: a chat starting in `path` stops the agent of
    /// whichever chat had it and detaches that chat, so deleting it later
    /// can never remove a folder another chat now works in.
    @discardableResult
    private func takeOverWorktree(_ path: String, for newSessionId: String) -> [String] {
        let key = Self.canonical(path)
        var names: [String] = []
        for var other in sessions where other.id != newSessionId && other.worktreePath.map(Self.canonical) == key {
            stop(other.id)
            other.worktreePath = nil
            try? store.save(other)
            names.append(other.name)
        }
        return names
    }

    /// The folder is going: its reviewers stop and let go of it, so none
    /// works in a folder that's gone (ABS-112).
    private func detachReviewers(of path: String, besides sessionId: String) {
        let key = Self.canonical(path)
        for var other in sessions where other.id != sessionId && other.reviewsSessionId != nil
            && other.worktreePath.map(Self.canonical) == key {
            stop(other.id)
            other.worktreePath = nil
            try? store.save(other)
        }
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

    /// The code-history tool for this chat (ABS-61): nil when its project
    /// has it off, or when this Mac has no `abstract` command to serve it.
    func historySettings(for session: Session) -> CodeHistorySettings? {
        guard let project = project(session.projectId), project.agentHistoryEnabled else { return nil }
        let tool = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/abstract").path
        guard FileManager.default.isExecutableFile(atPath: tool) else { return nil }
        let directory = AttachmentStore.root.deletingLastPathComponent().appendingPathComponent("code-history").path
        return CodeHistorySettings(command: tool, instructionFile: CodeHistorySettings.instructionFile(in: directory))
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
        // Never beside an agent `abstract` runs: the app must hold the chat's lock.
        try holdLock(session.id)
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
        var settings = LaunchSettings(providerOverrides: providerOverrides, outputStyle: outputStyle, claudeProfile: claudeProfile,
                                      standardClaudeProfile: accounts.standardProfilePath, attachmentsDirectory: AttachmentStore.root.path,
                                      agentDefaults: agentDefaults, modelCatalogs: modelCatalogs,
                                      codeHistory: historySettings(for: session),
                                      toolServers: toolServers(for: session.projectId), agentConfigRoot: Self.agentConfigRoot)
        if freshRunAutomation(session) != nil {
            let tool = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/abstract").path
            if FileManager.default.isExecutableFile(atPath: tool) { settings.branchCommand = tool }
        }
        settings.pluginToolsCommand = pluginToolsCommand(for: session)
        settings.addSkills(for: session, project: project(session.projectId), profile: profile(session.profileId),
                           sources: skillSources, dataDirectory: dataDirectory)
        settings.environment.merge(projectIssueTrackers(session.projectId).environment) { $1 }
        if !resume, let note = SkillLibrary.unsupportedNote(provider: provider, skills: settings.skills) {
            engine.record(sessionId: session.id, OutputLine(stream: .note, line: note))
        }
        var spec = AgentLaunch.spec(for: session, provider: provider, prompt: prompt, resumeId: resumeId, images: images,
                                    settings: settings, home: executor.homeDirectory)
        let cwd = spec.cwd
        if isDemo { spec = DemoAgent.wrap(spec, session: session, prompt: prompt, followUp: resume) }
        if session.providerId == "claude" { sessionProfiles[session.id] = claudeProfile ?? accounts.standardProfilePath }
        let enricherKey = "\(session.id)/\(provider.id)"
        if enrichers[enricherKey] == nil { enrichers[enricherKey] = provider.makeLineEnricher(executor: executor, cwd: cwd) }
        loadTimelineIfNeeded(session.id)
        stream(for: session.id)?.restart(providerId: provider.id)
        let launchRecord = LaunchInspection.record(spec: spec, prompt: prompt,
                                                   model: session.model ?? settings.agentDefaults[provider.id]?.model
                                                       ?? provider.configuredDefaultModel(home: executor.homeDirectory),
                                                   effort: session.effort ?? settings.agentDefaults[provider.id]?.effort)
        try engine.launch(sessionId: session.id, spec: spec, enricher: enrichers[enricherKey], launchRecord: launchRecord)
        alive.insert(session.id)
        publishAgent(session.id, providerId: provider.id)
        turnStartedAt[session.id] = Date()
        setStatus(session.id, .running)
    }

    /// `chain`: the automations that led to this message (see `eventChains`);
    /// none for one you send.
    func sendFollowUp(_ sessionId: String, text: String, attachments: [PromptAttachment] = [], chain: Set<String> = []) throws {
        if sessionId.hasPrefix(RemoteService.mirrorPrefix) {
            throw AbstractError.message("Send this message from the remote chat's composer.")
        }
        if isDrivenFromCLI(sessionId) { throw Self.drivenFromCLI }
        guard let session = session(sessionId), let provider = ProviderRegistry.provider(session.providerId) else { return }
        // Its agent starts once it's set up, with the chat's first message.
        if setups[sessionId] != nil { throw AbstractError.message("“\(session.name)” is still being set up; its agent starts after.") }
        if compacting.contains(sessionId) { throw AbstractError.message("Still compacting; send again in a moment.") }
        eventChains[sessionId] = chain.isEmpty ? nil : chain
        // Mid-turn it waits, and goes as the next turn.
        if turnInProgress(sessionId) {
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty {
                enqueue(sessionId, QueuedMessage(text: text, attachments: attachments))
            }
            return
        }
        // Messages still waiting (after Stop, a failure or a relaunch) go first, in one.
        try send(engine.queued(sessionId: sessionId), plus: QueuedMessage(text: text, attachments: attachments), in: session, provider)
    }

    /// Sends a message now: as the next turn, or into the running one when
    /// its agent reads stdin. `queued`: the queued messages it carries, taken
    /// off the queue as it's logged.
    func deliver(_ session: Session, _ provider: any ProviderDefinition, message: String, images: [String],
                 queued: [QueuedMessage] = []) throws {
        let sessionId = session.id
        // The agent was switched: the new one hears what happened first.
        if session.handoffFrom != nil {
            if handingOff.contains(sessionId) { throw AbstractError.message("Still handing this chat over; send again in a moment.") }
            // On their way: no longer editable while the handover runs.
            engine.markSending(sessionId: sessionId, queued.map(\.id))
            refreshQueue(sessionId)
            interrupting.remove(sessionId)
            Task { await handOver(session, message: message, images: images, queued: queued) }
            return
        }
        engine.recordInput(sessionId: sessionId, text: message, queued: queued.map(\.id))
        if !queued.isEmpty { refreshQueue(sessionId) }
        interrupting.remove(sessionId)
        // A new agent, model or effort takes effect by restarting between
        // turns, once no background task would end with the old process.
        if needsRelaunch.contains(sessionId), isAlive(sessionId), session.status != .running, session.status != .waitingInput,
           runningBackgroundTasks(sessionId) == 0 {
            needsRelaunch.remove(sessionId)
            setStatus(sessionId, .running)
            Task { await relaunch(session, prompt: message, images: images, queued: queued) }
            return
        }
        if provider.followUpMode == .stdin, isAlive(sessionId),
           let line = provider.buildUserMessage(message, images: images, sessionId: session.providerSessionId) {
            try engine.write(sessionId: sessionId, isDemo ? DemoAgent.followUpLine(message) : line)
            // Steered into a running turn, the turn and what it waits on go on.
            if session.status != .running, session.status != .waitingInput {
                turnStartedAt[sessionId] = Date()
                setStatus(sessionId, .running)
            }
        } else {
            try launch(session, prompt: message, resume: true, images: images)
        }
    }

    func sendRemoteFollowUp(_ sessionId: String, text: String, attachments: [PromptAttachment] = []) async throws {
        try await remote.send(sessionId, text: text, attachments: attachments)
    }

    func remoteAction(_ sessionId: String, _ request: RemoteRequest, succeeded: (() -> Void)? = nil) {
        Task {
            do {
                try await remote.perform(sessionId, request)
                succeeded?()
            } catch { flash(error.localizedDescription, isError: true) }
        }
    }

    /// Switch a chat's agent, model or effort. The next message uses them: a
    /// running agent restarts, resuming its conversation when the agent is the
    /// same. A different agent is handed the chat with that message (see
    /// `handOver`); one that worked here before resumes its own conversation.
    func setAgent(_ sessionId: String, providerId: String, model: String?, effort: String?) {
        if let (_, host) = RemoteService.split(sessionId) {
            remoteAction(sessionId, .setAgent(sessionId: host, providerId: providerId, model: model, effort: effort))
            return
        }
        guard !isDrivenFromCLI(sessionId), var s = session(sessionId), (s.providerId, s.model, s.effort) != (providerId, model, effort) else { return }
        // Before its first agent has started there's nothing to hand over.
        if s.providerId != providerId, setups[sessionId] == nil {
            let logged = engine.logLength(sessionId: sessionId)
            // Only the agent the log last belongs to leaves a seat: one picked
            // and dropped again before a message never joined the chat.
            if s.handoffFrom == nil {
                s.providerSessions[s.providerId] = ProviderSeat(sessionId: s.providerSessionId, model: s.model,
                                                                effort: s.effort, logOffset: logged)
            }
            let from = s.handoffFrom ?? s.providerId
            s.handoffFrom = from == providerId || logged == 0 ? nil : from
            s.providerSessionId = s.providerSessions[providerId]?.sessionId
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
            remoteAction(sessionId, .setPolicy(sessionId: host, policy: policy))
            return
        }
        guard !isDrivenFromCLI(sessionId), var s = session(sessionId), s.permissionPolicy != policy,
              let provider = ProviderRegistry.provider(s.providerId) else { return }
        // Approving a plan returns to the level you were at before it.
        if policy.isReadOnly, PermissionPolicy.autonomyCases.contains(s.permissionPolicy) {
            normalPolicies[sessionId] = s.permissionPolicy
        }
        s.permissionPolicy = policy
        try? store.save(s)
        reload()
        guard isAlive(sessionId), !isDemo,
              let line = provider.buildPermissionModeChange(policy, requestId: "mode-\(UUID().uuidString.prefix(8))") else { return }
        do { try engine.write(sessionId: sessionId, line) } catch { needsRelaunch.insert(sessionId) }
    }

    /// Stop the agent, wait for it to go, and start it again with `prompt`.
    private func relaunch(_ session: Session, prompt: String, images: [String] = [], queued: [QueuedMessage] = []) async {
        relaunching.insert(session.id)
        engine.stop(sessionId: session.id)
        for _ in 0..<60 where engine.isAlive(session.id) { try? await Task.sleep(for: .milliseconds(100)) }
        relaunching.remove(session.id)
        guard let current = self.session(session.id) else { return }
        do {
            try launch(current, prompt: prompt, resume: current.providerSessionId != nil, images: images)
        } catch {
            requeue(session.id, queued)
            flash(error.localizedDescription, isError: true)
            setStatus(session.id, .errored, detail: error.localizedDescription)
        }
    }

    // MARK: Handing a chat to another agent

    /// The chat's new agent takes over with `message`: the outgoing agent is
    /// asked for a handover note (Backtick writes one from the transcript
    /// when it can't answer), the transcript is saved where the new agent can
    /// read it, and the new agent starts with both ahead of your message.
    private func handOver(_ session: Session, message: String, images: [String], queued: [QueuedMessage] = []) async {
        let id = session.id
        guard let from = session.handoffFrom, !handingOff.contains(id) else { requeue(id, queued); return }
        handingOff.insert(id)
        let wasRunning = session.status == .running
        setStatus(id, .running, detail: "Preparing handover…")

        // What the incoming agent hasn't seen: all of it, or since it last left.
        let incoming = session.providerSessions[session.providerId]
        let unseen = Array(engine.replay(sessionId: id).map(\.line).dropFirst(incoming?.logOffset ?? 0))
        let blocks = ChatStream.timeline(unseen, currentProvider: from).blocks
        let limited = Self.endedOnLimit(blocks)

        let note = limited ? nil : await askForSummary(session, from: from, wasRunning: wasRunning)
        await stopForRestart(id)
        needsRelaunch.remove(id)
        let summary = note ?? HandoffDigest.build(blocks: blocks)
        let transcript = writeTranscript(id, blocks: blocks, agent: ProviderRegistry.name(from))
        if transcript == nil { flash("The transcript couldn't be saved; the new agent gets a summary only.", isError: true) }

        engine.record(sessionId: id, HandoffMarker(phase: .handoff, from: from, to: session.providerId, summary: summary,
                                                   source: note == nil ? .app : .agent, transcriptPath: transcript).line)
        engine.recordInput(sessionId: id, text: message, queued: queued.map(\.id))
        if !queued.isEmpty { refreshQueue(id) }
        handingOff.remove(id)

        guard var current = self.session(id) else { return }
        current.handoffFrom = nil
        try? store.save(current)
        reload()
        let prompt = HandoffPreamble.compose(from: ProviderRegistry.name(from), summary: summary, transcriptPath: transcript,
                                             resuming: current.providerSessionId != nil, message: message)
        do {
            try launch(current, prompt: prompt, resume: current.providerSessionId != nil, images: images)
        } catch {
            requeue(id, queued)
            flash(error.localizedDescription, isError: true)
            setStatus(id, .errored, detail: error.localizedDescription)
        }
    }

    /// Stops the chat's agent, if running, to start another: its exit isn't an ending.
    private func stopForRestart(_ sessionId: String) async {
        guard isAlive(sessionId) else { return }
        relaunching.insert(sessionId)
        engine.stop(sessionId: sessionId)
        for _ in 0..<60 where engine.isAlive(sessionId) { try? await Task.sleep(for: .milliseconds(100)) }
    }

    /// The last turn stopped on a usage, rate or context limit: the agent
    /// can't be asked for anything now.
    static func endedOnLimit(_ blocks: [TimelineBlock]) -> Bool {
        for block in blocks.reversed() {
            switch block {
            case let .error(_, message): if LimitDetector.classify(message) != nil { return true }
            case .notice(_, .limitReached): return true
            case .user, .handoff: return false
            default: continue
            }
        }
        return false
    }

    /// Asks the outgoing agent for a handover note, in a turn the chat doesn't
    /// show. nil when it has no conversation to resume, fails or takes too long.
    private func askForSummary(_ session: Session, from: String, wasRunning: Bool) async -> String? {
        let id = session.id
        guard !isDemo, let provider = ProviderRegistry.provider(from) else { return nil }
        let seat = session.providerSessions[from]
        let live = isAlive(id) && !wasRunning && provider.followUpMode == .stdin
        guard live || seat?.sessionId != nil else { return nil }
        engine.record(sessionId: id, HandoffMarker(phase: .summarize, from: from, to: session.providerId).line)
        do {
            if live, let line = provider.buildUserMessage(HandoffPrompt.summaryRequest, images: [],
                                                           sessionId: seat?.sessionId ?? session.providerSessionId) {
                try engine.write(sessionId: id, line)
            } else {
                await stopForRestart(id)
                var outgoing = session
                outgoing.providerId = from
                outgoing.providerSessionId = seat?.sessionId
                outgoing.model = seat?.model
                outgoing.effort = seat?.effort
                try launch(outgoing, prompt: HandoffPrompt.summaryRequest, resume: true)
                setStatus(id, .running, detail: "Preparing handover…")
            }
        } catch {
            return nil
        }
        for _ in 0..<450 {
            if let s = streams[id], s.isSummarizing, s.summaryFinished { break }
            try? await Task.sleep(for: .milliseconds(200))
        }
        guard let s = streams[id], s.isSummarizing, s.summaryFinished, !s.summaryFailed, !s.capturedSummary.isEmpty else { return nil }
        return s.capturedSummary
    }

    /// The chat so far as markdown, beside its attachments, where every agent may read.
    private func writeTranscript(_ sessionId: String, blocks: [TimelineBlock], agent: String) -> String? {
        let folder = AttachmentStore.root.appendingPathComponent("handoffs", isDirectory: true)
        let file = folder.appendingPathComponent("\(sessionId)-\(engine.logLength(sessionId: sessionId)).md")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try HandoffTranscript.render(blocks: blocks, agentName: agent).write(to: file, atomically: true, encoding: .utf8)
            return file.path
        } catch {
            return nil
        }
    }

    /// A chat stopped by a limit carries on with another agent.
    func continueWith(_ sessionId: String, providerId: String) {
        if let (_, host) = RemoteService.split(sessionId) {
            Task {
                do {
                    try await remote.perform(sessionId, .setAgent(sessionId: host, providerId: providerId, model: nil, effort: nil))
                    try await sendRemoteFollowUp(sessionId, text: "Continue where you left off.")
                }
                catch { flash(error.localizedDescription, isError: true) }
            }
            return
        }
        setAgent(sessionId, providerId: providerId, model: nil, effort: nil)
        do { try sendFollowUp(sessionId, text: "Continue where you left off.") } catch { flash(error.localizedDescription, isError: true) }
    }

    func answerPermission(_ sessionId: String, requestId: String, allow: Bool) {
        if sessionId.hasPrefix(RemoteService.mirrorPrefix) {
            guard let (_, host) = RemoteService.split(sessionId) else { return }
            remoteAction(sessionId, .answer(sessionId: host, requestId: requestId, allow: allow)) {
                self.permissions[sessionId]?.removeAll { $0.requestId == requestId }
            }
            return
        }
        respond(sessionId, requestId: requestId, allow: allow, input: permissions[sessionId]?.first { $0.requestId == requestId }?.input)
    }

    /// Answers the agent's questions (AskUserQuestion), by question text. The
    /// agent hears them as its question tool's input, allowed.
    func answerQuestion(_ sessionId: String, requestId: String, answers: [String: String]) {
        if sessionId.hasPrefix(RemoteService.mirrorPrefix) {
            guard let (_, host) = RemoteService.split(sessionId) else { return }
            remoteAction(sessionId, .answerQuestion(sessionId: host, requestId: requestId, answers: answers)) {
                self.permissions[sessionId]?.removeAll { $0.requestId == requestId }
            }
            return
        }
        guard let request = permissions[sessionId]?.first(where: { $0.requestId == requestId }) else { return }
        respond(sessionId, requestId: requestId, allow: true, input: AgentQuestion.answeredInput(request.input, answers: answers))
    }

    // MARK: Plans

    /// The `ExitPlanMode` approval a chat is waiting on, if it is.
    private func pendingPlanRequest(_ sessionId: String) -> PendingPermission? {
        permissions[sessionId]?.first { Plan.isExitPlanMode($0.toolName) }
    }

    /// What approving a plan returns the chat to: where it was before
    /// Plan, else its project's usual level, else asking first.
    private func normalPolicy(_ sessionId: String) -> PermissionPolicy {
        if let normal = normalPolicies[sessionId] { return normal }
        if let s = session(sessionId), let p = project(s.projectId),
           PermissionPolicy.autonomyCases.contains(p.defaultPermissionPolicy) { return p.defaultPermissionPolicy }
        return .ask
    }

    /// Start on the plan: back to your usual permissions, then either
    /// let Claude's `ExitPlanMode` through (it starts at once) or tell
    /// an agent whose turn already ended to implement it.
    func approvePlan(_ sessionId: String) {
        guard plans[sessionId]?.current != nil else { return }
        plans[sessionId]?.approve()
        setPolicy(sessionId, normalPolicy(sessionId))
        if let pending = pendingPlanRequest(sessionId) {
            answerPermission(sessionId, requestId: pending.requestId, allow: true)
            return
        }
        if sessionId.hasPrefix(RemoteService.mirrorPrefix) {
            Task {
                do { try await sendRemoteFollowUp(sessionId, text: Plan.approveMessage) }
                catch { flash(error.localizedDescription, isError: true) }
            }
        } else {
            do { try sendFollowUp(sessionId, text: Plan.approveMessage) }
            catch { flash(error.localizedDescription, isError: true) }
        }
    }

    /// The plan waits in the reply box as a quote, for what you want
    /// changed. The next plan is a new revision; this one stays in
    /// the card's history.
    func requestPlanChanges(_ sessionId: String) {
        guard let plan = plans[sessionId]?.current else { return }
        plans[sessionId]?.requestChanges()
        if let pending = pendingPlanRequest(sessionId) {
            answerPermission(sessionId, requestId: pending.requestId, allow: false)
        }
        pendingDrafts[sessionId] = Plan.quoted(plan) + "\n\n"
    }

    /// Drop the plan. The chat keeps the mode it's in.
    func discardPlan(_ sessionId: String) {
        guard plans[sessionId]?.current != nil else { return }
        plans[sessionId]?.discard()
        if let pending = pendingPlanRequest(sessionId) {
            answerPermission(sessionId, requestId: pending.requestId, allow: false)
        }
    }

    /// A Plan-mode turn just ended: for agents without a plan tool,
    /// its final reply is the plan.
    private func capturePlan(_ sessionId: String) {
        guard let s = session(sessionId), s.providerId != "claude",
              pendingPlanRequest(sessionId) == nil,
              let reply = lastReplies[sessionId],
              let text = Plan.text(fromFinalReply: reply, policy: s.permissionPolicy) else { return }
        plans[sessionId, default: PlanState()].add(text)
    }

    /// After a relaunch, a chat still in Plan mode gets its card back
    /// from its log: every `ExitPlanMode` it sent, or its last reply.
    private func seedPlan(_ sessionId: String) {
        guard plans[sessionId] == nil, let s = session(sessionId), s.permissionPolicy == .plan else { return }
        var plan = PlanState()
        for call in feed(sessionId).calls where Plan.isExitPlanMode(call.name) {
            if let text = Plan.text(fromExitPlanModeInput: call.input) { plan.add(text) }
        }
        if plan.current == nil, s.providerId != "claude" {
            let reply = feed(sessionId).timeline.blocks.last { if case .assistant = $0 { true } else { false } }
            if case let .assistant(_, text, _, _) = reply, let text = Plan.text(fromFinalReply: text, policy: .plan) {
                plan.add(text)
            }
        }
        if plan.current != nil { plans[sessionId] = plan }
    }

    /// Asks about one plugin tool call (ABS-97) the way an agent's own
    /// request is asked: a card on its tool row, the chat waiting for you,
    /// and your project's remembered answers. True once you allow it;
    /// false when you decline, the card goes away with its turn, or
    /// nobody answers in time.
    func askPluginTool(_ sessionId: String, toolName: String, input: JSONValue) async -> Bool {
        let requestId = "plugin-tool-\(UUID().uuidString)"
        let deadline = Date().addingTimeInterval(PluginTools.askTimeout)
        return await withCheckedContinuation { continuation in
            pluginToolAsks[requestId] = continuation
            apply(.permissionRequest(requestId: requestId, toolName: toolName, input: input), to: sessionId)
            Task { @MainActor [weak self] in
                while let self, self.pluginToolAsks[requestId] != nil {
                    let waiting = self.permissions[sessionId]?.contains { $0.requestId == requestId } ?? false
                    if !waiting || Date() >= deadline {
                        self.permissions[sessionId]?.removeAll { $0.requestId == requestId }
                        self.pluginToolAsks.removeValue(forKey: requestId)?.resume(returning: false)
                        return
                    }
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
    }

    private func respond(_ sessionId: String, requestId: String, allow: Bool, input: JSONValue?) {
        // A plugin tool's card answers the waiting call, not the agent.
        if let waiting = pluginToolAsks.removeValue(forKey: requestId) {
            permissions[sessionId]?.removeAll { $0.requestId == requestId }
            if session(sessionId)?.status == .waitingInput, permissions[sessionId]?.isEmpty ?? true {
                setStatus(sessionId, .running)
            }
            waiting.resume(returning: allow)
            return
        }
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

    /// Stop as you press it in the chat: an agent that can be interrupted
    /// (Claude) ends its turn and stays alive, with its background tasks, for
    /// the next message; any other ends its process. Either way the turn
    /// reads as stopped, not failed.
    func stop(_ sessionId: String) {
        if let task = compactions[sessionId] { task.cancel(); return }
        if let (device, host) = RemoteService.split(sessionId) {
            remoteAction(sessionId, .stop(sessionId: host)) { self.remoteNotices[device]?.stopRequested(host) }
            return
        }
        if setups[sessionId]?.active == true { cancelSetup(sessionId); return }
        if stopCLIAgent(sessionId) { return }
        guard engine.isAlive(sessionId), let session = session(sessionId) else { return }
        let token = UUID()
        stopRequests[sessionId] = token
        guard !isDemo, !handingOff.contains(sessionId), let provider = ProviderRegistry.provider(session.providerId),
              case let .interrupt(line) = TurnStop.action(provider, status: session.status, requestId: "stop-\(token.uuidString.prefix(8))"),
              (try? engine.write(sessionId: sessionId, line)) != nil else {
            engine.stop(sessionId: sessionId)
            return
        }
        // Its turn ending takes the request; one that doesn't end has its process ended.
        Task {
            try? await Task.sleep(for: TurnStop.grace)
            if stopRequests[sessionId] == token { engine.stop(sessionId: sessionId) }
        }
    }

    /// Ends the chat's agent and its background tasks, as archiving or
    /// removing its worktree needs. Still a stop you asked for.
    func stopAgent(_ sessionId: String) {
        if compactions[sessionId] != nil || sessionId.hasPrefix(RemoteService.mirrorPrefix) || setups[sessionId]?.active == true {
            stop(sessionId)
            return
        }
        if stopCLIAgent(sessionId) { return }
        guard engine.isAlive(sessionId) else { return }
        stopRequests[sessionId] = UUID()
        engine.stop(sessionId: sessionId)
    }

    // MARK: Chats on other Macs

    /// Output from a chat on another Mac, parsed here: questions for you
    /// wait like local ones; the rest joins its transcript.
    /// `at`: when the other Mac logged the line they came from.
    func applyRemote(_ events: [AgentEvent], at: Date? = Date(), to mirrorId: String) {
        for event in events {
            switch event {
            case let .permissionRequest(requestId, toolName, input):
                permissions[mirrorId, default: []].append(PendingPermission(requestId: requestId, toolName: toolName, input: input))
                if Plan.isExitPlanMode(toolName), let text = Plan.text(fromExitPlanModeInput: input) {
                    plans[mirrorId, default: PlanState()].add(text)
                }
            case .sessionId:
                continue
            case let .gitOperation(operation):
                onGitOperation(operation, in: mirrorId)
                feed(mirrorId).append(event, at: at)
            // The chat's status comes with the other Mac's snapshot; here it
            // only ends a turn, so its line and length show.
            default:
                feed(mirrorId).append(event, at: at)
            }
        }
    }

    /// A question answered on the other Mac itself leaves nothing to answer
    /// here. Its chats notify here like this Mac's own.
    func remoteSnapshotChanged(device: String, _ snapshot: RemoteSnapshot, fresh: Bool) {
        if let pending = snapshot.pendingPermissions {
            for session in snapshot.sessions {
                let id = RemoteService.mirrorId(device: device, session: session.id)
                // Each snapshot repeats what's waiting: keep when it began.
                let since = Dictionary((permissions[id] ?? []).map { ($0.requestId, $0.requestedAt) }, uniquingKeysWith: { a, _ in a })
                permissions[id] = pending[session.id]?.map {
                    PendingPermission(requestId: $0.requestId, toolName: $0.toolName, input: $0.input,
                                      requestedAt: since[$0.requestId] ?? Date())
                }
            }
        }
        for session in snapshot.sessions where session.status != .waitingInput {
            let id = RemoteService.mirrorId(device: device, session: session.id)
            if permissions[id]?.isEmpty == false { permissions[id] = nil }
        }
        let onScreen = NSApp.isActive ? selectedSessionId.flatMap(RemoteService.split).flatMap { $0.device == device ? $0.session : nil } : nil
        let notices = remoteNotices[device, default: RemoteNotices()].next(snapshot, fresh: fresh, notifyAttention: notifyAttention,
                                                                         notifyFinished: notifyFinished, onScreen: onScreen)
        let mac = remote.links[device]?.device.peer.name ?? "another Mac"
        for notice in notices {
            guard let s = session(RemoteService.mirrorId(device: device, session: notice.sessionId)) else { continue }
            post(s, notice.status, body: [project(s.projectId)?.name, "on \(mac)"].compactMap { $0 }.joined(separator: " "))
        }
    }

    func resume(_ sessionId: String) {
        if let (_, host) = RemoteService.split(sessionId) { remoteAction(sessionId, .resume(sessionId: host)); return }
        if isDrivenFromCLI(sessionId) { flash(Self.drivenFromCLI.localizedDescription, isError: true); return }
        // A side channel compacting the same conversation isn't `alive`, but a
        // resumed agent would race it.
        if compacting.contains(sessionId) {
            flash(AbstractError.message("Still compacting; send again in a moment.").localizedDescription, isError: true)
            return
        }
        guard let session = session(sessionId) else { return }
        // Not set up yet: set it up, then its agent starts.
        if setups[sessionId] != nil { runSetup(sessionId); return }
        if session.handoffFrom != nil {
            Task { await handOver(session, message: "Continue where you left off.", images: []) }
            return
        }
        do {
            try launch(session, prompt: session.providerSessionId == nil ? (session.prompt ?? "") : "Continue where you left off.",
                       resume: session.providerSessionId != nil)
        } catch {
            flash(error.localizedDescription, isError: true)
        }
    }

    func rename(_ sessionId: String, to name: String) {
        if let (_, host) = RemoteService.split(sessionId) { remoteAction(sessionId, .rename(sessionId: host, name: name)); return }
        let name = name.trimmingCharacters(in: .whitespaces)
        guard var s = session(sessionId), !name.isEmpty, name != s.name else { return }
        // Yours: nothing renames it again.
        s.name = name
        s.nameSource = .manual
        try? store.save(s)
        reload()
    }

    func setPinned(_ sessionId: String, _ pinned: Bool) {
        guard var s = session(sessionId) else { return }
        s.pinnedAt = pinned ? Date() : nil
        try? store.save(s)
        reload()
    }

    func setArchived(_ sessionId: String, _ archived: Bool) {
        if let (_, host) = RemoteService.split(sessionId) {
            remoteAction(sessionId, .setArchived(sessionId: host, archived: archived))
            return
        }
        guard var s = session(sessionId) else { return }
        let wasArchived = s.archivedAt != nil
        s.archivedAt = archived ? Date() : nil
        try? store.save(s)
        if archived {
            mainTabs.removeSession(sessionId)
            syncDestinationWithTabs(leaving: sessionId)
        }
        reload()
        if archived, !wasArchived { automationEvent(.chatArchived, in: sessionId) }
    }

    func delete(_ sessionId: String, removeWorktree: Bool) async {
        guard let s = session(sessionId) else { return }
        stopAgent(sessionId)
        setups[sessionId] = nil
        // A reviewer's folder belongs to the chat it reviews (ABS-112).
        let removeWorktree = removeWorktree && s.reviewsSessionId == nil
        if removeWorktree, let path = s.worktreePath { detachReviewers(of: path, besides: sessionId) }
        if removeWorktree, let path = s.worktreePath, let project = project(s.projectId) {
            await runTeardownScript(project, worktree: path)
            do {
                try await Git.removeWorktree(executor, root: project.rootPath, path: path, deleteBranch: nil)
            } catch {
                flash("Worktree not removed: \(error.localizedDescription)", isError: true)
            }
        } else if removeWorktree, s.projectId == nil, let path = s.worktreePath, Workspace.isChatFolder(path, home: executor.homeDirectory) {
            // A standalone chat's own folder, which nothing else uses.
            do { try executor.removeItem(path) } catch { flash("Folder not removed: \(error.localizedDescription)", isError: true) }
        }
        engine.deleteLog(sessionId: sessionId)
        ChatConfigFiles.remove(root: Self.agentConfigRoot, chatId: sessionId)
        discardLayout(sessionId)
        mainTabs.removeSession(sessionId)
        try? store.deleteSession(sessionId)
        feeds[sessionId] = nil
        permissions[sessionId] = nil
        streams[sessionId] = nil
        enrichers = enrichers.filter { !$0.key.hasPrefix(sessionId + "/") }
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
            tailPositions[sessionId] = nil
            // Claude reports its account's limits as it goes; Usage shows the latest.
            if line.line.contains("rate_limit_event"), let quota = ClaudeAccounts.quota(fromLine: line.line) {
                accounts.record(quota, profile: sessionProfiles[sessionId] ?? accounts.standardProfilePath)
            }
            guard let stream = stream(for: sessionId) else { return }
            let events = stream.feed(line)
            // An agent whose parser drives its protocol answers from here.
            for reply in stream.takePendingInput() { try? engine.write(sessionId: sessionId, reply) }
            if startWaits[sessionId] != nil, line.stream == .stdout,
               let outcome = AgentStart.outcome(of: events, agentName: ProviderRegistry.name(stream.providerId)) {
                agentStart(sessionId, outcome)
            }
            for e in events {
                if handingOff.contains(sessionId) {
                    // The summary turn works without tools, and a new id would be the outgoing agent's.
                    if case let .permissionRequest(requestId, _, _) = e { respond(sessionId, requestId: requestId, allow: false, input: nil); continue }
                    if case .sessionId = e { continue }
                }
                apply(e, to: sessionId, at: line.at)
            }
            remote.forward(sessionId: sessionId, seq: seq, line: line)
        case let .exit(sessionId, code):
            alive.remove(sessionId)
            let manualCompaction = manualCompactionTurns.remove(sessionId) != nil
            // An in-stream compaction whose process died without a status: freed
            // here so the chat never stays stuck; what actually happened to it is
            // logged below, from the same `onExit` the rest of this exit reads.
            let wasCompacting = compacting.contains(sessionId) && compactions[sessionId] == nil
            if wasCompacting { endCompacting(sessionId) }
            // A turn that ended here sends the queue last, so the next
            // process isn't published as gone (defers run in reverse).
            var ended: (status: SessionStatus, stopped: Bool)?
            defer { if let ended { turnEnded(sessionId, ended.status, stopped: ended.stopped) } }
            // Only once its last status is written may `abstract` take the chat.
            defer {
                publishAgent(sessionId, providerId: nil)
                syncLocks()
            }
            if startWaits[sessionId] != nil {
                let name = ProviderRegistry.name(session(sessionId)?.providerId ?? "")
                agentStart(sessionId, .failed("\(name) exited with code \(code.map(String.init) ?? "?") before it started."))
            }
            let stopRequested = stopRequests.removeValue(forKey: sessionId) != nil
            // Stopped only to start again with a new model or agent: not an ending.
            if relaunching.remove(sessionId) != nil { permissions[sessionId] = nil; return }
            if handingOff.contains(sessionId) {
                _ = streams[sessionId]?.onExit(code: code)
                permissions[sessionId] = nil
                return
            }
            // Stopped between turns (quit, stop): the turn was over, nothing failed.
            if session(sessionId)?.status == .idle {
                setStatus(sessionId, .finished)
                remote.forwardExit(sessionId: sessionId, code: code)
                permissions[sessionId] = nil
                return
            }
            // Stopped mid-turn: a quiet line, no notification, and the chat
            // waits for your next message. Not forwarded: another Mac would
            // read the exit as a failure, and its status comes with the chat.
            if stopRequested {
                for e in stream(for: sessionId)?.onExit(code: code, stopRequested: true) ?? [] { append(e, to: sessionId) }
                setStatus(sessionId, .idle)
                permissions[sessionId] = nil
                ended = (.idle, true)
                return
            }
            if let stream = streams[sessionId] {
                let exitEvents = stream.onExit(code: code)
                if wasCompacting {
                    closeCompactionOnExit(exitEvents, sessionId: sessionId)
                } else {
                    for e in exitEvents { apply(e, to: sessionId) }
                }
            }
            remote.forwardExit(sessionId: sessionId, code: code)
            if let s = session(sessionId), s.status.isActive {
                setStatus(sessionId, code == 0 ? .finished : .errored, detail: code == 0 ? nil : "Exited with code \(code.map(String.init) ?? "?")")
                // An agent that runs a process per turn (Codex) ends its turn by exiting.
                if code == 0, !manualCompaction, ProviderRegistry.provider(s.providerId)?.followUpMode != .stdin {
                    RevundService.shared.turnEnded(sessionId, model: self)
                    nameAutomationRun(sessionId)
                }
            }
            permissions[sessionId] = nil
            if let status = session(sessionId)?.status { ended = (status, false) }
        }
    }

    /// Closes an in-stream compaction whose process just exited, from the same
    /// exit events the rest of the exit handling reads: Claude may have finished
    /// (a compaction boundary flushed with no summary turn after it) rather than
    /// failed, and either way this must be the only place that closes it — a
    /// second, independent guess (e.g. from the exit's own `.error`) would double
    /// up or contradict what's recorded here.
    private func closeCompactionOnExit(_ exitEvents: [AgentEvent], sessionId: String) {
        let finished = exitEvents.compactMap { event -> CompactionMarker? in
            guard case let .compaction(.finished(result, trigger, durationMs)) = event else { return nil }
            return .finished(result, trigger: trigger, durationMs: durationMs)
        }.first
        let marker = finished ?? .failed(CompactionState.stoppedEarly)
        // Recorded, then marked already-seen: its own async echo off `engine.events`
        // must not re-apply it, since it's applied here, in order with the rest.
        let seq = engine.record(sessionId: sessionId, marker.line)
        seenSeq[sessionId] = max(seenSeq[sessionId] ?? 0, seq)
        // Mirrors get lines from the `.line` handler, which skips this one.
        remote.forward(sessionId: sessionId, seq: seq, line: marker.line)
        apply(marker.event, to: sessionId)
        for e in exitEvents {
            if case .compaction = e { continue }
            apply(e, to: sessionId)
        }
    }

    /// Until a handoff is logged, output is still the outgoing agent's.
    private func stream(for sessionId: String) -> ChatStream? {
        if let s = streams[sessionId] { return s }
        guard let s = session(sessionId) else { return nil }
        let stream = ChatStream(providerId: s.handoffFrom ?? s.providerId)
        streams[sessionId] = stream
        return stream
    }

    /// `at`: when the event's line was logged; now, for what the agent's exit says.
    private func apply(_ event: AgentEvent, to sessionId: String, at: Date? = Date()) {
        switch event {
        case .sessionId(let id):
            if var s = session(sessionId), s.providerSessionId != id {
                s.providerSessionId = id
                try? store.save(s)
                replaceSession(s)
            }
        case let .status(status, detail):
            if status != .running, compactions[sessionId] == nil { endCompacting(sessionId) }
            setStatus(sessionId, status, detail: detail)
            if status == .idle || status == .finished { capturePlan(sessionId) }
            // A `/compact` you asked for ending did no work: nothing to announce or review.
            let manualCompaction = status != .running && manualCompactionTurns.remove(sessionId) != nil
            if status == .idle, stopRequests.removeValue(forKey: sessionId) != nil {
                // A turn you stopped: nothing to tell you, review or answer.
                permissions[sessionId] = nil
                turnEnded(sessionId, status, stopped: true)
            } else if status == .idle, !manualCompaction {
                // Still at work in the background, or about to take your
                // queued messages: not done yet.
                if runningBackgroundTasks(sessionId) == 0, queues[sessionId] == nil { notify(sessionId, .finished) }
                RevundService.shared.turnEnded(sessionId, model: self)
                nameAutomationRun(sessionId)
                turnEnded(sessionId, status, stopped: false)
            }
            if status == .waitingInput || status == .errored { notify(sessionId, status, detail: detail) }
        case let .permissionRequest(requestId, toolName, input) where AgentQuestion.isQuestion(toolName):
            // Never answered for you, whatever else is allowed: it needs your choice.
            permissions[sessionId, default: []].append(PendingPermission(requestId: requestId, toolName: toolName, input: input))
            setStatus(sessionId, .waitingInput, detail: "Question for you")
            pluginBackground?.deliver(.permissionRequested(chatId: sessionId, requestId: requestId, kind: "question", toolName: toolName,
                                                           questions: AgentQuestion.parse(input).map(\.question)))
            notify(sessionId, .waitingInput, detail: AgentQuestion.parse(input).first?.question
                ?? "\(ProviderRegistry.name(session(sessionId)?.providerId ?? "")) has a question")
        case let .permissionRequest(requestId, toolName, input) where Plan.isExitPlanMode(toolName):
            // A plan to approve, never let through on its own. It stays a
            // pending permission so Approve can answer it, but the plan
            // card is what shows.
            permissions[sessionId, default: []].append(PendingPermission(requestId: requestId, toolName: toolName, input: input))
            if let text = Plan.text(fromExitPlanModeInput: input) { plans[sessionId, default: PlanState()].add(text) }
            setStatus(sessionId, .waitingInput, detail: "Plan ready for your approval")
            pluginBackground?.deliver(.permissionRequested(chatId: sessionId, requestId: requestId, kind: "plan",
                                                           toolName: toolName, questions: []))
            notify(sessionId, .waitingInput, detail: "\(ProviderRegistry.name(session(sessionId)?.providerId ?? "")) wrote a plan for your approval")
        case let .permissionRequest(requestId, toolName, input):
            if let rule = permissionRuleAnswer(sessionId, toolName: toolName, input: input) {
                recordRuleAnswer(rule, requestId: requestId, toolName: toolName, input: input, in: sessionId)
                permissions[sessionId, default: []].append(PendingPermission(requestId: requestId, toolName: toolName, input: input))
                answerPermission(sessionId, requestId: requestId, allow: rule.decision == .allow)
                return
            }
            if shouldAutoContinue(toolName, in: sessionId) {
                permissions[sessionId, default: []].append(PendingPermission(requestId: requestId, toolName: toolName, input: input))
                answerPermission(sessionId, requestId: requestId, allow: true)
                return
            }
            permissions[sessionId, default: []].append(PendingPermission(requestId: requestId, toolName: toolName, input: input))
            setStatus(sessionId, .waitingInput, detail: "\(toolName) needs approval")
            pluginBackground?.deliver(.permissionRequested(chatId: sessionId, requestId: requestId, kind: "permission",
                                                           toolName: toolName, questions: []))
            notify(sessionId, .waitingInput, detail: "\(ProviderRegistry.name(session(sessionId)?.providerId ?? "")) wants to use \(toolName)")
        case let .text(.assistant, text, _, false):
            lastReplies[sessionId] = text
            nameFromReply(sessionId, text)
        case let .usage(totals, cost, duration, turns):
            let s = session(sessionId)
            try? store.record(UsageRecord(sessionId: sessionId, projectId: s?.projectId, providerId: s?.providerId ?? "unknown",
                                          usage: totals, costUsd: cost ?? 0, durationMs: duration ?? 0, turns: turns ?? 1))
        case let .gitOperation(operation):
            onGitOperation(operation, in: sessionId)
        case .compaction(.finished), .compaction(.failed):
            // Claude's own report ends an in-stream compaction; a side channel ends its own.
            if compactions[sessionId] == nil { endCompacting(sessionId) }
        default:
            break
        }
        append(event, to: sessionId, at: at)
    }

    private func append(_ event: AgentEvent, to sessionId: String, at: Date? = Date()) {
        feed(sessionId).append(event, at: at)
    }

    func setStatus(_ sessionId: String, _ status: SessionStatus, detail: String? = nil) {
        // Claude repeats "running" on every message; rewriting the chat for it
        // would redraw every view that shows chats, and hit the disk, each time.
        if let s = session(sessionId), (s.status, s.statusDetail) == (status, detail) { return }
        try? store.updateSessionStatus(sessionId, status, detail: detail)
        guard var s = session(sessionId) else { return }
        let wasWorking = [.running, .provisioning, .waitingInput].contains(s.status)
        s.status = status
        s.statusDetail = detail
        s.lastEventAt = Date()
        replaceSession(s)
        guard !sessionId.hasPrefix(RemoteService.mirrorPrefix) else { return }
        if status == .running { turnRecorder.begin(sessionId, worktree: s.worktreePath, exec: executor(for: sessionId)) }
        // A turn that ended may have left changes: the sidebar files the chat by them.
        if wasWorking, [.idle, .finished, .errored].contains(status) {
            Task { await refreshBranch(sessionId) }
            Task { await recordTurn(sessionId) }
            reportTurnToPlugins(s, status: status)
        }
    }

    /// A finished turn, for plugins' background scripts (ABS-93); an
    /// automation's run finishes with its chat's first turn.
    private func reportTurnToPlugins(_ s: Session, status: SessionStatus) {
        guard let background = pluginBackground else { return }
        let outcome = status == .errored ? "failed" : stopRequests[s.id] != nil ? "stopped" : "done"
        background.deliver(.turnFinished(chatId: s.id, outcome: outcome, endedAt: Date()))
        if let automationId = s.automationId, reportedAutomationRuns.insert(s.id).inserted {
            background.deliver(.automationRunFinished(automationId: automationId, outcome: outcome, at: Date(), chatId: s.id))
        }
    }

    /// Saves what the turn that just ended changed and why.
    private func recordTurn(_ sessionId: String) async {
        guard let s = session(sessionId) else { return }
        let pr = pullRequests[sessionId].map { (number: $0.number, body: $0.body) }
        await turnRecorder.end(s, engine: engine, exec: executor(for: sessionId), pullRequest: pr)
    }

    private func replaceSession(_ s: Session) {
        if let i = sessions.firstIndex(where: { $0.id == s.id }) { sessions[i] = s }
    }

    func loadTimelineIfNeeded(_ sessionId: String) {
        guard !feed(sessionId).isLoaded, let s = session(sessionId) else { return }
        let (replay, end, lastSeq) = engine.tail(sessionId: sessionId, fromByte: 0, firstSeq: 1)
        tailPositions[sessionId] = (end, lastSeq)
        let lines = replay.map(\.line)
        // Each agent's part of the log is read by its own parser.
        let stream = ChatStream(providerId: ChatStream.firstProvider(in: lines, current: s.handoffFrom ?? s.providerId))
        feed(sessionId).reset(stream.replay(lines))
        // Abstract quit mid-compaction: that one will never report back.
        if !compacting.contains(sessionId), !isAlive(sessionId), feed(sessionId).timeline.hasRunningCompaction {
            engine.record(sessionId: sessionId, CompactionMarker.failed("Abstract closed before compacting finished.").line)
        }
        seedPlan(sessionId)
        seenSeq[sessionId] = max(seenSeq[sessionId] ?? 0, replay.last?.seq ?? 0)
        streams[sessionId] = streams[sessionId] ?? stream
    }

    /// Reads what's new in a chat's log into its transcript: the log another
    /// process (`abstract`'s agent) writes. What it did to the chat's status
    /// is already in the store.
    func tailLog(_ sessionId: String) {
        guard feed(sessionId).isLoaded else { loadTimelineIfNeeded(sessionId); return }
        // From where it last got to; the first time, from the top (once).
        let from = tailPositions[sessionId] ?? (0, 0)
        let (lines, end, lastSeq) = engine.tail(sessionId: sessionId, fromByte: from.byte, firstSeq: from.seq + 1)
        tailPositions[sessionId] = (end, lastSeq)
        for (seq, line) in lines where seq > (seenSeq[sessionId] ?? 0) {
            seenSeq[sessionId] = seq
            guard let stream = stream(for: sessionId) else { return }
            for event in stream.feed(line) { append(event, to: sessionId, at: line.at) }
        }
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
        post(s, status, body: detail ?? project(s.projectId)?.name ?? "")
    }

    private func post(_ s: Session, _ status: SessionStatus, body: String) {
        let title = status == .waitingInput ? "\(s.name) needs you" : status == .errored ? "\(s.name) hit an error" : "\(s.name) is done"
        Notifier.shared.post(title: title, body: body, sessionId: s.id)
    }
}
