import Foundation

/// Project Settings › Clean up (ABS-206): the project's chats not active for
/// longer than a chosen age, each either to be deleted or kept for a reason
/// (which you can override chat by chat).
public enum ChatCleanup {
    /// "Delete chats not active for more than …".
    public enum Age: String, CaseIterable, Sendable, Hashable, Identifiable {
        case oneWeek, twoWeeks, oneMonth, threeMonths

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .oneWeek: "1 week"
            case .twoWeeks: "2 weeks"
            case .oneMonth: "1 month"
            case .threeMonths: "3 months"
            }
        }

        public var interval: TimeInterval {
            switch self {
            case .oneWeek: 7 * 86_400
            case .twoWeeks: 14 * 86_400
            case .oneMonth: 30 * 86_400
            case .threeMonths: 90 * 86_400
            }
        }
    }

    /// Why an old chat is kept unless you tick it.
    public enum Reason: Sendable, Hashable {
        case pinned
        case working
        case waitingOnYou
        case openPullRequest(Int?)
        /// Commits never pushed, or changes never committed: they'd be lost.
        case unpushed(commits: Int, uncommitted: Int)

        public var text: String {
            switch self {
            case .pinned: return "Pinned"
            case .working: return "Working"
            case .waitingOnYou: return "Waiting on you"
            case .openPullRequest(let n): return n.map { "Pull request #\($0) is open" } ?? "Its pull request is open"
            case let .unpushed(commits, uncommitted):
                var parts: [String] = []
                if commits > 0 { parts.append(commits == 1 ? "1 commit never pushed" : "\(commits) commits never pushed") }
                if uncommitted > 0 { parts.append(uncommitted == 1 ? "1 uncommitted change" : "\(uncommitted) uncommitted changes") }
                return parts.joined(separator: ", ")
            }
        }
    }

    /// What's known about a chat that decides whether it goes.
    public struct Facts: Sendable, Hashable, Identifiable {
        public var session: Session
        public var backgroundTasks: Int
        public var pullRequest: PullRequest.State?
        public var pullRequestNumber: Int?
        /// Commits origin doesn't have; nil until read (or with no worktree).
        public var unpushedCommits: Int?
        public var uncommittedFiles: Int?

        public var id: String { session.id }
        public var activeAt: Date { session.lastEventAt ?? session.createdAt }

        public init(session: Session, backgroundTasks: Int = 0, pullRequest: PullRequest.State? = nil, pullRequestNumber: Int? = nil,
                    unpushedCommits: Int? = nil, uncommittedFiles: Int? = nil) {
            self.session = session; self.backgroundTasks = backgroundTasks
            self.pullRequest = pullRequest; self.pullRequestNumber = pullRequestNumber
            self.unpushedCommits = unpushedCommits; self.uncommittedFiles = uncommittedFiles
        }
    }

    /// An old chat in the review list.
    public struct Candidate: Sendable, Hashable, Identifiable {
        public var facts: Facts
        /// Why it's kept; nil when it goes.
        public var reason: Reason?

        public var id: String { facts.id }
    }

    /// Why `facts`' chat is kept, or nil: pinned, at work, waiting on you,
    /// with an open pull request, or with work never pushed.
    public static func reason(_ facts: Facts) -> Reason? {
        let s = facts.session
        if s.pinnedAt != nil { return .pinned }
        switch s.status {
        case .running, .provisioning: return .working
        case .waitingInput: return .waitingOnYou
        default: break
        }
        if facts.backgroundTasks > 0 { return .working }
        if facts.pullRequest == .open { return .openPullRequest(facts.pullRequestNumber) }
        let commits = facts.unpushedCommits ?? 0, files = facts.uncommittedFiles ?? 0
        if commits > 0 || files > 0 { return .unpushed(commits: commits, uncommitted: files) }
        return nil
    }

    /// Chats last active before `age` ago, archived ones too, oldest first,
    /// each with why it's kept, if it is.
    public static func candidates(_ chats: [Facts], olderThan age: Age, now: Date = Date()) -> [Candidate] {
        let cutoff = now.addingTimeInterval(-age.interval)
        return chats.filter { $0.activeAt < cutoff }
            .sorted { $0.activeAt == $1.activeAt ? $0.id < $1.id : $0.activeAt < $1.activeAt }
            .map { Candidate(facts: $0, reason: reason($0)) }
    }

    /// The chats to delete: those with no reason to stay, plus the kept
    /// ones in `including`.
    public static func toDelete(_ candidates: [Candidate], including: Set<String> = []) -> [String] {
        candidates.filter { $0.reason == nil || including.contains($0.id) }.map(\.id)
    }

    /// The work in `worktree` that deleting it would lose: commits no remote
    /// and not its base have (a branch merged locally loses nothing), and
    /// files changed but not committed.
    public static func unsavedWork(_ exec: any Executor, worktree: String, preferredBase: String?) async -> (commits: Int, uncommitted: Int) {
        let status = (try? await Git.gitOK(exec, cwd: worktree, ["status", "--porcelain"])) ?? ""
        let uncommitted = status.split(separator: "\n").count
        let base = await Diff.resolveBase(exec, worktree: worktree, preferred: preferredBase)
        let args = ["rev-list", "--count", "HEAD", "--not", "--remotes"] + (base.map { [$0] } ?? [])
        let commits = Int(GitText.trimmed((try? await Git.gitOK(exec, cwd: worktree, args)) ?? "")) ?? 0
        return (commits, uncommitted)
    }

    /// "Deleted 14 chats, freed 21 GB."
    public static func summary(deleted: Int, freed: Int64) -> String {
        let chats = BulkChatDelete.chats(deleted)
        guard freed > 0 else { return "Deleted \(chats)." }
        return "Deleted \(chats), freed \(ByteCountFormatter.string(fromByteCount: freed, countStyle: .file))."
    }
}
