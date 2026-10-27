import Foundation

/// The recognizable indicator a tool row shows (ABS-165, decided by
/// ABS-167). Resolved from the tool name and input every row already
/// has; never fetched, never guessed. An unknown tool is `.generic`,
/// an unknown MCP server a letter monogram, and a shell command with
/// no catalog hit the plain terminal.
public enum ToolIndicator: Sendable, Hashable {
    /// A catalog brand, by id ("GitHub", "Linear", "Abstract", …).
    case brand(String)
    /// An MCP server with no catalog brand: a monogram tile.
    case mcpServer(name: String)
    /// An SF Symbol, as rows showed before brands.
    case kind(symbol: String)
    case generic

    /// Help and accessibility wording ("GitHub", "weather MCP server").
    public var label: String {
        switch self {
        case .brand(let id): ToolIndicator.catalog.first { $0.id == id }?.label ?? id
        case .mcpServer(let name): "\(name) MCP server"
        case .kind(let symbol):
            switch symbol {
            case "hammer": "Build tool"
            case "magnifyingglass": "Search"
            case "network": "Network tool"
            case "macwindow": "Editor"
            case "terminal": "Terminal"
            case "book.closed": "Skill"
            case "puzzlepiece.extension": "Plugin tool"
            default: "Tool"
            }
        case .generic: "Tool"
        }
    }

    // MARK: - Monogram

    /// A monogram tile's letter and its place in the 7-colour icon
    /// palette, from a stable hash of the server name (FNV-1a over the
    /// lowercased name; the phone mirrors this exactly).
    public struct Monogram: Sendable, Hashable {
        public var letter: String
        public var colorIndex: Int
    }

