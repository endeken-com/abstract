import Foundation

// Where a project's pull requests live (ABS-139). Core keeps every screen
// (sidebar marks, the Pull Request tab, the Pull Requests screen, Create /
// View PR, attachments, automations, history) and asks the project's code
// host for what it shows. A code host is a plugin that declares
// `contributes.codeHost` and answers these operations from its background
// script, in the JSON shapes below. Plain git (commit, push, fetch) stays
// in core.

/// One thing core asks a code host.
public enum CodeHostOperation: String, Sendable, Hashable, Codable, CaseIterable {
    case access
    case listPullRequests
    case pullRequest
    case create
    case merge
    case markReady
    case close
    case reviewThreads
    case rerunFailed
    case updateBranch
    case pushAccess
    case searchIssuesAndPullRequests

    /// Every code host answers these; the rest it lists when it can.
    public static let required: Set<CodeHostOperation> = [.access, .listPullRequests, .pullRequest]

    /// Operations that change something. Core only asks for one when the
    /// person clicked for it, so the commands it runs don't ask again.
    public var isWrite: Bool {
        switch self {
        case .create, .merge, .markReady, .close, .rerunFailed, .updateBranch: true
        default: false
        }
    }

    /// How long the plugin may take to answer.
    public var timeout: Duration { isWrite ? .seconds(150) : .seconds(45) }
}

/// A plugin's `contributes.codeHost`: the remotes it handles and what it
/// answers.
public struct CodeHostDeclaration: Sendable, Hashable, Codable {
    /// The host's name in the UI: "GitHub".
    public var title: String
    /// Exact hosts whose remotes it handles, like `github.com`. Its script
    /// may add the Enterprise hosts its tool is signed in to while it runs.
    public var hosts: [String]
    public var operations: [CodeHostOperation]

    public init(title: String, hosts: [String], operations: [CodeHostOperation]) {
        self.title = title; self.hosts = hosts; self.operations = operations
    }

    public static let hostLimit = 16

    public var answers: Set<CodeHostOperation> { Set(operations) }

    func validate() throws {
        func refuse(_ why: String) -> PluginValidationError { .invalidManifest("codeHost: \(why)") }
        guard PluginManifest.isSound(id: "codeHost", title: title) else { throw refuse("needs a title of at most 40 characters") }
        let lowered = hosts.map { $0.lowercased() }
        guard !hosts.isEmpty, hosts.count <= Self.hostLimit, Set(lowered).count == lowered.count,
              lowered.allSatisfy(PluginManifest.isExactHost) else {
            throw refuse("hosts are up to \(Self.hostLimit) exact hosts like github.com")
        }
        guard Set(operations).count == operations.count, CodeHostOperation.required.isSubset(of: Set(operations)) else {
            throw refuse("operations must include access, listPullRequests and pullRequest, once each")
        }
    }
}

/// Whether the code host can talk to its service for this person.
public enum CodeHostAccess: Sendable, Hashable {
    /// Signed in, as `viewer` when it says.
    case ready(viewer: String?)
    /// Its tool isn't installed; `install` says how.
    case missing(install: String?)
    /// Installed, not signed in; `hint` says how, like `gh auth login`.
    case signedOut(hint: String?)

    public var isReady: Bool { if case .ready = self { true } else { false } }
}

/// Why a code host couldn't answer, in a plain sentence.
public enum CodeHostError: Error, Sendable, Equatable, LocalizedError {
    /// No usable plugin handles this remote's host.
    case noHost(String?)
    /// The code host doesn't answer this operation.
    case unsupported(host: String, CodeHostOperation)
    /// Its plugin isn't running, or didn't answer in time.
    case unavailable(String)
    /// It answered with an error.
    case failed(String)
    /// It answered with something that isn't the contract's shape.
    case malformed(CodeHostOperation)

    public var errorDescription: String? {
        switch self {
        case .noHost(let host): CodeHosts.needsPlugin(host)
        case .unsupported(let host, _): "\(host) can't do that yet."
        case .unavailable(let why), .failed(let why): why
        case .malformed(let op): "The code host's answer to \(op.rawValue) couldn't be read."
        }
    }
}

