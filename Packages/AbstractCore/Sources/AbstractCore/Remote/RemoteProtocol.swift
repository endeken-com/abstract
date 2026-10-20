import Foundation

/// What a paired device may ask this one, and what this one tells it.
///
/// The host streams each chat's raw agent output, line by line with its
/// sequence number, and the controller parses it with the same provider code
/// the host uses. So any agent Abstract can run can be driven from another
/// device, with no per-agent remote support.
public enum RemoteMessage: Codable, Sendable {
    case request(id: Int, RemoteRequest)
    case response(id: Int, RemoteResponse)
    case event(RemoteEvent)
    /// Older versions carried a connection to a local model server over this
    /// channel. Kept so their frames still decode: an open is answered with close.
    case tunnel(id: Int, TunnelFrame)
}

public enum TunnelFrame: Codable, Sendable {
    case open(String)
    case data(Data)
    case close
}

public enum RemoteRequest: Codable, Sendable {
    /// Projects and chats, now and whenever they change.
    case snapshot
    /// A chat's output from `afterSeq` on, then as it streams.
    case subscribe(sessionId: String, afterSeq: Int)
    /// Subscribe to live output and initially send only the latest page.
    case subscribeRecent(sessionId: String, limit: Int)
    /// A page strictly before `beforeSeq`; does not change the live subscription.
    case history(sessionId: String, beforeSeq: Int, limit: Int)
    case unsubscribe(sessionId: String)
    case send(sessionId: String, text: String)
    /// A message with attachments; a file's bytes travel with it, by attachment id.
    case sendAttachments(sessionId: String, text: String, attachments: [PromptAttachment], files: [String: Data])
    case start(projectId: String, providerId: String, prompt: String, policy: PermissionPolicy)
    /// A chat as the New Chat window sets it up, started on the Mac its project is on.
    case startChat(RemoteStart)
    case startStandalone(providerId: String, prompt: String, policy: PermissionPolicy)
    case startStandaloneConfigured(providerId: String, prompt: String, policy: PermissionPolicy,
                                   attachments: [PromptAttachment], files: [String: Data], model: String?, effort: String?)
    case stop(sessionId: String)
    /// A stalled chat's clock restarts; its turn keeps running.
    case keepWaiting(sessionId: String)
    /// End a stalled chat's turn and send its last message again.
    case stopAndRetry(sessionId: String)
    case answer(sessionId: String, requestId: String, allow: Bool)
    /// Answers to the agent's questions, by question text.
    case answerQuestion(sessionId: String, requestId: String, answers: [String: String])
    /// A chat's agent, model and effort, or how much it may do alone.
    case setAgent(sessionId: String, providerId: String, model: String?, effort: String?)
    case setPolicy(sessionId: String, policy: PermissionPolicy)
    /// A plan written in Plan mode: approve it, ask for changes, or drop it.
    /// Only send these to a Mac whose snapshot says `planApproval`.
    case approvePlan(sessionId: String)
    case requestPlanChanges(sessionId: String)
    case discardPlan(sessionId: String)
    /// One of the agent's background tasks, or work to move there (Ctrl+B).
    case stopTask(sessionId: String, taskId: String)
    case moveToBackground(sessionId: String, toolUseId: String?)
    case resume(sessionId: String)
    case rename(sessionId: String, name: String)
    case setArchived(sessionId: String, archived: Bool)
    case deleteChat(sessionId: String, removeWorktree: Bool)
    case removeWorktree(projectId: String, path: String, deleteBranch: Bool)
    /// Automations are scheduled and persisted on the host Mac.
    case saveAutomation(Automation)
    case deleteAutomation(id: String)
    /// "Pause everything" on this Mac, and its per-project form: stops the
    /// agents at work in scope and pauses its automations (see `PauseState`).
    /// Resume turns back on only the automations the pause switched off.
    /// Only send these to a Mac whose snapshot says `pauseControl`.
    case pauseEverything
    case resumeEverything
    case pauseProject(projectId: String)
    case resumeProject(projectId: String)
    case runAutomation(id: String)
    case automationRuns(id: String)
    /// One run of an automation kept on the asking Mac, started here.
    /// Only send it to a Mac whose snapshot says `automationDevice`.
    case startRun(RemoteRunStart)
    case review(sessionId: String, committed: Bool)
    case reviewFile(sessionId: String, path: String, committed: Bool, accept: Bool)
    case createPullRequest(sessionId: String, title: String, body: String, base: String?, draft: Bool, commitFirst: Bool)
    case pushChanges(sessionId: String, message: String)
    case mergePullRequest(sessionId: String, method: String)
    case markPullRequestReady(sessionId: String)
    case closePullRequest(sessionId: String)
    /// A project's code-history setting (ABS-61): whether its agents may
    /// look up what earlier chats decided. Only send it to a Mac whose
    /// snapshot says `codeHistory`.
    case setAgentHistory(projectId: String, enabled: Bool)
    /// Ask the chat that wrote some lines about them: the host blames
    /// `path` (relative to `root`, a project root or worktree there) at
    /// `revision` (nil = the worktree as it is) and answers with who to
    /// ask and the pre-filled prompt. Only send it to a Mac whose
    /// snapshot says `codeHistory`.
    case askAuthor(root: String, path: String, lineStart: Int, lineEnd: Int, code: [String], revision: String?, sessionId: String?)

