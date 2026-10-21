import Foundation

/// A git repository Abstract manages worktrees for. A chat belongs to one,
/// or to none (a standalone chat, in a folder of its own).
public struct Project: Sendable, Hashable, Identifiable, Codable {
    public var id: String
    public var name: String
    public var rootPath: String
    public var defaultBaseRef: String
    public var defaultProviderId: String
    public var defaultPermissionPolicy: PermissionPolicy
    public var nestedRepos: [String]
    /// Overrides the global worktree location template when set.
    public var worktreeTemplate: String?
    /// Overrides the global branch prefix when set.
    public var branchPrefix: String?
    public var sortOrder: Int
    public var createdAt: Date
    public var archivedAt: Date?
    /// SF Symbol for the project's icon; nil = the default (GitHub owner's avatar, else its initial).
    public var iconSymbol: String?
    /// The icon tile's colour, a palette token name.
    public var iconColor: String?
    /// A custom icon image copied into Application Support; wins over the symbol.
    public var iconImagePath: String?
    /// Guides model-generated chat titles and branch names; nil or empty = the usual naming.
    public var namingInstructions: String?
    /// Folders (relative to the root) new worktrees check out; empty = everything.
    public var sparseCheckout: [String]
    /// Run in a terminal under the chat when a new worktree is created.
    public var setupScript: String?
    /// Run in the worktree before it is removed.
    public var teardownScript: String?
    /// What a chat's Run button runs.
    public var runScript: String?
    /// The paired Mac new chats for this project start on; nil = this Mac.
    public var defaultDeviceId: String?
    /// Agents may look up the history of the code they change (ABS-61);
    /// nil (projects saved before) = yes.
    public var agentHistory: Bool?
    /// The profiles the New Chat window offers in this project (ABS-101);
    /// nil = every profile shows.
    public var profileIds: [String]? = nil
    /// Plugin tools (ABS-97) set to Allowed or Off here, by
    /// `<plugin id>/<tool>`; any tool not listed asks first.
    public var pluginTools: [String: PluginToolMode]? = nil

    /// Whether this project's agents get the code-history tool.
    public var agentHistoryEnabled: Bool { agentHistory ?? true }

    public init(
        id: String = UUID().uuidString, name: String, rootPath: String, defaultBaseRef: String = "HEAD",
        defaultProviderId: String = "claude", defaultPermissionPolicy: PermissionPolicy = .ask,
        nestedRepos: [String] = [], worktreeTemplate: String? = nil, branchPrefix: String? = nil,
        sortOrder: Int = 0, createdAt: Date = Date(), archivedAt: Date? = nil,
        iconSymbol: String? = nil, iconColor: String? = nil, iconImagePath: String? = nil,
        namingInstructions: String? = nil, sparseCheckout: [String] = [],
        setupScript: String? = nil, teardownScript: String? = nil, runScript: String? = nil,
        defaultDeviceId: String? = nil, agentHistory: Bool? = nil
    ) {
        self.id = id; self.name = name; self.rootPath = rootPath; self.defaultBaseRef = defaultBaseRef
        self.defaultProviderId = defaultProviderId; self.defaultPermissionPolicy = defaultPermissionPolicy
        self.nestedRepos = nestedRepos; self.worktreeTemplate = worktreeTemplate; self.branchPrefix = branchPrefix
        self.sortOrder = sortOrder; self.createdAt = createdAt; self.archivedAt = archivedAt
        self.iconSymbol = iconSymbol; self.iconColor = iconColor; self.iconImagePath = iconImagePath
        self.namingInstructions = namingInstructions; self.sparseCheckout = sparseCheckout
        self.setupScript = setupScript; self.teardownScript = teardownScript; self.runScript = runScript
        self.defaultDeviceId = defaultDeviceId; self.agentHistory = agentHistory
    }

    /// The Mac a new chat for this project starts on: its chosen default
    /// when that Mac is connected now, else this Mac (nil).
    public func resolvedDefaultDevice(online: Set<String>) -> String? {
        defaultDeviceId.flatMap { online.contains($0) ? $0 : nil }
    }

    /// A default Mac is chosen but isn't connected now, so the chat runs
    /// on this Mac instead and the Launcher says so.
    public func defaultDeviceMissing(online: Set<String>) -> Bool {
        defaultDeviceId.map { !online.contains($0) } ?? false
    }

