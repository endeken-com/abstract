import Foundation

/// A problem Revund found in a change: from `revund review --json` (schema 1),
/// or read back from the annotations of its GitHub check runs.
public struct RevundFinding: Codable, Sendable, Hashable, Identifiable {
    public enum Severity: String, Codable, Sendable, CaseIterable, Comparable {
        case blocker, warning, nitpick

        public var title: String { rawValue.capitalized }
        private var rank: Int { Self.allCases.firstIndex(of: self)! }
        public static func < (a: Severity, b: Severity) -> Bool { a.rank < b.rank }
    }

    public struct SnippetLine: Codable, Sendable, Hashable {
        public var number: Int
        public var text: String
        public var hit: Bool?
    }

    public var id: String
    public var fingerprint: String?
    /// The review pass that found it: security, performance, architecture, style, conventions.
    public var pass: String
    public var severity: Severity
    public var file: String
    /// In the file as it is now.
    public var line: Int?
    public var body: String
    public var why: String?
    public var confidence: Double?
    /// Code to replace the line with, when Revund has one.
    public var suggest: String?
    public var snippet: [SnippetLine]?

    public init(id: String, fingerprint: String? = nil, pass: String, severity: Severity, file: String, line: Int?, body: String,
                why: String? = nil, confidence: Double? = nil, suggest: String? = nil, snippet: [SnippetLine]? = nil) {
        self.id = id; self.fingerprint = fingerprint; self.pass = pass; self.severity = severity; self.file = file
        self.line = line; self.body = body; self.why = why; self.confidence = confidence; self.suggest = suggest
        self.snippet = snippet
    }

    private enum CodingKeys: String, CodingKey { case id, fingerprint, pass, severity, file, line, body, why, confidence, suggest, snippet }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fingerprint = try c.decodeIfPresent(String.self, forKey: .fingerprint)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? fingerprint ?? UUID().uuidString
        pass = try c.decodeIfPresent(String.self, forKey: .pass) ?? "review"
        severity = (try? c.decodeIfPresent(String.self, forKey: .severity)).flatMap { $0.flatMap(Severity.init(rawValue:)) } ?? .warning
        file = try c.decodeIfPresent(String.self, forKey: .file) ?? ""
        line = try c.decodeIfPresent(Int.self, forKey: .line)
        body = try c.decodeIfPresent(String.self, forKey: .body) ?? ""
        why = try c.decodeIfPresent(String.self, forKey: .why).flatMap { $0.isEmpty ? nil : $0 }
        confidence = try c.decodeIfPresent(Double.self, forKey: .confidence)
        suggest = try c.decodeIfPresent(String.self, forKey: .suggest).flatMap { $0.isEmpty ? nil : $0 }
        snippet = try c.decodeIfPresent([SnippetLine].self, forKey: .snippet)
    }

    /// "src/auth/token.ts:14".
    public var location: String { line.map { "\(file):\($0)" } ?? file }
}

public struct RevundReport: Sendable, Hashable {
    /// Worst first, then by file and line.
    public var findings: [RevundFinding]
    public var durationMs: Int?

    public init(findings: [RevundFinding], durationMs: Int? = nil) {
        self.findings = findings.sorted { ($0.severity, $0.file, $0.line ?? 0) < ($1.severity, $1.file, $1.line ?? 0) }
        self.durationMs = durationMs
    }

    public func count(_ severity: RevundFinding.Severity) -> Int { findings.count { $0.severity == severity } }

    /// "1 blocker · 2 warnings", or "No findings".
    public var summary: String { Revund.summary(findings) }
}

/// A Revund check run on a pull request: one per review pass.
public struct RevundCheck: Sendable, Hashable, Identifiable {
    public var name: String
    /// "success", "failure", "neutral"; nil while it runs.
    public var conclusion: String?
    /// "N findings · B blocker · W warning · N nitpick", or why it was skipped.
    public var title: String?
    public var url: URL?
    public var id: String { name }
    /// "security" for "revund/security".
    public var pass: String { name.hasPrefix("revund/") ? String(name.dropFirst(7)) : name }
    public var isRunning: Bool { conclusion == nil }
}

