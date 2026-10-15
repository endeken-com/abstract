import Foundation
import Synchronization

/// What a turn's log says: your request and corrections, the agent's
/// summary, and the files its edits named.
public struct TurnTranscript: Sendable, Hashable {
    public var request: String?
    public var corrections: [String]
    public var summary: String?
    /// As the agent named them: absolute, or relative to its directory.
    public var editedPaths: [String]
    public var startedAt: Date?
    public var endedAt: Date?
    /// The agent did something: replied, used a tool, or reported an end.
    public var worked: Bool

    /// Lines of the last reply kept when the agent gives no summary.
    static let replyLines = 4
    static let replyCharacters = 600

    public init(_ entries: [TimelineEntry]) {
        var messages: [String] = []
        var paths: [String] = []
        var summary: String?
        var reply: String?
        var worked = false
        func edited(_ edit: EditPreview?) {
            if let path = edit?.filePath, !path.isEmpty, !paths.contains(path) { paths.append(path) }
        }
        func read(_ event: AgentEvent) {
            switch event {
            case let .text(.user, text, _, _):
                let text = PromptAttachments.split(text).text.trimmingCharacters(in: .whitespacesAndNewlines)
                // Logged by Abstract, then echoed by the agent: one message.
                if !text.isEmpty, messages.last != text { messages.append(text) }
            case let .text(.assistant, text, _, _):
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { reply = text; worked = true }
            case let .toolUse(_, _, _, edit), let .toolResult(_, _, _, edit):
                edited(edit)
                worked = true
            case let .toolFileChanges(_, changes):
                for edit in changes.previews { edited(edit) }
                for path in changes.remainingPaths where !path.isEmpty && !paths.contains(path) { paths.append(path) }
                worked = true
            case let .turnEnd(_, _, _, said):
                worked = true
                if event != TurnStop.rule, let said = said?.trimmingCharacters(in: .whitespacesAndNewlines), !said.isEmpty {
                    summary = said
                }
            case let .subagent(_, inner):
                read(inner)
            default:
                break
            }
        }
        for entry in entries { read(entry.event) }
        request = messages.first
        corrections = Array(messages.dropFirst())
        self.summary = summary ?? reply.map(Self.shortened)
        editedPaths = paths
        startedAt = entries.lazy.compactMap(\.at).first
        endedAt = entries.reversed().lazy.compactMap(\.at).first
        self.worked = worked
    }

    /// A reply cut to its first few lines.
    static func shortened(_ reply: String) -> String {
        let lines = reply.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n", omittingEmptySubsequences: false)
        var text = lines.prefix(replyLines).joined(separator: "\n")
        if text.count > replyCharacters { text = String(text.prefix(replyCharacters)) }
        return text.count < reply.count ? text.trimmingCharacters(in: .whitespacesAndNewlines) + "…" : text
    }

    /// `path` relative to `worktree`; nil for a file outside it.
    static func relative(_ path: String, to worktree: String) -> String? {
        guard path.hasPrefix("/") else { return path.hasPrefix("../") ? nil : path }
        let root = GitText.trimTrailingSlashes(worktree) + "/"
        guard path.hasPrefix(root) else { return nil }
        let rest = String(path.dropFirst(root.count))
        return rest.isEmpty ? nil : rest
    }
}

/// The git facts a turn record is made from.
public enum TurnGit {
    /// A worktree at one moment: `HEAD`, and every changed or untracked file
    /// with a hash of what it holds, so two moments tell which files changed
    /// in between, even ones already changed before.
    public struct State: Sendable, Hashable {
        public var head: String?
        /// Path → its content's hash; "" for a deleted file, "dir" for a submodule.
        public var dirty: [String: String]

        public init(head: String?, dirty: [String: String] = [:]) { self.head = head; self.dirty = dirty }

        /// The files whose content differs between `before` and `self`.
        public func changed(since before: State) -> Set<String> {
            Set(dirty.keys).union(before.dirty.keys).filter { dirty[$0] != before.dirty[$0] }
        }
    }

    public struct Commit: Sendable, Hashable {
        public var sha: String
        public var parents: [String]
        public var files: [String]
        public var patchId: String?
    }

    /// More than this many changed files and only the paths are kept.
    static let hashLimit = 2000
    /// Patch IDs are worked out for at most this many commits at once.
    static let patchLimit = 200

    public static func head(_ exec: any Executor, worktree: String) async -> String? {
        guard let out = try? await Git.git(exec, cwd: worktree, ["rev-parse", "--verify", "--quiet", "HEAD"]), out.ok else { return nil }
        let sha = GitText.trimmed(out.stdout)
        return sha.isEmpty ? nil : sha
    }

