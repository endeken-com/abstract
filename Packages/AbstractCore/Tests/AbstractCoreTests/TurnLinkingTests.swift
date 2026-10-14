import Foundation
import Synchronization
import Testing
@testable import AbstractCore

/// Counts the git commands it runs, by their first argument.
private final class CountingExecutor: Executor {
    let base = LocalExecutor.shared
    let counts = Mutex<[String: Int]>([:])
    var homeDirectory: String { base.homeDirectory }

    func count(_ command: String) -> Int { counts.withLock { $0[command] ?? 0 } }
    func reset() { counts.withLock { $0.removeAll() } }

    func run(_ command: String, _ args: [String], cwd: String?, stdin: Data?) async throws -> ExecResult {
        counts.withLock { $0[args.first ?? command, default: 0] += 1 }
        return try await base.run(command, args, cwd: cwd, stdin: stdin)
    }
    func spawn(_ spec: LaunchSpec, onLine: @escaping @Sendable (OutputLine) -> Void,
               onExit: @escaping @Sendable (Int32?) -> Void) throws -> RunningProcess {
        try base.spawn(spec, onLine: onLine, onExit: onExit)
    }
    func fileExists(_ path: String) -> Bool { base.fileExists(path) }
    func readFile(_ path: String) throws -> String { try base.readFile(path) }
    func createDirectory(_ path: String) throws { try base.createDirectory(path) }
    func removeItem(_ path: String) throws { try base.removeItem(path) }
    func which(_ binary: String) async -> String? { await base.which(binary) }
}

/// A repository with a chat's worktree on its own branch, and the chat's log.
private struct ChatRepoFixture {
    let dir: String
    let repo: String
    let worktree: String
    let store: Store
    let engine: SessionEngine
    let recorder: TurnRecorder
    var session: Session
    let exec = LocalExecutor.shared

    static func make(branch: String = "feature/abs-62") async throws -> ChatRepoFixture {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("turns-\(UUID().uuidString)").path
        let repo = dir + "/repo", worktree = dir + "/wt"
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        let store = try Store.inMemory()
        let engine = SessionEngine(executor: LocalExecutor.shared, logDirectory: URL(fileURLWithPath: dir + "/logs"))
        let session = Session(projectId: "p1", name: "Add a and b", providerId: "claude", worktreePath: worktree, branch: branch)
        var f = ChatRepoFixture(dir: dir, repo: repo, worktree: worktree, store: store, engine: engine,
                                recorder: TurnRecorder(store: store), session: session)
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "test@abstract.local"],
                     ["config", "user.name", "Abstract Test"], ["config", "commit.gpgsign", "false"]] {
            try await f.git(repo, args)
        }
        try f.write(repo + "/base.txt", (1...5).map { "base \($0)\n" }.joined())
        try await f.git(repo, ["add", "-A"])
        try await f.git(repo, ["commit", "-qm", "Start"])
        try await f.git(repo, ["worktree", "add", "-q", "-b", branch, worktree, "main"])
        f.session.worktreePath = worktree
        return f
    }

    func remove() { try? FileManager.default.removeItem(atPath: dir) }

    @discardableResult
    func git(_ cwd: String, _ args: [String]) async throws -> String {
        let out = try await exec.run("git", args, cwd: cwd)
        try #require(out.ok, "git \(args) failed: \(out.stderr)")
        return out.stdout
    }

    func head(_ cwd: String) async throws -> String { GitText.trimmed(try await git(cwd, ["rev-parse", "HEAD"])) }

    func write(_ path: String, _ text: String) throws { try text.write(toFile: path, atomically: true, encoding: .utf8) }

    func log(_ lines: OutputLine...) { for line in lines { engine.record(sessionId: session.id, line) } }

    /// Starts a turn, as the chat going to work does.
    func begin() async { _ = await recorder.begin(session.id, worktree: worktree, exec: exec)?.value }

    /// A turn in which the agent writes `file` in the worktree, commits it when `commit`, and ends.
    @discardableResult
    func turn(_ request: String, writes file: String, commit: Bool) async throws -> TurnRecord {
        await begin()
        log(ClaudeTurnLines.user(request), ClaudeTurnLines.write(UUID().uuidString, path: worktree + "/" + file))
        try write(worktree + "/" + file, request + "\n")
        if commit {
            try await git(worktree, ["add", "-A"])
            try await git(worktree, ["commit", "-qm", request])
        }
        log(ClaudeTurnLines.end)
        return try #require(await recorder.end(session, engine: engine, exec: exec))
    }
}

