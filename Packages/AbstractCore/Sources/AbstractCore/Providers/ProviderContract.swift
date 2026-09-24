import Foundation

/// How much an agent may do without asking.
public enum PermissionPolicy: String, Sendable, Codable, CaseIterable {
    case ask
    case autoEdits = "auto-edits"
    case bypass

    public var title: String {
        switch self {
        case .ask: "Ask before acting"
        case .autoEdits: "Accept edits"
        case .bypass: "Full autonomy"
        }
    }

    public var detail: String {
        switch self {
        case .ask: "You approve each tool call in the chat."
        case .autoEdits: "File edits go through; commands still ask."
        case .bypass: "Nothing asks. Only for trusted tasks."
        }
    }
}

public struct LaunchContext: Sendable {
    /// Working directory: the session's worktree.
    public var cwd: String
    public var prompt: String
    public var resumeId: String?
    public var permissionPolicy: PermissionPolicy
    public var extraArgs: [String]
    public var binaryOverride: String?
    /// Model name or alias; nil uses the agent's own configured default.
    public var model: String?
    /// Reasoning effort, e.g. "high"; nil uses the agent's own default.
    public var effort: String?
    public var outputStyle: OutputStyle
    /// Images sent with the prompt, as files on the agent's Mac.
    public var images: [String]
    /// Folders outside the worktree the agent may read without asking (attachments).
    public var readableDirs: [String]

    public init(cwd: String, prompt: String, resumeId: String? = nil, permissionPolicy: PermissionPolicy,
                extraArgs: [String] = [], binaryOverride: String? = nil, model: String? = nil, effort: String? = nil,
                outputStyle: OutputStyle = .default, images: [String] = [], readableDirs: [String] = []) {
        self.cwd = cwd; self.prompt = prompt; self.resumeId = resumeId; self.permissionPolicy = permissionPolicy
        self.extraArgs = extraArgs; self.binaryOverride = binaryOverride; self.outputStyle = outputStyle
        self.images = images; self.readableDirs = readableDirs
        self.model = Self.nonBlank(model)
        self.effort = Self.nonBlank(effort)
    }

    private static func nonBlank(_ value: String?) -> String? {
        value.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0.trimmingCharacters(in: .whitespaces) }
    }
}

/// How the agent writes its answers. Claude Code has these built in (its
/// `outputStyle` setting); Codex gets the same guidance as developer
/// instructions.
public enum OutputStyle: String, Sendable, CaseIterable, Identifiable, Codable {
    case `default`, proactive, concise, explanatory, learning

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .default: "Default"
        case .proactive: "Proactive"
        case .concise: "Concise"
        case .explanatory: "Explanatory"
        case .learning: "Learning"
        }
    }

    public var detail: String {
        switch self {
        case .default: "The agent's own way of working."
        case .proactive: "Acts right away, interrupts less, and prefers doing to planning."
        case .concise: "Terse answers that lead with the result and skip the narration."
        case .explanatory: "Explains its choices and the codebase's patterns as it works."
        case .learning: "Explains as it goes and leaves small pieces of code for you to write."
        }
    }

    /// Guidance for agents without built-in styles.
    var instructions: String? {
        switch self {
        case .default: nil
        case .proactive: "Work autonomously: act immediately, minimise interruptions and clarifying questions, and prefer action over planning."
        case .concise: "Be concise: lead with the result, skip preamble and narration, and keep only what the user needs."
        case .explanatory: "Alongside the work, briefly explain your implementation choices and the codebase's patterns, as short educational insights."
        case .learning: "Teach as you work: explain your reasoning, and where it helps the user learn, leave small, well-scoped pieces of code for them to write, marked clearly."
        }
    }
}