    /// This project as another Mac has it: the same project there (its own
    /// record of the same repository), by id when both share one, else by
    /// name. Nil when that Mac has no such project.
    public static func counterpart(of project: Project, in projects: [Project]) -> Project? {
        projects.first { $0.id == project.id } ?? projects.first { $0.name == project.name }
    }

    /// A script with something in it, else nil.
    public static func nonBlank(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    /// The branch new chats start from, as typed: trimmed, or nil when blank.
    public static func baseRef(typed text: String) -> String? {
        let ref = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return ref.isEmpty ? nil : ref
    }
}

public enum SessionStatus: String, Sendable, Codable, CaseIterable {
    case created
    case provisioning
    case running
    /// Blocked on the developer: a permission prompt or an explicit question.
    case waitingInput = "waiting_input"
    /// The turn is over; the agent is alive and waiting for a follow-up.
    case idle
    case finished
    case errored

    /// The process is (or should be) attached.
    public var isActive: Bool { self == .running || self == .provisioning || self == .waitingInput || self == .idle }
}

/// Where a chat's name came from, worst first: a better source may replace
/// it, and a name you typed is never replaced.
public enum ChatNameSource: String, Sendable, Codable, CaseIterable {
    /// The prompt's first words, or an automation run's placeholder.
    case fallback
    /// Named from the prompt when the chat started.
    case request
    /// What the agent said it's taking on, or did.
    case work
    /// Its pull request's title.
    case pullRequest = "pull_request"
    /// A name you typed.
    case manual

    private var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    /// Whether a name from `source` may take this one's place. A pull
    /// request's name follows the pull request when it is renamed.
    public func mayBeReplaced(by source: ChatNameSource) -> Bool {
        if source == .manual { return true }
        if self == .manual { return false }
        return source == .pullRequest || source.rank > rank
    }
}

/// One chat: an agent working in its own worktree, or a standalone chat's folder.
public struct Session: Sendable, Hashable, Identifiable, Codable {
    public var id: String
    /// nil for a standalone chat, and for automation runs in "No project" mode.
    public var projectId: String?
    public var name: String
    public var providerId: String
    /// The agent's own session id, used to resume.
    public var providerSessionId: String?
    public var worktreePath: String?
    public var branch: String?
    public var baseRef: String?
    public var status: SessionStatus
    public var statusDetail: String?
    public var permissionPolicy: PermissionPolicy
    public var prompt: String?
    public var automationId: String?
    public var createdAt: Date
    public var lastEventAt: Date?
    public var archivedAt: Date?
    /// Model name or alias the chat runs on; nil = the agent's configured default.
    public var model: String?
    /// Reasoning effort, e.g. "high"; nil = the agent's own default.
    public var effort: String?
    /// The agent the chat was just switched from: it hands over with the next message.
    public var handoffFrom: String? = nil
    /// Each agent that has worked in the chat, as it left it, so switching
    /// back resumes its own conversation.
    public var providerSessions: [String: ProviderSeat] = [:]
    /// When it was pinned to the top of its project in the sidebar; nil = not pinned.
    public var pinnedAt: Date? = nil
    /// Where its name came from.
    public var nameSource: ChatNameSource = .request
    /// The profile it started from (ABS-101), as it was at the start: its
    /// id, its name for the header, and its instructions. Editing the
    /// profile later changes later chats, never this one.
    public var profileId: String? = nil
    public var profileName: String? = nil
    public var profileInstructions: String? = nil
    /// The chat whose changes this one reviews (ABS-112). It reads that
    /// chat's worktree and never owns it: it doesn't take it over, and
    /// deleting it never removes the folder.
    public var reviewsSessionId: String? = nil

    public init(
        id: String = UUID().uuidString, projectId: String?, name: String, providerId: String,
        providerSessionId: String? = nil, worktreePath: String? = nil, branch: String? = nil,
        baseRef: String? = nil, status: SessionStatus = .created, statusDetail: String? = nil,
        permissionPolicy: PermissionPolicy = .ask, prompt: String? = nil, automationId: String? = nil,
        createdAt: Date = Date(), lastEventAt: Date? = nil, archivedAt: Date? = nil, model: String? = nil,
        effort: String? = nil
    ) {
        self.model = model; self.effort = effort
        self.id = id; self.projectId = projectId; self.name = name; self.providerId = providerId
        self.providerSessionId = providerSessionId; self.worktreePath = worktreePath; self.branch = branch
        self.baseRef = baseRef; self.status = status; self.statusDetail = statusDetail
        self.permissionPolicy = permissionPolicy; self.prompt = prompt; self.automationId = automationId
        self.createdAt = createdAt; self.lastEventAt = lastEventAt; self.archivedAt = archivedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, projectId, name, providerId, providerSessionId, worktreePath, branch, baseRef, status, statusDetail
        case permissionPolicy, prompt, automationId, createdAt, lastEventAt, archivedAt, model, effort, handoffFrom
        case providerSessions, pinnedAt, nameSource, profileId, profileName, profileInstructions, reviewsSessionId
    }

