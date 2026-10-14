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

    /// Renames a run's branch `from` for the naming call's `suggestion`
    /// (behind `prefix`, as a new chat's branch; `-1`, `-2`… when taken).
    /// Only a branch still named as the run started (never one its agent
    /// renamed), with the worktree on it, never published (no upstream, no
    /// copy on origin, no pull request) and no git lock held. While the agent
    /// may be at work, `allowCommits` is false: the branch must hold nothing
    /// beyond `base` either, so no commit can be under way on it. nil when it
    /// keeps its name.
    public static func renameBranch(
        _ exec: any Executor, worktree: String, from: String, suggestion: String, prefix: String,
        base: String?, allowCommits: Bool, hasPullRequest: @Sendable (String) async -> Bool
    ) async -> BranchRename? {
        await renameBranch(exec, worktree: worktree, from: from, suggestion: suggestion, prefix: prefix, base: base,
                           allowCommits: allowCommits, hasPullRequest: hasPullRequest, racing: nil)
    }

    /// `racing` runs straight after the rename, as a commit under way would (tests).
    static func renameBranch(
        _ exec: any Executor, worktree: String, from: String, suggestion: String, prefix: String,
        base: String?, allowCommits: Bool, hasPullRequest: @Sendable (String) async -> Bool,
        racing: (@Sendable () async -> Void)?
    ) async -> BranchRename? {
        guard WorktreeNaming.isRunBranch(from), let slug = WorktreeNaming.branchSlug(suggestion),
              "\(prefix)\(slug)" != from, await !hasPullRequest(from) else { return nil }
        func out(_ args: [String]) async -> String? {
            guard let r = try? await exec.run("git", args, cwd: worktree), r.ok else { return nil }
            return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func isEmpty(_ branch: String) async -> Bool {
            guard let base else { return false }
            return await out(["rev-list", "--count", "\(base)..refs/heads/\(branch)"]) == "0"
        }
        // Checked as close to the rename as git allows.
        if !allowCommits, await !isEmpty(from) { return nil }
        guard await out(["symbolic-ref", "--quiet", "--short", "HEAD"]) == from,
              await out(["config", "--get", "branch.\(from).remote"]) == nil,
              await !Git.branchExists(exec, root: worktree, branch: "refs/remotes/origin/\(from)"),
              let gitDir = await out(["rev-parse", "--absolute-git-dir"]),
              let commonDir = await out(["rev-parse", "--path-format=absolute", "--git-common-dir"]) else { return nil }
        let locks = [gitDir + "/index.lock", gitDir + "/HEAD.lock", commonDir + "/packed-refs.lock",
                     commonDir + "/refs/heads/\(from).lock"]
        guard !locks.contains(where: exec.fileExists) else { return nil }

        var name: String?
        for attempt in 0..<50 {
            let candidate = prefix + (attempt == 0 ? slug : "\(slug)-\(attempt)")
            if await Git.branchExists(exec, root: worktree, branch: "refs/heads/\(candidate)") { continue }
            name = candidate
            break
        }
        guard let name, await out(["branch", "-m", from, name]) != nil else { return nil }
        await racing?()

        // A commit that started before the rename may have written the old
        // name again. The chat follows HEAD; whichever name it isn't on goes,
        // if it holds nothing beyond the base.
        let head = await out(["symbolic-ref", "--quiet", "--short", "HEAD"])
        if let head, head == from || head == name {
            let leftover = head == name ? from : name
            if await Git.branchExists(exec, root: worktree, branch: "refs/heads/\(leftover)"), await isEmpty(leftover) {
                _ = await out(["branch", "-D", leftover])
            }
        }
        return BranchRename(name: name, head: head)
    }
}