/// What Revund said about a pull request on GitHub.
public struct RevundPullRequestReview: Sendable, Hashable {
    public var checks: [RevundCheck]
    public var report: RevundReport
}

/// Who the Revund CLI is signed in as, from `~/.revund/credentials` (written
/// by `revund login`). The token itself is never read.
public struct RevundAccount: Sendable, Hashable {
    public var email: String?
    public var org: String?
    public var expiresAt: Date?

    public static func read(home: String) -> RevundAccount? {
        guard let data = FileManager.default.contents(atPath: home + "/.revund/credentials"),
              let json = try? JSONDecoder().decode(JSONValue.self, from: data), json["access_token"]?.string != nil else { return nil }
        return RevundAccount(email: json["email"]?.string, org: json["org_slug"]?.string,
                             expiresAt: json["expires_at"]?.string.flatMap { ISO8601DateFormatter().date(from: $0) })
    }
}

/// Revund, the AI code review, through its CLI and its GitHub check runs.
public enum Revund {
    public static let binary = "revund"
    public static let install = "brew install revund-dev/tap/revund"
    /// What `REVUND_API_KEY` holds: `revund_` then a prefix and a secret.
    public static let keyPrefix = "revund_"

    /// What a local review compares.
    public enum Scope: Sendable, Hashable {
        /// What isn't committed yet.
        case uncommitted
        /// Everything since this commit (the branch's merge base), uncommitted work included.
        case since(String)
    }

    public static func reviewArgs(repo: String, scope: Scope) -> [String] {
        let base = switch scope {
        case .uncommitted: "HEAD"
        case .since(let sha): sha
        }
        return ["review", "--json", "--no-tui", "--no-color", "--repo", repo, "--base", base]
    }

    public static func decode(_ data: Data) throws -> RevundReport {
        struct Document: Decodable {
            var findings: [RevundFinding]?
            var duration_ms: Int?
        }
        let doc = try JSONDecoder().decode(Document.self, from: data)
        return RevundReport(findings: doc.findings ?? [], durationMs: doc.duration_ms)
    }

    /// The JSON document in the CLI's output, whatever came before it.
    public static func decode(stdout: String) throws -> RevundReport {
        guard let start = stdout.firstIndex(of: "{") else { throw AbstractError.message("Revund printed no review.") }
        return try decode(Data(stdout[start...].utf8))
    }

    /// Revund says there was nothing to look at, and exits 1 for it.
    public static func isNothingToReview(_ stderr: String) -> Bool {
        stderr.localizedCaseInsensitiveContains("nothing to review") || stderr.localizedCaseInsensitiveContains("no changes")
    }

    /// A progress line from stderr ("✓ security · 3 findings · 12s"), or nil for noise.
    public static func progress(_ line: String) -> String? {
        let text = line.trimmingCharacters(in: .whitespaces)
        guard let first = text.unicodeScalars.first, "→✓·✗─".unicodeScalars.contains(first) else { return nil }
        let rest = text.drop { "→✓·✗─ ".contains($0) }
        return rest.isEmpty ? nil : String(rest)
    }

    public static func summary(_ findings: [RevundFinding]) -> String {
        guard !findings.isEmpty else { return "No findings" }
        return RevundFinding.Severity.allCases.compactMap { s in
            let n = findings.count { $0.severity == s }
            return n == 0 ? nil : "\(n) \(s.rawValue)\(n == 1 ? "" : "s")"
        }.joined(separator: " · ")
    }