    // The host's worktrees, so a chat there reviews, browses and edits here
    // as it would on the host. Only inside its projects and worktrees; only
    // git, gh and revund run.
    /// `stdin` is the command's whole input; older Macs ignore it, so only
    /// send it to one whose snapshot says `execInput`.
    case exec(command: String, args: [String], cwd: String?, stdin: Data? = nil)
    /// Output streams back as `.process` events under the request's id.
    case spawn(LaunchSpec)
    case stopProcess(id: Int)
    case readFile(path: String)
    case writeFile(path: String, data: Data)
    case fileInfo(path: String)
    /// Every file under a folder that isn't a repository, relative to it.
    case listFiles(root: String)
    /// `.changed` events whenever something under the paths changes.
    case watch(id: Int, paths: [String])
    case unwatch(id: Int)

    /// A shell in a worktree there, in a terminal here.
    case openTerminal(id: Int, cwd: String, cols: Int, rows: Int)
    case terminalInput(id: Int, data: Data)
    case resizeTerminal(id: Int, cols: Int, rows: Int)
    case closeTerminal(id: Int)
}

/// A new chat on the host: everything the New Chat window chose, with the
/// bytes of any files attached (by attachment id).
public struct RemoteStart: Codable, Sendable {
    public var projectId: String
    public var providerId: String
    public var prompt: String
    public var attachments: [PromptAttachment]
    public var files: [String: Data]
    public var baseRef: String?
    public var policy: PermissionPolicy
    public var model: String?
    public var effort: String?
    /// An existing worktree there to start in, by path; nil makes a new one.
    public var worktree: String?
    /// The profile the chat starts from, as chosen here (ABS-101); a Mac
    /// from before profiles starts the chat without it.
    public var profile: ProfileSnapshot?

    public init(projectId: String, providerId: String, prompt: String, attachments: [PromptAttachment] = [], files: [String: Data] = [:],
                baseRef: String?, policy: PermissionPolicy, model: String?, effort: String?, worktree: String?,
                profile: ProfileSnapshot? = nil) {
        self.projectId = projectId; self.providerId = providerId; self.prompt = prompt; self.attachments = attachments
        self.files = files; self.baseRef = baseRef; self.policy = policy; self.model = model; self.effort = effort
        self.worktree = worktree; self.profile = profile
    }
}

