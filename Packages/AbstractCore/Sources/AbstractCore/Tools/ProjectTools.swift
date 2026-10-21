import Foundation

/// An MCP server a project gives its chats' agents (ABS-123), added once in
/// Project Settings → Tools (MCP). Each agent gets it through its own flag
/// for that chat only; the user's global agent config is never written.
public struct ProjectToolServer: Sendable, Hashable, Identifiable, Codable {
    /// How the agent reaches the server.
    public enum Connection: Sendable, Hashable, Codable {
        /// Streamable HTTP. A server that signs in with OAuth does so through
        /// the agent, where the agent supports it.
        case url(String, headers: [String: String])
        /// A command the agent starts and talks to over stdio.
        case command([String], env: [String: String])

        /// The URL, or the command as typed.
        public var summary: String {
            switch self {
            case let .url(url, _): url
            case let .command(argv, _): ShellWords.join(argv)
            }
        }
    }

    public var id: String
    public var projectId: String
    /// What agents call it: tools read `mcp__<name>__<tool>` in Claude.
    public var name: String
    public var connection: Connection
    /// The agents (provider ids) whose chats get it.
    public var agents: [String]
    /// How to use it, added to the agent's instructions.
    public var notes: String
    /// What the server said it offers, when Abstract last asked.
    public var tools: [Tool]
    /// Each tool's access, by name; a tool missing here has its default.
    public var access: [String: ToolAccess]
    public var listedAt: Date?
    /// Why the last listing failed, in words for the user.
    public var listError: String?
    public var createdAt: Date

    /// Usage notes are cut here, as Paperclip does for connection instructions.
    public static let notesLimit = 2_000

    public init(id: String = UUID().uuidString, projectId: String, name: String, connection: Connection,
                agents: [String] = ["claude", "codex", "opencode"], notes: String = "", tools: [Tool] = [],
                access: [String: ToolAccess] = [:], listedAt: Date? = nil, listError: String? = nil,
                createdAt: Date = Date()) {
        self.id = id; self.projectId = projectId; self.name = name; self.connection = connection
        self.agents = agents; self.notes = String(notes.prefix(Self.notesLimit)); self.tools = tools
        self.access = access; self.listedAt = listedAt; self.listError = listError; self.createdAt = createdAt
    }

    /// One tool, as the server listed it.
    public struct Tool: Sendable, Hashable, Codable, Identifiable {
        public var name: String
        public var detail: String?
        /// The server says it only reads (MCP's `readOnlyHint`).
        public var readOnly: Bool

        public var id: String { name }

        public init(name: String, detail: String? = nil, readOnly: Bool = false) {
            self.name = name; self.detail = detail; self.readOnly = readOnly
        }
    }

    /// A tool's access: what was chosen, else Allowed for a tool that only
    /// reads and Ask first for one that may change something.
    public func access(_ tool: Tool) -> ToolAccess {
        access[tool.name] ?? (tool.readOnly ? .allowed : .askFirst)
    }

    /// What `provider` gets of this server for one chat, or nil when it
    /// gets none of it: not chosen for it, or an agent that can't take it.
    public func launch(for provider: any ProviderDefinition) -> MCPServerLaunch? {
        guard agents.contains(provider.id), provider.toolServerSupport != .none else { return nil }
        var launch = MCPServerLaunch(name: name, connection: connection, notes: notes)
        for tool in tools {
            switch access(tool) {
            case .allowed: launch.allowed.append(tool.name)
            case .askFirst: launch.askFirst.append(tool.name)
            case .off: launch.off.append(tool.name)
            }
        }
        return launch
    }

    /// The name agents will see: lower case letters, digits and dashes, as
    /// every agent's config takes it (Codex keys split on dots).
    public static func cleanName(_ text: String) -> String {
        let mapped = text.lowercased().unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII ? Character(scalar) : "-"
        }
        return String(mapped).split(separator: "-").joined(separator: "-")
    }

    /// A name from what was pasted: `mcp.linear.app` → `linear`,
    /// `npx -y @sentry/mcp-server` → `sentry`.
    public static func suggestedName(for connection: Connection) -> String {
        switch connection {
        case let .url(url, _):
            let host = URL(string: url)?.host ?? url
            let parts = host.split(separator: ".").map(String.init)
                .filter { !["mcp", "api", "www", "com", "app", "io", "dev", "net", "org", "ai", "so", "co"].contains($0) }
            return cleanName(parts.last ?? host)
        case let .command(argv, _):
            // The first word that isn't a runner or a flag: the package or program.
            let runners: Set = ["npx", "uvx", "bunx", "pnpx", "node", "python", "python3", "uv", "bun", "deno",
                                "pnpm", "yarn", "dlx", "run", "exec", "docker", "-i", "--rm"]
            let word = argv.first { !$0.hasPrefix("-") && !runners.contains(($0 as NSString).lastPathComponent) } ?? "server"
            let package = (word as NSString).lastPathComponent.split(separator: "@").first.map(String.init) ?? word
            let scope = word.hasPrefix("@") ? word.dropFirst().split(separator: "/").first.map(String.init) : nil
            let trimmed = cleanName(package).split(separator: "-")
                .filter { !["mcp", "server", "stdio"].contains($0) }.joined(separator: "-")
            let name = trimmed.isEmpty ? cleanName(scope ?? "") : trimmed
            return name.isEmpty ? "server" : name
        }
    }
}

