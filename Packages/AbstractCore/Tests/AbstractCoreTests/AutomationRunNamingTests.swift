import Foundation
import Testing
@testable import AbstractCore

@Suite struct AutomationRunNamingTests {
    @Test func aRunStartsNamedForItsAutomationAndIsRecognisedUntilRenamed() {
        let name = AutomationRunNaming.provisional("Roadmap: build the next ticket", at: Date(timeIntervalSince1970: 0))
        #expect(name.hasPrefix("Roadmap: build the next ticket · "))
        #expect(AutomationRunNaming.isProvisional(name, automationName: "Roadmap: build the next ticket"))
        #expect(!AutomationRunNaming.isProvisional("Show each worktree's diff stat", automationName: "Roadmap: build the next ticket"))
        #expect(!AutomationRunNaming.isProvisional(name, automationName: "Roadmap"))
    }

    @Test func theNamingCallReadsTheAgentsReport() {
        let task = AutomationRunNaming.task(fromReport: "Opened #42: Shows each worktree's diff stat (ABS-7).")
        #expect(task.hasSuffix("Opened #42: Shows each worktree's diff stat (ABS-7)."))
    }

    @Test func theReportIsTheAgentsLatestReply() {
        var t = Timeline()
        #expect(t.lastReply == nil)
        t.append(.text(role: .user, text: "Build the next ticket", blockId: nil, partial: false))
        #expect(t.lastReply == nil)
        t.append(.text(role: .assistant, text: "Taking ABS-7.", blockId: "m:0", partial: false))
        t.append(.toolUse(id: "a", name: "Bash", input: .object([:]), edit: nil))
        t.append(.text(role: .assistant, text: "Opened #42 for ABS-7.", blockId: "m:1", partial: false))
        t.append(.text(role: .assistant, text: "  ", blockId: "m:2", partial: false))
        #expect(t.lastReply == "Opened #42 for ABS-7.")
    }

    // MARK: Naming from the first reply

