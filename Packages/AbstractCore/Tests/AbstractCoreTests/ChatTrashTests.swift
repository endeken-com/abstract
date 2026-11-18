import Foundation
import Testing
@testable import AbstractCore

/// A throwaway repository with linked worktrees under a stand-in for
/// `~/.abstract/worktrees`, and a trash beside it. Nothing outside it is touched.
struct TrashFixture {
    let dir: URL
    var repo: String { dir.appendingPathComponent("repo").path }
    var worktrees: URL { dir.appendingPathComponent("worktrees", isDirectory: true) }
    var trash: URL { dir.appendingPathComponent("trash", isDirectory: true) }
    let exec = LocalExecutor.shared

    static func make() async throws -> TrashFixture {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("trash-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let f = TrashFixture(dir: URL(fileURLWithPath: ChatTrash.resolved(dir.deletingLastPathComponent().path)).appendingPathComponent(dir.lastPathComponent))
        try FileManager.default.createDirectory(atPath: f.repo, withIntermediateDirectories: true)
        try await f.git(f.repo, ["init", "-q", "-b", "main"])
        try "hello\n".write(toFile: f.repo + "/README", atomically: true, encoding: .utf8)
        try await f.git(f.repo, ["add", "."])
        try await f.git(f.repo, ["-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-qm", "first"])
        return f
    }

    @discardableResult
    func git(_ cwd: String, _ args: [String]) async throws -> String {
        let r = try await exec.run("/usr/bin/git", args, cwd: cwd, stdin: nil)
        guard r.ok else { throw AbstractError.message("git \(args.joined(separator: " ")): \(r.stderr)") }
        return r.stdout
    }

    /// A linked worktree on a new branch at `worktrees/repo-x/<name>`, or `at` elsewhere.
    func addWorktree(_ name: String, at: String? = nil) async throws -> String {
        let path = at ?? worktrees.appendingPathComponent("repo-x/\(name)").path
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try await git(repo, ["worktree", "add", "-q", "-b", name, path])
        return path
    }

    func listed() async throws -> [String] {
        try await Git.worktrees(exec, root: repo).map { ChatTrash.resolved($0.path) }
    }

    func branchExists(_ name: String) async -> Bool {
        await Git.branchExists(exec, root: repo, branch: "refs/heads/\(name)")
    }

    func job(_ id: String, _ path: String, branch: String? = nil, deleteBranch: Bool = false, teardown: String? = nil) -> ChatTrash.Job {
        ChatTrash.Job(chatId: id, path: path, projectRoot: repo, branch: branch, deleteBranch: deleteBranch, teardownScript: teardown)
    }

    func run(_ job: ChatTrash.Job, limit: Duration = ChatTrash.teardownLimit) async -> (outcome: ChatTrash.Outcome, teardown: String?) {
        await ChatTrash.run(job, exec: exec, home: dir.path, trash: trash, roots: [worktrees], teardownLimit: limit)
    }

    func remove() { try? FileManager.default.removeItem(at: dir) }
}

extension GitHeavy {
    @Suite("Chat trash", .serialized)
    struct ChatTrashTests {
        @Test func renamingToTrashThenPruningLeavesNoWorktreeEntry() async throws {
            let f = try await TrashFixture.make()
            defer { f.remove() }
            let path = try await f.addWorktree("chat-1")
            #expect(try await f.listed().contains(ChatTrash.resolved(path)))

            let (outcome, teardown) = await f.run(f.job("c1", path, branch: "chat-1"))
            guard case .trashed(let moved) = outcome else { Issue.record("not trashed: \(outcome)"); return }
            #expect(teardown == nil)
            #expect(!FileManager.default.fileExists(atPath: path))
            #expect(moved.deletingLastPathComponent().path == f.trash.path)
            #expect(try await !f.listed().contains(ChatTrash.resolved(path)))
            #expect(await f.branchExists("chat-1"), "the branch stays unless asked")
            #expect(FileManager.default.fileExists(atPath: f.repo + "/README"), "the checkout is untouched")

            #expect(await ChatTrash.purge(moved, trash: f.trash))
            #expect(!FileManager.default.fileExists(atPath: moved.path))
        }

