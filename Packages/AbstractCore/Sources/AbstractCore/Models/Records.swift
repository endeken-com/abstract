import Foundation

/// A git repository Abstract manages worktrees for. Every chat belongs to one.
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

    public init(
        id: String = UUID().uuidString, name: String, rootPath: String, defaultBaseRef: String = "HEAD",
        defaultProviderId: String = "claude", defaultPermissionPolicy: PermissionPolicy = .ask,
        nestedRepos: [String] = [], worktreeTemplate: String? = nil, branchPrefix: String? = nil,
        sortOrder: Int = 0, createdAt: Date = Date(), archivedAt: Date? = nil,
        iconSymbol: String? = nil, iconColor: String? = nil, iconImagePath: String? = nil,
        namingInstructions: String? = nil, sparseCheckout: [String] = [],
        setupScript: String? = nil, teardownScript: String? = nil, runScript: String? = nil
    ) {
        self.id = id; self.name = name; self.rootPath = rootPath; self.defaultBaseRef = defaultBaseRef
        self.defaultProviderId = defaultProviderId; self.defaultPermissionPolicy = defaultPermissionPolicy
        self.nestedRepos = nestedRepos; self.worktreeTemplate = worktreeTemplate; self.branchPrefix = branchPrefix
        self.sortOrder = sortOrder; self.createdAt = createdAt; self.archivedAt = archivedAt
        self.iconSymbol = iconSymbol; self.iconColor = iconColor; self.iconImagePath = iconImagePath
        self.namingInstructions = namingInstructions; self.sparseCheckout = sparseCheckout
        self.setupScript = setupScript; self.teardownScript = teardownScript; self.runScript = runScript
    }

    /// A script with something in it, else nil.
    public static func nonBlank(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
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

/// One chat: an agent working in its own worktree.
public struct Session: Sendable, Hashable, Identifiable, Codable {
    public var id: String
    /// nil only for automation runs in "No project" mode.
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
}

public enum WorkspaceMode: String, Sendable, Codable, CaseIterable {
    /// A fresh worktree per run (superset: "new workspace per run").
    case newWorktree = "new_worktree"
    /// Reuse one session's worktree every run (superset: pinned workspace).
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

/// A scheduled agent run, modelled on superset.sh automations.
public struct Automation: Sendable, Hashable, Identifiable, Codable {
    public var id: String
    public var name: String
    public var prompt: String
    public var providerId: String
    /// nil = "No project": each run gets a scratch directory, no worktree.
    public var projectId: String?
    /// When it runs. Empty means it only runs when started by hand.
    public var triggers: [AutomationTrigger]
    public var workspaceMode: WorkspaceMode
    public var pinnedSessionId: String?
    /// Deliver each run into this automation's previous agent session. Only
    /// meaningful with a pinned worktree.
    public var continueAgentSession: Bool
    public var permissionPolicy: PermissionPolicy
    /// Fire once on launch if a scheduled time was missed while closed.
    public var catchUp: Bool
    public var enabled: Bool
    public var nextRunAt: Date?
    public var createdAt: Date
    public var updatedAt: Date
    /// Model name or alias for every run; nil = the agent's configured default.
    public var model: String?
    /// Reasoning effort for every run; nil = the agent's own default.
    public var effort: String?

    public init(
        id: String = UUID().uuidString, name: String, prompt: String, providerId: String, projectId: String?,
        triggers: [AutomationTrigger], workspaceMode: WorkspaceMode = .newWorktree,
        pinnedSessionId: String? = nil, continueAgentSession: Bool = false,
        permissionPolicy: PermissionPolicy = .autoEdits, catchUp: Bool = false, enabled: Bool = true,
        nextRunAt: Date? = nil, createdAt: Date = Date(), updatedAt: Date = Date(), model: String? = nil,
        effort: String? = nil
    ) {
        self.model = model; self.effort = effort
        self.id = id; self.name = name; self.prompt = prompt; self.providerId = providerId; self.projectId = projectId
        self.triggers = triggers; self.workspaceMode = workspaceMode
        self.pinnedSessionId = pinnedSessionId; self.continueAgentSession = continueAgentSession
        self.permissionPolicy = permissionPolicy; self.catchUp = catchUp; self.enabled = enabled
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
        effort: String? = nil
    ) {
        self.init(
            id: id, name: name, prompt: prompt, providerId: providerId, projectId: projectId,
            triggers: [AutomationTrigger(rrule: rrule, timezone: timezone, dtstart: dtstart)],
            workspaceMode: workspaceMode, pinnedSessionId: pinnedSessionId, continueAgentSession: continueAgentSession,
            permissionPolicy: permissionPolicy, catchUp: catchUp, enabled: enabled, nextRunAt: nextRunAt,
            createdAt: createdAt, updatedAt: updatedAt, model: model, effort: effort)
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
}

public enum RunTrigger: String, Sendable, Codable { case schedule, manual }

public enum RunStatus: String, Sendable, Codable {
    case creating
    /// The run's workspace exists. Says nothing about whether the agent succeeded.
    case created
    case failed
}

public struct AutomationRun: Sendable, Hashable, Identifiable, Codable {
    public var id: String
    public var automationId: String
    public var firedAt: Date
    public var trigger: RunTrigger
    public var status: RunStatus
    public var sessionId: String?
    public var error: String?

    public init(id: String = UUID().uuidString, automationId: String, firedAt: Date = Date(), trigger: RunTrigger,
                status: RunStatus = .creating, sessionId: String? = nil, error: String? = nil) {
        self.id = id; self.automationId = automationId; self.firedAt = firedAt; self.trigger = trigger
        self.status = status; self.sessionId = sessionId; self.error = error
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