/// One automation run to start on the host: everything a run on the
/// automation's own Mac starts with. `projectId` is the host's own record
/// of the project; nil is a standalone chat.
public struct RemoteRunStart: Codable, Sendable, Hashable {
    public var projectId: String?
    public var providerId: String
    public var prompt: String
    public var policy: PermissionPolicy
    public var model: String?
    public var effort: String?
    /// What the chat is called, and whether a better name may replace it.
    public var name: String
    public var nameSource: ChatNameSource
    /// The new worktree's branch, when the run starts in a project.
    public var slug: String?
    public var automationId: String
    /// The profile the run starts from, resolved here (ABS-101).
    public var profile: ProfileSnapshot?

    public init(projectId: String?, providerId: String, prompt: String, policy: PermissionPolicy,
                model: String?, effort: String?, name: String, nameSource: ChatNameSource,
                slug: String?, automationId: String, profile: ProfileSnapshot? = nil) {
        self.projectId = projectId; self.providerId = providerId; self.prompt = prompt; self.policy = policy
        self.model = model; self.effort = effort; self.name = name; self.nameSource = nameSource
        self.slug = slug; self.automationId = automationId; self.profile = profile
    }
}

public enum RemoteResponse: Codable, Sendable {
    case ok
    case historyPage(beforeSeq: Int?, hasMore: Bool)
    case failed(String)
    case started(sessionId: String)
    case exec(ExecResult)
    case data(Data)
    case fileInfo(FileInfo?)
    case files([String], truncated: Bool)
    case automation(Automation)
    case automationRuns([AutomationRun])
    case review([RemoteReviewFile])
    case askAuthor(RemoteAskAuthor)
}

/// Who to ask about some lines, and what the asking starts with: the
/// chat that wrote them (`sessionId`, unarchived by the host) with
/// `draft` for its reply box, or no chat — `draft` is then a new chat's
/// first message in `projectId`. `notice` says when that chat can
/// answer but no longer edit (its worktree is gone).
public struct RemoteAskAuthor: Codable, Sendable, Hashable {
    public var sessionId: String?
    public var projectId: String?
    public var draft: String
    public var notice: String?

    public init(sessionId: String?, projectId: String?, draft: String, notice: String?) {
        self.sessionId = sessionId; self.projectId = projectId; self.draft = draft; self.notice = notice
    }
}

public struct RemoteReviewFile: Codable, Sendable, Hashable {
    public var path: String
    public var status: String
    public var additions: Int
    public var deletions: Int
    public var binary: Bool
    public var patch: String

    public init(path: String, status: String, additions: Int, deletions: Int, binary: Bool, patch: String) {
        self.path = path; self.status = status; self.additions = additions; self.deletions = deletions
        self.binary = binary; self.patch = patch
    }
}

public enum RemoteEvent: Codable, Sendable {
    /// The pairing prompt was answered on the host.
    case paired(Bool)
    case snapshot(RemoteSnapshot)
    case lines(sessionId: String, [RemoteLine])
    case exit(sessionId: String, code: Int32?)
    case process(id: Int, OutputLine)
    case processExit(id: Int, code: Int32?)
    case changed(watchId: Int)
    case terminalOutput(id: Int, Data)
    case terminalExit(id: Int, code: Int32?)
}

