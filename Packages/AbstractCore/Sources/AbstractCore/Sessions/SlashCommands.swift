import Foundation

/// A command the agent itself understands, typed as `/name` at the start of a message.
public struct AgentCommand: Sendable, Hashable {
    public enum Kind: Sendable, Hashable { case command, skill }
    public var name: String
    /// What it does, when the agent says.
    public var detail: String?
    /// What to type after it, e.g. `<number>`, when it takes something.
    public var argumentHint: String?
    public var kind: Kind

    public init(name: String, detail: String? = nil, argumentHint: String? = nil, kind: Kind = .command) {
        self.name = name
        self.detail = detail
        self.argumentHint = argumentHint
        self.kind = kind
    }
}

/// The commands an agent reported, and which agent it was.
public struct AgentCommandList: Sendable, Hashable {
    public var providerId: String
    public var commands: [AgentCommand]

    public init(providerId: String, commands: [AgentCommand]) {
        self.providerId = providerId
        self.commands = commands
    }

    /// Its commands when they are `providerId`'s. A chat just switched to
    /// another agent still has the old one's list until the new one starts.
    public func commands(for providerId: String) -> [AgentCommand] {
        self.providerId == providerId ? commands : []
    }
}

/// Abstract's own chat actions, offered in the composer's `/` menu.
public enum AppCommand: String, CaseIterable, Sendable, Hashable {
    case agent, model, effort, mode, stop, diff, rename, attach, tasks

    public var name: String { rawValue }

    public var detail: String {
        switch self {
        case .agent: "Switch this chat to another agent"
        case .model: "Choose the model"
        case .effort: "Choose the reasoning effort"
        case .mode: "Choose how much the agent may do without asking"
        case .stop: "Stop the agent"
        case .diff: "Review the changes"
        case .rename: "Rename this chat"
        case .attach: "Attach files or a folder"
        case .tasks: "Show background tasks"
        }
    }

    /// Offered in every chat. The rest only where a provider adds them.
    public static let everywhere: [AppCommand] = [.agent, .model, .effort, .mode, .stop, .diff, .rename, .attach]

    /// Those that make no sense right now: Stop while the agent is idle,
    /// Rename for a chat on another Mac (its row can't rename).
    public static func unavailable(working: Bool, remote: Bool) -> Set<AppCommand> {
        var out: Set<AppCommand> = []
        if !working { out.insert(.stop) }
        if remote { out.insert(.rename) }
        return out
    }
}

/// App commands an agent adds, and its own commands that app commands stand in for.
public struct ProviderCommands: Sendable, Hashable {
    public var extra: [AppCommand]
    /// Agent command name → the app command that does its job, so only one is listed.
    public var replaces: [String: AppCommand]

    public init(extra: [AppCommand] = [], replaces: [String: AppCommand] = [:]) {
        self.extra = extra
        self.replaces = replaces
    }

    public static let none = ProviderCommands()
}

/// One entry of the `/` menu.
public enum SlashEntry: Sendable, Hashable {
    case app(AppCommand)
    case agent(AgentCommand)

    public var name: String {
        switch self {
        case .app(let command): command.name
        case .agent(let command): command.name
        }
    }

    var isApp: Bool { if case .app = self { true } else { false } }
}

public enum SlashCommands {
    /// What follows `/` while the menu should be open: the draft is `/` and a
    /// name so far, with no space or line break. nil: the menu is closed.
    public static func query(forDraft draft: String) -> String? {
        guard draft.hasPrefix("/") else { return nil }
        let rest = draft.dropFirst()
        return rest.contains(where: \.isWhitespace) ? nil : String(rest)
    }

    /// The menu for `query`: a command named exactly that first, then app
    /// commands, then the agent's, each group by how well it matches. An agent
    /// command an app command covers (same name, or one the provider says it
    /// replaces) is left out.
    public static func entries(query: String, agentCommands: [AgentCommand], provider: ProviderCommands,
                               excluding: Set<AppCommand>) -> [SlashEntry] {
        let offered = AppCommand.everywhere + provider.extra
        let covered = Set(offered.map(\.name)).union(provider.replaces.keys)
        let all = offered.filter { !excluding.contains($0) }.map(SlashEntry.app)
            + agentCommands.filter { !covered.contains($0.name) }.map(SlashEntry.agent)
        let q = query.lowercased()
        guard !q.isEmpty else { return all }
        return all.enumerated()
            .compactMap { index, entry -> (index: Int, entry: SlashEntry, score: Int)? in
                let score = FuzzyScore.score(entry.name.lowercased(), q)
                return score > 0 ? (index, entry, score) : nil
            }
            .sorted { a, b in
                let aExact = a.entry.name.lowercased() == q, bExact = b.entry.name.lowercased() == q
                if aExact != bExact { return aExact }
                if a.entry.isApp != b.entry.isApp { return a.entry.isApp }
                if a.score != b.score { return a.score > b.score }
                return a.index < b.index
            }
            .map(\.entry)
    }

    /// The app command a whole draft names (`/model`), to run instead of
    /// sending it to the agent. `/model x` or an agent's command gives nil.
    public static func appCommand(forDraft draft: String, provider: ProviderCommands,
                                  excluding: Set<AppCommand>) -> AppCommand? {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return (AppCommand.everywhere + provider.extra).first { "/" + $0.name == text && !excluding.contains($0) }
    }
}