    /// An older Mac's chats come without what it doesn't know yet.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(String.self, forKey: .id), projectId: try c.decodeIfPresent(String.self, forKey: .projectId),
                  name: try c.decode(String.self, forKey: .name), providerId: try c.decode(String.self, forKey: .providerId),
                  providerSessionId: try c.decodeIfPresent(String.self, forKey: .providerSessionId),
                  worktreePath: try c.decodeIfPresent(String.self, forKey: .worktreePath),
                  branch: try c.decodeIfPresent(String.self, forKey: .branch), baseRef: try c.decodeIfPresent(String.self, forKey: .baseRef),
                  status: try c.decode(SessionStatus.self, forKey: .status),
                  statusDetail: try c.decodeIfPresent(String.self, forKey: .statusDetail),
                  permissionPolicy: try c.decode(PermissionPolicy.self, forKey: .permissionPolicy),
                  prompt: try c.decodeIfPresent(String.self, forKey: .prompt),
                  automationId: try c.decodeIfPresent(String.self, forKey: .automationId),
                  createdAt: try c.decode(Date.self, forKey: .createdAt), lastEventAt: try c.decodeIfPresent(Date.self, forKey: .lastEventAt),
                  archivedAt: try c.decodeIfPresent(Date.self, forKey: .archivedAt), model: try c.decodeIfPresent(String.self, forKey: .model),
                  effort: try c.decodeIfPresent(String.self, forKey: .effort))
        handoffFrom = try c.decodeIfPresent(String.self, forKey: .handoffFrom)
        providerSessions = try c.decodeIfPresent([String: ProviderSeat].self, forKey: .providerSessions) ?? [:]
        pinnedAt = try c.decodeIfPresent(Date.self, forKey: .pinnedAt)
        nameSource = try c.decodeIfPresent(ChatNameSource.self, forKey: .nameSource) ?? .request
        profileId = try c.decodeIfPresent(String.self, forKey: .profileId)
        profileName = try c.decodeIfPresent(String.self, forKey: .profileName)
        profileInstructions = try c.decodeIfPresent(String.self, forKey: .profileInstructions)
        reviewsSessionId = try c.decodeIfPresent(String.self, forKey: .reviewsSessionId)
    }
}

/// Where an agent left a chat it may come back to.
public struct ProviderSeat: Sendable, Hashable, Codable {
    /// Its own session id, to resume.
    public var sessionId: String?
    public var model: String?
    public var effort: String?
    /// Log lines when it left: a handover back covers only what came after.
    public var logOffset: Int

    public init(sessionId: String?, model: String?, effort: String?, logOffset: Int) {
        self.sessionId = sessionId; self.model = model; self.effort = effort; self.logOffset = logOffset
    }
}

/// Which chat an automation's runs happen in.
public enum WorkspaceMode: String, Sendable, Codable, CaseIterable {
    /// A new chat per run: in its project, set up in a worktree of its own;
    /// with no project, a standalone chat.
    case newWorktree = "new_worktree"
    /// One chat every run, `pinnedSessionId`: each run is its next message.
    /// With none yet, the first run makes the automation a chat of its own.
    case pinned
}

/// One schedule an automation fires on. An automation can have several; it
/// runs at the earliest next occurrence across all of them.
public struct AutomationTrigger: Sendable, Hashable, Identifiable, Codable {
    public var id: String
    /// RFC 5545 RRULE body, e.g. `FREQ=DAILY;BYHOUR=9;BYMINUTE=0`.
    public var rrule: String
    /// IANA timezone the rule is evaluated in.
    public var timezone: String
    public var dtstart: Date

    public init(id: String = UUID().uuidString, rrule: String, timezone: String, dtstart: Date = Date()) {
        self.id = id; self.rrule = rrule; self.timezone = timezone; self.dtstart = dtstart
    }