/// Exactly what to spawn. The core runs it without interpreting it.
public struct LaunchSpec: Sendable, Hashable, Codable {
    public var command: String
    public var args: [String]
    public var cwd: String
    public var env: [String: String]
    /// Written to stdin right after spawn.
    public var stdinInitial: String?
    /// Keep stdin open for follow-up turns and permission answers. When false,
    /// stdin is closed right after `stdinInitial` (agents like `codex exec`
    /// otherwise wait on it forever).
    public var keepStdinOpen: Bool

    public init(command: String, args: [String], cwd: String, env: [String: String] = [:],
                stdinInitial: String? = nil, keepStdinOpen: Bool) {
        self.command = command; self.args = args; self.cwd = cwd; self.env = env
        self.stdinInitial = stdinInitial; self.keepStdinOpen = keepStdinOpen
    }
}

public enum OutputStreamKind: String, Sendable, Codable {
    case stdout, stderr
    /// What you sent the agent, kept in the log beside its output: agents
    /// don't echo it, and a transcript rebuilt from the log (after a relaunch,
    /// or on another device) needs it.
    case user
}

public struct UsageTotals: Sendable, Hashable, Codable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheRead: Int
    public var cacheWrite: Int
    public init(inputTokens: Int = 0, outputTokens: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0) {
        self.inputTokens = inputTokens; self.outputTokens = outputTokens
        self.cacheRead = cacheRead; self.cacheWrite = cacheWrite
    }
    public static let zero = UsageTotals()
    public static func + (a: UsageTotals, b: UsageTotals) -> UsageTotals {
        UsageTotals(inputTokens: a.inputTokens + b.inputTokens, outputTokens: a.outputTokens + b.outputTokens,
                    cacheRead: a.cacheRead + b.cacheRead, cacheWrite: a.cacheWrite + b.cacheWrite)
    }
}

/// A small inline diff shown under an edit tool call.
public struct EditPreview: Sendable, Hashable, Codable {
    public enum Origin: String, Sendable, Codable { case context = " ", added = "+", removed = "-" }
    public struct Line: Sendable, Hashable, Codable {
        public var origin: Origin
        public var content: String
        /// Line numbers in the old and new file, when the source knows them.
        public var oldLine: Int?
        public var newLine: Int?
        /// First line of a new hunk: the reader sees a gap before it.
        public var startsHunk: Bool?
        public init(origin: Origin, content: String, oldLine: Int? = nil, newLine: Int? = nil, startsHunk: Bool? = nil) {
            self.origin = origin; self.content = content
            self.oldLine = oldLine; self.newLine = newLine; self.startsHunk = startsHunk
        }
    }
    public var filePath: String
    public var additions: Int
    public var deletions: Int
    public var lines: [Line]
    public init(filePath: String, additions: Int, deletions: Int, lines: [Line]) {
        self.filePath = filePath; self.additions = additions; self.deletions = deletions; self.lines = lines
    }
}

public enum TextRole: String, Sendable, Codable { case assistant, user }

/// Normalised agent output. Every provider parser produces only these.
public enum AgentEvent: Sendable, Hashable {
    case status(SessionStatus, detail: String?)
    case sessionId(String)
    case system(model: String?, cwd: String?, permissionMode: String?, sessionId: String?)
    /// `partial` chunks share `blockId` and are appended; the final block
    /// (partial == false) with the same id replaces them.
    case text(role: TextRole, text: String, blockId: String?, partial: Bool)
    case thinking(text: String, blockId: String?, partial: Bool)
    case toolUse(id: String, name: String, input: JSONValue, edit: EditPreview?)
    case toolResult(toolUseId: String, output: String, isError: Bool, edit: EditPreview?)
    case permissionRequest(requestId: String, toolName: String, input: JSONValue)
    case turnEnd(durationMs: Int?, costUsd: Double?, usage: UsageTotals?, summary: String?)
    case usage(UsageTotals, costUsd: Double?, durationMs: Int?, turns: Int?)
    case error(String)
    case raw(line: String, stream: OutputStreamKind)
    /// What the agent predicts you'll say next, offered in the reply box.
    case promptSuggestion(String)
}

