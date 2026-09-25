// A new chat's setup against real git and a real shell: the base is fetched
// fresh from origin, the branch doesn't track it, and the setup script's
// output, exit code and cancellation come through.

import Foundation
import Synchronization
import Testing
@testable import AbstractCore

private func git(_ exec: any Executor, _ cwd: String, _ args: [String]) async throws -> String {
    let out = try await exec.run("git", args, cwd: cwd)
    try #require(out.ok, "git \(args) failed: \(out.stderr)")
    return GitText.trimmed(out.stdout)
}

/// An `origin` repository and a clone of it, in one temporary folder.
private struct Remote {
    let dir: String
    var origin: String { dir + "/origin" }
    var clone: String { dir + "/clone" }

    static func make(_ exec: any Executor) async throws -> Remote {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("abstract-setup-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dir + "/origin", withIntermediateDirectories: true)
        let remote = Remote(dir: dir)
        _ = try await git(exec, remote.origin, ["init", "-q", "-b", "main"])
        try await remote.commit(exec, in: remote.origin, "first")
        _ = try await git(exec, dir, ["clone", "-q", remote.origin, remote.clone])
        try await remote.configure(exec, remote.clone)
        return remote
    }

    func configure(_ exec: any Executor, _ repo: String) async throws {
        _ = try await git(exec, repo, ["config", "user.email", "test@abstract.local"])
        _ = try await git(exec, repo, ["config", "user.name", "Abstract Test"])
        _ = try await git(exec, repo, ["config", "commit.gpgsign", "false"])
    }

    func commit(_ exec: any Executor, in repo: String, _ message: String) async throws {
        try await configure(exec, repo)
        _ = try await git(exec, repo, ["commit", "-q", "--allow-empty", "-m", message])
    }

    func remove() { try? FileManager.default.removeItem(atPath: dir) }
}

@Suite struct FreshBaseTests {
    let exec = LocalExecutor.shared

    @Test func startsFromWhatOriginHasNow() async throws {
        let remote = try await Remote.make(exec)
        defer { remote.remove() }
        try await remote.commit(exec, in: remote.origin, "pushed after the clone")
        let newest = try await git(exec, remote.origin, ["rev-parse", "HEAD"])

        let base = await Workspace.freshBase(executor: exec, root: remote.clone, base: "main")
        #expect(base == Workspace.Base(ref: "origin/main"))
        #expect(try await git(exec, remote.clone, ["rev-parse", "origin/main"]) == newest)
    }

    @Test func keepsUnpushedLocalCommits() async throws {
        let remote = try await Remote.make(exec)
        defer { remote.remove() }
        try await remote.commit(exec, in: remote.clone, "not pushed yet")

        let base = await Workspace.freshBase(executor: exec, root: remote.clone, base: "main")
        #expect(base == Workspace.Base(ref: "main"))
    }

    @Test func divergedLocalBranchStartsFromOrigin() async throws {
        let remote = try await Remote.make(exec)
        defer { remote.remove() }
        try await remote.commit(exec, in: remote.clone, "local only")
        try await remote.commit(exec, in: remote.origin, "origin only")

        let base = await Workspace.freshBase(executor: exec, root: remote.clone, base: "main")
        #expect(base.ref == "origin/main")
    }

    @Test func offlineUsesTheCopyAlreadyHere() async throws {
        let remote = try await Remote.make(exec)
        defer { remote.remove() }
        _ = try await git(exec, remote.clone, ["remote", "set-url", "origin", remote.dir + "/gone"])

        let base = await Workspace.freshBase(executor: exec, root: remote.clone, base: "main")
        #expect(base.ref == "origin/main")
        // git's reason, not its closing advice ("…and the repository exists.").
        #expect(base.fetchError?.contains("does not appear to be a git repository") == true, "\(base.fetchError ?? "nil")")
    }

    @Test func notABranchOrNoOriginIsUsedAsGiven() async throws {
        let remote = try await Remote.make(exec)
        defer { remote.remove() }
        #expect(await Workspace.freshBase(executor: exec, root: remote.clone, base: "HEAD") == Workspace.Base(ref: "HEAD"))
        let sha = try await git(exec, remote.clone, ["rev-parse", "HEAD"])
        #expect(await Workspace.freshBase(executor: exec, root: remote.clone, base: sha) == Workspace.Base(ref: sha))
        #expect(await Workspace.freshBase(executor: exec, root: remote.origin, base: "main") == Workspace.Base(ref: "main"))
    }