    /// First occurrence strictly after `date`.
    public func nextOccurrence(after date: Date) throws -> Date? {
        try Schedule.nextOccurrence(rrule: rrule, timezone: timezone, dtstart: dtstart, after: date)
    }
}

/// What a scheduled run does when the last one is still going.
public enum AutomationConcurrency: String, Sendable, Codable, CaseIterable {
    case skipIfActive = "skip_if_active"
    case runAfterActiveFinishes = "run_after"
    case startAnother = "start_another"

    /// A run that continues one chat skips rather than piling onto it; a
    /// run in a worktree of its own starts beside the last one.
    public static func defaults(for mode: WorkspaceMode) -> AutomationConcurrency {
        mode == .pinned ? .skipIfActive : .startAnother
    }
}

/// What happens to scheduled runs whose time passed while Abstract was closed.
public enum AutomationMissedRuns: String, Sendable, Codable, CaseIterable {
    case skip
    case runOnce = "run_once"
    case runEach = "run_each"

    /// How many missed runs "run each" starts at most.
    public static let runEachLimit = 5
}

/// A scheduled agent run, modelled on superset.sh automations.
public struct Automation: Sendable, Hashable, Identifiable, Codable {
    public var id: String
    public var name: String
    public var prompt: String
    public var providerId: String
    /// Where its new chats start; nil = "No project": standalone chats.
    public var projectId: String?
    /// When it runs. Empty means it only runs when started by hand.
    public var triggers: [AutomationTrigger]
    public var workspaceMode: WorkspaceMode
    /// The chat every run continues, in `.pinned` mode.
    public var pinnedSessionId: String?
    /// Kept for older versions, which read `.pinned` with it on as "continue
    /// the chat"; a pinned automation always does now.
    public var continueAgentSession: Bool
    public var permissionPolicy: PermissionPolicy
    /// What a scheduled run does when the last one is still going.
    public var concurrency: AutomationConcurrency
    /// What happens to runs missed while Abstract was closed.
    public var missedRuns: AutomationMissedRuns
    /// Skip a scheduled run when the project's base hasn't moved since
    /// the last run.
    public var onlyWhenChanged: Bool
    public var enabled: Bool
    public var nextRunAt: Date?
    public var createdAt: Date
    public var updatedAt: Date
    /// Model name or alias for every run; nil = the agent's configured default.
    public var model: String?
    /// Reasoning effort for every run; nil = the agent's own default.
    public var effort: String?
    /// The paired Mac its runs start on; nil = the Mac it's stored on.
    public var deviceId: String?
    /// The profile each run starts from (ABS-101), resolved when the run
    /// starts; nil = the automation's own agent, model, effort and policy.
    public var profileId: String? = nil

    /// The switch this replaced: fire once on launch if a scheduled time
    /// was missed while closed. Kept so older Macs and older rows, which
    /// know nothing finer, still read and write the same thing.
    public var catchUp: Bool {
        get { missedRuns != .skip }
        set { missedRuns = newValue ? .runOnce : .skip }
    }

    public init(
        id: String = UUID().uuidString, name: String, prompt: String, providerId: String, projectId: String?,
        triggers: [AutomationTrigger], workspaceMode: WorkspaceMode = .newWorktree,
        pinnedSessionId: String? = nil, continueAgentSession: Bool = false,
        permissionPolicy: PermissionPolicy = .autoEdits, catchUp: Bool = false, enabled: Bool = true,
        nextRunAt: Date? = nil, createdAt: Date = Date(), updatedAt: Date = Date(), model: String? = nil,
        effort: String? = nil, deviceId: String? = nil,
        concurrency: AutomationConcurrency? = nil, missedRuns: AutomationMissedRuns? = nil,
        onlyWhenChanged: Bool = false
    ) {
        self.model = model; self.effort = effort; self.deviceId = deviceId
        self.id = id; self.name = name; self.prompt = prompt; self.providerId = providerId; self.projectId = projectId
        self.triggers = triggers; self.workspaceMode = workspaceMode
        self.pinnedSessionId = pinnedSessionId; self.continueAgentSession = continueAgentSession
        self.permissionPolicy = permissionPolicy; self.enabled = enabled
        self.concurrency = concurrency ?? .defaults(for: workspaceMode)
        self.missedRuns = missedRuns ?? (catchUp ? .runOnce : .skip)
        self.onlyWhenChanged = onlyWhenChanged
        self.nextRunAt = nextRunAt; self.createdAt = createdAt; self.updatedAt = updatedAt
    }