/// What an agent may do with one of a server's tools.
public enum ToolAccess: String, Sendable, Hashable, Codable, CaseIterable {
    case allowed
    case askFirst = "ask-first"
    case off

    public var title: String {
        switch self {
        case .allowed: "Allowed"
        case .askFirst: "Ask first"
        case .off: "Off"
        }
    }
}

/// How much of a project's tool servers an agent can take.
public enum ToolServerSupport: Sendable, Hashable {
    /// None: its CLI can't be given a server, or can't keep a tool out.
    case none
    /// Tools can be allowed or turned off, but the agent can't stop and ask
    /// Abstract, so a tool set to Ask first is left out.
    case allowOrOff
    /// Ask first shows the chat's permission card before the tool runs.
    case askFirst
}

/// One MCP server handed to one chat's agent: a project's (ABS-123), or
/// Abstract's own code-history server (ABS-61). Each provider renders the
/// whole list as one config, with its own flag.
public struct MCPServerLaunch: Sendable, Hashable {
    public var name: String
    public var connection: ProjectToolServer.Connection
    /// Every tool runs without asking, listed or not (Abstract's own servers).
    public var allowsEverything = false
    public var allowed: [String] = []
    public var askFirst: [String] = []
    public var off: [String] = []
    public var notes: String = ""

    public init(name: String, connection: ProjectToolServer.Connection, allowsEverything: Bool = false,
                allowed: [String] = [], askFirst: [String] = [], off: [String] = [], notes: String = "") {
        self.name = name; self.connection = connection; self.allowsEverything = allowsEverything
        self.allowed = allowed; self.askFirst = askFirst; self.off = off; self.notes = notes
    }

    /// The tools an agent that can't ask first must leave out.
    public var withheld: [String] { off + askFirst }

    /// The environment names that carry this server's secrets to an agent
    /// whose config can only name a variable (Codex, Muse): never argv,
    /// which every user on the Mac can read.
    public func secretVariable(_ key: String) -> String {
        let clean = { (s: String) in s.uppercased().map { $0.isLetter || $0.isNumber ? $0 : "_" } }
        return "ABSTRACT_MCP_" + String(clean(name)) + "_" + String(clean(key))
    }

    /// The usage notes of every server that has some, for the agent's instructions.
    public static func instructions(_ servers: [MCPServerLaunch]) -> String? {
        let parts = servers.compactMap { server -> String? in
            let notes = server.notes.trimmingCharacters(in: .whitespacesAndNewlines)
            return notes.isEmpty ? nil : "How to use the \(server.name) MCP tools:\n\(notes)"
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }
}

/// Splitting a pasted command into its words, the way a shell would for
/// quotes and backslashes (nothing is expanded).
public enum ShellWords {
    public static func split(_ text: String) -> [String] {
        var words: [String] = []
        var current = ""
        var inWord = false
        var quote: Character?
        var escaped = false
        for ch in text {
            if escaped { current.append(ch); escaped = false; inWord = true; continue }
            if ch == "\\" && quote != "'" { escaped = true; continue }
            if let q = quote {
                if ch == q { quote = nil } else { current.append(ch) }
                continue
            }
            if ch == "\"" || ch == "'" { quote = ch; inWord = true; continue }
            if ch.isWhitespace {
                if inWord { words.append(current); current = ""; inWord = false }
                continue
            }
            current.append(ch); inWord = true
        }
        if inWord { words.append(current) }
        return words
    }

    /// The words back as one line, quoting those that need it.
    public static func join(_ words: [String]) -> String {
        words.map { word in
            word.isEmpty || word.contains(where: { $0.isWhitespace || "\"'\\$`".contains($0) })
                ? "'" + word.replacingOccurrences(of: "'", with: #"'\''"#) + "'" : word
        }.joined(separator: " ")
    }

    /// `NAME=value` lines (environment) or `Name: value` lines (headers);
    /// blank lines and lines without the separator are skipped.
    public static func pairs(_ text: String, separator: Character) -> [String: String] {
        var pairs: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let i = line.firstIndex(of: separator) else { continue }
            let key = line[..<i].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            pairs[key] = line[line.index(after: i)...].trimmingCharacters(in: .whitespaces)
        }
        return pairs
    }

    public static func lines(_ pairs: [String: String], separator: String) -> String {
        pairs.keys.sorted().map { "\($0)\(separator)\(pairs[$0] ?? "")" }.joined(separator: "\n")
    }
}