    public static func monogram(name: String) -> Monogram {
        let lower = name.lowercased()
        var hash: UInt32 = 0x811C_9DC5
        for byte in lower.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 0x0100_0193
        }
        let letter = lower.first { $0.isLetter || $0.isNumber }.map { String($0).uppercased() } ?? "?"
        return Monogram(letter: letter, colorIndex: Int(hash % 7))
    }

    // MARK: - Shell unwrapping

    /// The command a `zsh -lc "…"` wrapper runs, else the command
    /// itself. Shared by the Mac rows and this resolver.
    public static func unwrapShell(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for shell in ["/bin/zsh", "/bin/bash", "/bin/sh", "zsh", "bash", "sh"] {
            for flag in [" -lc ", " -c "] where s.hasPrefix(shell + flag) {
                var body = String(s.dropFirst(shell.count + flag.count))
                guard let quote = body.first, quote == "\"" || quote == "'", body.count >= 2, body.last == quote else { continue }
                body = String(body.dropFirst().dropLast())
                if quote == "\"" {
                    body = body.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\$", with: "$")
                        .replacingOccurrences(of: "\\`", with: "`").replacingOccurrences(of: "\\\\", with: "\\")
                }
                return body
            }
        }
        return s
    }

    // MARK: - Resolution

    private static let officialPlugins: [String: String] = [
        "sh.abstract.github": "GitHub",
        "sh.abstract.bitbucket": "Bitbucket",
        "sh.abstract.linear": "Linear",
        "sh.abstract.jira": "Jira",
    ]

    private static let commandTools: Set<String> = ["bash", "shell", "command_execution", "bashoutput"]

    /// First match wins, in the ABS-167 order: skill, Abstract's own
    /// MCP servers, plugin tools, other MCP calls, shell commands,
    /// built-ins, generic.
    ///
    /// `pluginId` is the plugin behind a published plugin tool, when
    /// the app can still look it up; nil when the plugin is gone
    /// (plugin tools then take the Abstract mark). `skillUse` is false
    /// on a pending approval, which always shows what runs, never a
    /// skill reading.
    public static func resolve(name: String, input: JSONValue, pluginId: String? = nil, skillUse allowsSkill: Bool = true) -> ToolIndicator {
        if allowsSkill, SkillUse.name(tool: name, input: input) != nil { return .kind(symbol: "book.closed") }
        if CodeHistory.tool(inStreamName: name) != nil,
           ["code_history", "chat_excerpt"].contains(name)
            || name.hasPrefix("mcp__abstract-code-history__")
            || name.hasPrefix("abstract-code-history_") { return .brand("Abstract") }
        if name == "name_branch" { return .brand("Abstract") }
        if PluginTools.toolName(inStreamName: name) != nil {
            if let pluginId, let brand = officialPlugins[pluginId] { return .brand(brand) }
            return pluginId != nil ? .kind(symbol: "puzzlepiece.extension") : .brand("Abstract")
        }
        if let mcp = mcpIndicator(name) { return mcp }
        if commandTools.contains(name.lowercased()) {
            guard let raw = input["command"]?.string ?? input["cmd"]?.string, !raw.isEmpty else { return .kind(symbol: "terminal") }
            return commandIndicator(unwrapShell(raw)) ?? .kind(symbol: "terminal")
        }
        if let symbol = builtinSymbol(name) { return .kind(symbol: symbol) }
        return .generic
    }

    /// A folded command run keeps its brand only when every call has it.
    public static func foldedCommands(_ calls: [ToolCall]) -> ToolIndicator {
        let indicators = calls.map { resolve(name: $0.name, input: $0.input) }
        guard let first = indicators.first, indicators.allSatisfy({ $0 == first }) else { return .kind(symbol: "terminal") }
        return first
    }

    /// `mcp__<server>__<tool>` directly, or OpenCode's `<server>_<tool>`
    /// when the server is a known catalog alias (that spelling alone
    /// could be a plain tool named with an underscore).
    private static func mcpIndicator(_ name: String) -> ToolIndicator? {
        if name.hasPrefix("mcp__") {
            let rest = String(name.dropFirst(5))
            let server = rest.components(separatedBy: "__").first ?? ""
            guard !server.isEmpty else { return nil }
            if let entry = aliasEntry(server) { return indicator(for: entry) }
            return .mcpServer(name: server)
        }
        // Longest candidates first so `abstract-code-history_` wins
        // over a shorter alias that happens to be its prefix.
        var candidates: [String] = []
        for entry in catalog {
            for alias in entry.mcpAliases { candidates += [alias, "\(alias)-mcp", "mcp-\(alias)"] }
        }
        for candidate in candidates.sorted(by: { $0.count > $1.count }) where name.hasPrefix(candidate + "_") && name.count > candidate.count + 1 {
            if let entry = aliasEntry(candidate) { return indicator(for: entry) }
        }
        return nil
    }

    /// Catalog alias match: exact, lowercased, also with a `-mcp` or
    /// `mcp-` affix.
    private static func aliasEntry(_ server: String) -> ToolBrandEntry? {
        var key = server.lowercased()
        if key.hasSuffix("-mcp") { key = String(key.dropLast(4)) }
        if key.hasPrefix("mcp-") { key = String(key.dropFirst(4)) }
        return catalog.first { $0.mcpAliases.contains(key) }
    }

    private static func indicator(for entry: ToolBrandEntry) -> ToolIndicator {
        entry.symbol.map { .kind(symbol: $0) } ?? .brand(entry.id)
    }

    /// Today's built-in symbol table, unchanged.
    private static func builtinSymbol(_ name: String) -> String? {
        switch name.lowercased() {
        case "read", "read_file", "notebookread": "doc.text"
        case "write", "write_file": "doc.badge.plus"
        case "edit", "edit_file", "multiedit", "notebookedit", "applypatch", "apply_patch", "file_change": "pencil"
        case "bash", "shell", "command_execution", "bashoutput": "terminal"
        case "grep", "glob", "search", "ls", "toolsearch": "magnifyingglass"
        case "webfetch", "web_fetch", "websearch", "web_search": "globe"
        case "todowrite", "todolist", "todo_list": "checklist"
        case "exitplanmode": "list.bullet.clipboard"
        case "task", "agent": "person.2"
        case "skill": "book.closed"
        case "askuserquestion": "questionmark.bubble"
        default: name.hasPrefix("mcp__") ? "puzzlepiece.extension" : nil
        }
    }
}

// MARK: - Command parsing

/// The segment/wrapper algorithm from ABS-167: split a command into
/// segments, strip wrappers per segment, match the executable exactly
/// against the catalog. Anything uncertain (unknown wrapper flag, a
/// `$` or backtick in the executable) makes its segment unresolvable
/// rather than guessed.
extension ToolIndicator {
    static func commandIndicator(_ command: String, depth: Int = 0) -> ToolIndicator? {
        for segment in splitSegments(command) {
            if let hit = segmentIndicator(tokenize(segment), depth: depth) { return hit }
        }
        return nil
    }