    /// One trigger from a single rule, the shape automations had before
    /// they could have several.
    public init(
        id: String = UUID().uuidString, name: String, prompt: String, providerId: String, projectId: String?,
        rrule: String, timezone: String, dtstart: Date = Date(), workspaceMode: WorkspaceMode = .newWorktree,
        pinnedSessionId: String? = nil, continueAgentSession: Bool = false,
        permissionPolicy: PermissionPolicy = .autoEdits, catchUp: Bool = false, enabled: Bool = true,
        nextRunAt: Date? = nil, createdAt: Date = Date(), updatedAt: Date = Date(), model: String? = nil,
        effort: String? = nil, deviceId: String? = nil,
        concurrency: AutomationConcurrency? = nil, missedRuns: AutomationMissedRuns? = nil,
        onlyWhenChanged: Bool = false
    ) {
        self.init(
            id: id, name: name, prompt: prompt, providerId: providerId, projectId: projectId,
            triggers: [AutomationTrigger(rrule: rrule, timezone: timezone, dtstart: dtstart)],
            workspaceMode: workspaceMode, pinnedSessionId: pinnedSessionId, continueAgentSession: continueAgentSession,
            permissionPolicy: permissionPolicy, catchUp: catchUp, enabled: enabled, nextRunAt: nextRunAt,
            createdAt: createdAt, updatedAt: updatedAt, model: model, effort: effort, deviceId: deviceId,
            concurrency: concurrency, missedRuns: missedRuns, onlyWhenChanged: onlyWhenChanged)
    }

    /// The earliest next occurrence across every trigger, strictly after
    /// `date`. A trigger that cannot be evaluated (say, its time zone no
    /// longer exists) is skipped so the others keep firing.
    public func nextOccurrence(after date: Date) -> Date? {
        triggers.compactMap { (try? $0.nextOccurrence(after: date)) ?? nil }.min()
    }

    /// Throws the first trigger's problem, if any trigger is invalid.
    public func validateTriggers() throws {
        for t in triggers { try Schedule.validate(rrule: t.rrule, timezone: t.timezone) }
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, prompt, providerId, projectId, triggers, workspaceMode, pinnedSessionId
        case continueAgentSession, permissionPolicy, catchUp, concurrency, missedRuns, onlyWhenChanged
        case enabled, nextRunAt, createdAt, updatedAt, model, effort, deviceId, profileId
    }

    /// An older Mac's automations carry the catch-up switch instead of
    /// the missed-runs choice, and nothing about still-going runs.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(String.self, forKey: .id), name: try c.decode(String.self, forKey: .name),
                  prompt: try c.decode(String.self, forKey: .prompt), providerId: try c.decode(String.self, forKey: .providerId),
                  projectId: try c.decodeIfPresent(String.self, forKey: .projectId),
                  triggers: try c.decode([AutomationTrigger].self, forKey: .triggers),
                  workspaceMode: try c.decode(WorkspaceMode.self, forKey: .workspaceMode),
                  pinnedSessionId: try c.decodeIfPresent(String.self, forKey: .pinnedSessionId),
                  continueAgentSession: try c.decode(Bool.self, forKey: .continueAgentSession),
                  permissionPolicy: try c.decode(PermissionPolicy.self, forKey: .permissionPolicy),
                  catchUp: try c.decodeIfPresent(Bool.self, forKey: .catchUp) ?? false,
                  enabled: try c.decode(Bool.self, forKey: .enabled),
                  nextRunAt: try c.decodeIfPresent(Date.self, forKey: .nextRunAt),
                  createdAt: try c.decode(Date.self, forKey: .createdAt), updatedAt: try c.decode(Date.self, forKey: .updatedAt),
                  model: try c.decodeIfPresent(String.self, forKey: .model), effort: try c.decodeIfPresent(String.self, forKey: .effort),
                  deviceId: try c.decodeIfPresent(String.self, forKey: .deviceId),
                  concurrency: try c.decodeIfPresent(AutomationConcurrency.self, forKey: .concurrency),
                  missedRuns: try c.decodeIfPresent(AutomationMissedRuns.self, forKey: .missedRuns),
                  onlyWhenChanged: try c.decodeIfPresent(Bool.self, forKey: .onlyWhenChanged) ?? false)
        profileId = try c.decodeIfPresent(String.self, forKey: .profileId)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(name, forKey: .name); try c.encode(prompt, forKey: .prompt)
        try c.encode(providerId, forKey: .providerId); try c.encodeIfPresent(projectId, forKey: .projectId)
        try c.encode(triggers, forKey: .triggers); try c.encode(workspaceMode, forKey: .workspaceMode)
        try c.encodeIfPresent(pinnedSessionId, forKey: .pinnedSessionId)
        try c.encode(continueAgentSession, forKey: .continueAgentSession); try c.encode(permissionPolicy, forKey: .permissionPolicy)
        try c.encode(catchUp, forKey: .catchUp); try c.encode(concurrency, forKey: .concurrency)
        try c.encode(missedRuns, forKey: .missedRuns); try c.encode(onlyWhenChanged, forKey: .onlyWhenChanged)
        try c.encode(enabled, forKey: .enabled); try c.encodeIfPresent(nextRunAt, forKey: .nextRunAt)
        try c.encode(createdAt, forKey: .createdAt); try c.encode(updatedAt, forKey: .updatedAt)
        try c.encodeIfPresent(model, forKey: .model); try c.encodeIfPresent(effort, forKey: .effort)
        try c.encodeIfPresent(deviceId, forKey: .deviceId); try c.encodeIfPresent(profileId, forKey: .profileId)
    }
}