extension GitHeavy {
    @Suite("Turn records and links", .serialized)
    struct TurnLinkingTests {
        @Test func aTurnThatCommitsTwiceListsBothCommitsItsFilesAndItsCorrection() async throws {
            let f = try await ChatRepoFixture.make()
            defer { f.remove() }
            try f.write(f.worktree + "/old.txt", "left from before\n")
            await f.begin()
            f.log(ClaudeTurnLines.user("Add a"), ClaudeTurnLines.write("t1", path: f.worktree + "/a.txt"))
            try f.write(f.worktree + "/a.txt", "a\n")
            try await f.git(f.worktree, ["add", "a.txt"])
            try await f.git(f.worktree, ["commit", "-qm", "Add a"])
            let first = try await f.head(f.worktree)
            f.log(ClaudeTurnLines.user("Also b, and fix the base"))
            // Changed by a shell command: no edit names it, git does.
            try f.write(f.worktree + "/b.txt", "b\n")
            try f.write(f.worktree + "/base.txt", "rewritten\n")
            try await f.git(f.worktree, ["add", "b.txt", "base.txt"])
            try await f.git(f.worktree, ["commit", "-qm", "Add b"])
            let second = try await f.head(f.worktree)
            f.log(ClaudeTurnLines.summary("Added a and b"), ClaudeTurnLines.end)

            let turn = try #require(await f.recorder.end(f.session, engine: f.engine, exec: f.exec))
            #expect(turn.number == 1)
            #expect(turn.request == "Add a")
            #expect(turn.corrections == ["Also b, and fix the base"])
            #expect(turn.summary == "Added a and b")
            #expect(turn.files == ["a.txt", "b.txt", "base.txt"], "old.txt was already there, untouched")
            #expect(turn.uncommitted.isEmpty)
            #expect(turn.headAfter == second)
            #expect(turn.branch == "feature/abs-62")
            #expect(turn.ticket == "ABS-62")
            #expect(turn.logStart == 1 && turn.logEnd == f.engine.logLength(sessionId: f.session.id))
            let commits = try f.store.commits(turnId: turn.id)
            #expect(commits.map(\.sha) == [first, second])
            #expect(commits.allSatisfy { $0.link == .turn && $0.patchId != nil })

            // The next turn starts where this one ended.
            let next = try await f.turn("Add c", writes: "c.txt", commit: false)
            #expect(next.number == 2)
            #expect(next.headBefore == second)
            #expect(next.logStart == turn.logEnd + 1)
            #expect(next.files == ["c.txt"] && next.uncommitted == ["c.txt"])
        }

        @Test func aTurnInWhichNothingHappenedIsNotRecorded() async throws {
            let f = try await ChatRepoFixture.make()
            defer { f.remove() }
            await f.begin()
            f.log(OutputLine(stream: .note, line: "Reconnected"))
            #expect(await f.recorder.end(f.session, engine: f.engine, exec: f.exec) == nil)
        }

        @Test func theCommitButtonsCommitBelongsToTheTurnsThatLeftItsFiles() async throws {
            let f = try await ChatRepoFixture.make()
            defer { f.remove() }
            let committed = try await f.turn("Add a", writes: "a.txt", commit: true)
            let left = try await f.turn("Add b", writes: "b.txt", commit: false)
            let other = try await f.turn("Add c", writes: "c.txt", commit: false)
            let before = try await f.head(f.worktree)
            try await f.git(f.worktree, ["add", "b.txt"])
            try await f.git(f.worktree, ["commit", "-qm", "Commit b"])
            await f.recorder.linkCommitted(f.session.id, exec: f.exec, worktree: f.worktree, from: before)
            let sha = try await f.head(f.worktree)
            let found = try f.store.turns(commit: sha)
            #expect(found.map(\.turn.id) == [left.id], "not \(committed.number), which committed its own, nor \(other.number)")
            #expect(found.first?.link == .commitButton)
        }

        @Test func aMergeCommitOnTheBaseBranchLeadsBackToTheChat() async throws {
            let f = try await ChatRepoFixture.make()
            defer { f.remove() }
            let a = try await f.turn("Add a", writes: "a.txt", commit: true)
            let b = try await f.turn("Add b", writes: "b.txt", commit: true)
            try await f.git(f.repo, ["merge", "-q", "--no-ff", "feature/abs-62", "-m", "Merge pull request #7 from owner/feature/abs-62"])
            let merge = try await f.head(f.repo)
            let history = TurnHistory(store: f.store, projectId: "p1")
            let origin = try #require(await history.origin(of: merge, exec: f.exec, repo: f.repo))
            #expect(origin.turns.map(\.id) == [a.id, b.id])
            #expect(origin.link == .merge)
            #expect(origin.pullRequest == 7)
            #expect(try f.store.turns(commit: merge).count == 2, "saved, so the next lookup finds it straight away")

            // As Abstract sees the pull request merge on GitHub.
            let other = try await ChatRepoFixture.make()
            defer { other.remove() }
            let turn = try await other.turn("Add z", writes: "z.txt", commit: true)
            other.recorder.linkMerge(other.session.id, number: 12, sha: "f00d")
            #expect(try other.store.turns(commit: "f00d").map(\.link) == [.merge])
            #expect(try other.store.turnRecord(turn.id)?.pullRequest == 12)
        }

