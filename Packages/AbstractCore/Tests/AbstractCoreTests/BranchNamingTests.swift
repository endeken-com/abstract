import Foundation
import Testing
@testable import AbstractCore

@Suite struct BranchNamingTests {
    @Test func toolListsAnExplicitBranchActionAndExplainsBadRequests() async throws {
        let server = BranchMCPServer(chatId: "chat")
        func answer(_ line: String) async throws -> JSONValue {
            let output = try #require(await server.handle(line))
            return try JSONDecoder().decode(JSONValue.self, from: Data(output.utf8))
        }
        let listed = try await answer(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
        #expect(listed["result"]?["tools"]?.array?.first?["name"]?.string == "name_branch")
        let bad = try await answer(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"name_branch","arguments":{}}}"#)
        #expect(bad["result"]?["isError"] == .bool(true))
    }

    @Test func everyAgentGetsTheToolAndCommandInstructions() throws {
        let settings = LaunchSettings(providerOverrides: [:], outputStyle: .default, claudeProfile: nil,
                                      attachmentsDirectory: "/tmp/attachments")
        var configured = settings
        configured.branchCommand = "/Applications/Abstract.app/Contents/Helpers/abstract"
        let session = Session(id: "chat", projectId: "p", name: "Run", providerId: "claude",
                              worktreePath: "/tmp/worktree", branch: "auto/run/2026-10-21-1200")
        for provider in [ClaudeProvider(), CodexProvider(), OpenCodeProvider(), MuseProvider()] as [any ProviderDefinition] {
            let spec = AgentLaunch.spec(for: session, provider: provider, prompt: "Find the next ticket",
                                        resumeId: nil, settings: configured, home: "/tmp")
            let joined = spec.args.joined(separator: " ") + (spec.stdinInitial ?? "") + spec.env.values.joined()
            if provider.id == "muse" {
                let lines = try #require(spec.stdinInitial).split(separator: "\n")
                let start = try #require(lines.map { try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
                    .first { $0["method"]?.string == "session/start" })
                let id = try #require(start["params"]?["sessionId"]?.string)
                #expect(MusePendingTurns.peek(id)?.prompt.contains("abstract branch name") == true)
                MusePendingTurns.remove(id)
            } else {
                #expect(joined.contains("abstract branch name"), "\(provider.id) needs the CLI instruction")
            }
        }
        let ctx = LaunchContext(cwd: "/tmp/worktree", prompt: "Find the next ticket", permissionPolicy: .ask,
                                branchTool: BranchToolLaunch(command: configured.branchCommand!, chatId: "chat"))
        #expect(ctx.mcpServers.map(\.name).contains(BranchMCPServer.serverName))
    }

    @Test func commandCannotNameAnotherChatsWorktree() async throws {
        let store = try Store.inMemory()
        try store.save(Project(id: "p", name: "Test", rootPath: "/tmp/repo"))
        try store.save(Automation(id: "a", name: "Run", prompt: "Work", providerId: "claude", projectId: "p",
                                  triggers: [], workspaceMode: .newWorktree))
        try store.save(Session(id: "chat", projectId: "p", name: "Run", providerId: "claude",
                               worktreePath: "/tmp/worktree", branch: "auto/run/2026-10-21-1200", automationId: "a"))
        let commands = Commands(store: store, storePath: "/tmp/test-store.db", locks: URL(fileURLWithPath: "/tmp/locks"),
                                executable: "/bin/abstract")
        await #expect(throws: CLIError.self) {
            try await commands.nameRunBranch("abstract/fix", in: "/tmp/other", chatId: "chat")
        }
        await #expect(throws: CLIError.self) {
            try await commands.nameRunBranch("abstract/fix", in: "/tmp/worktree", chatId: "other")
        }
        #expect(try store.session("chat")?.branch == "auto/run/2026-10-21-1200")
    }

    @Test func commandNamesTheCurrentRunOnceAndRecordsIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("abstract-branch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repo = root.appendingPathComponent("repo").path
        let worktree = root.appendingPathComponent("worktree").path
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        let exec = LocalExecutor.shared
        func git(_ cwd: String, _ args: [String]) async throws {
            let result = try await exec.run("git", args, cwd: cwd)
            try #require(result.ok, "git \(args) failed: \(result.stderr)")
        }
        try await git(repo, ["init", "-q", "-b", "main"])
        try await git(repo, ["config", "user.name", "Abstract Test"])
        try await git(repo, ["config", "user.email", "test@abstract.local"])
        try await git(repo, ["config", "commit.gpgsign", "false"])
        try await git(repo, ["commit", "-q", "--allow-empty", "-m", "base"])
        let provisional = "auto/run/2026-10-21-1200"
        try await git(repo, ["worktree", "add", "-q", "-b", provisional, worktree])

        let store = try Store.inMemory()
        try store.save(Project(id: "p", name: "Test", rootPath: repo))
        try store.save(Automation(id: "a", name: "Run", prompt: "Work", providerId: "claude", projectId: "p",
                                  triggers: [], workspaceMode: .newWorktree))
        try store.save(Session(id: "chat", projectId: "p", name: "Run", providerId: "claude",
                               worktreePath: worktree, branch: provisional, automationId: "a"))
        let commands = Commands(store: store, storePath: root.appendingPathComponent("store.db").path,
                                locks: root.appendingPathComponent("locks"), executable: "/bin/abstract")
        let named = try await commands.nameRunBranch("abstract/fix/run-branch", in: worktree)
        #expect(named.branch == "abstract/fix/run-branch")
        #expect(try store.session("chat")?.branch == named.branch)
        #expect(try await Git.currentBranch(exec, root: worktree) == named.branch)
        await #expect(throws: CLIError.self) {
            try await commands.nameRunBranch("abstract/another-name", in: worktree)
        }
        #expect(try store.session("chat")?.branch == named.branch)
    }

    @Test func codexBranchToolOverrideIsAClosedTable() {
        let args = CodexProvider.branchArgs(BranchToolLaunch(command: "/bin/abstract", chatId: "chat"))
        #expect(args.contains(#"mcp_servers.abstract-branch.tools={ "name_branch" = { approval_mode = "approve" } }"#))
    }
}