    /// nil when `worktree` isn't a git worktree.
    public static func state(_ exec: any Executor, worktree: String) async -> State? {
        guard let out = try? await Git.git(exec, cwd: worktree, ["status", "--porcelain=v1", "-z", "--untracked-files=all"]),
              out.ok else { return nil }
        var dirty: [String: String] = [:]
        var toHash: [String] = []
        for path in changedPaths(out.stdout) {
            let info = await exec.fileInfo(worktree + "/" + path)
            if info == nil { dirty[path] = "" } else if info?.isDirectory == true { dirty[path] = "dir" } else { toHash.append(path) }
        }
        if !toHash.isEmpty, toHash.count <= hashLimit,
           let hashed = try? await Git.git(exec, cwd: worktree, ["hash-object", "--"] + toHash), hashed.ok {
            for (path, hash) in zip(toHash, GitText.lines(hashed.stdout)) { dirty[path] = GitText.trimmed(hash) }
        } else {
            for path in toHash { dirty[path] = "?" }
        }
        return State(head: await head(exec, worktree: worktree), dirty: dirty)
    }

    /// The paths `git status --porcelain=v1 -z` lists; a rename gives both names.
    static func changedPaths(_ porcelain: String) -> [String] {
        var paths: [String] = []
        var fields = porcelain.split(separator: "\0", omittingEmptySubsequences: true).makeIterator()
        while let field = fields.next() {
            guard field.count > 3 else { continue }
            let code = field.prefix(2)
            paths.append(String(field.dropFirst(3)))
            if code.contains("R") || code.contains("C"), let source = fields.next() { paths.append(String(source)) }
        }
        return paths
    }

    /// The commits in `from..to`, oldest first, with their files and patch IDs.
    public static func commits(_ exec: any Executor, worktree: String, from: String, to: String) async -> [Commit] {
        guard let out = try? await Git.git(exec, cwd: worktree, ["log", "--reverse", "--no-color", "--format=%x01%H %P",
                                                                  "--name-only", "\(from)..\(to)"]), out.ok else { return [] }
        var commits: [Commit] = []
        for block in out.stdout.split(separator: "\u{1}", omittingEmptySubsequences: true) {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard let ids = lines.first?.split(separator: " ").map(String.init), let sha = ids.first else { continue }
            commits.append(Commit(sha: sha, parents: Array(ids.dropFirst()), files: Array(lines.dropFirst())))
        }
        guard !commits.isEmpty, commits.count <= patchLimit else { return commits }
        let ids = await patchIds(exec, cwd: worktree, ["log", "--no-merges", "\(from)..\(to)"])
        return commits.map { var c = $0; c.patchId = ids[c.sha]; return c }
    }

    /// Commit → `git patch-id --stable` of the commits `logArgs` lists.
    static func patchIds(_ exec: any Executor, cwd: String, _ logArgs: [String]) async -> [String: String] {
        guard let log = try? await Git.git(exec, cwd: cwd, logArgs + ["-p", "--no-color", "--no-ext-diff", "--format=commit %H"]),
              log.ok, !log.stdout.isEmpty,
              let ids = try? await Git.git(exec, cwd: cwd, ["patch-id", "--stable"], stdin: Data(log.stdout.utf8)), ids.ok
        else { return [:] }
        var out: [String: String] = [:]
        for line in GitText.lines(ids.stdout) {
            let parts = line.split(separator: " ")
            if parts.count == 2 { out[String(parts[1])] = String(parts[0]) }
        }
        return out
    }
}

/// Saves a record of each turn as it ends (`TurnRecord`), and ties the
/// commits made afterwards to the turns they hold: by the Commit button,
/// and by the chat's pull request merging.
public final class TurnRecorder: Sendable {
    public let store: Store
    /// Each chat's worktree as its turn under way started.
    private let starts = Mutex<[String: Task<TurnGit.State?, Never>]>([:])
    /// Pull requests and merges already written, so polling doesn't write them again.
    private let written = Mutex<Set<String>>([])

    public init(store: Store) { self.store = store }

    /// A turn starts: remembers the worktree as it is, unless the turn
    /// under way already did (the agent asking for approval mid-turn).
    /// Returns the look at the worktree, under way.
    @discardableResult
    public func begin(_ sessionId: String, worktree: String?, exec: any Executor) -> Task<TurnGit.State?, Never>? {
        guard let worktree else { return nil }
        return starts.withLock { starts in
            if let started = starts[sessionId] { return started }
            let look = Task { await TurnGit.state(exec, worktree: worktree) }
            starts[sessionId] = look
            return look
        }
    }

