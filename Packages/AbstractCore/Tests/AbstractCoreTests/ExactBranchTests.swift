import Foundation
import Testing
@testable import AbstractCore

/// `Workspace.provision` with a branch used exactly as given, as `abstract session create` does.
@Suite struct ExactBranchTests {
    let exec = LocalExecutor.shared

    private func makeRepo() async throws -> (project: Project, dir: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("abstract-exact-\(UUID().uuidString)")
        let root = dir.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "test@abstract.local"],
                     ["config", "user.name", "Abstract Test"], ["config", "commit.gpgsign", "false"],
                     ["commit", "-q", "--allow-empty", "-m", "init"]] {
            let out = try await exec.run("git", args, cwd: root.path)
            try #require(out.ok, "git \(args): \(out.stderr)")
        }
        return (Project(name: "repo", rootPath: root.path, defaultBaseRef: "main"), dir)
    }

    @Test func theBranchIsUsedVerbatimWithoutThePrefix() async throws {
        let (project, dir) = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ws = try await Workspace.provision(
            executor: exec, project: project, name: "Fix login", baseRef: nil, template: dir.path + "/wt/{slug}",
            prefix: "abstract/", worktreeName: "Lisbon", exactBranch: "Feature/Login_Fix")
        #expect(ws.branch == "Feature/Login_Fix")
        #expect(ws.path == dir.path + "/wt/lisbon")
        #expect(try await Git.currentBranch(exec, root: ws.path) == "Feature/Login_Fix")
    }

    @Test func anExistingBranchFailsAndLeavesNoFolder() async throws {
        let (project, dir) = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try await exec.run("git", ["branch", "taken"], cwd: project.rootPath)
        await #expect(throws: WorkspaceError.branchExists("taken")) {
            try await Workspace.provision(executor: exec, project: project, name: "x", baseRef: nil,
                                          template: dir.path + "/wt/{slug}", prefix: "", worktreeName: "Oslo",
                                          exactBranch: "taken")
        }
        #expect(!FileManager.default.fileExists(atPath: dir.path + "/wt/oslo"))
    }

    @Test func aTakenFolderIsSuffixedButTheBranchIsNot() async throws {
        let (project, dir) = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(atPath: dir.path + "/wt/oslo", withIntermediateDirectories: true)
        let ws = try await Workspace.provision(
            executor: exec, project: project, name: "x", baseRef: nil, template: dir.path + "/wt/{slug}",
            prefix: "abstract/", worktreeName: "Oslo", exactBranch: "work")
        #expect(ws.path == dir.path + "/wt/oslo-1")
        #expect(ws.branch == "work")
    }
}