public protocol OutputParser: AnyObject {
    /// One raw line from the agent. Must never throw or crash on bad input.
    func feed(_ line: String, stream: OutputStreamKind) -> [AgentEvent]
    func onExit(code: Int32?) -> [AgentEvent]
}

/// A model an agent can run, as offered in pickers. `id` is passed verbatim
/// to the CLI, so aliases ("opus") and full names both work.
public struct ModelOption: Sendable, Hashable, Identifiable, Codable {
    public var id: String
    public var label: String
    /// What the model is for, from the CLI's own catalogue.
    public var detail: String?
    /// Reasoning-effort levels it accepts, lowest first. Empty = no effort choice.
    public var efforts: [String]
    /// The effort it runs at when none is passed, when the CLI says.
    public var defaultEffort: String?
    /// Set while the model is being retired, e.g. "Retires Oct 14".
    public var note: String?
    /// The concrete model an alias runs today, e.g. "claude-sonnet-5" for "sonnet".
    public var resolvedId: String?

    public init(id: String, label: String, detail: String? = nil, efforts: [String] = [], defaultEffort: String? = nil,
                note: String? = nil, resolvedId: String? = nil) {
        self.id = id; self.label = label; self.detail = detail; self.efforts = efforts
        self.defaultEffort = defaultEffort; self.note = note; self.resolvedId = resolvedId
    }

    /// "xhigh" → "Extra high". Unknown levels are capitalised.
    public static func effortTitle(_ effort: String) -> String {
        switch effort {
        case "xhigh": "Extra high"
        default: effort.prefix(1).uppercased() + effort.dropFirst()
        }
    }
}

public enum FollowUpMode: Sendable {
    /// Follow-ups are written to the live process's stdin.
    case stdin
    /// Follow-ups spawn a new process that resumes the provider session.
    case respawn
}

/// Everything agent-specific. Adding an agent = one conforming type plus one
/// line in `ProviderRegistry`. The rest of the app never names a provider.
public protocol ProviderDefinition: Sendable {
    var id: String { get }
    var name: String { get }
    /// Asset name of the provider's logo in the app bundle.
    var logoAsset: String { get }
    var binary: String { get }
    var detectArgs: [String] { get }
    var followUpMode: FollowUpMode { get }
    func buildLaunch(_ ctx: LaunchContext) -> LaunchSpec
    func buildResume(_ ctx: LaunchContext, resumeId: String) -> LaunchSpec
    func makeParser() -> OutputParser
    /// stdin line for a follow-up turn (stdin mode only).
    func buildUserMessage(_ text: String) -> String?
    /// The same with images, as files on the agent's Mac.
    func buildUserMessage(_ text: String, images: [String]) -> String?
    /// stdin line answering a permission request (stdin mode only).
    func buildPermissionResponse(requestId: String, allow: Bool, input: JSONValue?) -> String?
    /// A stdin line that switches a running agent's permission mode, when the
    /// agent can change it live. nil: the new mode applies at the next launch.
    func buildPermissionModeChange(_ policy: PermissionPolicy, requestId: String) -> String?
    /// Offered until discovery succeeds, and whenever it fails. Any other
    /// name can still be typed in.
    var fallbackModels: ModelCatalog { get }
    /// Asks the CLI which models this account has. nil when it can't tell.
    /// `binary` overrides the provider's own binary name.
    func discoverModels(executor: any Executor, binary: String?) async -> ModelCatalog?
    /// The model the CLI uses when none is passed, read from its own config.
    func configuredDefaultModel(home: String) -> String?
    /// The effort the CLI uses when none is passed, read from its own config.
    func configuredDefaultEffort(home: String) -> String?
}

public extension ProviderDefinition {
    func configuredDefaultEffort(home: String) -> String? { nil }
    func buildUserMessage(_ text: String, images: [String]) -> String? { buildUserMessage(text) }
    func buildPermissionModeChange(_ policy: PermissionPolicy, requestId: String) -> String? { nil }
}