    /// Splits on `&&`, `||`, `;`, `|` and newlines outside quotes.
    static func splitSegments(_ command: String) -> [String] {
        let chars = Array(command)
        var segments: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        var i = 0
        func flush() { segments.append(current); current = "" }
        while i < chars.count {
            let c = chars[i]
            if escaped { current.append(c); escaped = false; i += 1; continue }
            if c == "\\", quote != "'" { current.append(c); escaped = true; i += 1; continue }
            if let open = quote {
                current.append(c)
                if c == open { quote = nil }
                i += 1; continue
            }
            if c == "'" || c == "\"" { quote = c; current.append(c); i += 1; continue }
            let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
            if c == "&", next == "&" { flush(); i += 2; continue }
            if c == "|" { flush(); i += next == "|" ? 2 : 1; continue }
            if c == ";" || c == "\n" { flush(); i += 1; continue }
            current.append(c); i += 1
        }
        flush()
        return segments
    }

    /// Whitespace tokens outside quotes, quotes stripped, backslash
    /// escapes resolved.
    static func tokenize(_ segment: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var started = false
        var quote: Character?
        var escaped = false
        for c in segment {
            if escaped { current.append(c); escaped = false; started = true; continue }
            if c == "\\", quote != "'" { escaped = true; started = true; continue }
            if let open = quote {
                if c == open { quote = nil } else { current.append(c) }
                started = true; continue
            }
            if c == "'" || c == "\"" { quote = c; started = true; continue }
            if c == " " || c == "\t" || c == "\r" {
                if started { tokens.append(current); current = ""; started = false }
                continue
            }
            current.append(c); started = true
        }
        if started { tokens.append(current) }
        return tokens
    }

    private static func segmentIndicator(_ rawTokens: [String], depth: Int) -> ToolIndicator? {
        var tokens = rawTokens
        guard !tokens.contains(where: { $0.contains("$") || $0.contains("`") }) else { return nil }
        while let first = tokens.first {
            let stripped = String(first.drop(while: { $0 == "(" }))
            if stripped.isEmpty { tokens.removeFirst(); continue }
            tokens[0] = stripped
            break
        }
        guard let at = executableIndex(tokens) else { return nil }
        // A nested `sh -c "…"` recurses into the quoted string, one level.
        if ["sh", "bash", "zsh"].contains(baseName(tokens[at])),
           depth == 0, at + 2 < tokens.count, ["-c", "-lc", "-cl"].contains(tokens[at + 1]) {
            return commandIndicator(tokens[at + 2], depth: depth + 1)
        }
        // Runner wrappers look through only when the next token itself
        // resolves to a catalog entry; otherwise the runner's own
        // brand stands.
        if let form = runnerForm(tokens, at: at) {
            if let hit = executableIndicator(tokens, at: at + form) { return hit }
            return executableIndicator(tokens, at: at)
        }
        return executableIndicator(tokens, at: at)
    }

    /// The index of the executable token after any environment
    /// assignments and transparent wrappers; nil when a wrapper takes
    /// a flag we don't know and the segment is abandoned.
    private static func executableIndex(_ tokens: [String]) -> Int? {
        var i = 0
        func consumeFlags(plain: Set<String>, valued: Set<String>) -> Bool {
            while i < tokens.count {
                let token = tokens[i]
                if plain.contains(token) { i += 1 }
                else if valued.contains(token) { i += 2 }
                else if token.hasPrefix("-") { return false }
                else { return true }
            }
            return true
        }
        while i < tokens.count {
            let token = tokens[i]
            if isEnvAssignment(token) { i += 1; continue }
            switch baseName(token) {
            case "env":
                i += 1
                while i < tokens.count, isEnvAssignment(tokens[i]) { i += 1 }
                guard consumeFlags(plain: ["-i"], valued: ["-u"]) else { return nil }
                while i < tokens.count, isEnvAssignment(tokens[i]) { i += 1 }
            case "sudo":
                i += 1
                guard consumeFlags(plain: ["-E", "-n", "-s", "-H"], valued: ["-u", "-g"]) else { return nil }
            case "command", "builtin", "exec", "nohup", "time":
                i += 1
            case "nice":
                i += 1
                if i < tokens.count, tokens[i] == "-n" { i += 2 }
            case "xargs":
                i += 1
                guard consumeFlags(plain: ["-0"], valued: ["-I", "-n", "-P"]) else { return nil }
            default:
                return i < tokens.count ? i : nil
            }
        }
        return nil
    }

