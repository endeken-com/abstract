import Foundation
import Testing
@testable import AbstractCore

/// The Review tab's refresh: a cheap look before each full read, reloads
/// merged and spaced out, and only the file events that matter.
@Suite("Review refresh", .serialized)
struct ReviewRefreshTests {
    // MARK: The cheap look

    @Test func nothingChangedLooksTheSameAndOnlyAsksForStatus() async throws {
        let f = try await SubmoduleFixture.make()
        defer { f.remove() }
        try f.write(f.worktree + "/a.txt", "changed\n")
        let exec = RecordingExecutor()
        let first = try #require(await WorktreeSnapshot.take(exec, worktree: f.worktree))
        let second = try #require(await WorktreeSnapshot.take(exec, worktree: f.worktree))
        #expect(first == second)
        let commands = exec.calls(in: f.worktree).map { $0.first(where: { !$0.hasPrefix("-") }) ?? "" }
        #expect(Set(commands) == ["status"])
    }

    @Test func editingAFileAlreadyChangedChangesTheLook() async throws {
        let f = try await SubmoduleFixture.make()
        defer { f.remove() }
        let file = f.worktree + "/a.txt"
        try f.write(file, "changed\n")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -60)], ofItemAtPath: file)
        let before = await WorktreeSnapshot.take(f.exec, worktree: f.worktree)
        // git's status line for it stays the same: only its size and age tell.
        try f.write(file, "changed again\n")
        let after = await WorktreeSnapshot.take(f.exec, worktree: f.worktree)
        #expect(before != nil)
        #expect(before != after)
    }

    @Test func aCommitChangesTheLook() async throws {
        let f = try await SubmoduleFixture.make()
        defer { f.remove() }
        try f.write(f.worktree + "/a.txt", "changed\n")
        let before = await WorktreeSnapshot.take(f.exec, worktree: f.worktree)
        try await f.git(f.worktree, ["commit", "-qam", "Change a"])
        let after = await WorktreeSnapshot.take(f.exec, worktree: f.worktree)
        #expect(before != after)
        // Committed and clean again: no file lines left, only the new HEAD.
        #expect(after?.lines.contains { $0.hasPrefix("# branch.oid ") } == true)
    }

    @Test func theFullReadsOwnAddNDoesntChangeTheLook() async throws {
        let f = try await SubmoduleFixture.make()
        defer { f.remove() }
        try f.write(f.worktree + "/new.txt", "new\n")
        let before = await WorktreeSnapshot.take(f.exec, worktree: f.worktree)
        _ = try await Diff.collect(f.exec, worktree: f.worktree)
        let after = await WorktreeSnapshot.take(f.exec, worktree: f.worktree)
        #expect(before != nil)
        #expect(before == after)
    }

    @Test func workInASubmoduleIsLookedIntoThereOnly() async throws {
        let f = try await SubmoduleFixture.make()
        defer { f.remove() }
        let file = f.worktree + "/libs/core/a.txt"
        try f.write(file, "changed\n")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -60)], ofItemAtPath: file)
        let exec = RecordingExecutor()
        let before = await WorktreeSnapshot.take(exec, worktree: f.worktree)
        #expect(!exec.calls(in: f.worktree + "/libs/core").isEmpty)
        #expect(exec.calls(in: f.worktree + "/libs/other lib").isEmpty)
        #expect(exec.calls(in: f.worktree + "/libs/core/vendor/deep").isEmpty)
        try f.write(file, "changed again\n")
        #expect(await WorktreeSnapshot.take(exec, worktree: f.worktree) != before)
    }

    @Test func gitThatCantSayGivesNoLook() async {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("abstract-none-\(UUID().uuidString)").path
        #expect(await WorktreeSnapshot.take(LocalExecutor.shared, worktree: missing) == nil)
    }

    @Test func statusRecordsAreParsed() {
        let output = [
            "# branch.oid abc", "# branch.head chat",
            "1 .M N... 100644 100644 100644 aaa aaa src/a b.swift",
            "1 .D N... 100644 100644 000000 aaa aaa gone.swift",
            "1 .A N... 000000 000000 100644 000 000 new.swift",
            "2 R. N... 100644 100644 100644 aaa aaa R100 to.swift", "from.swift",
            "1 .M S.M. 160000 160000 160000 ccc ccc libs/core",
            "1 .M SC.. 160000 160000 160000 ccc ccc libs/moved",
            "1 M. S... 160000 160000 160000 ccc ddd libs/staged",
            "? notes.md",
        ].joined(separator: "\u{0}") + "\u{0}"
        let entries = WorktreeSnapshot.parse(output)
        #expect(entries.map(\.file) == [nil, nil, "src/a b.swift", nil, "new.swift", "to.swift", nil, nil, nil, "notes.md"])
        #expect(entries.compactMap(\.changedSubmodule) == ["libs/core", "libs/moved"])
        #expect(entries[4].line == "? new.swift")
        #expect(entries[5].line.hasSuffix("to.swift\u{0}from.swift"))
    }

    // MARK: Which events count

    @Test func onlyRefsAndHeadsCountInAGitFolder() {
        let git = "/p/.git/worktrees/chat"
        let refs = "/p/.git/refs"
        func matters(_ path: String) -> Bool { ReviewWatch.matters(path, gitDir: git, refs: refs) }
        #expect(matters("/wt/src/a.swift"))
        #expect(matters(git + "/HEAD"))
        #expect(matters(git + "/MERGE_HEAD"))
        #expect(matters(git + "/REBASE_HEAD"))
        #expect(matters(refs + "/heads/chat"))
        #expect(matters(git + "/modules/libs/core/refs/heads/main"))
        #expect(!matters(git + "/index"))
        #expect(!matters(git + "/FETCH_HEAD"))
        #expect(!matters(git + "/logs/HEAD"))
        #expect(!matters(refs + "/heads/chat.lock"))
        #expect(!matters(git + "/modules/libs/core/index"))
        // A checkout's own .git inside the worktree.
        #expect(matters("/wt/.git/HEAD"))
        #expect(!matters("/wt/.git/index"))
        #expect(!matters("/wt/.git/FETCH_HEAD"))
    }

    // MARK: Which list it shows

    @Test func itLeavesAListOnlyOnceThatListIsEmpty() {
        func follows(_ showing: Bool?, dirty: Bool, base: Bool = true, commits: Bool) -> Bool {
            RepoReview.followsCommitted(showingCommitted: showing, dirty: dirty, hasBase: base, hasCommits: commits)
        }
        // First load: the uncommitted work while there is some.
        #expect(!follows(nil, dirty: true, commits: true))
        #expect(follows(nil, dirty: false, commits: true))
        #expect(!follows(nil, dirty: false, base: false, commits: false))
        // Uncommitted: the agent commits part of it, the rest stays in view.
        #expect(!follows(false, dirty: true, commits: true))
        #expect(follows(false, dirty: false, commits: true))
        // Committed: the agent starts writing again, the commits stay in view.
        #expect(follows(true, dirty: true, commits: true))
        #expect(!follows(true, dirty: true, commits: false))
    }

    // MARK: Keeping your place

    @Test func unchangedFilesKeepWhatWasPrepared() {
        func file(_ path: String, _ blob: String) -> FileDiff {
            FileDiff(path: path, additions: 1, rawHeader: "diff --git a/\(path) b/\(path)\nindex 000..\(blob)")
        }
        struct Prepared { let diff: FileDiff; let stamp: Int }
        let previous = [Prepared(diff: file("a", "1"), stamp: 1), Prepared(diff: file("b", "1"), stamp: 2)]
        let kept = RepoReview.unchanged([file("a", "1"), file("b", "2"), file("c", "1")], previous: previous, diff: \.diff)
        #expect(kept.mapValues(\.stamp) == ["a": 1])
    }

    @Test func theSelectionStaysOnItsFile() {
        #expect(RepoReview.selection("b", before: ["a", "b", "c"], after: ["c", "b"]) == "b")
        // Gone: the file now where it was.
        #expect(RepoReview.selection("b", before: ["a", "b", "c"], after: ["a", "c"]) == "c")
        #expect(RepoReview.selection("c", before: ["a", "b", "c"], after: ["a"]) == "a")
        #expect(RepoReview.selection(nil, before: [], after: ["a"]) == "a")
        #expect(RepoReview.selection("a", before: ["a"], after: []) == nil)
    }

    // MARK: When it reloads

    @Test func onlyTheEndOfATurnReloads() {
        #expect(SessionStatus.endsTurn(from: .running, to: .idle))
        #expect(SessionStatus.endsTurn(from: .running, to: .finished))
        #expect(SessionStatus.endsTurn(from: .waitingInput, to: .errored))
        #expect(!SessionStatus.endsTurn(from: .idle, to: .running))
        #expect(!SessionStatus.endsTurn(from: .running, to: .waitingInput))
        #expect(!SessionStatus.endsTurn(from: .waitingInput, to: .running))
        #expect(!SessionStatus.endsTurn(from: .idle, to: .idle))
    }

    @MainActor @Test func triggersWhileOneWaitsJoinIt() async throws {
        let queue = ReloadQueue(delay: .milliseconds(50))
        let probe = Probe(blocking: false)
        for _ in 0..<40 { queue.soon { await probe.work() } }
        try await probe.until { probe.runs == 1 }
        try await Task.sleep(for: .milliseconds(150))
        #expect(probe.runs == 1)
    }

    @MainActor @Test func atMostOneWaitsBehindTheOneRunning() async throws {
        let queue = ReloadQueue(delay: .milliseconds(10))
        let probe = Probe(blocking: true)
        queue.soon { await probe.work() }
        try await probe.until { probe.runs == 1 }
        // The agent keeps writing while the first read runs.
        for _ in 0..<40 {
            queue.soon { await probe.work() }
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(probe.runs == 1)
        probe.open()
        try await probe.until { probe.runs == 2 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(probe.runs == 2)
        #expect(probe.mostAtOnce == 1)
    }

    @MainActor @Test func nowSkipsTheWaitAndFoldsInTheOneWaiting() async throws {
        let queue = ReloadQueue(delay: .seconds(30))
        let probe = Probe(blocking: false)
        queue.soon { await probe.work() }
        await queue.now { await probe.work() }
        #expect(probe.runs == 1)
        try await Task.sleep(for: .milliseconds(50))
        #expect(probe.runs == 1)
    }
}

/// A reload that counts its runs and can be held until released.
@MainActor
private final class Probe {
    private(set) var runs = 0
    private(set) var mostAtOnce = 0
    private var active = 0
    private var blocking: Bool
    private var held: [CheckedContinuation<Void, Never>] = []

    init(blocking: Bool) { self.blocking = blocking }

    func work() async {
        runs += 1
        active += 1
        mostAtOnce = max(mostAtOnce, active)
        if blocking { await withCheckedContinuation { held.append($0) } }
        active -= 1
    }

    func open() {
        blocking = false
        held.forEach { $0.resume() }
        held = []
    }

    func until(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            try #require(ContinuousClock.now < deadline, "timed out")
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