/// Picks the code host for a remote.
public enum CodeHosts {
    /// One usable plugin's code host, with the hosts it handles now.
    public struct Candidate: Sendable, Hashable {
        public var pluginId: String
        public var declaration: CodeHostDeclaration
        /// Hosts its script added while running (Enterprise).
        public var extraHosts: Set<String>

        public init(pluginId: String, declaration: CodeHostDeclaration, extraHosts: Set<String> = []) {
            self.pluginId = pluginId; self.declaration = declaration; self.extraHosts = extraHosts
        }

        public var hosts: Set<String> { Set(declaration.hosts.map { $0.lowercased() }).union(extraHosts) }
    }

    /// The first candidate, in plugin id order, that handles the remote's
    /// host; nil when none does or the remote names no host.
    public static func match(remote: String?, among candidates: [Candidate]) -> Candidate? {
        guard let remote, let host = GitRemote.host(remote) else { return nil }
        return candidates.sorted { $0.pluginId < $1.pluginId }.first { $0.hosts.contains(host) }
    }

    /// What PR screens say when nothing handles a project's remote.
    public static func needsPlugin(_ host: String?) -> String {
        "Install a plugin for \(host ?? "this project's code host") to see pull requests."
    }

    /// The most extra hosts one script may add.
    public static let extraHostLimit = 16
}

/// Where a call is about: the project (and chat) whose folder its plugin's
/// commands run in, and the remote it is for.
public struct CodeHostContext: Sendable, Hashable {
    public var projectKey: String?
    public var chatId: String?
    public var remote: String?

    public init(projectKey: String? = nil, chatId: String? = nil, remote: String? = nil) {
        self.projectKey = projectKey; self.chatId = chatId; self.remote = remote
    }

    public func jsonValue() -> JSONValue {
        .object(["projectKey": projectKey.map(JSONValue.string) ?? .null, "chatId": chatId.map(JSONValue.string) ?? .null,
                 "remote": remote.map(JSONValue.string) ?? .null])
    }
}

/// What core calls: one project's code host, typed. Every operation is
/// one request to the plugin and one JSON answer.
public struct CodeHost: Sendable {
    public typealias Call = @Sendable (CodeHostOperation, JSONValue) async throws -> JSONValue

    public var pluginId: String
    public var declaration: CodeHostDeclaration
    private let call: Call

    /// `call` sends one operation with its input to the plugin and returns
    /// its `result`, or throws a `CodeHostError`.
    public init(pluginId: String, declaration: CodeHostDeclaration, call: @escaping Call) {
        self.pluginId = pluginId; self.declaration = declaration; self.call = call
    }

    public var title: String { declaration.title }

    private func ask(_ op: CodeHostOperation, _ input: [String: JSONValue] = [:]) async throws -> JSONValue {
        guard declaration.answers.contains(op) else { throw CodeHostError.unsupported(host: title, op) }
        return try await call(op, .object(input))
    }

    public func answers(_ op: CodeHostOperation) -> Bool { declaration.answers.contains(op) }

    // MARK: Operations

    public func access() async -> CodeHostAccess {
        guard let out = try? await ask(.access) else { return .missing(install: nil) }
        return switch out["access"]?.string {
        case "ready": .ready(viewer: out["viewer"]?.string)
        case "signedOut": .signedOut(hint: out["hint"]?.string)
        default: .missing(install: out["install"]?.string)
        }
    }

    /// Recent pull requests, newest first; `state` is `all` or `open`.
    public func pullRequests(state: String = "all", limit: Int = 100) async throws -> [PullRequest] {
        let out = try await ask(.listPullRequests, ["state": .string(state), "limit": .number(Double(limit))])
        guard let list = out["pullRequests"]?.array else { throw CodeHostError.malformed(.listPullRequests) }
        return list.compactMap(PullRequest.init(contract:))
    }

    /// The pull request whose head is `branch`; nil when there is none.
    public func pullRequest(branch: String) async throws -> PullRequest? {
        try await single(.pullRequest, ["branch": .string(branch)])
    }

    public func pullRequest(number: Int) async throws -> PullRequest? {
        try await single(.pullRequest, ["number": .number(Double(number))])
    }

    /// Opens a pull request for a branch core has already pushed.
    public func create(branch: String, base: String?, title: String, body: String, draft: Bool) async throws -> PullRequest? {
        var input: [String: JSONValue] = ["branch": .string(branch), "title": .string(title), "body": .string(body),
                                          "draft": .bool(draft)]
        if let base, !base.isEmpty { input["base"] = .string(base) }
        return try await single(.create, input)
    }

