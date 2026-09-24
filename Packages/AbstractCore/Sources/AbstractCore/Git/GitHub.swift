import Foundation

/// A GitHub pull request as `gh --json` reports it. Lists carry the summary
/// fields; `GitHub.pullRequest` fills in reviews, comments and the body.
public struct PullRequest: Sendable, Hashable, Identifiable {
    public enum State: String, Sendable, Hashable { case open = "OPEN", closed = "CLOSED", merged = "MERGED" }

    public enum ReviewDecision: String, Sendable, Hashable {
        case approved = "APPROVED", changesRequested = "CHANGES_REQUESTED", reviewRequired = "REVIEW_REQUIRED"
    }

    public struct Check: Sendable, Hashable, Identifiable {
        public enum Outcome: Sendable, Hashable { case pending, passed, failed, skipped }
        public var name: String
        public var workflow: String?
        public var outcome: Outcome
        public var url: URL?
        public var id: String { (workflow ?? "") + "/" + name }
    }

    public struct Review: Sendable, Hashable {
        public enum Verdict: String, Sendable, Hashable {
            case approved = "APPROVED", changesRequested = "CHANGES_REQUESTED", commented = "COMMENTED"
            case dismissed = "DISMISSED", pending = "PENDING"
        }
        public var author: String
        public var verdict: Verdict
        public var body: String
        public var submittedAt: Date?
    }

    public struct Comment: Sendable, Hashable {
        public var author: String
        public var body: String
        public var createdAt: Date?
        public var isBot: Bool
    }

    /// A conversation on a line of the diff: the first comment and its replies.
    public struct ReviewThread: Sendable, Hashable, Identifiable {
        public struct Comment: Sendable, Hashable, Identifiable {
            public var id: String
            public var author: String
            public var avatar: URL?
            public var body: String
            public var createdAt: Date?
            public var url: URL?
        }
        public var id: String
        public var path: String
        /// The line in the current diff; nil once the code it was on has changed.
        public var line: Int?
        public var originalLine: Int?
        public var isResolved: Bool
        public var isOutdated: Bool
        /// The diff lines the thread was started on, ending at its line.
        public var diffHunk: String?
        public var comments: [Comment]
    }

    public struct ChecksSummary: Sendable, Hashable {
        public var passed = 0, failed = 0, pending = 0, skipped = 0
        public var total: Int { passed + failed + pending + skipped }
    }

    public var number: Int
    public var title: String
    public var state: State
    public var isDraft: Bool
    public var url: URL?
    public var head: String
    public var base: String
    public var author: String?
    public var reviewDecision: ReviewDecision?
    /// `MERGEABLE`, `CONFLICTING` or `UNKNOWN`.
    public var mergeable: String?
    /// `CLEAN`, `BLOCKED`, `BEHIND`, `DIRTY`, `UNSTABLE`, `DRAFT`, `HAS_HOOKS`, `UNKNOWN`.
    public var mergeState: String?
    public var additions: Int?
    public var deletions: Int?
    public var changedFiles: Int?
    public var createdAt: Date?
    public var updatedAt: Date?
    public var body: String?
    public var checks: [Check]
    public var reviews: [Review]
    public var comments: [Comment]
    /// Review threads on the code; filled by `GitHub.reviewThreads`.
    public var threads: [ReviewThread] = []

    public var id: Int { number }

    public var checksSummary: ChecksSummary {
        checks.reduce(into: ChecksSummary()) { sum, check in
            switch check.outcome {
            case .passed: sum.passed += 1
            case .failed: sum.failed += 1
            case .pending: sum.pending += 1
            case .skipped: sum.skipped += 1
            }
        }
    }

    public var hasConflicts: Bool { mergeable == "CONFLICTING" }

    /// Apply a fresh list result without discarding fields only `pr view` loads.
    /// Checks can change while `updatedAt` stays the same.
    public func refreshingSummary(with summary: PullRequest) -> PullRequest {
        guard number == summary.number else { return summary }
        var updated = summary
        updated.mergeable = mergeable
        updated.mergeState = mergeState
        updated.changedFiles = changedFiles
        updated.createdAt = createdAt
        updated.body = body
        updated.reviews = reviews
        updated.comments = comments
        updated.threads = threads
        return updated
    }
}

/// Whether `gh` can talk to GitHub for this user.
public enum GitHubAccess: Sendable, Hashable {
    case ready
    /// `gh` isn't on the login shell's PATH.
    case missing
    /// Installed, but `gh auth login` hasn't been run.
    case signedOut
}

public enum MergeMethod: String, Sendable, CaseIterable {
    case squash, merge, rebase
}

