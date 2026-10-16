import Foundation

/// The sidebar's chats, grouped by what each needs from you, across projects
/// and Macs. The app hands over what it knows of each chat; nothing here
/// reads git or GitHub itself.
public enum SidebarChats {
    public enum Group: String, Sendable, Hashable, CaseIterable, Identifiable {
        case pinned, needsYou, working, readyToReview, done, archived

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .pinned: "Pinned"
            case .needsYou: "Needs you"
            case .working: "Working"
            case .readyToReview: "Ready to review"
            case .done: "Done"
            case .archived: "Archived"
            }
        }
    }

    /// How the sidebar arranges chats: by what they need (the default), or
    /// under their projects.
    public enum Arrangement: String, Sendable, CaseIterable {
        case status, project
    }

    /// How a chat's pull request stands, as far as its row goes.
    public struct PullRequestFacts: Sendable, Hashable {
        public enum Checks: String, Sendable, Hashable { case passed, failing, running }

        public var number: Int
        public var state: PullRequest.State
        public var isDraft: Bool
        public var checks: Checks?
        public var changesRequested: Bool

        public init(number: Int, state: PullRequest.State, isDraft: Bool = false, checks: Checks? = nil, changesRequested: Bool = false) {
            self.number = number; self.state = state; self.isDraft = isDraft
            self.checks = checks; self.changesRequested = changesRequested
        }

        public init(_ pr: PullRequest) {
            let sum = pr.checksSummary
            self.init(number: pr.number, state: pr.state, isDraft: pr.isDraft,
                      checks: Self.checks(passed: sum.passed, failed: sum.failed, pending: sum.pending),
                      changesRequested: pr.reviewDecision == .changesRequested)
        }

        /// A pull request as a paired Mac reports it.
        public init(_ pr: RemotePullRequest) {
            self.init(number: pr.number, state: PullRequest.State(rawValue: pr.state) ?? .open, isDraft: pr.isDraft,
                      checks: Self.checks(passed: pr.checks.count { $0.outcome == "passed" },
                                          failed: pr.checks.count { $0.outcome == "failed" },
                                          pending: pr.checks.count { $0.outcome == "pending" }),
                      changesRequested: pr.reviewDecision == PullRequest.ReviewDecision.changesRequested.rawValue)
        }

        /// One failing check is the news; then any still running; nil with none.
        static func checks(passed: Int, failed: Int, pending: Int) -> Checks? {
            if failed > 0 { return .failing }
            if pending > 0 { return .running }
            return passed > 0 ? .passed : nil
        }
    }

    /// What the sidebar knows of one chat.
    public struct Chat: Sendable, Hashable, Identifiable {
        public var session: Session
        public var pullRequest: PullRequestFacts?
        /// Uncommitted work, unpushed commits, or commits its base doesn't
        /// have yet; nil until its branch has been read.
        public var hasChanges: Bool?
        public var backgroundTasks: Int
        public var projectName: String?
        /// The Mac it runs on.
        public var mac: String
        /// On a paired Mac rather than this one.
        public var isRemote: Bool

        public var id: String { session.id }

        public init(session: Session, pullRequest: PullRequestFacts? = nil, hasChanges: Bool? = nil, backgroundTasks: Int = 0,
                    projectName: String? = nil, mac: String = "", isRemote: Bool = false) {
            self.session = session; self.pullRequest = pullRequest; self.hasChanges = hasChanges
            self.backgroundTasks = backgroundTasks; self.projectName = projectName; self.mac = mac; self.isRemote = isRemote
        }

        /// When it last did something.
        public var activeAt: Date { session.lastEventAt ?? session.createdAt }
    }

    /// One group's chats, most recently active first.
    public struct Section: Sendable, Hashable, Identifiable {
        public var group: Group
        public var chats: [Chat]
        /// Done chats quiet for longer than `doneWindow`, behind "Show N older".
        public var older: [Chat] = []
        public var id: Group { group }
    }

    /// How long a chat stays in Done before it folds under "Show N older".
    public static let doneWindow: TimeInterval = 7 * 86_400

    /// Where a chat belongs, pins and archive aside: what it needs from you.
    public static func status(of chat: Chat) -> Group {
        switch chat.session.status {
        case .waitingInput, .errored: return .needsYou
        case .running, .provisioning: return .working
        case .idle, .finished, .created: break
        }
        if chat.backgroundTasks > 0 { return .working }
        switch chat.pullRequest?.state {
        case .open?: return .readyToReview
        case .merged?, .closed?: return .done
        case nil:
            // Not known yet counts as changes: nothing is filed as done before
            // it's known to have none.
            return chat.hasChanges ?? true ? .readyToReview : .done
        }
    }

    public static func group(of chat: Chat) -> Group {
        if chat.session.archivedAt != nil { return .archived }
        if chat.session.pinnedAt != nil { return .pinned }
        return status(of: chat)
    }

    /// The chats in their groups, in the order the sidebar shows them; empty groups are left out.
    public static func sections(_ chats: [Chat], now: Date = Date()) -> [Section] {
        let byGroup = Dictionary(grouping: chats, by: group(of:))
        return Group.allCases.compactMap { group in
            guard var members = byGroup[group], !members.isEmpty else { return nil }
            if group == .pinned {
                members.sort { ($0.session.pinnedAt ?? .distantPast) < ($1.session.pinnedAt ?? .distantPast) }
            } else {
                members.sort { $0.activeAt > $1.activeAt }
            }
            guard group == .done else { return Section(group: group, chats: members) }
            let cutoff = now.addingTimeInterval(-doneWindow)
            return Section(group: group, chats: members.filter { $0.activeAt >= cutoff },
                           older: members.filter { $0.activeAt < cutoff })
        }
    }

    // MARK: The row

    /// The quiet second line under a chat's title. Empty parts are left out,
    /// so a fresh chat has none.
    public struct Line: Sendable, Hashable {
        public var project: String?
        public var pullRequest: PullRequestFacts?
        public var checks: PullRequestFacts.Checks?
        public var changesRequested = false
        public var mac: String?

        public var isEmpty: Bool { project == nil && pullRequest == nil && mac == nil }

        /// The line as words, the way VoiceOver and tests read it:
        /// "abstract · #3981 · passed · changes requested · Studio".
        public var text: String {
            var parts: [String] = []
            if let project { parts.append(project) }
            if let pullRequest { parts.append("#\(pullRequest.number)") }
            if let checks { parts.append(checks.rawValue) }
            if changesRequested { parts.append("changes requested") }
            if let mac { parts.append(mac) }
            return parts.joined(separator: " · ")
        }

        /// Names the pull request and its checks when VoiceOver reads the row.
        public var accessibilityText: String {
            var parts: [String] = []
            if let project { parts.append(project) }
            if let pullRequest { parts.append("Pull request \(pullRequest.number)") }
            if let checks { parts.append("checks \(checks.rawValue)") }
            if changesRequested { parts.append("changes requested") }
            if let mac { parts.append(mac) }
            return parts.joined(separator: ", ")
        }
    }

    /// Checks and requested changes only matter while the pull request is open.
    public static func line(for chat: Chat, showProject: Bool) -> Line {
        let open = chat.pullRequest?.state == .open
        return Line(project: showProject ? chat.projectName : nil,
                    pullRequest: chat.pullRequest,
                    checks: open ? chat.pullRequest?.checks : nil,
                    changesRequested: open && chat.pullRequest?.changesRequested == true,
                    mac: chat.isRemote ? chat.mac : nil)
    }

    // MARK: Search and filters

    /// What the search field and the filter menu narrow the chats to. An
    /// empty set lets everything through.
    public struct Filter: Sendable, Hashable, Codable {
        public var projects: Set<String> = []
        public var agents: Set<String> = []
        public var macs: Set<String> = []

        public init(projects: Set<String> = [], agents: Set<String> = [], macs: Set<String> = []) {
            self.projects = projects; self.agents = agents; self.macs = macs
        }

        public var isEmpty: Bool { projects.isEmpty && agents.isEmpty && macs.isEmpty }

        /// Projects by name, so the same repository on two Macs is one choice;
        /// a chat with no project is "Standalone".
        public func matches(_ chat: Chat) -> Bool {
            (projects.isEmpty || projects.contains(chat.projectName ?? standalone))
                && (agents.isEmpty || agents.contains(chat.session.providerId))
                && (macs.isEmpty || macs.contains(chat.mac))
        }
    }

    public static let standalone = "Standalone"

    /// The search box: the chat's title or branch, or its pull request's number.
    public static func matches(_ chat: Chat, query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return true }
        if let pr = chat.pullRequest, let n = Int(q.hasPrefix("#") ? String(q.dropFirst()) : q) { if pr.number == n { return true } }
        return chat.session.name.localizedCaseInsensitiveContains(q)
            || (chat.session.branch?.localizedCaseInsensitiveContains(q) ?? false)
    }
}

extension BranchState {
    /// Work on the branch that isn't merged anywhere yet: uncommitted
    /// changes, commits origin doesn't have, or commits its base doesn't
    /// (unless origin deleted the branch, as it does once a pull request merges).
    public var hasUnmergedWork: Bool {
        dirty || ahead > 0 || (aheadOfBase > 0 && !upstreamGone)
    }
}

/// How long ago, in the fewest characters: "now", "12m", "3h", "2d", "5w".
public enum RelativeAge {
    public static func short(_ date: Date, now: Date = Date()) -> String {
        let s = now.timeIntervalSince(date)
        if abs(s) < 45 { return "now" }
        let a = abs(s)
        let text = a < 3600 ? "\(Int(a / 60))m" : a < 86_400 ? "\(Int(a / 3600))h" : a < 604_800 ? "\(Int(a / 86_400))d" : "\(Int(a / 604_800))w"
        return s < 0 ? "in \(text)" : text
    }
}