        @Test func aSquashMergeLeadsBackThroughItsPullRequestNumber() async throws {
            let f = try await ChatRepoFixture.make(branch: "feature/squashed")
            defer { f.remove() }
            let a = try await f.turn("Add a", writes: "a.txt", commit: true)
            let b = try await f.turn("Add b", writes: "b.txt", commit: true)
            try await f.git(f.repo, ["merge", "-q", "--squash", "feature/squashed"])
            try await f.git(f.repo, ["commit", "-qm", "Add a and b (#43)"])
            let squash = try await f.head(f.repo)
            let history = TurnHistory(store: f.store, projectId: "p1")

            // No turn knows its pull request yet: GitHub's list names its branch.
            let pullRequests = [42: "feature/elsewhere", 43: "feature/squashed"]
            let origin = try #require(await history.origin(of: squash, exec: f.exec, repo: f.repo, pullRequests: pullRequests))
            #expect(origin.turns.map(\.id) == [a.id, b.id])
            #expect(origin.link == .squash)
            #expect(origin.pullRequest == 43)

            // Once the turns know it, the number alone does.
            let again = try await ChatRepoFixture.make(branch: "feature/known")
            defer { again.remove() }
            let turn = try await again.turn("Add a", writes: "a.txt", commit: true)
            again.recorder.notePullRequest(again.session.id, number: 44, body: "Fixes ABS-9", branch: again.session.branch)
            try await again.git(again.repo, ["merge", "-q", "--squash", "feature/known"])
            try await again.git(again.repo, ["commit", "-qm", "Add a (#44)"])
            let found = await TurnHistory(store: again.store, projectId: "p1")
                .origin(of: try await again.head(again.repo), exec: again.exec, repo: again.repo)
            #expect(found?.turns.map(\.id) == [turn.id])
            #expect(try again.store.turnRecord(turn.id)?.ticket == "ABS-9", "the ticket its pull request fixes")
        }

        @Test func aRebasedCommitStillMapsToItsTurn() async throws {
            let f = try await ChatRepoFixture.make()
            defer { f.remove() }
            let turn = try await f.turn("Add a", writes: "a.txt", commit: true)
            let original = try await f.head(f.worktree)
            try f.write(f.repo + "/main.txt", "main moved on\n")
            try await f.git(f.repo, ["add", "-A"])
            try await f.git(f.repo, ["commit", "-qm", "Meanwhile on main"])
            try await f.git(f.worktree, ["rebase", "-q", "main"])
            let rebased = try await f.head(f.worktree)
            #expect(rebased != original)
            let origin = try #require(await TurnHistory(store: f.store, projectId: "p1").origin(of: rebased, exec: f.exec, repo: f.repo))
            #expect(origin.turns.map(\.id) == [turn.id])
            #expect(origin.link == .patch)

            // A cherry-pick onto main, too.
            try await f.git(f.repo, ["cherry-pick", "-x", original])
            let picked = try await f.head(f.repo)
            #expect(await TurnHistory(store: f.store, projectId: "p1").origin(of: picked, exec: f.exec, repo: f.repo)?.turns.map(\.id) == [turn.id])
        }

        @Test func aCommitNoChatMadeNamesItsAuthor() async throws {
            let f = try await ChatRepoFixture.make()
            defer { f.remove() }
            try await f.turn("Add a", writes: "a.txt", commit: true)
            try f.write(f.repo + "/hand.txt", "by hand\n")
            try await f.git(f.repo, ["add", "-A"])
            try await f.git(f.repo, ["commit", "-qm", "Made by hand"])
            let origin = try #require(await TurnHistory(store: f.store, projectId: "p1").origin(of: try await f.head(f.repo), exec: f.exec, repo: f.repo))
            #expect(origin.turns.isEmpty)
            #expect(origin.link == nil)
            #expect(origin.author == "Abstract Test")
            #expect(origin.subject == "Made by hand")
        }