    public func merge(number: Int, method: MergeMethod, deleteBranch: Bool = false) async throws {
        _ = try await ask(.merge, ["number": .number(Double(number)), "method": .string(method.rawValue),
                                   "deleteBranch": .bool(deleteBranch)])
    }

    public func markReady(number: Int) async throws { _ = try await ask(.markReady, ["number": .number(Double(number))]) }
    public func close(number: Int) async throws { _ = try await ask(.close, ["number": .number(Double(number))]) }
    public func rerunFailed(number: Int) async throws { _ = try await ask(.rerunFailed, ["number": .number(Double(number))]) }
    public func updateBranch(number: Int) async throws { _ = try await ask(.updateBranch, ["number": .number(Double(number))]) }

    public func reviewThreads(number: Int) async throws -> [PullRequest.ReviewThread] {
        let out = try await ask(.reviewThreads, ["number": .number(Double(number))])
        guard let list = out["threads"]?.array else { throw CodeHostError.malformed(.reviewThreads) }
        return list.compactMap(PullRequest.ReviewThread.init(contract:))
    }

    /// Whether the person can push to `slug` (`owner/name`); `.unknown`
    /// when the host can't say.
    public func pushAccess(slug: String) async -> RepoAccess {
        guard let out = try? await ask(.pushAccess, ["slug": .string(slug)]) else { return .unknown }
        return RepoAccess(rawValue: out["access"]?.string ?? "") ?? .unknown
    }

    /// Issues, or pull requests, matching `query`; empty finds the open ones.
    public func search(_ query: String, pullRequests: Bool, limit: Int = 30) async throws -> [ForgeItem] {
        let out = try await ask(.searchIssuesAndPullRequests, [
            "query": .string(query), "kind": .string(pullRequests ? "pullRequest" : "issue"), "limit": .number(Double(limit)),
        ])
        guard let list = out["items"]?.array else { throw CodeHostError.malformed(.searchIssuesAndPullRequests) }
        return list.compactMap(ForgeItem.init(contract:))
    }

    private func single(_ op: CodeHostOperation, _ input: [String: JSONValue]) async throws -> PullRequest? {
        let out = try await ask(op, input)
        guard let value = out["pullRequest"] else { throw CodeHostError.malformed(op) }
        if value == .null { return nil }
        guard let pr = PullRequest(contract: value) else { throw CodeHostError.malformed(op) }
        return pr
    }
}

// MARK: The contract's JSON shapes

private func iso(_ date: Date?) -> JSONValue {
    date.map { .string(ISO8601DateFormatter().string(from: $0)) } ?? .null
}

private func date(_ value: JSONValue?) -> Date? {
    value?.string.flatMap { ISO8601DateFormatter().date(from: $0) }
}

private func string(_ value: String?) -> JSONValue { value.map(JSONValue.string) ?? .null }
private func optionalNumber(_ value: Int?) -> JSONValue { value.map { .number(Double($0)) } ?? .null }
private func link(_ value: URL?) -> JSONValue { value.map { .string($0.absoluteString) } ?? .null }

extension PullRequest.Check.Outcome {
    static let words: [Self: String] = [.pending: "pending", .passed: "passed", .failed: "failed", .skipped: "skipped"]
}

extension PullRequest.Review.Verdict {
    static let words: [Self: String] = [.approved: "approved", .changesRequested: "changesRequested", .commented: "commented",
                                        .dismissed: "dismissed", .pending: "pending"]
}

extension PullRequest.ReviewDecision {
    static let words: [Self: String] = [.approved: "approved", .changesRequested: "changesRequested",
                                        .reviewRequired: "reviewRequired"]
}

private func word<T: Hashable>(_ words: [T: String], _ text: String?) -> T? {
    words.first { $0.value == text }?.key
}