/// Pull requests through the GitHub CLI, over an `Executor`.
public enum GitHub {
    static let summaryFields = "number,title,state,isDraft,url,headRefName,baseRefName,author,reviewDecision,updatedAt,statusCheckRollup,additions,deletions"
    static let detailFields = summaryFields + ",mergeable,mergeStateStatus,changedFiles,createdAt,body,reviews,comments"

    public static func access(_ exec: any Executor) async -> GitHubAccess {
        guard await exec.which("gh") != nil else { return .missing }
        let out = try? await exec.run("gh", ["auth", "status"], cwd: nil)
        return out?.ok == true ? .ready : .signedOut
    }

    /// The pull request whose head is `branch`, or nil when there is none.
    /// Run in the project's root, so `gh` finds the repository from `origin`.
    public static func pullRequest(_ exec: any Executor, repo root: String, branch: String) async throws -> PullRequest? {
        try await pullRequest(exec, repo: root, selector: branch)
    }

    /// Resolve a particular PR when several PRs have used the same branch.
    public static func pullRequest(_ exec: any Executor, repo root: String, number: Int) async throws -> PullRequest? {
        try await pullRequest(exec, repo: root, selector: String(number))
    }

    private static func pullRequest(_ exec: any Executor, repo root: String, selector: String) async throws -> PullRequest? {
        let out = try await exec.run("gh", ["pr", "view", selector, "--json", detailFields], cwd: root)
        if !out.ok {
            if out.stderr.localizedCaseInsensitiveContains("no pull requests found") { return nil }
            throw AbstractError.command(code: out.code, stderr: GitText.trimmed(out.stderr))
        }
        return try decode(Data(out.stdout.utf8))
    }

    /// Recent pull requests of the project's repository, newest first.
    public static func pullRequests(_ exec: any Executor, repo root: String, state: String = "all", limit: Int = 100) async throws -> [PullRequest] {
        let out = try await exec.run("gh", ["pr", "list", "--state", state, "--limit", String(limit), "--json", summaryFields], cwd: root)
        guard out.ok else { throw AbstractError.command(code: out.code, stderr: GitText.trimmed(out.stderr)) }
        return try decodeList(Data(out.stdout.utf8))
    }

    /// The signed-in user's login.
    public static func viewer(_ exec: any Executor) async -> String? {
        guard let out = try? await exec.run("gh", ["api", "user", "--jq", ".login"], cwd: nil), out.ok else { return nil }
        let login = GitText.trimmed(out.stdout)
        return login.isEmpty ? nil : login
    }

    /// Commits whatever the worktree holds (when `commitMessage` is given),
    /// pushes the branch, and opens a pull request for it.
    public static func create(_ exec: any Executor, repo root: String, worktree: String, branch: String, base: String?,
                              title: String, body: String, draft: Bool, commitMessage: String?) async throws -> PullRequest? {
        if let commitMessage { try await Git.commitAll(exec, worktree: worktree, message: commitMessage) }
        try await Git.push(exec, worktree: worktree, branch: branch)
        var args = ["pr", "create", "--head", branch, "--title", title, "--body", body]
        if let base, !base.isEmpty { args += ["--base", base] }
        if draft { args.append("--draft") }
        let out = try await exec.run("gh", args, cwd: root)
        guard out.ok else { throw AbstractError.command(code: out.code, stderr: GitText.trimmed(out.stderr)) }
        return try await pullRequest(exec, repo: root, branch: branch)
    }

    /// The pull request's review threads, replies in order. `gh` fills in
    /// the owner and name from the project's `origin`.
    public static func reviewThreads(_ exec: any Executor, repo root: String, number: Int) async throws -> [PullRequest.ReviewThread] {
        let query = """
        query($owner: String!, $name: String!, $number: Int!) { repository(owner: $owner, name: $name) { pullRequest(number: $number) {
          reviewThreads(first: 100) { nodes { id isResolved isOutdated path line originalLine
            comments(first: 50) { nodes { id author { login avatarUrl } body createdAt url diffHunk } } } } } } }
        """
        let out = try await exec.run("gh", ["api", "graphql", "-F", "owner={owner}", "-F", "name={repo}", "-F", "number=\(number)",
                                            "-f", "query=\(query)"], cwd: root)
        guard out.ok else { throw AbstractError.command(code: out.code, stderr: GitText.trimmed(out.stderr)) }
        return try decodeThreads(Data(out.stdout.utf8))
    }

    public static func merge(_ exec: any Executor, repo root: String, number: Int, method: MergeMethod) async throws {
        try await ghOK(exec, root, ["pr", "merge", String(number), "--\(method.rawValue)"])
    }