public enum RunTrigger: String, Sendable, Codable { case schedule, manual }

public enum RunStatus: String, Sendable, Codable {
    case creating
    /// The run's workspace exists. Says nothing about whether the agent succeeded.
    case created
    case failed
    /// The run was due but the automation's rules said not to start it.
    case skipped
}

public struct AutomationRun: Sendable, Hashable, Identifiable, Codable {
    public var id: String
    public var automationId: String
    public var firedAt: Date
    public var trigger: RunTrigger
    public var status: RunStatus
    public var sessionId: String?
    public var error: String?
    /// Why a skipped run didn't start, as it reads in the run history.
    public var reason: String?
    /// The project's base commit when the run started; the mark a later
    /// "only when changed" run is compared with.
    public var baseCommit: String?

    public init(id: String = UUID().uuidString, automationId: String, firedAt: Date = Date(), trigger: RunTrigger,
                status: RunStatus = .creating, sessionId: String? = nil, error: String? = nil,
                reason: String? = nil, baseCommit: String? = nil) {
        self.id = id; self.automationId = automationId; self.firedAt = firedAt; self.trigger = trigger
        self.status = status; self.sessionId = sessionId; self.error = error
        self.reason = reason; self.baseCommit = baseCommit
    }

    public static func skipped(automationId: String, reason: AutomationSkipReason, at firedAt: Date = Date()) -> AutomationRun {
        AutomationRun(automationId: automationId, firedAt: firedAt, trigger: .schedule, status: .skipped, reason: reason.text)
    }
}

public struct UsageRecord: Sendable, Hashable, Codable {
    public var sessionId: String
    public var projectId: String?
    public var providerId: String
    public var at: Date
    public var usage: UsageTotals
    public var costUsd: Double
    public var durationMs: Int
    public var turns: Int

    public init(sessionId: String, projectId: String?, providerId: String, at: Date = Date(),
                usage: UsageTotals, costUsd: Double, durationMs: Int, turns: Int) {
        self.sessionId = sessionId; self.projectId = projectId; self.providerId = providerId; self.at = at
        self.usage = usage; self.costUsd = costUsd; self.durationMs = durationMs; self.turns = turns
    }
}

public struct UsageSummary: Sendable, Hashable, Codable {
    public var providerId: String
    public var sessions: Int
    public var turns: Int
    public var usage: UsageTotals
    public var costUsd: Double
    public var durationMs: Int
    public init(providerId: String, sessions: Int, turns: Int, usage: UsageTotals, costUsd: Double, durationMs: Int) {
        self.providerId = providerId; self.sessions = sessions; self.turns = turns; self.usage = usage
        self.costUsd = costUsd; self.durationMs = durationMs
    }
}

public struct UsageDay: Sendable, Hashable, Codable {
    /// `yyyy-MM-dd` in the local timezone.
    public var day: String
    public var providerId: String
    public var outputTokens: Int
    public var costUsd: Double
    public init(day: String, providerId: String, outputTokens: Int, costUsd: Double) {
        self.day = day; self.providerId = providerId; self.outputTokens = outputTokens; self.costUsd = costUsd
    }
}