public extension PullRequest {
    /// A pull request as a code host answers it: Abstract's own field
    /// names, states as words (`open`, `closed`, `merged`), dates ISO 8601.
    func contractJSON() -> JSONValue {
        .object([
            "number": .number(Double(number)), "title": .string(title), "state": .string(state.rawValue.lowercased()),
            "isDraft": .bool(isDraft), "url": link(url), "head": .string(head), "base": .string(base),
            "author": string(author), "reviewDecision": string(reviewDecision.flatMap { ReviewDecision.words[$0] }),
            "mergeable": string(mergeable), "mergeState": string(mergeState),
            "additions": optionalNumber(additions), "deletions": optionalNumber(deletions), "changedFiles": optionalNumber(changedFiles),
            "createdAt": iso(createdAt), "updatedAt": iso(updatedAt), "body": string(body), "mergeCommit": string(mergeCommit),
            "checks": .array(checks.map { check in
                .object(["name": .string(check.name), "workflow": string(check.workflow),
                         "outcome": .string(Check.Outcome.words[check.outcome] ?? "pending"), "url": link(check.url)])
            }),
            "reviews": .array(reviews.map { review in
                .object(["author": .string(review.author), "verdict": .string(Review.Verdict.words[review.verdict] ?? "commented"),
                         "body": .string(review.body), "submittedAt": iso(review.submittedAt), "association": string(review.association)])
            }),
            "comments": .array(comments.map { comment in
                .object(["author": .string(comment.author), "body": .string(comment.body), "createdAt": iso(comment.createdAt),
                         "isBot": .bool(comment.isBot), "association": string(comment.association)])
            }),
            "threads": .array(threads.map { $0.contractJSON() }),
        ])
    }

    /// Nil unless it has a number and a title.
    init?(contract json: JSONValue) {
        guard let number = json["number"]?.int, let title = json["title"]?.string else { return nil }
        self.init(number: number, title: title,
                  state: State(rawValue: (json["state"]?.string ?? "open").uppercased()) ?? .open,
                  isDraft: json["isDraft"]?.bool ?? false, url: json["url"]?.string.flatMap(URL.init(string:)),
                  head: json["head"]?.string ?? "", base: json["base"]?.string ?? "", author: json["author"]?.string,
                  reviewDecision: word(ReviewDecision.words, json["reviewDecision"]?.string),
                  mergeable: json["mergeable"]?.string, mergeState: json["mergeState"]?.string,
                  additions: json["additions"]?.int, deletions: json["deletions"]?.int, changedFiles: json["changedFiles"]?.int,
                  createdAt: date(json["createdAt"]), updatedAt: date(json["updatedAt"]), body: json["body"]?.string,
                  mergeCommit: json["mergeCommit"]?.string,
                  checks: (json["checks"]?.array ?? []).compactMap { c in
                      guard let name = c["name"]?.string else { return nil }
                      return Check(name: name, workflow: c["workflow"]?.string,
                                   outcome: word(Check.Outcome.words, c["outcome"]?.string) ?? .pending,
                                   url: c["url"]?.string.flatMap(URL.init(string:)))
                  },
                  reviews: (json["reviews"]?.array ?? []).compactMap { r in
                      guard let verdict = word(Review.Verdict.words, r["verdict"]?.string) else { return nil }
                      return Review(author: r["author"]?.string ?? "someone", verdict: verdict, body: r["body"]?.string ?? "",
                                    submittedAt: date(r["submittedAt"]), association: r["association"]?.string)
                  },
                  comments: (json["comments"]?.array ?? []).map { c in
                      Comment(author: c["author"]?.string ?? "someone", body: c["body"]?.string ?? "",
                              createdAt: date(c["createdAt"]), isBot: c["isBot"]?.bool ?? false,
                              association: c["association"]?.string)
                  },
                  threads: (json["threads"]?.array ?? []).compactMap(ReviewThread.init(contract:)))
    }
}

public extension PullRequest.ReviewThread {
    func contractJSON() -> JSONValue {
        .object([
            "id": .string(id), "path": .string(path), "line": optionalNumber(line), "originalLine": optionalNumber(originalLine),
            "isResolved": .bool(isResolved), "isOutdated": .bool(isOutdated), "diffHunk": string(diffHunk),
            "commit": string(commit),
            "comments": .array(comments.map { c in
                .object(["id": .string(c.id), "author": .string(c.author), "avatar": link(c.avatar), "body": .string(c.body),
                         "createdAt": iso(c.createdAt), "url": link(c.url), "association": string(c.association)])
            }),
        ])
    }