    @Test func aReplyTooShortToNameWaitsForTheNext() {
        #expect(!AutomationRunNaming.canName(fromReply: "Let me look."))
        #expect(!AutomationRunNaming.canName(fromReply: "  \n "))
        #expect(AutomationRunNaming.canName(fromReply: "I'll take ABS-51: the sidebar shows each worktree's diff stat."))
        let task = AutomationRunNaming.task(fromFirstReply: "I'll take ABS-51.")
        #expect(task.hasSuffix("I'll take ABS-51."))
        // Told it can't tell yet, the naming call answers with no title: no name, so the next reply is tried.
        #expect(ChatNaming.parse(#"{"type":"result","is_error":false,"result":"{\"title\": \"\", \"branch\": \"\"}"}"#) == nil)
        #expect(ChatNaming.parse(#"{"type":"result","is_error":false,"result":"{\"title\": \"Show diff stats\", \"branch\": \"feat/diff-stats\"}"}"#)
            == ChatNaming.Suggestion(title: "Show diff stats", branch: "feat/diff-stats"))
    }

    @Test func theRenameIsSaidQuietlyInTheChat() {
        let line = OutputLine(stream: .note, line: "Branch renamed to `fix/login-button`")
        let events = ChatStream(providerId: "claude").feed(line)
        #expect(events == [.notice(.info("Branch renamed to `fix/login-button`"))])
        var t = Timeline()
        t.append(contentsOf: events)
        #expect(t.blocks.count == 1)
        // Kept in the log like what you sent, so a relaunch shows it too.
        let data = try? JSONEncoder().encode(line)
        #expect(data.flatMap { try? JSONDecoder().decode(OutputLine.self, from: $0) } == line)
    }

    @Test func aRunBranchIsRecognisedUntilRenamed() {
        #expect(WorktreeNaming.isRunBranch("auto/nightly/2026-10-11-0900"))
        #expect(WorktreeNaming.isRunBranch("abstract/auto/nightly/2026-10-11-0900-2"))
        #expect(!WorktreeNaming.isRunBranch("feature-x"))
        #expect(!WorktreeNaming.isRunBranch("abs-51-diff-stats"))
        #expect(!WorktreeNaming.isRunBranch("auto-roadmap-build-the-next-ticket-20261-10"))
        #expect(!WorktreeNaming.isRunBranch("myauto/nightly/2026-10-11-0900"))
    }

    // MARK: Renaming the run's branch

    private let exec = LocalExecutor.shared
    private let run = "auto/nightly/2026-10-11-0900"

    private func git(_ cwd: String, _ args: [String]) async throws {
        let out = try await exec.run("git", args, cwd: cwd)
        try #require(out.ok, "git \(args) failed: \(out.stderr)")
    }

    private func branches(_ cwd: String) async throws -> Set<String> {
        let out = try await exec.run("git", ["for-each-ref", "--format=%(refname:short)", "refs/heads"], cwd: cwd)
        return Set(out.stdout.split(separator: "\n").map(String.init))
    }

    /// A worktree just set up on a run's branch, nothing committed on it yet.
    private func makeRun() async throws -> (dir: String, worktree: String) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("abstract-run-\(UUID().uuidString)").path
        let root = dir + "/repo", worktree = dir + "/wt"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try await git(root, ["init", "-q", "-b", "main"])
        try await git(root, ["config", "user.email", "test@abstract.local"])
        try await git(root, ["config", "user.name", "Abstract Test"])
        try await git(root, ["config", "commit.gpgsign", "false"])
        try await git(root, ["commit", "-q", "--allow-empty", "-m", "init"])
        try await git(root, ["worktree", "add", "-q", "-b", run, worktree])
        return (dir, worktree)
    }

    private func rename(_ worktree: String, from: String? = nil, to suggestion: String = "fix/Login button", prefix: String = "",
                        allowCommits: Bool = false, hasPullRequest: Bool = false,
                        racing: (@Sendable () async -> Void)? = nil) async -> AutomationRunNaming.BranchRename? {
        await AutomationRunNaming.renameBranch(exec, worktree: worktree, from: from ?? run, suggestion: suggestion, prefix: prefix,
                                               base: "main", allowCommits: allowCommits,
                                               hasPullRequest: { _ in hasPullRequest }, racing: racing)
    }

    @Test func anEmptyRunBranchIsRenamedFromTheFirstReply() async throws {
        let (dir, wt) = try await makeRun()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let renamed = await rename(wt, prefix: "abstract/")
        #expect(renamed == .init(name: "abstract/fix/login-button", head: "abstract/fix/login-button"))
        #expect(try await branches(wt) == ["main", "abstract/fix/login-button"])
    }

    @Test func aTakenNameGetsACounter() async throws {
        let (dir, wt) = try await makeRun()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try await git(wt, ["branch", "fix/login-button", "main"])
        #expect(await rename(wt)?.name == "fix/login-button-1")
    }

    @Test func commitsWaitForTheEndOfTheTurn() async throws {
        let (dir, wt) = try await makeRun()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try await git(wt, ["commit", "-q", "--allow-empty", "-m", "Work"])
        // While the agent may be committing, a branch with commits keeps its name…
        #expect(await rename(wt) == nil)
        #expect(try await Git.currentBranch(exec, root: wt) == run)
        // …and is renamed once the turn is over.
        #expect(await rename(wt, allowCommits: true)?.head == "fix/login-button")
    }

    @Test func aPushedRunBranchKeepsItsName() async throws {
        let (dir, wt) = try await makeRun()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try await git(dir, ["init", "-q", "--bare", dir + "/origin.git"])
        try await git(wt, ["remote", "add", "origin", dir + "/origin.git"])
        try await git(wt, ["push", "-q", "-u", "origin", run])
        #expect(await rename(wt, allowCommits: true) == nil)
        // Pushed without an upstream, origin's copy is enough.
        try await git(wt, ["branch", "--unset-upstream"])
        #expect(await rename(wt, allowCommits: true) == nil)
        #expect(try await Git.currentBranch(exec, root: wt) == run)
    }

    @Test func aRunBranchWithAPullRequestKeepsItsName() async throws {
        let (dir, wt) = try await makeRun()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        #expect(await rename(wt, allowCommits: true, hasPullRequest: true) == nil)
        #expect(try await Git.currentBranch(exec, root: wt) == run)
    }

    @Test func aHeldLockLeavesTheBranchAlone() async throws {
        let (dir, wt) = try await makeRun()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let gitDir = try await exec.run("git", ["rev-parse", "--absolute-git-dir"], cwd: wt).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        FileManager.default.createFile(atPath: gitDir + "/index.lock", contents: nil)
        #expect(await rename(wt) == nil)
        try FileManager.default.removeItem(atPath: gitDir + "/index.lock")
        #expect(await rename(wt)?.name == "fix/login-button")
    }

    @Test func aCommitRacingTheRenameLeavesNoStrayBranch() async throws {
        // The commit wrote the old name again while HEAD moved on: the chat stays on the new one.
        var (dir, wt) = try await makeRun()
        var tree = wt
        var renamed = await rename(wt, racing: { [exec, run, tree] in _ = try? await exec.run("git", ["branch", run, "main"], cwd: tree) })
        #expect(renamed == .init(name: "fix/login-button", head: "fix/login-button"))
        #expect(try await branches(wt) == ["main", "fix/login-button"])
        try? FileManager.default.removeItem(atPath: dir)

        // HEAD ended up on the old name: the chat follows it, and the new name goes.
        (dir, wt) = try await makeRun()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        tree = wt
        renamed = await rename(wt, racing: { [exec, run, tree] in
            _ = try? await exec.run("git", ["branch", run, "main"], cwd: tree)
            _ = try? await exec.run("git", ["symbolic-ref", "HEAD", "refs/heads/\(run)"], cwd: tree)
        })
        #expect(renamed == .init(name: "fix/login-button", head: run))
        #expect(try await branches(wt) == ["main", run])
    }

    @Test func aBranchTheAgentRenamedIsLeftAlone() async throws {
        let (dir, wt) = try await makeRun()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try await git(wt, ["branch", "-m", "abs-51-diff-stats"])
        #expect(await rename(wt, from: "abs-51-diff-stats", allowCommits: true) == nil)
        #expect(await rename(wt, allowCommits: true) == nil)
        #expect(try await Git.currentBranch(exec, root: wt) == "abs-51-diff-stats")
        #expect(await rename(wt, to: "!!!") == nil)
    }
}