    /// The findings as the agent reads them: each one's place, what's wrong,
    /// why, the lines it's on, and Revund's fix when it has one.
    public static func agentText(_ findings: [RevundFinding]) -> String {
        findings.enumerated().map { i, f in
            var lines = ["\(i + 1). [\(f.severity.rawValue)] \(f.pass) · \(f.location)", f.body]
            if let why = f.why { lines.append("Why: \(why)") }
            for s in f.snippet ?? [] { lines.append((s.hit == true ? "> " : "  ") + String(s.number) + " " + s.text) }
            if let suggest = f.suggest { lines += ["Suggested fix:", "```", suggest, "```"] }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    /// The findings as one attachment to a message.
    public static func attachment(_ findings: [RevundFinding], scope: String) -> PromptAttachment {
        PromptAttachment(kind: .revundReview, title: summary(findings), reference: "Revund", body: agentText(findings),
                         details: ["Reviewed: \(scope)"])
    }

    // MARK: GitHub

    public static func isCheck(_ name: String) -> Bool { name.lowercased().hasPrefix("revund/") }

    /// A check-run annotation: title "[blocker] security", the finding as its
    /// message, and "why" then "Suggested fix:" in its details.
    static func finding(annotation a: JSONValue) -> RevundFinding? {
        guard let path = a["path"]?.string, let message = a["message"]?.string else { return nil }
        let title = a["title"]?.string ?? ""
        var severity: RevundFinding.Severity = switch a["annotation_level"]?.string {
        case "failure": .blocker
        case "notice": .nitpick
        default: .warning
        }
        var pass = "review"
        if let m = title.firstMatch(of: #/^\[(\w+)\]\s*(.*)$/#) {
            severity = RevundFinding.Severity(rawValue: String(m.output.1).lowercased()) ?? severity
            if !m.output.2.isEmpty { pass = String(m.output.2) }
        }
        var why = a["raw_details"]?.string
        var suggest: String?
        if let details = why, let range = details.range(of: "Suggested fix:\n") {
            suggest = String(details[range.upperBound...]).trimmingCharacters(in: .newlines)
            why = String(details[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let line = a["start_line"]?.int
        return RevundFinding(id: "\(path):\(line ?? 0):\(pass):\(message.prefix(40))", pass: pass, severity: severity, file: path,
                             line: line, body: message, why: why?.isEmpty == true ? nil : why,
                             suggest: suggest?.isEmpty == true ? nil : suggest)
    }

    static func checks(_ json: JSONValue) -> [(RevundCheck, id: Int, annotations: Int)] {
        (json["check_runs"]?.array ?? []).compactMap { run in
            guard let name = run["name"]?.string, isCheck(name), let id = run["id"]?.int else { return nil }
            let check = RevundCheck(name: name, conclusion: run["conclusion"]?.string, title: run["output"]?["title"]?.string,
                                    url: (run["html_url"]?.string).flatMap(URL.init(string:)))
            return (check, id, run["output"]?["annotations_count"]?.int ?? 0)
        }
    }

    /// Revund's check runs on the pull request's head and the findings they
    /// annotate. nil when Revund didn't review it (not installed on the repo).
    public static func pullRequestReview(_ exec: any Executor, repo root: String, number: Int) async throws -> RevundPullRequestReview? {
        let head = try await exec.run("gh", ["pr", "view", String(number), "--json", "headRefOid", "--jq", ".headRefOid"], cwd: root)
        guard head.ok else { throw AbstractError.command(code: head.code, stderr: GitText.trimmed(head.stderr)) }
        let sha = GitText.trimmed(head.stdout)
        let runs = try await exec.run("gh", ["api", "repos/{owner}/{repo}/commits/\(sha)/check-runs?per_page=100"], cwd: root)
        guard runs.ok, let json = try? JSONDecoder().decode(JSONValue.self, from: Data(runs.stdout.utf8)) else {
            throw AbstractError.command(code: runs.code, stderr: GitText.trimmed(runs.stderr))
        }
        let found = checks(json)
        guard !found.isEmpty else { return nil }
        var findings: [RevundFinding] = []
        for (_, id, count) in found where count > 0 {
            let out = try await exec.run("gh", ["api", "repos/{owner}/{repo}/check-runs/\(id)/annotations?per_page=100"], cwd: root)
            guard out.ok, let list = try? JSONDecoder().decode(JSONValue.self, from: Data(out.stdout.utf8)) else { continue }
            findings += (list.array ?? []).compactMap(finding(annotation:))
        }
        return RevundPullRequestReview(checks: found.map(\.0).sorted { $0.name < $1.name }, report: RevundReport(findings: findings))
    }
}