        @Test func theBranchGoesOnlyWhenAsked() async throws {
            let f = try await TrashFixture.make()
            defer { f.remove() }
            let path = try await f.addWorktree("chat-2")
            _ = await f.run(f.job("c2", path, branch: "chat-2", deleteBranch: true))
            #expect(await !f.branchExists("chat-2"))
        }

        @Test func theTeardownRunsInTheWorktreeFirst() async throws {
            let f = try await TrashFixture.make()
            defer { f.remove() }
            let path = try await f.addWorktree("chat-3")
            let marker = f.dir.appendingPathComponent("ran").path
            let (outcome, teardown) = await f.run(f.job("c3", path, teardown: "pwd -P > '\(marker)'"))
            #expect(teardown == nil)
            #expect(try String(contentsOfFile: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) == ChatTrash.resolved(f.worktrees.path) + "/repo-x/chat-3")
            if case .trashed = outcome {} else { Issue.record("not trashed: \(outcome)") }
        }

        @Test func aTeardownPastItsLimitIsStoppedAndTheWorktreeStillGoes() async throws {
            let f = try await TrashFixture.make()
            defer { f.remove() }
            let path = try await f.addWorktree("chat-4")
            let clock = ContinuousClock()
            let start = clock.now
            let (outcome, teardown) = await f.run(f.job("c4", path, teardown: "sleep 30"), limit: .milliseconds(500))
            #expect(clock.now - start < .seconds(10))
            #expect(teardown?.hasPrefix("Teardown script stopped after") == true)
            if case .trashed = outcome {} else { Issue.record("not trashed: \(outcome)") }
            #expect(!FileManager.default.fileExists(atPath: path))
        }

        @Test func theProjectsCheckoutIsNeverTouched() async throws {
            let f = try await TrashFixture.make()
            defer { f.remove() }
            let (outcome, _) = await f.run(f.job("c5", f.repo))
            if case .left = outcome {} else { Issue.record("checkout moved: \(outcome)") }
            #expect(FileManager.default.fileExists(atPath: f.repo + "/README"))
            #expect(ChatTrash.worktreeRefusal(f.repo, projectRoot: f.repo, roots: [f.dir]) != nil)
        }

        @Test func aSymlinkIsNeverFollowed() async throws {
            let f = try await TrashFixture.make()
            defer { f.remove() }
            let path = try await f.addWorktree("chat-6")
            let outside = f.dir.appendingPathComponent("precious").path
            try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
            try "keep".write(toFile: outside + "/file", atomically: true, encoding: .utf8)
            // A link inside the worktree goes with it; what it points to stays.
            try FileManager.default.createSymbolicLink(atPath: path + "/link", withDestinationPath: outside)
            // A link standing in for a worktree is refused.
            let fake = f.worktrees.appendingPathComponent("repo-x/fake").path
            try FileManager.default.createSymbolicLink(atPath: fake, withDestinationPath: path)
            let (refused, _) = await f.run(f.job("fake", fake))
            if case .left = refused {} else { Issue.record("a symlink was moved: \(refused)") }
            #expect(FileManager.default.fileExists(atPath: path))

            let (outcome, _) = await f.run(f.job("c6", path))
            guard case .trashed(let moved) = outcome else { Issue.record("not trashed: \(outcome)"); return }
            #expect(await ChatTrash.purge(moved, trash: f.trash))
            #expect(FileManager.default.fileExists(atPath: outside + "/file"))
        }

        @Test func aWorktreeOutsideAbstractsFolderIsLeftToGit() async throws {
            let f = try await TrashFixture.make()
            defer { f.remove() }
            let path = try await f.addWorktree("chat-7", at: f.dir.appendingPathComponent("elsewhere/chat-7").path)
            #expect(ChatTrash.worktreeRefusal(path, projectRoot: f.repo, roots: [f.worktrees]) == ChatTrash.outsideRoots)
            let (outcome, _) = await f.run(f.job("c7", path))
            #expect(outcome == .removed)
            #expect(try await !f.listed().contains(ChatTrash.resolved(path)))
            #expect(ChatTrash.leftovers(trash: f.trash).isEmpty, "git removed it in place")
        }