    /// The turn under way ended: saves its record, from the chat's log
    /// since the last record and the worktree before and after. A turn in
    /// which nobody asked for anything and the agent did nothing has none.
    @discardableResult
    public func end(_ session: Session, engine: SessionEngine, exec: any Executor,
                    pullRequest: (number: Int, body: String?)? = nil) async -> TurnRecord? {
        let start = starts.withLock { $0.removeValue(forKey: session.id) }
        let before = await start?.value
        let previous = try? store.lastTurnRecord(sessionId: session.id)
        let lines = engine.replay(sessionId: session.id, after: previous?.logEnd ?? 0)
        guard let first = lines.first?.seq, let last = lines.last?.seq else { return nil }
        let outputs = lines.map(\.line)
        let stream = ChatStream(providerId: ChatStream.firstProvider(in: outputs, current: session.handoffFrom ?? session.providerId))
        let transcript = TurnTranscript(stream.replay(outputs).entries)
        guard transcript.request != nil || transcript.worked else { return nil }

        var after: TurnGit.State?
        var commits: [TurnGit.Commit] = []
        let headBefore = before?.head ?? previous?.headAfter
        var files = Set<String>()
        if let worktree = session.worktreePath {
            after = await TurnGit.state(exec, worktree: worktree)
            if let from = headBefore, let to = after?.head, from != to {
                commits = await TurnGit.commits(exec, worktree: worktree, from: from, to: to)
            }
            files.formUnion(transcript.editedPaths.compactMap { TurnTranscript.relative($0, to: worktree) })
            if let before, let after { files.formUnion(after.changed(since: before)) }
            for c in commits { files.formUnion(c.files) }
        } else {
            files.formUnion(transcript.editedPaths)
        }
        let record = TurnRecord(
            projectId: session.projectId, sessionId: session.id, chatName: session.name, providerId: session.providerId,
            number: (previous?.number ?? 0) + 1, startedAt: transcript.startedAt, endedAt: transcript.endedAt ?? Date(),
            request: transcript.request, corrections: transcript.corrections, summary: transcript.summary,
            files: files.sorted(), uncommitted: files.filter { after?.dirty[$0] != nil }.sorted(),
            headBefore: headBefore, headAfter: after?.head ?? headBefore, branch: session.branch,
            pullRequest: pullRequest?.number, ticket: Self.ticket(pullRequestBody: pullRequest?.body, branch: session.branch),
            logStart: first, logEnd: last)
        do {
            try store.save(record)
            try store.link(commits.map { TurnCommit(sha: $0.sha, turnId: record.id, link: .turn, patchId: $0.patchId) })
            try store.attachPendingNotes(sessionId: session.id, to: record.id)
        } catch {
            return nil
        }
        return record
    }

    /// After the Commit button committed the worktree from `before`: each
    /// new commit belongs to the chat's turns that left its files uncommitted
    /// on the commit it was made on.
    public func linkCommitted(_ sessionId: String, exec: any Executor, worktree: String, from before: String?) async {
        guard let before, let after = await TurnGit.head(exec, worktree: worktree), after != before else { return }
        let commits = await TurnGit.commits(exec, worktree: worktree, from: before, to: after)
        let turns = (try? store.turnRecords(sessionId: sessionId)) ?? []
        try? store.link(Self.claims(commits, turns: turns))
    }

    /// Which turns each commit made with the Commit button belongs to.
    static func claims(_ commits: [TurnGit.Commit], turns: [TurnRecord]) -> [TurnCommit] {
        commits.flatMap { commit in
            turns.filter { $0.headAfter != nil && commit.parents.first == $0.headAfter && !Set($0.uncommitted).isDisjoint(with: commit.files) }
                .map { TurnCommit(sha: commit.sha, turnId: $0.id, link: .commitButton, patchId: commit.patchId) }
        }
    }

    /// The chat has pull request `number`: its turns without one take it.
    public func notePullRequest(_ sessionId: String, number: Int, body: String?, branch: String?) {
        guard written.withLock({ $0.insert("pr/\(sessionId)/\(number)").inserted }) else { return }
        _ = try? store.setPullRequest(number, ticket: Self.ticket(pullRequestBody: body, branch: branch), sessionId: sessionId)
    }

    /// The chat's pull request merged as `sha` on its base branch: the merge
    /// (or squash) commit belongs to every turn of the chat.
    public func linkMerge(_ sessionId: String, number: Int, sha: String) {
        guard written.withLock({ $0.insert("merge/\(sessionId)/\(sha)").inserted }) else { return }
        _ = try? store.setPullRequest(number, ticket: nil, sessionId: sessionId)
        let turns = (try? store.turnRecords(sessionId: sessionId)) ?? []
        try? store.link(turns.map { TurnCommit(sha: sha, turnId: $0.id, link: .merge) })
    }

    // MARK: Tickets

    private static let fixesPattern = try! NSRegularExpression(
        pattern: #"(?i)\b(?:fix(?:es|ed)?|close[sd]?|resolve[sd]?)\s*:?\s+([A-Za-z][A-Za-z0-9]{1,9}-[0-9]+)\b"#)

    /// A ticket ID: the one a pull request says it fixes, else one in the
    /// branch's name (`feature/abs-62` → ABS-62).
    public static func ticket(pullRequestBody body: String?, branch: String?) -> String? {
        if let body {
            let ns = body as NSString
            if let match = fixesPattern.firstMatch(in: body, range: NSRange(location: 0, length: ns.length)) {
                return ns.substring(with: match.range(at: 1)).uppercased()
            }
        }
        guard let branch else { return nil }
        let id = ChatNaming.ticket(in: branch.uppercased())
        return id?.hasPrefix("#") == true ? nil : id
    }
}
