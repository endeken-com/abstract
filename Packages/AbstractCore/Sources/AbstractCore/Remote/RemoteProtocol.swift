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
    /// A connection to a local model server on the other Mac, carried over
    /// this channel, so the server itself never has to listen on the network.
    case tunnel(id: Int, TunnelFrame)
}

public enum TunnelFrame: Codable, Sendable {
    case open(LocalModelKind)
    case data(Data)
    case close
}

public enum RemoteRequest: Codable, Sendable {
    /// Projects and chats, now and whenever they change.
    case snapshot
    /// A chat's output from `afterSeq` on, then as it streams.
    case subscribe(sessionId: String, afterSeq: Int)
    case unsubscribe(sessionId: String)
    case send(sessionId: String, text: String)
    /// A message with attachments; a file's bytes travel with it, by attachment id.
    case sendAttachments(sessionId: String, text: String, attachments: [PromptAttachment], files: [String: Data])
    case start(projectId: String, providerId: String, prompt: String, policy: PermissionPolicy)
    /// A chat as the New Chat window sets it up, started on the Mac its project is on.
    case startChat(RemoteStart)
    case stop(sessionId: String)
    case answer(sessionId: String, requestId: String, allow: Bool)
    /// A chat's agent, model and effort, or how much it may do alone.
    case setAgent(sessionId: String, providerId: String, model: String?, effort: String?)
    case setPolicy(sessionId: String, policy: PermissionPolicy)
    case resume(sessionId: String)
    case rename(sessionId: String, name: String)
    case setArchived(sessionId: String, archived: Bool)

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
    case failed(String)
    case started(sessionId: String)
    case exec(ExecResult)
    case data(Data)
    case fileInfo(FileInfo?)
    case files([String], truncated: Bool)
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
    /// Local model servers on that Mac that it shares.
    public var localModels: [LocalModelKind]?
    /// That Mac's home folder.
    public var home: String?
    /// The models each agent offers there.
    public var modelCatalogs: [String: ModelCatalog]?

    public init(projects: [Project], sessions: [Session], providers: [String], alive: [String], localModels: [LocalModelKind]? = nil,
                home: String? = nil, modelCatalogs: [String: ModelCatalog]? = nil) {
        self.projects = projects; self.sessions = sessions; self.providers = providers; self.alive = alive
        self.localModels = localModels; self.home = home; self.modelCatalogs = modelCatalogs
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