        @Test func aFolderGitDoesntListIsLeftAlone() async throws {
            let f = try await TrashFixture.make()
            defer { f.remove() }
            let stray = f.worktrees.appendingPathComponent("repo-x/stray").path
            try FileManager.default.createDirectory(atPath: stray, withIntermediateDirectories: true)
            try "gitdir: nowhere\n".write(toFile: stray + "/.git", atomically: true, encoding: .utf8)
            let (outcome, _) = await f.run(f.job("c8", stray))
            if case .left = outcome {} else { Issue.record("an unlisted folder was moved: \(outcome)") }
            #expect(FileManager.default.fileExists(atPath: stray))
        }

        @Test func aStandaloneChatsFolderGoesButNoOtherFolder() async throws {
            let f = try await TrashFixture.make()
            defer { f.remove() }
            guard ProcessInfo.processInfo.environment["ABSTRACT_DATA_DIR"] == nil else { return }
            let folder = f.dir.appendingPathComponent(".abstract/chats/lisbon").path
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            #expect(ChatTrash.folderRefusal(folder, home: f.dir.path) == nil)
            #expect(ChatTrash.folderRefusal(f.repo, home: f.dir.path) != nil)
            let job = ChatTrash.Job(chatId: "s1", path: folder, projectRoot: nil)
            let (outcome, _) = await ChatTrash.run(job, exec: f.exec, home: f.dir.path, trash: f.trash, roots: [f.worktrees])
            if case .trashed = outcome {} else { Issue.record("not trashed: \(outcome)") }
            #expect(!FileManager.default.fileExists(atPath: folder))
        }

