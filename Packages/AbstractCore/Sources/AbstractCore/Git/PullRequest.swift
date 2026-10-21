import Foundation

/// A pull request as a project's code host reports it (ABS-139). Lists
/// carry the summary fields; asking for one fills in reviews, comments and
/// the body.
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
        /// How the host relates its author to the repository: `OWNER`,
        /// `MEMBER`, `COLLABORATOR`, `CONTRIBUTOR`, `NONE`…
        public var association: String? = nil
    }

    public struct Comment: Sendable, Hashable {
        public var author: String
        public var body: String
        public var createdAt: Date?
        public var isBot: Bool
        public var association: String? = nil
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
            public var association: String? = nil
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
        /// The commit its first comment was written on.
        public var commit: String? = nil
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
    /// The commit a merged pull request became on its base branch.
    public var mergeCommit: String?
    /// The code host's name for links and actions in the PR screens.
    public var hostTitle: String = "GitHub"
    /// Merge choices this host offers for this pull request.
    public var mergeMethods: [MergeMethod] = [.squash, .merge, .rebase]
    public var checks: [Check]
    public var reviews: [Review]
    public var comments: [Comment]
    /// Review threads on the code; filled by the code host's `reviewThreads`.
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

    /// An author who owns the repository, is in its organisation, or was
    /// added to it: someone whose words may go to an agent unasked (ABS-109).
    /// Anyone else can comment on a public repository's pull requests.
    public static func isCollaborator(_ association: String?) -> Bool {
        ["OWNER", "MEMBER", "COLLABORATOR"].contains(association ?? "")
    }

    /// Apply a fresh list result without discarding fields only a single read loads.
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
        updated.mergeCommit = summary.mergeCommit ?? mergeCommit
        updated.mergeMethods = mergeMethods
        return updated
    }
}

public enum MergeMethod: String, Sendable, Hashable, CaseIterable {
    case squash, merge, rebase, fastForward
}

/// What the signed-in user may do with a repository on its code host.
public enum RepoAccess: String, Sendable, Hashable {
    case push, readOnly, unknown
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

    public init(number: Int, title: String, url: String, state: String, body: String?, isPullRequest: Bool,
                isDraft: Bool, baseRefName: String?, headRefName: String?) {
        self.number = number; self.title = title; self.url = url; self.state = state; self.body = body
        self.isPullRequest = isPullRequest; self.isDraft = isDraft; self.baseRefName = baseRefName; self.headRefName = headRefName
    }
}
