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