    /// How many tokens a runner form takes at `at`, when one starts
    /// there: `npx`, `npm exec`, `uv run`, `uv tool run`, …
    private static func runnerForm(_ tokens: [String], at: Int) -> Int? {
        func token(_ offset: Int) -> String? { at + offset < tokens.count ? tokens[at + offset] : nil }
        switch (baseName(tokens[at]), token(1), token(2)) {
        case ("npx", _, _), ("bunx", _, _), ("uvx", _, _): return 1
        case ("npm", "exec", _), ("pnpm", "dlx", _), ("pnpm", "exec", _),
             ("yarn", "dlx", _), ("yarn", "exec", _), ("uv", "run", _),
             ("pipx", "run", _), ("poetry", "run", _), ("bundle", "exec", _): return 2
        case ("uv", "tool", "run"): return 3
        default: return nil
        }
    }

    /// The catalog indicator for the executable token at `at`, exact
    /// match on its basename. Only `acli` also reads the next token.
    private static func executableIndicator(_ tokens: [String], at: Int) -> ToolIndicator? {
        guard at < tokens.count else { return nil }
        let token = tokens[at]
        guard !token.contains("$"), !token.contains("`") else { return nil }
        let exe = baseName(token)
        if exe == "acli" {
            guard at + 1 < tokens.count, tokens[at + 1].lowercased() == "jira",
                  let entry = catalog.first(where: { $0.id == "Jira" }) else { return nil }
            return indicator(for: entry)
        }
        guard let entry = catalog.first(where: { $0.executables.contains(exe) }) else { return nil }
        return indicator(for: entry)
    }

    private static func baseName(_ token: String) -> String {
        token.split(separator: "/").last.map { String($0).lowercased() } ?? token.lowercased()
    }

    private static func isEnvAssignment(_ token: String) -> Bool {
        guard let eq = token.firstIndex(of: "="), eq != token.startIndex else { return false }
        let head = token[..<eq]
        return head.first.map { $0.isLetter || $0 == "_" } == true
            && head.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }
}

// MARK: - Catalog (ABS-167 v1)

/// One catalog row. The icon names the service or tool the binary
/// drives. Later additions must unambiguously mean that one tool on a
/// typical Mac; anything short of that stays generic.
public struct ToolBrandEntry: Sendable, Hashable {
    public var id: String
    public var label: String
    public var executables: [String]
    public var mcpAliases: [String]
    /// Simple Icons slug of the bundled glyph, when it has one.
    public var simpleIcon: String?
    /// SF Symbol for kind rows, which are categories, not brands.
    public var symbol: String?

    public init(id: String, label: String, executables: [String] = [], mcpAliases: [String] = [],
                simpleIcon: String? = nil, symbol: String? = nil) {
        self.id = id; self.label = label; self.executables = executables; self.mcpAliases = mcpAliases
        self.simpleIcon = simpleIcon; self.symbol = symbol
    }
}