/// A host's projects and chats, and the agents it can run.
public struct RemoteSnapshot: Codable, Sendable, Hashable {
    public var projects: [Project]
    public var sessions: [Session]
    public var providers: [String]
    /// Chats whose agent process is running.
    public var alive: [String]
    /// That Mac's home folder.
    public var home: String?
    /// The models each agent offers there.
    public var modelCatalogs: [String: ModelCatalog]?
    /// The model shown in the host's composer when a chat uses its default.
    public var defaultModelNames: [String: String]?
    /// Pull requests keyed by the host's chat id. Optional for older peers.
    public var pullRequests: [String: RemotePullRequest]?
    /// Optional so snapshots from older Macs still decode.
    public var automations: [Automation]?
    public var pendingPermissions: [String: [RemotePendingPermission]]?
    /// Start of the current agent turn, keyed by chat id. Optional for older peers.
    public var turnStartedAt: [String: Date]?
    /// A host advertising bounded chat history requests.
    public var pagedHistory: Bool?
    /// A host that gives `exec` its `stdin`.
    public var execInput: Bool?
    /// Exchanged only inside an authenticated, encrypted session.
    public var internetAddress: InternetAddress?
    /// Chats with tasks still at work in the background. Optional for older peers.
    public var backgroundTasks: [String]?
    /// Whether each chat's branch has work not merged anywhere yet, for the
    /// chats whose branch that Mac has read. Optional for older peers.
    public var unmergedWork: [String: Bool]?
    /// Uploaded project icons by project id, as image bytes: a project's
    /// `iconImagePath` names a file on this Mac, which a viewing Mac cannot
    /// read. Optional for older peers.
    public var projectIcons: [String: Data]?
    /// A host that starts another Mac's automation runs (`startRun`).
    /// Optional for older peers.
    public var automationDevice: Bool?
    /// "Pause everything" is on for this Mac. Optional for older peers.
    public var everythingPaused: Bool?
    /// Projects paused on their own, by id, sorted. Optional for older peers.
    public var pausedProjectIds: [String]?
    /// A host that takes the pause/resume requests. Optional for older peers.
    public var pauseControl: Bool?
    /// Working chats gone quiet or stalled, by chat id, as this Mac's stall
    /// watch reads them. The watching device only shows them; the thresholds
    /// and the one notification stay here. Optional for older peers.
    public var stalls: [String: RemoteStall]?
    /// A host that answers `setAgentHistory` and `askAuthor`.
    /// Optional for older peers.
    public var codeHistory: Bool?
    /// Each chat's plan awaiting a decision, by chat id. Optional for older peers.
    public var plans: [String: RemotePlan]?
    /// A host that takes plan decisions ('approvePlan' and friends).
    /// Optional for older peers.
    public var planApproval: Bool?

    /// The largest uploaded icon a snapshot carries; larger ones are left out.
    public static let maxProjectIconBytes = 512 << 10

    public init(projects: [Project], sessions: [Session], providers: [String], alive: [String],
                home: String? = nil, modelCatalogs: [String: ModelCatalog]? = nil,
                defaultModelNames: [String: String]? = nil,
                pullRequests: [String: RemotePullRequest]? = nil, automations: [Automation]? = nil,
                pendingPermissions: [String: [RemotePendingPermission]]? = nil,
                turnStartedAt: [String: Date]? = nil, pagedHistory: Bool? = nil, execInput: Bool? = nil,
                internetAddress: InternetAddress? = nil, backgroundTasks: [String]? = nil, unmergedWork: [String: Bool]? = nil,
                projectIcons: [String: Data]? = nil, automationDevice: Bool? = nil,
                everythingPaused: Bool? = nil, pausedProjectIds: [String]? = nil, pauseControl: Bool? = nil,
                stalls: [String: RemoteStall]? = nil,
                codeHistory: Bool? = nil, plans: [String: RemotePlan]? = nil, planApproval: Bool? = nil) {
        self.projects = projects; self.sessions = sessions; self.providers = providers; self.alive = alive
        self.home = home; self.modelCatalogs = modelCatalogs; self.defaultModelNames = defaultModelNames
        self.pullRequests = pullRequests
        self.automations = automations
        self.pendingPermissions = pendingPermissions
        self.turnStartedAt = turnStartedAt
        self.pagedHistory = pagedHistory
        self.execInput = execInput
        self.internetAddress = internetAddress
        self.backgroundTasks = backgroundTasks
        self.unmergedWork = unmergedWork
        self.projectIcons = projectIcons
        self.automationDevice = automationDevice
        self.everythingPaused = everythingPaused
        self.pausedProjectIds = pausedProjectIds
        self.pauseControl = pauseControl
        self.stalls = stalls
        self.codeHistory = codeHistory
        self.plans = plans
        self.planApproval = planApproval
    }
}