    public static func markReady(_ exec: any Executor, repo root: String, number: Int) async throws {
        try await ghOK(exec, root, ["pr", "ready", String(number)])
    }

    public static func close(_ exec: any Executor, repo root: String, number: Int) async throws {
        try await ghOK(exec, root, ["pr", "close", String(number)])
    }

    private static func ghOK(_ exec: any Executor, _ root: String, _ args: [String]) async throws {
        let out = try await exec.run("gh", args, cwd: root)
        guard out.ok else { throw AbstractError.command(code: out.code, stderr: GitText.trimmed(out.stderr)) }
    }

    // MARK: Decoding

    public static func decode(_ data: Data) throws -> PullRequest {
        try PullRequest(json: JSONDecoder().decode(JSONValue.self, from: data))
    }

    public static func decodeThreads(_ data: Data) throws -> [PullRequest.ReviewThread] {
        let json = try JSONDecoder().decode(JSONValue.self, from: data)
        let nodes = json["data"]?["repository"]?["pullRequest"]?["reviewThreads"]?["nodes"]?.array ?? []
        return nodes.compactMap { t in
            guard let id = t["id"]?.string, let path = t["path"]?.string else { return nil }
            let comments = (t["comments"]?["nodes"]?.array ?? []).compactMap { c -> PullRequest.ReviewThread.Comment? in
                guard let id = c["id"]?.string else { return nil }
                return .init(id: id, author: c["author"]?["login"]?.string ?? "someone",
                             avatar: c["author"]?["avatarUrl"]?.string.flatMap(URL.init(string:)), body: c["body"]?.string ?? "",
                             createdAt: c["createdAt"]?.string.flatMap { ISO8601DateFormatter().date(from: $0) },
                             url: c["url"]?.string.flatMap(URL.init(string:)))
            }
            let hunk = (t["comments"]?["nodes"]?.array?.first?["diffHunk"]?.string)
            return .init(id: id, path: path, line: t["line"]?.int, originalLine: t["originalLine"]?.int,
                         isResolved: t["isResolved"]?.bool ?? false, isOutdated: t["isOutdated"]?.bool ?? false,
                         diffHunk: hunk, comments: comments)
        }
    }

    public static func decodeList(_ data: Data) throws -> [PullRequest] {
        try (JSONDecoder().decode(JSONValue.self, from: data).array ?? []).compactMap { try? PullRequest(json: $0) }
    }
}

extension PullRequest {
    init(json: JSONValue) throws {
        guard let number = json["number"]?.int, let title = json["title"]?.string else {
            throw AbstractError.message("Unexpected pull request JSON from gh")
        }
        self.number = number
        self.title = title
        state = json["state"]?.string.flatMap(State.init(rawValue:)) ?? .open
        isDraft = json["isDraft"]?.bool ?? false
        url = json["url"]?.string.flatMap(URL.init(string:))
        head = json["headRefName"]?.string ?? ""
        base = json["baseRefName"]?.string ?? ""
        author = json["author"]?["login"]?.string
        reviewDecision = json["reviewDecision"]?.string.flatMap(ReviewDecision.init(rawValue:))
        mergeable = json["mergeable"]?.string
        mergeState = json["mergeStateStatus"]?.string
        additions = json["additions"]?.int
        deletions = json["deletions"]?.int
        changedFiles = json["changedFiles"]?.int
        createdAt = json["createdAt"]?.string.flatMap(Self.date)
        updatedAt = json["updatedAt"]?.string.flatMap(Self.date)
        body = json["body"]?.string
        checks = (json["statusCheckRollup"]?.array ?? []).compactMap(Self.check)
        reviews = (json["reviews"]?.array ?? []).compactMap { r in
            guard let verdict = r["state"]?.string.flatMap(Review.Verdict.init(rawValue:)) else { return nil }
            return Review(author: r["author"]?["login"]?.string ?? "someone", verdict: verdict, body: r["body"]?.string ?? "",
                          submittedAt: r["submittedAt"]?.string.flatMap(Self.date))
        }
        comments = (json["comments"]?.array ?? []).map { c in
            let login = c["author"]?["login"]?.string ?? "someone"
            return Comment(author: login, body: c["body"]?.string ?? "", createdAt: c["createdAt"]?.string.flatMap(Self.date),
                           // Apps and bots (Linear, Vercel, CI) post as accounts with no tie to the repo.
                           isBot: login.hasSuffix("[bot]") || c["authorAssociation"]?.string == "NONE")
        }
    }

