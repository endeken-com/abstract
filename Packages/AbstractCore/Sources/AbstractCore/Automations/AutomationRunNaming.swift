import Foundation

/// A fresh-worktree automation run's chat: named for its automation and
/// start time until its agent says what it's taking on. The prompt is the
/// same every run, so it can't name one. Only a run still named for its
/// automation when its turn ends is named from the agent's report.
public enum AutomationRunNaming {
    static let separator = " · "

    /// The name a run's chat starts with.
    public static func provisional(_ automationName: String, at date: Date) -> String {
        automationName + separator + date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    /// Whether a run's chat still has the name it started with.
    public static func isProvisional(_ name: String, automationName: String) -> Bool {
        name.hasPrefix(automationName + separator)
    }

    /// Whether the end of a turn names the chat from its agent's report:
    /// only while nothing better than the run's placeholder has, never over
    /// a name from the agent's first reply, its pull request or you.
    public static func namesFromReport(_ name: String, source: ChatNameSource, automationName: String) -> Bool {
        source == .fallback && isProvisional(name, automationName: automationName)
    }

    /// What the naming call is told to name when its task is the agent's
    /// report: the goal of the work, not the checks that ended it.
    public static let reportFocus =
        "The task holds what a coding agent was asked, its first reply and its final report. Name the chat for the goal "
            + "of the work, what it delivers, not for the checks it ran at the end or the instructions it followed."

    /// The report's naming task: the request and the agent's first reply
    /// come with it, each clipped so none crowds the others out.
    public static func reportTask(request: String?, firstReply: String?, report: String) -> String {
        func clip(_ text: String, _ limit: Int) -> String {
            let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.count > limit ? String(text.prefix(limit)) + "…" : text
        }
        let parts: [(String, String?, Int)] = [("Asked", request, 500), ("First reply", firstReply, 600), ("Final report", report, 800)]
        return parts.compactMap { label, text, limit in
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return label + ":\n" + clip(text, limit)
        }.joined(separator: "\n\n")
    }

    /// Too little to name the work from: the agent hasn't said what it's
    /// doing yet ("Let me look."), so its next reply is waited for.
    public static func canName(fromReply reply: String) -> Bool {
        reply.split(whereSeparator: \.isWhitespace).count >= 4
    }

    /// What the naming call is told to name when its task is the agent's
    /// first reply: what it says it's taking on. An empty title means it
    /// hasn't said yet.
    public static let firstReplyFocus =
        "The task is what a coding agent first said. Name the chat for the work it says it is taking on, "
            + "not for the instructions it follows. If it doesn't say what that work is yet, reply with an empty title."

    /// What became of a run's branch.
    public struct BranchRename: Sendable, Equatable {
        /// The name Abstract gave it.
        public var name: String
        /// The branch the worktree is on afterwards: `name`, unless a commit
        /// under way put the old name back under HEAD. nil on a detached HEAD.
        public var head: String?
    }

    public enum RenameFailure: Error, Sendable, Equatable, LocalizedError {
        case invalidName, wrongPrefix(String), alreadyNamed, changedBranch, published, pullRequest
        case locked, collision, gitFailed

        public var errorDescription: String? {
            switch self {
            case .invalidName: "That is not a valid git branch name. Give the exact name you want."
            case .wrongPrefix(let prefix): "The branch name must start with “\(prefix)”."
            case .alreadyNamed: "This automation branch was already renamed."
            case .changedBranch: "The worktree is no longer on its provisional branch."
            case .published: "This branch has already been pushed or has an upstream."
            case .pullRequest: "This branch has a pull request, or Abstract could not check for one."
            case .locked: "Git is using this branch right now. Try again after the current operation finishes."
            case .collision: "A branch with that exact name already exists."
            case .gitFailed: "Git could not rename the branch. The branch and chat were left as they were."
            }
        }
    }

    /// Renames a provisional run branch to the exact name the agent chose.
    /// Every check runs just before git's own collision-safe rename.
    public static func renameBranch(
        _ exec: any Executor, worktree: String, from: String, name: String, prefix: String,
        hasPullRequest: @Sendable (String) async -> Bool
    ) async -> Result<BranchRename, RenameFailure> {
        await renameBranch(exec, worktree: worktree, from: from, name: name, prefix: prefix,
                           hasPullRequest: hasPullRequest, racing: nil)
    }

    /// `racing` simulates a concurrent commit after git renames the branch (tests).
    static func renameBranch(
        _ exec: any Executor, worktree: String, from: String, name: String, prefix: String,
        hasPullRequest: @Sendable (String) async -> Bool,
        racing: (@Sendable () async -> Void)?
    ) async -> Result<BranchRename, RenameFailure> {
        guard WorktreeNaming.isRunBranch(from) else { return .failure(.alreadyNamed) }
        guard name.hasPrefix(prefix), name.count > prefix.count else { return .failure(.wrongPrefix(prefix)) }
        guard let valid = try? await exec.run("git", ["check-ref-format", "--branch", name], cwd: worktree),
              valid.ok else { return .failure(.invalidName) }
        guard name != from else { return .failure(.alreadyNamed) }
        func out(_ args: [String]) async -> String? {
            guard let r = try? await exec.run("git", args, cwd: worktree), r.ok else { return nil }
            return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard await out(["symbolic-ref", "--quiet", "--short", "HEAD"]) == from else { return .failure(.changedBranch) }
        let upstream = await out(["config", "--get", "branch.\(from).remote"])
        let originBranch = await Git.branchExists(exec, root: worktree, branch: "refs/remotes/origin/\(from)")
        if upstream != nil || originBranch {
            return .failure(.published)
        }
        guard await !hasPullRequest(from) else { return .failure(.pullRequest) }
        guard let gitDir = await out(["rev-parse", "--absolute-git-dir"]),
              let commonDir = await out(["rev-parse", "--path-format=absolute", "--git-common-dir"]) else { return .failure(.gitFailed) }
        let locks = [gitDir + "/index.lock", gitDir + "/HEAD.lock", commonDir + "/packed-refs.lock",
                     commonDir + "/refs/heads/\(from).lock", commonDir + "/refs/heads/\(name).lock"]
        guard !locks.contains(where: exec.fileExists) else { return .failure(.locked) }
        guard await !Git.branchExists(exec, root: worktree, branch: "refs/heads/\(name)") else { return .failure(.collision) }
        let originalHead = await out(["rev-parse", "refs/heads/\(from)"])
        guard await out(["branch", "-m", from, name]) != nil else { return .failure(.gitFailed) }
        await racing?()

        // A commit that started before the rename may have written the old
        // name again. The chat follows HEAD; whichever name it isn't on goes,
        // if it holds nothing beyond the base.
        let head = await out(["symbolic-ref", "--quiet", "--short", "HEAD"])
        if let head, head == from || head == name {
            let leftover = head == name ? from : name
            if await out(["rev-parse", "--verify", "refs/heads/\(leftover)"]) == originalHead {
                _ = await out(["branch", "-D", leftover])
            }
        }
        return .success(BranchRename(name: name, head: head))
    }
}