        @Test func blameMapsLinesToTheirTurnsAndRemembersEachCommit() async throws {
            let f = try await ChatRepoFixture.make()
            defer { f.remove() }
            let a = try await f.turn("Add a", writes: "a.txt", commit: true)
            await f.begin()
            f.log(ClaudeTurnLines.user("Add more to a"), ClaudeTurnLines.write("t9", path: f.worktree + "/a.txt"))
            try f.write(f.worktree + "/a.txt", "Add a\nmore\n")
            try await f.git(f.worktree, ["commit", "-qam", "More a"])
            f.log(ClaudeTurnLines.end)
            let more = try #require(await f.recorder.end(f.session, engine: f.engine, exec: f.exec))
            try f.write(f.worktree + "/a.txt", "Add a\nmore\nnot committed\n")

            let exec = CountingExecutor()
            let history = TurnHistory(store: f.store, projectId: "p1")
            let lines = try await history.blame("a.txt", lines: 1...2, revision: "HEAD", exec: exec, repo: f.worktree)
            #expect(lines.map(\.lines) == [1...1, 2...2])
            #expect(lines.map { $0.turns.map(\.id) } == [[a.id], [more.id]])
            #expect(lines.last?.turns.first?.request == "Add more to a")
            #expect(history.cachedCommits.count == 2)
            let looked = exec.count("log")
            #expect(looked > 0)

            exec.reset()
            let again = try await history.blame("a.txt", lines: 1...2, revision: "HEAD", exec: exec, repo: f.worktree)
            #expect(again.map { $0.turns.map(\.id) } == [[a.id], [more.id]])
            #expect(exec.count("blame") == 1)
            #expect(exec.count("log") == 0, "each commit is worked out once")

            // Lines not committed yet have no commit.
            let mine = try await TurnHistory(store: f.store, projectId: "p1")
                .blame("a.txt", lines: 3...3, revision: nil, exec: f.exec, repo: f.worktree)
            #expect(mine.count == 1 && mine.first?.commit == nil)
        }

        @Test func backfillRecordsAnOldChatsTurnsFromItsLog() async throws {
            let f = try await ChatRepoFixture.make()
            defer { f.remove() }
            try f.write(f.worktree + "/a.txt", "a\n")
            try await f.git(f.worktree, ["add", "-A"])
            try await f.git(f.worktree, ["commit", "-qm", "Add a"])
            let sha = try await f.head(f.worktree)
            let short = String(sha.prefix(7))
            f.log(ClaudeTurnLines.user("Add a"), ClaudeTurnLines.write("t1", path: f.worktree + "/a.txt"),
                  ClaudeTurnLines.bash("t2", command: "git commit -am 'Add a'"),
                  ClaudeTurnLines.result("t2", "[feature/abs-62 \(short)] Add a\\n 1 file changed"), ClaudeTurnLines.end,
                  ClaudeTurnLines.user("Open its pull request"), ClaudeTurnLines.bash("t3", command: "gh pr create"),
                  ClaudeTurnLines.result("t3", "https://github.com/owner/repo/pull/50"), ClaudeTurnLines.end)
            let records = await HistoryBackfill.backfill(f.session, lines: f.engine.replay(sessionId: f.session.id),
                                                         store: f.store, exec: f.exec, repo: f.repo)
            #expect(records.map(\.number) == [1, 2])
            #expect(try f.store.turns(commit: sha).map(\.turn.request) == ["Add a"])
            #expect(try f.store.turnRecords(sessionId: f.session.id).map(\.pullRequest) == [50, 50])
            #expect(await HistoryBackfill.backfill(f.session, lines: f.engine.replay(sessionId: f.session.id),
                                                   store: f.store, exec: f.exec, repo: f.repo).isEmpty, "only once")

            // How much of main leads back to a turn.
            try await f.git(f.repo, ["merge", "-q", "--no-ff", "feature/abs-62", "-m", "Merge pull request #50 from owner/feature/abs-62"])
            try f.write(f.repo + "/hand.txt", "by hand\n")
            try await f.git(f.repo, ["add", "-A"])
            try await f.git(f.repo, ["commit", "-qm", "By hand"])
            let coverage = try await HistoryCoverage.measure(TurnHistory(store: f.store, projectId: "p1"), exec: f.exec, repo: f.repo,
                                                             ref: "main", since: "2000-01-01", pullRequests: [:])
            #expect(coverage.commits == 4)
            #expect(coverage.mapped == [.turn: 1, .merge: 1])
            #expect(coverage.misses.map(\.subject).sorted() == ["By hand", "Start"])
            #expect(coverage.report.hasPrefix("2 of 4 commits map to a turn (50%)."))
        }
    }
}