    @Test func aBranchOnlyOriginHasIsFetched() async throws {
        let remote = try await Remote.make(exec)
        defer { remote.remove() }
        _ = try await git(exec, remote.origin, ["branch", "release"])
        let base = await Workspace.freshBase(executor: exec, root: remote.clone, base: "release")
        #expect(base == Workspace.Base(ref: "origin/release"))
        // Not a branch anywhere: as given, and no complaint about origin.
        #expect(await Workspace.freshBase(executor: exec, root: remote.clone, base: "no-such-branch") == Workspace.Base(ref: "no-such-branch"))
    }

    @Test func aBranchFromOriginDoesNotTrackIt() async throws {
        let remote = try await Remote.make(exec)
        defer { remote.remove() }
        let path = remote.dir + "/wt"
        try await Git.addWorktree(exec, root: remote.clone, path: path, branch: "abstract/chat", baseRef: "origin/main")
        let upstream = try await exec.run("git", ["rev-parse", "--abbrev-ref", "@{upstream}"], cwd: path)
        #expect(!upstream.ok, "no upstream: \(upstream.stdout)")
    }
}

@Suite struct SetupScriptTests {
    let exec = LocalExecutor.shared
    let dir = FileManager.default.temporaryDirectory.path

    private final class Lines: Sendable {
        let all = Mutex<[String]>([])
        func append(_ line: String) { all.withLock { $0.append(line) } }
    }

    @Test func streamsOutputAndReturnsTheExitCode() async throws {
        let lines = Lines()
        let code = try await SetupScript.run("echo one\necho two >&2\nexit 3", in: dir, executor: exec, shell: "/bin/sh") {
            lines.append($0)
        }
        #expect(code == 3)
        #expect(Set(lines.all.withLock { $0 }).isSuperset(of: ["one", "two"]))
    }

    @Test func runsInTheWorktree() async throws {
        let lines = Lines()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("abstract-setup-cwd-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let code = try await SetupScript.run("pwd -P", in: folder, executor: exec, shell: "/bin/sh") { lines.append($0) }
        #expect(code == 0)
        // /var is /private/var: compare the folder's own name.
        #expect(lines.all.withLock { $0 }.last?.hasSuffix("/" + URL(fileURLWithPath: folder).lastPathComponent) == true)
    }

    @Test func cancellingStopsIt() async throws {
        let started = ContinuousClock.now
        let task = Task { try await SetupScript.run("sleep 30", in: dir, executor: exec, shell: "/bin/sh") { _ in } }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(ContinuousClock.now - started < .seconds(10))
    }

    @Test func cleansTerminalCodes() {
        #expect(SetupScript.clean("\u{1B}[32m✓\u{1B}[0m installed") == "✓ installed")
        #expect(SetupScript.clean("10%\r50%\r100%") == "100%")
        #expect(SetupScript.clean("done\r") == "done")
        #expect(SetupScript.clean("\u{1B}]0;title\u{07}text") == "text")
    }
}

@Suite struct StandaloneFolderTests {
    @Test func eachChatGetsAFolderOfItsOwn() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("abstract-home-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: home) }
        // Only when no data directory is set; the demo and tests set one.
        guard ProcessInfo.processInfo.environment["ABSTRACT_DATA_DIR"] == nil else { return }
        let first = try Workspace.standaloneFolder(home: home)
        let second = try Workspace.standaloneFolder(home: home)
        #expect(first != second)
        #expect(first.hasPrefix(home + "/.abstract/chats/"))
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: second, isDirectory: &isDirectory) && isDirectory.boolValue)
        #expect(Workspace.isChatFolder(first, home: home))
    }

    @Test func onlyAChatsOwnFolderMayBeDeleted() {
        let home = "/Users/someone"
        guard ProcessInfo.processInfo.environment["ABSTRACT_DATA_DIR"] == nil else { return }
        #expect(Workspace.isChatFolder("/Users/someone/.abstract/chats/lisbon", home: home))
        #expect(!Workspace.isChatFolder("/Users/someone/.abstract/chats", home: home))
        #expect(!Workspace.isChatFolder("/Users/someone/.abstract/chats/lisbon/src", home: home))
        #expect(!Workspace.isChatFolder("/Users/someone/.abstract/chats/../worktrees", home: home))
        #expect(!Workspace.isChatFolder("/Users/someone/code/app", home: home))
    }
}
