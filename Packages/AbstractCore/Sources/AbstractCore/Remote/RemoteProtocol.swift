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
    case answer(sessionId: String, requestId: String, allow: Bool)
    /// Answers to the agent's questions, by question text.
    case answerQuestion(sessionId: String, requestId: String, answers: [String: String])
    /// A chat's agent, model and effort, or how much it may do alone.
    case setAgent(sessionId: String, providerId: String, model: String?, effort: String?)
    case setPolicy(sessionId: String, policy: PermissionPolicy)
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
    case runAutomation(id: String)
    case automationRuns(id: String)
    case review(sessionId: String, committed: Bool)
    case reviewFile(sessionId: String, path: String, committed: Bool, accept: Bool)
    case createPullRequest(sessionId: String, title: String, body: String, base: String?, draft: Bool, commitFirst: Bool)
    case pushChanges(sessionId: String, message: String)
    case mergePullRequest(sessionId: String, method: String)
    case markPullRequestReady(sessionId: String)
    case closePullRequest(sessionId: String)

    // The host's worktrees, so a chat there reviews, browses and edits here
    // as it would on the host. Only inside its projects and worktrees; only
    // git, gh and revund run.
    case exec(command: String, args: [String], cwd: String?)
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

    public init(projectId: String, providerId: String, prompt: String, attachments: [PromptAttachment] = [], files: [String: Data] = [:],
                baseRef: String?, policy: PermissionPolicy, model: String?, effort: String?, worktree: String?) {
        self.projectId = projectId; self.providerId = providerId; self.prompt = prompt; self.attachments = attachments
        self.files = files; self.baseRef = baseRef; self.policy = policy; self.model = model; self.effort = effort
        self.worktree = worktree
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
    /// Exchanged only inside an authenticated, encrypted session.
    public var internetAddress: InternetAddress?

    public init(projects: [Project], sessions: [Session], providers: [String], alive: [String],
                home: String? = nil, modelCatalogs: [String: ModelCatalog]? = nil,
                defaultModelNames: [String: String]? = nil,
                pullRequests: [String: RemotePullRequest]? = nil, automations: [Automation]? = nil,
                pendingPermissions: [String: [RemotePendingPermission]]? = nil,
                turnStartedAt: [String: Date]? = nil, pagedHistory: Bool? = nil, internetAddress: InternetAddress? = nil) {
        self.projects = projects; self.sessions = sessions; self.providers = providers; self.alive = alive
        self.home = home; self.modelCatalogs = modelCatalogs; self.defaultModelNames = defaultModelNames
        self.pullRequests = pullRequests
        self.automations = automations
        self.pendingPermissions = pendingPermissions
        self.turnStartedAt = turnStartedAt
        self.pagedHistory = pagedHistory
        self.internetAddress = internetAddress
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