    init?(contract json: JSONValue) {
        guard let id = json["id"]?.string, let path = json["path"]?.string else { return nil }
        self.init(id: id, path: path, line: json["line"]?.int, originalLine: json["originalLine"]?.int,
                  isResolved: json["isResolved"]?.bool ?? false, isOutdated: json["isOutdated"]?.bool ?? false,
                  diffHunk: json["diffHunk"]?.string,
                  comments: (json["comments"]?.array ?? []).compactMap { c in
                      guard let id = c["id"]?.string else { return nil }
                      return Comment(id: id, author: c["author"]?.string ?? "someone",
                                     avatar: c["avatar"]?.string.flatMap(URL.init(string:)), body: c["body"]?.string ?? "",
                                     createdAt: date(c["createdAt"]), url: c["url"]?.string.flatMap(URL.init(string:)),
                                     association: c["association"]?.string)
                  },
                  commit: json["commit"]?.string)
    }
}

public extension ForgeItem {
    func contractJSON() -> JSONValue {
        .object(["number": .number(Double(number)), "title": .string(title), "url": .string(url), "state": .string(state),
                 "body": string(body), "isPullRequest": .bool(isPullRequest), "isDraft": .bool(isDraft),
                 "base": string(baseRefName), "head": string(headRefName)])
    }

    init?(contract json: JSONValue) {
        guard let number = json["number"]?.int, let title = json["title"]?.string else { return nil }
        self.init(number: number, title: title, url: json["url"]?.string ?? "",
                  state: (json["state"]?.string ?? "OPEN").uppercased(), body: json["body"]?.string,
                  isPullRequest: json["isPullRequest"]?.bool ?? false, isDraft: json["isDraft"]?.bool ?? false,
                  baseRefName: json["base"]?.string, headRefName: json["head"]?.string)
    }
}

/// Core's calls a code host plugin's script hasn't answered yet, each
/// with its time limit (ABS-139). A write call the person started also
/// lets the commands it runs change things without asking again, a
/// couple of them, while it's waiting.
public actor PluginCodeHostCalls {
    private struct Waiting {
        var continuation: CheckedContinuation<PluginCodeHostAnswer, Never>
        var op: CodeHostOperation
        var writesLeft: Int
    }

    /// Commands that change things one write call may run unasked.
    public static let writesPerCall = 2

    private var waiting: [String: Waiting] = [:]
    private let pluginName: String

    public init(pluginName: String) { self.pluginName = pluginName }

    /// Sends a call through `send` (given its id) and waits for its end.
    /// `send` returns false when the script can't take it.
    public func call(_ op: CodeHostOperation, _ send: @Sendable @escaping (String) async -> Bool) async -> PluginCodeHostAnswer {
        let id = UUID().uuidString
        let name = pluginName
        return await withCheckedContinuation { continuation in
            waiting[id] = Waiting(continuation: continuation, op: op, writesLeft: op.isWrite ? Self.writesPerCall : 0)
            Task {
                guard await send(id) else {
                    self.finish(id, .failed("\(name) isn't running, so it can't answer."))
                    return
                }
                try? await Task.sleep(for: op.timeout)
                self.finish(id, .failed("\(name) didn't answer within \(op.timeout.components.seconds) seconds."))
            }
        }
    }

    /// Whether a write command run for `callId` goes ahead unasked: the
    /// call is waiting, is a write the person started, and has writes left.
    public func authorizesWrite(_ callId: String?) -> Bool {
        guard let callId, var call = waiting[callId], call.writesLeft > 0 else { return false }
        call.writesLeft -= 1
        waiting[callId] = call
        return true
    }

    /// Ends a call; a second end, or one for an unknown id, does nothing.
    public func finish(_ id: String, _ answer: PluginCodeHostAnswer) {
        waiting.removeValue(forKey: id)?.continuation.resume(returning: answer)
    }

    /// Ends every call still waiting: the script stopped.
    public func failAll(_ reason: String) {
        let all = waiting
        waiting = [:]
        for call in all.values { call.continuation.resume(returning: .failed(reason)) }
    }

    public var pending: Int { waiting.count }
}

public extension PluginCodeHostAnswer {
    /// The answer as core's typed calls take it.
    func value() throws -> JSONValue {
        switch self {
        case .result(let value): value
        case .failed(let why): throw CodeHostError.failed(why)
        }
    }
}
