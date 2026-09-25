import Foundation
import Testing
@testable import AbstractCore

/// A project with submodules and a chat worktree of it, in one temp folder:
///
///     app/                  the project, on main
///       libs/core/          submodule (repo core), with its own vendor/deep (repo deep)
///       libs/other lib/     submodule (repo other): a space in its path
///       libs/unused/        submodule (repo unused), never checked out in the worktree
///     wt/                   the chat's worktree of app, on branch chat, with
///                           libs/core (recursively) and libs/other lib checked out
struct SubmoduleFixture {
    let dir: String
    let exec: any Executor = LocalExecutor.shared

    var app: String { dir + "/app" }
    var worktree: String { dir + "/wt" }
    func repo(_ name: String) -> String { dir + "/" + name }

    /// git with a test identity, local-path submodules allowed.
    @discardableResult
    func git(_ cwd: String, _ args: [String]) async throws -> String {
        let out = try await exec.run("git", ["-c", "protocol.file.allow=always", "-c", "user.email=test@abstract.local",
                                             "-c", "user.name=Abstract Test", "-c", "commit.gpgsign=false"] + args, cwd: cwd)
        try #require(out.ok, "git \(args) failed: \(out.stderr)")
        return out.stdout
    }

    func write(_ path: String, _ content: String) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    func read(_ path: String) throws -> String { try String(contentsOfFile: path, encoding: .utf8) }

    /// Commits everything in `cwd` with `message`.
    func commitAll(_ cwd: String, _ message: String) async throws {
        try await git(cwd, ["add", "-A"])
        try await git(cwd, ["commit", "-qm", message])
    }

    func remove() { try? FileManager.default.removeItem(atPath: dir) }

    static func make() async throws -> SubmoduleFixture {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("abstract-submodules-\(UUID().uuidString)").path
        let f = SubmoduleFixture(dir: dir)
        for name in ["deep", "core", "other", "unused", "app"] {
            try FileManager.default.createDirectory(atPath: f.repo(name), withIntermediateDirectories: true)
            try await f.git(f.repo(name), ["init", "-q", "-b", "main"])
            try f.write(f.repo(name) + "/a.txt", "\(name)\n")
            try await f.commitAll(f.repo(name), "init")
        }
        try await f.git(f.repo("core"), ["submodule", "add", "-q", f.repo("deep"), "vendor/deep"])
        try await f.git(f.repo("core"), ["commit", "-qm", "Add deep"])
        try await f.git(f.app, ["submodule", "add", "-q", f.repo("core"), "libs/core"])
        try await f.git(f.app, ["submodule", "add", "-q", f.repo("other"), "libs/other lib"])
        try await f.git(f.app, ["submodule", "add", "-q", f.repo("unused"), "libs/unused"])
        try await f.git(f.app, ["commit", "-qm", "Add submodules"])
        try await f.git(f.app, ["worktree", "add", "-q", "-b", "chat", f.worktree, "main"])
        try await f.git(f.worktree, ["submodule", "update", "-q", "--init", "--recursive", "--", "libs/core", "libs/other lib"])
        return f
    }
}