public extension ToolIndicator {
    static let catalog: [ToolBrandEntry] = [
        .init(id: "Abstract", label: "Abstract", executables: ["abstract"],
              mcpAliases: ["abstract-code-history", "abstract-branch", "abstract-plugins"]),
        .init(id: "GitHub", label: "GitHub", executables: ["gh"], mcpAliases: ["github"], simpleIcon: "github"),
        .init(id: "Bitbucket", label: "Bitbucket", executables: ["bkt"], mcpAliases: ["bitbucket"], simpleIcon: "bitbucket"),
        .init(id: "GitLab", label: "GitLab", executables: ["glab"], mcpAliases: ["gitlab"], simpleIcon: "gitlab"),
        .init(id: "Jira", label: "Jira", executables: ["jira"], mcpAliases: ["jira", "atlassian"], simpleIcon: "jira"),
        .init(id: "Linear", label: "Linear", executables: ["linear"], mcpAliases: ["linear"], simpleIcon: "linear"),
        .init(id: "Git", label: "Git", executables: ["git"], simpleIcon: "git"),
        .init(id: "Docker", label: "Docker", executables: ["docker", "docker-compose", "podman"], simpleIcon: "docker"),
        .init(id: "Kubernetes", label: "Kubernetes", executables: ["kubectl", "k9s"], simpleIcon: "kubernetes"),
        .init(id: "Helm", label: "Helm", executables: ["helm"], simpleIcon: "helm"),
        .init(id: "Terraform", label: "Terraform", executables: ["terraform", "tofu"], simpleIcon: "terraform"),
        .init(id: "AWS", label: "AWS", executables: ["aws"], simpleIcon: "amazonwebservices"),
        .init(id: "GoogleCloud", label: "Google Cloud", executables: ["gcloud"], simpleIcon: "googlecloud"),
        .init(id: "Azure", label: "Azure", executables: ["az"], simpleIcon: "microsoftazure"),
        .init(id: "Node", label: "Node.js", executables: ["node"], simpleIcon: "nodedotjs"),
        .init(id: "Npm", label: "npm", executables: ["npm", "npx"], simpleIcon: "npm"),
        .init(id: "Pnpm", label: "pnpm", executables: ["pnpm", "pnpx"], simpleIcon: "pnpm"),
        .init(id: "Yarn", label: "Yarn", executables: ["yarn"], simpleIcon: "yarn"),
        .init(id: "Bun", label: "Bun", executables: ["bun", "bunx"], simpleIcon: "bun"),
        .init(id: "Deno", label: "Deno", executables: ["deno"], simpleIcon: "deno"),
        .init(id: "Python", label: "Python", executables: ["python", "python3", "pip", "pip3"], simpleIcon: "python"),
        .init(id: "Uv", label: "uv", executables: ["uv", "uvx"], simpleIcon: "uv"),
        .init(id: "Pytest", label: "pytest", executables: ["pytest"], simpleIcon: "pytest"),
        .init(id: "Go", label: "Go", executables: ["go"], simpleIcon: "go"),
        .init(id: "Rust", label: "Rust", executables: ["cargo", "rustc", "rustup"], simpleIcon: "rust"),
        .init(id: "Swift", label: "Swift", executables: ["swift", "swiftc", "xcodebuild", "xcrun"], simpleIcon: "swift"),
        .init(id: "Ruby", label: "Ruby", executables: ["ruby", "gem", "bundle", "bundler", "rake"], simpleIcon: "ruby"),
        .init(id: "Homebrew", label: "Homebrew", executables: ["brew"], simpleIcon: "homebrew"),
        .init(id: "PostgreSQL", label: "PostgreSQL", executables: ["psql", "pg_dump", "pg_restore"], simpleIcon: "postgresql"),
        .init(id: "MySQL", label: "MySQL", executables: ["mysql", "mysqldump"], simpleIcon: "mysql"),
        .init(id: "Redis", label: "Redis", executables: ["redis-cli"], simpleIcon: "redis"),
        .init(id: "MongoDB", label: "MongoDB", executables: ["mongosh", "mongo"], simpleIcon: "mongodb"),
        .init(id: "SQLite", label: "SQLite", executables: ["sqlite3"], simpleIcon: "sqlite"),
        .init(id: "Jest", label: "Jest", executables: ["jest"], simpleIcon: "jest"),
        .init(id: "Vitest", label: "Vitest", executables: ["vitest"], simpleIcon: "vitest"),
        .init(id: "Playwright", label: "Playwright", executables: ["playwright"], simpleIcon: "playwright"),
        .init(id: "ESLint", label: "ESLint", executables: ["eslint"], simpleIcon: "eslint"),
        .init(id: "Prettier", label: "Prettier", executables: ["prettier"], simpleIcon: "prettier"),
        .init(id: "TypeScript", label: "TypeScript", executables: ["tsc"], simpleIcon: "typescript"),
        .init(id: "Vercel", label: "Vercel", executables: ["vercel"], simpleIcon: "vercel"),
        .init(id: "Firebase", label: "Firebase", executables: ["firebase"], simpleIcon: "firebase"),
        .init(id: "Sentry", label: "Sentry", executables: ["sentry-cli"], mcpAliases: ["sentry"], simpleIcon: "sentry"),
        .init(id: "Stripe", label: "Stripe", executables: ["stripe"], simpleIcon: "stripe"),
        .init(id: "Supabase", label: "Supabase", executables: ["supabase"], mcpAliases: ["supabase"], simpleIcon: "supabase"),
        .init(id: "Build", label: "Build tool", executables: ["make", "cmake", "ninja", "gradle", "mvn", "bazel"], symbol: "hammer"),
        .init(id: "Search", label: "Search", executables: ["rg", "grep", "ag", "ack", "fd", "find"], symbol: "magnifyingglass"),
        .init(id: "Network", label: "Network tool", executables: ["curl", "wget", "ssh", "scp", "rsync"], symbol: "network"),
        .init(id: "Editors", label: "Editor", executables: ["code", "cursor", "zed", "open"], symbol: "macwindow"),
    ]
}
