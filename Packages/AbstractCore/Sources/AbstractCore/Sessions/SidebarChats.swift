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
        /// Reviews, comments and comments on the code known so far: zero
        /// until the pull request's detail has been read (ABS-109).
        public var comments: Int
        public var failedChecks: Int

        public init(number: Int, state: PullRequest.State, isDraft: Bool = false, checks: Checks? = nil, changesRequested: Bool = false,
                    comments: Int = 0, failedChecks: Int = 0) {
            self.number = number; self.state = state; self.isDraft = isDraft
            self.checks = checks; self.changesRequested = changesRequested
            self.comments = comments; self.failedChecks = failedChecks
        }

        public init(_ pr: PullRequest) {
            let sum = pr.checksSummary
            self.init(number: pr.number, state: pr.state, isDraft: pr.isDraft,
                      checks: Self.checks(passed: sum.passed, failed: sum.failed, pending: sum.pending),
                      changesRequested: pr.reviewDecision == .changesRequested,
                      comments: pr.reviews.count + pr.comments.count + pr.threads.reduce(0) { $0 + $1.comments.count },
                      failedChecks: sum.failed)
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

    /// A project's icon as its chat rows show it: its uploaded image, else
    /// its symbol (or its initial) on its colour. An uploaded image from a
    /// paired Mac travels as bytes (`imageData`); one on this Mac stays a
    /// file (`imageFile`), and only once it is known to still be there.
    public struct ProjectMark: Sendable, Hashable {
        public var name: String
        public var symbol: String?
        public var color: String?
        public var imageFile: String?
        public var imageData: Data?

        public init(name: String, symbol: String? = nil, color: String? = nil, imageFile: String? = nil, imageData: Data? = nil) {
            self.name = name; self.symbol = symbol; self.color = color; self.imageFile = imageFile; self.imageData = imageData
        }
    }

    /// What leads a chat's row: its project's icon, or (standalone) its agent's logo.
    public enum Icon: Sendable, Hashable {
        case agentLogo
        case project(ProjectMark)
    }

    /// The icon a chat's row leads with, following Project Settings: an
    /// uploaded image that is still there wins, then the symbol and colour,
    /// then the default tile. A paired Mac sends image bytes, never its local
    /// path; an older Mac that sends no bytes falls back to the tile.
    public static func icon(project: Project?, isRemote: Bool, remoteImage: Data?,
                            fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Icon {
        guard let project else { return .agentLogo }
        var mark = ProjectMark(name: project.name, symbol: project.iconSymbol, color: project.iconColor)
        if isRemote {
            if let remoteImage, !remoteImage.isEmpty { mark.imageData = remoteImage }
        } else if let path = project.iconImagePath, fileExists(path) {
            mark.imageFile = path
        }
        return .project(mark)
    }

    /// What the sidebar knows of one chat.
    public struct SubtaskProgress: Sendable, Hashable {
        public var done: Int
        public var total: Int
        public init(done: Int, total: Int) { self.done = done; self.total = total }
    }

    public struct Chat: Sendable, Hashable, Identifiable {
        public var session: Session
        public var pullRequest: PullRequestFacts?
        /// Uncommitted work, unpushed commits, or commits its base doesn't
        /// have yet; nil until its branch has been read.
        public var hasChanges: Bool?
        public var backgroundTasks: Int
        /// Direct children that finished their turn, and all direct children.
        public var subtaskProgress: SubtaskProgress?
        public var stalled: Bool
        public var projectName: String?
        /// The Mac it runs on.
        public var mac: String
        /// On a paired Mac rather than this one.
        public var isRemote: Bool
        /// What leads its row: its project's icon, or its agent's logo.
        public var icon: Icon

        public var id: String { session.id }

        public init(session: Session, pullRequest: PullRequestFacts? = nil, hasChanges: Bool? = nil, backgroundTasks: Int = 0,
                    projectName: String? = nil, mac: String = "", isRemote: Bool = false, icon: Icon = .agentLogo,
                    subtaskProgress: SubtaskProgress? = nil, stalled: Bool = false) {
            self.session = session; self.pullRequest = pullRequest; self.hasChanges = hasChanges
            self.backgroundTasks = backgroundTasks; self.projectName = projectName; self.mac = mac; self.isRemote = isRemote
            self.icon = icon
            self.subtaskProgress = subtaskProgress
            self.stalled = stalled
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

    /// Parents precede their delegated chats, even when the input is ordered
    /// by recent activity. Broken or cyclic parent links still appear once.
    private static func chains(_ chats: [Chat]) -> [[Chat]] {
        let byID = Dictionary(chats.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var children: [String: [Chat]] = [:]
        for chat in chats {
            if let parent = chat.session.parentSessionId, byID[parent] != nil {
                children[parent, default: []].append(chat)
            }
        }
        for id in children.keys {
            children[id]?.sort { $0.activeAt == $1.activeAt ? $0.id < $1.id : $0.activeAt > $1.activeAt }
        }

        var seen = Set<String>()
        var result: [[Chat]] = []
        func addChain(startingAt root: Chat) {
            var members: [Chat] = []
            func visit(_ chat: Chat) {
                guard seen.insert(chat.id).inserted else { return }
                members.append(chat)
                for child in children[chat.id] ?? [] { visit(child) }
            }
            visit(root)
            if !members.isEmpty { result.append(members) }
        }
        for chat in chats where chat.session.parentSessionId.flatMap({ byID[$0] }) == nil {
            addChain(startingAt: chat)
        }
        for chat in chats where !seen.contains(chat.id) { addChain(startingAt: chat) }
        return result
    }

    /// The chats in their groups, in the order the sidebar shows them; empty groups are left out.
    /// A delegated chain stays together in its most urgent member's group.
    public static func sections(_ chats: [Chat], now: Date = Date()) -> [Section] {
        struct Chain {
            var chats: [Chat]
            var group: Group
            var activeAt: Date
            var pinnedAt: Date?
        }

        let priority = Dictionary(uniqueKeysWithValues: Group.allCases.enumerated().map { ($0.element, $0.offset) })
        let chains = chains(chats).map { members in
            Chain(chats: members,
                  group: members.map(group(of:)).min { priority[$0, default: 0] < priority[$1, default: 0] }!,
                  activeAt: members.map(\.activeAt).max()!,
                  pinnedAt: members.compactMap { $0.session.pinnedAt }.min())
        }

        let byGroup = Dictionary(grouping: chains, by: \.group)
        return Group.allCases.compactMap { group in
            guard var members = byGroup[group], !members.isEmpty else { return nil }
            if group == .pinned {
                members.sort { ($0.pinnedAt ?? .distantPast) < ($1.pinnedAt ?? .distantPast) }
            } else {
                members.sort { $0.activeAt > $1.activeAt }
            }
            guard group == .done else { return Section(group: group, chats: members.flatMap(\.chats)) }
            let cutoff = now.addingTimeInterval(-doneWindow)
            return Section(group: group, chats: members.filter { $0.activeAt >= cutoff }.flatMap(\.chats),
                           older: members.filter { $0.activeAt < cutoff }.flatMap(\.chats))
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
        public enum Activity: String, Sendable, Hashable, Codable, CaseIterable {
            case today, last3Days, last7Days, last30Days, olderThan30Days

            public var title: String {
                switch self {
                case .today: "Today"
                case .last3Days: "Last 3 Days"
                case .last7Days: "Last 7 Days"
                case .last30Days: "Last 30 Days"
                case .olderThan30Days: "Older Than 30 Days"
                }
            }
        }

        public var projects: Set<String> = []
        public var agents: Set<String> = []
        public var macs: Set<String> = []
        public var activity: Activity?

        public init(projects: Set<String> = [], agents: Set<String> = [], macs: Set<String> = [], activity: Activity? = nil) {
            self.projects = projects; self.agents = agents; self.macs = macs; self.activity = activity
        }

        public var isEmpty: Bool { projects.isEmpty && agents.isEmpty && macs.isEmpty && activity == nil }

        /// Projects by name, so the same repository on two Macs is one choice;
        /// a chat with no project is "Standalone".
        public func matches(_ chat: Chat) -> Bool { matches(chat, now: Date()) }

        public func matches(_ chat: Chat, now: Date) -> Bool {
            (projects.isEmpty || projects.contains(chat.projectName ?? standalone))
                && (agents.isEmpty || agents.contains(chat.session.providerId))
                && (macs.isEmpty || macs.contains(chat.mac))
                && matchesActivity(chat.activeAt, now: now)
        }

        private func matchesActivity(_ date: Date, now: Date) -> Bool {
            switch activity {
            case nil: true
            case .today: Calendar.current.isDate(date, inSameDayAs: now)
            case .last3Days: date >= now.addingTimeInterval(-3 * 86_400) && date <= now
            case .last7Days: date >= now.addingTimeInterval(-7 * 86_400) && date <= now
            case .last30Days: date >= now.addingTimeInterval(-30 * 86_400) && date <= now
            case .olderThan30Days: date < now.addingTimeInterval(-30 * 86_400)
            }
        }
    }

    public static let standalone = "Standalone"

    /// The chats the rail shows: archived ones only when asked for, then the
    /// filter menu's choices, then the search box. The query is trimmed,
    /// read as a pull-request number once, not once per chat.
    public static func visible(_ chats: [Chat], filter: Filter, query: String, showArchived: Bool, now: Date = Date()) -> [Chat] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let number = Int(q.hasPrefix("#") ? String(q.dropFirst()) : q)
        let matches = chats.filter { chat in
            guard showArchived || chat.session.archivedAt == nil, filter.matches(chat, now: now) else { return false }
            guard !q.isEmpty else { return true }
            if let number, chat.pullRequest?.number == number { return true }
            return chat.session.name.localizedCaseInsensitiveContains(q)
                || (chat.session.branch?.localizedCaseInsensitiveContains(q) ?? false)
        }
        let byID = Dictionary(chats.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var included = Set(matches.map(\.id))
        for chat in matches {
            var parent = chat.session.parentSessionId
            while let id = parent, let ancestor = byID[id], included.insert(id).inserted {
                parent = ancestor.session.parentSessionId
            }
        }
        return chats.filter { included.contains($0.id) }
    }

    /// Chats under their projects (nil: standalone), in one pass, each group
    /// in the rail's order: pinned first in pin order, the rest as given —
    /// the order `Ordering.pinnedFirst` gives a project's sessions.
    public static func groupedByProject(_ chats: [Chat]) -> [String?: [Chat]] {
        var groups: [String?: [[Chat]]] = [:]
        for chain in chains(chats) {
            groups[chain[0].session.projectId, default: []].append(chain)
        }
        return groups.mapValues { chains in
            var pinned: [[Chat]] = [], rest: [[Chat]] = []
            for chain in chains {
                if chain.contains(where: { $0.session.pinnedAt != nil }) { pinned.append(chain) }
                else { rest.append(chain) }
            }
            pinned.sort { $0.compactMap { $0.session.pinnedAt }.min()! < $1.compactMap { $0.session.pinnedAt }.min()! }
            return (pinned + rest).flatMap { $0 }
        }
    }

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