/// One working chat's silence, for a watching device: `state` is "quiet" or
/// "stalled", `since` when output last arrived. Computed on the chat's own
/// Mac from its stall thresholds; the watcher never recomputes it.
public struct RemoteStall: Codable, Sendable, Hashable {
    public var state: String
    public var since: Date

    public init(state: String, since: Date) {
        self.state = state; self.since = since
    }

    /// The stall worth showing, or nil while output is still recent.
    public init?(_ stall: StallState) {
        switch stall {
        case .working: return nil
        case .quiet(let since): self.init(state: "quiet", since: since)
        case .stalled(let since): self.init(state: "stalled", since: since)
        }
    }
}

/// One chat's plan as it travels: every revision, oldest first, and where
/// it stands (`waiting`, `changesRequested`, `approved`, `discarded`).
public struct RemotePlan: Codable, Sendable, Hashable {
    public var revisions: [String]
    public var status: String

    public init(revisions: [String], status: String) {
        self.revisions = revisions; self.status = status
    }

    public init(_ plan: PlanState) {
        revisions = plan.revisions
        status = switch plan.status {
        case .waiting: "waiting"
        case .approved: "approved"
        case .discarded: "discarded"
        case .changesRequested: "changesRequested"
        }
    }
}

public struct RemotePendingPermission: Codable, Sendable, Hashable {
    public var requestId: String
    public var toolName: String
    public var input: JSONValue

    public init(requestId: String, toolName: String, input: JSONValue) {
        self.requestId = requestId; self.toolName = toolName; self.input = input
    }
}

public struct RemotePullRequest: Codable, Sendable, Hashable {
    public var number: Int
    public var title: String
    public var state: String
    public var isDraft: Bool
    public var url: URL?
    public var standing: String?
    public var reviewDecision: String?
    public var hasConflicts: Bool
    public var checks: [RemotePullRequestCheck]
    public var head: String?
    public var base: String?
    public var author: String?
    public var additions: Int?
    public var deletions: Int?
    public var body: String?
    public var reviews: [RemotePullRequestReview]
    public var comments: [RemotePullRequestComment]
    public var threads: [RemotePullRequestThread]

    public init(number: Int, title: String, state: String, isDraft: Bool, url: URL?,
                standing: String? = nil, reviewDecision: String? = nil,
                hasConflicts: Bool = false, checks: [RemotePullRequestCheck] = [],
                head: String? = nil, base: String? = nil, author: String? = nil,
                additions: Int? = nil, deletions: Int? = nil, body: String? = nil,
                reviews: [RemotePullRequestReview] = [], comments: [RemotePullRequestComment] = [],
                threads: [RemotePullRequestThread] = []) {
        self.number = number; self.title = title; self.state = state; self.isDraft = isDraft; self.url = url
        self.standing = standing; self.reviewDecision = reviewDecision
        self.hasConflicts = hasConflicts; self.checks = checks
        self.head = head; self.base = base; self.author = author
        self.additions = additions; self.deletions = deletions; self.body = body
        self.reviews = reviews; self.comments = comments; self.threads = threads
    }

    private enum CodingKeys: String, CodingKey {
        case number, title, state, isDraft, url, standing, reviewDecision, hasConflicts, checks
        case head, base, author, additions, deletions, body, reviews, comments, threads
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        number = try values.decode(Int.self, forKey: .number)
        title = try values.decode(String.self, forKey: .title)
        state = try values.decode(String.self, forKey: .state)
        isDraft = try values.decode(Bool.self, forKey: .isDraft)
        url = try values.decodeIfPresent(URL.self, forKey: .url)
        standing = try values.decodeIfPresent(String.self, forKey: .standing)
        reviewDecision = try values.decodeIfPresent(String.self, forKey: .reviewDecision)
        hasConflicts = try values.decodeIfPresent(Bool.self, forKey: .hasConflicts) ?? false
        checks = try values.decodeIfPresent([RemotePullRequestCheck].self, forKey: .checks) ?? []
        head = try values.decodeIfPresent(String.self, forKey: .head)
        base = try values.decodeIfPresent(String.self, forKey: .base)
        author = try values.decodeIfPresent(String.self, forKey: .author)
        additions = try values.decodeIfPresent(Int.self, forKey: .additions)
        deletions = try values.decodeIfPresent(Int.self, forKey: .deletions)
        body = try values.decodeIfPresent(String.self, forKey: .body)
        reviews = try values.decodeIfPresent([RemotePullRequestReview].self, forKey: .reviews) ?? []
        comments = try values.decodeIfPresent([RemotePullRequestComment].self, forKey: .comments) ?? []
        threads = try values.decodeIfPresent([RemotePullRequestThread].self, forKey: .threads) ?? []
    }
}

