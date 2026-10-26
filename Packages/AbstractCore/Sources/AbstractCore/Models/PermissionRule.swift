import Foundation

/// What a remembered permission answer matches against.
public enum PermissionRuleKind: String, Sendable, Codable, CaseIterable {
    case command
    case path
    case tool

    public var title: String {
        switch self {
        case .command: "Command"
        case .path: "Path"
        case .tool: "Tool"
        }
    }
}

public enum PermissionDecision: String, Sendable, Codable, CaseIterable {
    case allow
    case deny

    public var title: String { self == .allow ? "Always allow" : "Always deny" }
}

/// One remembered permission answer for a project: requests matching
/// `pattern` are answered for you in every chat of the project, until the
/// rule is deleted or expires. A deny rule beats an allow rule.
public struct PermissionRule: Sendable, Hashable, Identifiable, Codable {
    public var id: String
    public var projectId: String
    public var kind: PermissionRuleKind
    /// A glob: `*` is any run of characters (`**` crosses `/` in a path),
    /// `?` is one character. No wildcards means the whole text must match.
    public var pattern: String
    public var decision: PermissionDecision
    /// When the rule stops applying; nil = it doesn't expire.
    public var expiresAt: Date?
    public var createdAt: Date

    public init(id: String = UUID().uuidString, projectId: String, kind: PermissionRuleKind, pattern: String,
                decision: PermissionDecision, expiresAt: Date? = nil, createdAt: Date = Date()) {
        self.id = id; self.projectId = projectId; self.kind = kind; self.pattern = pattern
        self.decision = decision; self.expiresAt = expiresAt; self.createdAt = createdAt
    }

    public func isExpired(at now: Date = Date()) -> Bool {
        expiresAt.map { $0 <= now } ?? false
    }

    /// The small note a tool row carries when this rule answered for you.
    public var note: String {
        "\(decision == .allow ? "Allowed" : "Denied") by rule `\(pattern)`"
    }

    /// Whether this rule answers the request. `root` is the chat's worktree
    /// (or the project's root): a path pattern is tried against the path
    /// relative to it, and against the full path.
    public func matches(toolName: String, input: JSONValue, root: String? = nil, at now: Date = Date()) -> Bool {
        guard !isExpired(at: now), !pattern.isEmpty else { return false }
        switch kind {
        case .command:
            return Self.commands(in: input).contains { Self.glob(pattern, matches: $0, pathSeparators: false) }
        case .path:
            return Self.paths(in: input, root: root).contains { Self.glob(pattern, matches: $0, pathSeparators: true) }
        case .tool:
            return Self.glob(pattern, matches: toolName, pathSeparators: false)
        }
    }

    /// The rule that answers a request, if any: the first matching deny,
    /// else the first matching allow, in the order given.
    public static func answer(_ rules: [PermissionRule], toolName: String, input: JSONValue,
                              root: String? = nil, at now: Date = Date()) -> PermissionRule? {
        let matching = rules.filter { $0.matches(toolName: toolName, input: input, root: root, at: now) }
        return matching.first { $0.decision == .deny } ?? matching.first
    }

    /// The rule to pre-fill the "Always allow in this project…" sheet with,
    /// from the request being asked about.
    public static func suggested(toolName: String, input: JSONValue, root: String? = nil) -> (kind: PermissionRuleKind, pattern: String) {
        if let command = commands(in: input).last, !command.isEmpty { return (.command, command) }
        if let path = paths(in: input, root: root).first, !path.isEmpty {
            // A file under a folder suggests the folder: `src/a/b.swift` → `src/**`.
            if let slash = path.firstIndex(of: "/"), slash != path.startIndex {
                return (.path, String(path[..<slash]) + "/**")
            }
            return (.path, path)
        }
        return (.tool, toolName)
    }

    // MARK: - What a request carries

    /// The command a request wants to run, as typed and unwrapped from a
    /// `zsh -lc "…"` shell wrapper, newest form last.
    static func commands(in input: JSONValue) -> [String] {
        guard let raw = input["command"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return [] }
        let unwrapped = unwrapShell(raw)
        return unwrapped == raw ? [raw] : [raw, unwrapped]
    }

    /// The paths a request touches: relative to `root` first when under it,
    /// then as given.
    static func paths(in input: JSONValue, root: String?) -> [String] {
        var out: [String] = []
        for key in ["file_path", "filePath", "notebook_path", "path"] {
            guard let path = input[key]?.string, !path.isEmpty else { continue }
            if let root, !root.isEmpty {
                let base = root.hasSuffix("/") ? root : root + "/"
                if path.hasPrefix(base) { out.append(String(path.dropFirst(base.count))) }
            }
            out.append(path)
            if path.hasPrefix("./") { out.append(String(path.dropFirst(2))) }
        }
        return out
    }

    static func unwrapShell(_ raw: String) -> String {
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

    // MARK: - Glob

    /// Glob match of the whole text. In a path, `*` and `?` stop at `/`
    /// and `**` crosses it; elsewhere every `*` is any run of characters.
    static func glob(_ pattern: String, matches text: String, pathSeparators: Bool) -> Bool {
        let p = Array(pattern), t = Array(text)
        // dp[i][j]: pattern prefix i matches text prefix j.
        var dp = [[Bool]](repeating: [Bool](repeating: false, count: t.count + 1), count: p.count + 1)
        dp[0][0] = true
        for i in 0..<p.count where p[i] == "*" { dp[i + 1][0] = dp[i][0] }  // a run of stars matches empty
        for i in 0..<p.count {
            let doubleStar = pathSeparators && p[i] == "*" && i + 1 < p.count && p[i + 1] == "*"
            for j in 0..<t.count {
                switch p[i] {
                case "*":
                    // Matches empty, or one more character (`/` only for `**` in a path).
                    let crosses = !pathSeparators || doubleStar || t[j] != "/"
                    dp[i + 1][j + 1] = dp[i][j + 1] || (crosses && dp[i + 1][j])
                case "?":
                    dp[i + 1][j + 1] = dp[i][j] && (!pathSeparators || t[j] != "/")
                default:
                    dp[i + 1][j + 1] = dp[i][j] && p[i] == t[j]
                }
            }
        }
        return dp[p.count][t.count]
    }
}