    /// A check run (Actions) or a commit status (other CI), as one shape.
    private static func check(_ c: JSONValue) -> Check? {
        if let name = c["name"]?.string {
            let outcome: Check.Outcome = switch (c["status"]?.string, c["conclusion"]?.string) {
            case ("COMPLETED", "SUCCESS"?), ("COMPLETED", "NEUTRAL"?): .passed
            case ("COMPLETED", "SKIPPED"?), ("COMPLETED", "STALE"?): .skipped
            case ("COMPLETED", _): .failed
            default: .pending
            }
            return Check(name: name, workflow: c["workflowName"]?.string, outcome: outcome,
                         url: c["detailsUrl"]?.string.flatMap(URL.init(string:)))
        }
        if let context = c["context"]?.string {
            let outcome: Check.Outcome = switch c["state"]?.string {
            case "SUCCESS": .passed
            case "FAILURE", "ERROR": .failed
            default: .pending
            }
            return Check(name: context, workflow: nil, outcome: outcome, url: c["targetUrl"]?.string.flatMap(URL.init(string:)))
        }
        return nil
    }

    private static func date(_ text: String) -> Date? {
        ISO8601DateFormatter().date(from: text)
    }
}

/// An issue or pull request found to attach to a message.
public struct ForgeItem: Sendable, Hashable, Identifiable {
    public var number: Int
    public var title: String
    public var url: String
    /// "OPEN", "CLOSED", "MERGED".
    public var state: String
    public var body: String?
    public var isPullRequest: Bool
    public var isDraft: Bool
    public var baseRefName: String?
    public var headRefName: String?

    public var id: String { (isPullRequest ? "pr-" : "issue-") + String(number) }

    public var attachment: PromptAttachment {
        PromptAttachment(kind: isPullRequest ? .pullRequest : .githubIssue, title: title, reference: "#\(number)", url: url, body: body,
                         details: [baseRefName.map { "Base: \($0)" }, headRefName.map { "Head: \($0)" }].compactMap { $0 })
    }

    init?(json: JSONValue, isPullRequest: Bool) {
        guard let number = json["number"]?.int, let title = json["title"]?.string else { return nil }
        self.number = number
        self.title = title
        url = json["url"]?.string ?? ""
        state = json["state"]?.string ?? "OPEN"
        body = json["body"]?.string
        self.isPullRequest = isPullRequest
        isDraft = json["isDraft"]?.bool ?? false
        baseRefName = json["baseRefName"]?.string
        headRefName = json["headRefName"]?.string
    }
}

public extension GitHub {
    /// Open issues, or with a query any that match it; a number or a link
    /// finds that one issue.
    static func searchIssues(_ exec: any Executor, repo root: String, query: String, limit: Int = 30) async throws -> [ForgeItem] {
        try await search(exec, root, "issue", query: query, limit: limit)
    }

    static func searchPullRequests(_ exec: any Executor, repo root: String, query: String, limit: Int = 30) async throws -> [ForgeItem] {
        try await search(exec, root, "pr", query: query, limit: limit)
    }

    private static func search(_ exec: any Executor, _ root: String, _ kind: String, query: String, limit: Int) async throws -> [ForgeItem] {
        let isPR = kind == "pr"
        let fields = "number,title,url,state,body" + (isPR ? ",isDraft,baseRefName,headRefName" : "")
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if let one = directReference(q) {
            let out = try await exec.run("gh", [kind, "view", one, "--json", fields], cwd: root)
            guard out.ok, let json = try? JSONDecoder().decode(JSONValue.self, from: Data(out.stdout.utf8)) else { return [] }
            return ForgeItem(json: json, isPullRequest: isPR).map { [$0] } ?? []
        }
        let filter = q.isEmpty ? ["--state", "open"] : ["--state", "all", "--search", q]
        let out = try await exec.run("gh", [kind, "list", "--limit", String(limit), "--json", fields] + filter, cwd: root)
        guard out.ok else {
            if out.stderr.contains("git remote") { throw AbstractError.message("This project's repository isn't on GitHub.") }
            throw AbstractError.command(code: out.code, stderr: GitText.trimmed(out.stderr))
        }
        return decodeItems(Data(out.stdout.utf8), isPullRequest: isPR)
    }

    /// "12", "#12" or a github.com link: one item, looked up directly.
    static func directReference(_ query: String) -> String? {
        if query.wholeMatch(of: #/#?\d+/#) != nil { return query.hasPrefix("#") ? String(query.dropFirst()) : query }
        if query.hasPrefix("https://github.com/"), query.contains("/issues/") || query.contains("/pull/") { return query }
        return nil
    }

    static func decodeItems(_ data: Data, isPullRequest: Bool) -> [ForgeItem] {
        ((try? JSONDecoder().decode(JSONValue.self, from: data))?.array ?? []).compactMap { ForgeItem(json: $0, isPullRequest: isPullRequest) }
    }
}