public struct RemotePullRequestReview: Codable, Sendable, Hashable {
    public var author: String
    public var verdict: String
    public var body: String
    public var submittedAt: Date?

    public init(author: String, verdict: String, body: String, submittedAt: Date?) {
        self.author = author; self.verdict = verdict; self.body = body; self.submittedAt = submittedAt
    }
}

public struct RemotePullRequestComment: Codable, Sendable, Hashable {
    public var author: String
    public var body: String
    public var createdAt: Date?
    public var isBot: Bool

    public init(author: String, body: String, createdAt: Date?, isBot: Bool) {
        self.author = author; self.body = body; self.createdAt = createdAt; self.isBot = isBot
    }
}

public struct RemotePullRequestThread: Codable, Sendable, Hashable {
    public var id: String
    public var path: String
    public var line: Int?
    public var isResolved: Bool
    public var isOutdated: Bool
    public var comments: [RemotePullRequestComment]

    public init(id: String, path: String, line: Int?, isResolved: Bool, isOutdated: Bool,
                comments: [RemotePullRequestComment]) {
        self.id = id; self.path = path; self.line = line; self.isResolved = isResolved
        self.isOutdated = isOutdated; self.comments = comments
    }
}

public struct RemotePullRequestCheck: Codable, Sendable, Hashable {
    public var name: String
    public var workflow: String?
    public var outcome: String
    public var url: URL?

    public init(name: String, workflow: String?, outcome: String, url: URL?) {
        self.name = name; self.workflow = workflow; self.outcome = outcome; self.url = url
    }
}

public struct RemoteLine: Codable, Sendable, Hashable {
    public var seq: Int
    public var line: OutputLine

    public init(seq: Int, line: OutputLine) { self.seq = seq; self.line = line }

    /// Longest line sent whole; past it the line is cut (a tool that printed megabytes).
    public static let maxLine = 4 << 20

    /// Lines in batches of about `bytes` each, a line too long for one cut down to size.
    public static func batches(_ lines: [RemoteLine], bytes: Int) -> [[RemoteLine]] {
        var out: [[RemoteLine]] = []
        var batch: [RemoteLine] = []
        var size = 0
        for var line in lines {
            if line.line.line.utf8.count > maxLine {
                line.line.line = String(line.line.line.utf8.prefix(maxLine)) ?? String(line.line.line.prefix(maxLine / 4))
            }
            let count = line.line.line.utf8.count + 64
            if !batch.isEmpty, size + count > bytes {
                out.append(batch)
                batch = []
                size = 0
            }
            batch.append(line)
            size += count
        }
        if !batch.isEmpty { out.append(batch) }
        return out
    }
}

/// Four-byte big-endian length, then the bytes.
public enum RemoteFraming {
    /// Larger frames are refused rather than buffered.
    public static let maxFrame = 16 << 20

    public static func frame(_ payload: Data) -> Data {
        var length = UInt32(payload.count).bigEndian
        return Data(bytes: &length, count: 4) + payload
    }

    public static func length(_ header: Data) -> Int? {
        guard header.count == 4 else { return nil }
        let value = header.reduce(0) { $0 << 8 | Int($1) }
        return value <= maxFrame ? value : nil
    }
}