        @Test func leftoverTrashAndUnfinishedJobsResumeOnLaunch() async throws {
            let f = try await TrashFixture.make()
            defer { f.remove() }
            // A quit after one rename, and before another chat's folder moved.
            let moved = try await f.addWorktree("chat-9")
            let item = try ChatTrash.moveToTrash(moved, chatId: "c9", trash: f.trash)
            try FileManager.default.createDirectory(at: item.appendingPathComponent("node_modules/x"), withIntermediateDirectories: true)
            let waiting = try await f.addWorktree("chat-10")
            ChatTrash.record(f.job("c10", waiting), trash: f.trash)

            #expect(ChatTrash.leftovers(trash: f.trash) == [item])
            let pending = ChatTrash.pending(trash: f.trash)
            #expect(pending.map(\.chatId) == ["c10"])
            // What the app does on launch: finish the jobs, then empty the trash.
            for job in pending {
                if case .trashed = await f.run(job).outcome {} else { Issue.record("not resumed") }
                ChatTrash.finish(job.chatId, trash: f.trash)
            }
            for left in ChatTrash.leftovers(trash: f.trash) { #expect(await ChatTrash.purge(left, trash: f.trash)) }
            #expect(ChatTrash.leftovers(trash: f.trash).isEmpty)
            #expect(ChatTrash.pending(trash: f.trash).isEmpty)
            #expect(!FileManager.default.fileExists(atPath: waiting))
            #expect(try await f.listed() == [ChatTrash.resolved(f.repo)])
        }

        @Test func purgeOnlyDeletesWhatsInTheTrash() async throws {
            let f = try await TrashFixture.make()
            defer { f.remove() }
            #expect(await !ChatTrash.purge(URL(fileURLWithPath: f.repo), trash: f.trash))
            #expect(FileManager.default.fileExists(atPath: f.repo + "/README"))
        }

        @Test func aMovedNameNeverReplacesOneAlreadyInTheTrash() async throws {
            let f = try await TrashFixture.make()
            defer { f.remove() }
            let a = f.dir.appendingPathComponent("a"), b = f.dir.appendingPathComponent("b")
            try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
            let first = try ChatTrash.moveToTrash(a.path, chatId: "same", trash: f.trash)
            let second = try ChatTrash.moveToTrash(b.path, chatId: "same", trash: f.trash)
            #expect(first != second)
            #expect(ChatTrash.leftovers(trash: f.trash).count == 2)
        }

        /// The ticket's timing claim: a worktree holding ~100k files (a
        /// `node_modules`) is gone from its path in well under a second;
        /// the space comes back afterwards.
        @Test func aHundredThousandFileWorktreeLeavesItsPathInUnderASecond() async throws {
            let f = try await TrashFixture.make()
            defer { f.remove() }
            let path = try await f.addWorktree("big")
            let files = try generateTree(at: path + "/node_modules", files: 100_000)
            let size = await ChatTrash.size(of: path) ?? 0

            let clock = ContinuousClock()
            let start = clock.now
            let (outcome, _) = await f.run(f.job("big", path))
            let gone = clock.now - start
            guard case .trashed(let moved) = outcome else { Issue.record("not trashed: \(outcome)"); return }
            #expect(!FileManager.default.fileExists(atPath: path))
            #expect(gone < .seconds(1), "gone from its path in \(gone)")

            let purgeStart = clock.now
            #expect(await ChatTrash.purge(moved, trash: f.trash))
            let purged = clock.now - purgeStart
            print("chat trash timing: \(files) files, \(size / 1_048_576) MB: path gone in \(gone), trash purged in \(purged)")
        }

        @Test func cleanUpCountsOnlyWorkThatWouldBeLost() async throws {
            let f = try await TrashFixture.make()
            defer { f.remove() }
            let path = try await f.addWorktree("old-chat")
            var work = await ChatCleanup.unsavedWork(f.exec, worktree: path, preferredBase: "main")
            #expect(work.commits == 0, "main's own commits aren't this chat's, with no remote")
            #expect(work.uncommitted == 0)

            try "change\n".write(toFile: path + "/new.txt", atomically: true, encoding: .utf8)
            work = await ChatCleanup.unsavedWork(f.exec, worktree: path, preferredBase: "main")
            #expect(work.uncommitted == 1)
            try await f.git(path, ["add", "."])
            try await f.git(path, ["-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-qm", "work"])
            work = await ChatCleanup.unsavedWork(f.exec, worktree: path, preferredBase: "main")
            #expect(work.commits == 1)
            #expect(work.uncommitted == 0)

            // Merged into main here: nothing is lost with the worktree.
            try await f.git(f.repo, ["merge", "-q", "--ff-only", "old-chat"])
            work = await ChatCleanup.unsavedWork(f.exec, worktree: path, preferredBase: "main")
            #expect(work.commits == 0)
        }

        @Test func atMostThreeTeardownsRunAtOnce() async {
            actor Peak {
                var now = 0, most = 0
                func enter() { now += 1; most = max(most, now) }
                func leave() { now -= 1 }
            }
            let throttle = Throttle(ChatTrash.concurrentTeardowns)
            let peak = Peak()
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<10 {
                    group.addTask {
                        await throttle.run {
                            await peak.enter()
                            try? await Task.sleep(for: .milliseconds(30))
                            await peak.leave()
                        }
                    }
                }
            }
            #expect(await peak.most == 3)
        }
    }
}

/// `files` small files in folders of 1,000, like a `node_modules`.
private func generateTree(at root: String, files: Int) throws -> Int {
    let fm = FileManager.default
    let data = Data("module.exports = {}\n".utf8)
    var made = 0
    var folder = 0
    while made < files {
        let dir = root + "/pkg-\(folder)/lib"
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for i in 0..<min(1_000, files - made) {
            guard fm.createFile(atPath: dir + "/f\(i).js", contents: data) else { throw AbstractError.message("couldn't write") }
            made += 1
        }
        folder += 1
    }
    return made
}
