import Foundation
import Testing
@testable import AbstractCore

/// Project settings: what the store keeps, and what new worktrees and chat
/// names do with it.
@Suite struct ProjectSettingsTests {
    static let created = Date(timeIntervalSince1970: 1_790_000_000)

    // MARK: - Store

    @Test func everyProjectSettingRoundTrips() throws {
        let store = try Store.inMemory()
        let project = Project(
            id: "p1", name: "api", rootPath: "/r/api", worktreeTemplate: "/wt/{repo}-{hash}/{slug}", branchPrefix: "",
            createdAt: Self.created, iconSymbol: "shippingbox", iconColor: "sage", iconImagePath: "/icons/p1.png",
            namingInstructions: "Prefix fixes with fix/.", sparseCheckout: ["apps/web", "packages/ui"],
            setupScript: "npm install\ncp \"$ROOT/.env\" .", teardownScript: "docker compose down", runScript: "npm run dev")
        try store.save(project)
        #expect(try store.project("p1") == project)

        var cleared = project
        cleared.iconSymbol = nil; cleared.iconColor = nil; cleared.iconImagePath = nil
        cleared.namingInstructions = nil; cleared.sparseCheckout = []
        cleared.setupScript = nil; cleared.teardownScript = nil; cleared.runScript = nil
        try store.save(cleared)
        #expect(try store.projects() == [cleared])
    }

    @Test func projectsFromBeforeTheMigrationLoadUnchanged() throws {
        let store = try Store.inMemory(migratedTo: "v4-triggers", thenRunning: """
            INSERT INTO projects (id, name, root_path, default_base_ref, default_provider_id, default_permission_policy,
                                  nested_repos, worktree_template, branch_prefix, sort_order, created_at)
            VALUES ('p1', 'abstract', '/r/abstract', 'main', 'codex', 'auto-edits', '["vendor/a"]', NULL, 'wes/', 2,
                    '2026-09-01 12:00:00.000');
            INSERT INTO sessions (id, project_id, name, provider_id, created_at) VALUES ('s1', 'p1', 'Chat', 'claude',
                    '2026-09-02 12:00:00.000');
            """)
        let p = try #require(try store.project("p1"))
        #expect(p.name == "abstract" && p.rootPath == "/r/abstract" && p.defaultBaseRef == "main")
        #expect(p.defaultProviderId == "codex" && p.defaultPermissionPolicy == .autoEdits && p.nestedRepos == ["vendor/a"])
        #expect(p.worktreeTemplate == nil && p.branchPrefix == "wes/" && p.sortOrder == 2)
        #expect(p.iconSymbol == nil && p.iconColor == nil && p.iconImagePath == nil && p.namingInstructions == nil)
        #expect(p.sparseCheckout.isEmpty)
        #expect(p.setupScript == nil && p.teardownScript == nil && p.runScript == nil)
        #expect(try store.sessions().map(\.id) == ["s1"])

        var edited = p
        edited.runScript = "make run"
        edited.sparseCheckout = ["src"]
        try store.save(edited)
        #expect(try store.project("p1") == edited)
    }

    // MARK: - Pure helpers

    @Test func sparseFoldersAreNormalised() {
        #expect(SparseCheckout.parse("apps/web\n\n  ./packages/ui/ \n/docs\n# comment\napps/web\n.\n") ==
                ["apps/web", "packages/ui", "docs"])
        #expect(SparseCheckout.parse("   \n").isEmpty)
    }

    @Test func remotesBecomeWebPagesAndOwners() {
        #expect(GitRemote.webURL("git@github.com:wes/abstract.git")?.absoluteString == "https://github.com/wes/abstract")
        #expect(GitRemote.webURL("https://github.com/wes/abstract.git")?.absoluteString == "https://github.com/wes/abstract")
        #expect(GitRemote.webURL("https://wes:token@github.com/wes/abstract")?.absoluteString == "https://github.com/wes/abstract")
        #expect(GitRemote.webURL("ssh://git@gitlab.com/group/sub/repo.git")?.absoluteString == "https://gitlab.com/group/sub/repo")
        #expect(GitRemote.webURL("/Users/wes/repos/abstract") == nil)
        #expect(GitRemote.webURL("file:///Users/wes/repos/abstract") == nil)
        #expect(GitRemote.githubOwner("git@github.com:wes/abstract.git") == "wes")
        #expect(GitRemote.githubOwner("https://GitHub.com/anthropics/claude-code") == "anthropics")
        #expect(GitRemote.githubOwner("git@gitlab.com:wes/abstract.git") == nil)
        #expect(GitRemote.sameRepository("git@github.com:wes/abstract.git", "https://github.com/wes/abstract"))
        #expect(!GitRemote.sameRepository("git@github.com:wes/abstract.git", "git@github.com:wes/other.git"))
    }

    @Test func suggestedBranchNamesAreMadeSafe() {
        #expect(WorktreeNaming.branchSlug("fix/Login Button Alignment") == "fix/login-button-alignment")
        #expect(WorktreeNaming.branchSlug("feat//new  thing/") == "feat/new-thing")
        #expect(WorktreeNaming.branchSlug("  ") == nil)
        #expect(WorktreeNaming.branchSlug("!!!/???") == nil)
        #expect(WorktreeNaming.branchSlug("session-cleanup") == "session-cleanup")
        let long = WorktreeNaming.branchSlug("feat/" + String(repeating: "word-", count: 30))!
        #expect(long.count <= 60 && !long.hasSuffix("-") && long.hasPrefix("feat/"))
    }

    @Test func namingOutputIsParsedFromTheCLIEnvelope() {
        let fenced = #"{"type":"result","is_error":false,"result":"```json\n{\n  \"title\": \"Fix the login button alignment\",\n  \"branch\": \"fix/Login-Button\"\n}\n```"}"#
        #expect(ChatNaming.parse(fenced) == .init(title: "Fix the login button alignment", branch: "fix/login-button"))
        let chatty = #"{"is_error":false,"result":"Sure! {\"x\":1} Here it is: {\"title\": \"Tidy docs\", \"branch\": \"docs/tidy\"}"}"#
        #expect(ChatNaming.parse(chatty) == .init(title: "Tidy docs", branch: "docs/tidy"))
        let noBranch = #"{"is_error":false,"result":"{\"title\": \"Speed up CI\"}"}"#
        #expect(ChatNaming.parse(noBranch) == .init(title: "Speed up CI", branch: "speed-up-ci"))
        #expect(ChatNaming.parse(#"{"is_error":true,"result":"{\"title\":\"x\",\"branch\":\"y\"}"}"#) == nil)
        #expect(ChatNaming.parse(#"{"is_error":false,"result":"I can't help with that."}"#) == nil)
        #expect(ChatNaming.parse("not json") == nil)
        #expect(ChatNaming.prompt(instructions: "Use fix/ for bugs", task: "The button is off").contains("Use fix/ for bugs"))
        #expect(ChatNaming.prompt(instructions: "", task: "The button is off").contains("Summarize this coding request"))
    }

    @Test func chatTitlesCanBeGeneratedByTheSelectedProvider() throws {
        let claude = try #require(ChatNaming.launchSpec(home: "/tmp", binary: nil, providerId: "claude", model: nil,
                                                        instructions: "", task: "Fix login"))
        #expect(claude.command == "claude" && claude.stdinInitial != nil)

        let codex = try #require(ChatNaming.launchSpec(home: "/tmp", binary: "/bin/codex", providerId: "codex",
                                                       model: "gpt-test", instructions: "", task: "Fix login"))
        #expect(codex.command == "/bin/codex")
        #expect(codex.args.contains("read-only") && codex.args.contains("gpt-test"))
        #expect(codex.stdinInitial == nil && !codex.keepStdinOpen)

        #expect(ChatNaming.launchSpec(home: "/tmp", binary: nil, providerId: "ollama", model: "llama-test",
                                      instructions: "", task: "Fix login") == nil)
        #expect(ChatNaming.launchSpec(home: "/tmp", binary: nil, providerId: "missing", model: nil,
                                      instructions: "", task: "Fix login") == nil)

        let output = """
            {"type":"item.completed","item":{"type":"agent_message","text":"I will name it."}}
            {"type":"item.completed","item":{"type":"agent_message","text":"{\\"title\\":\\"Fix login button\\",\\"branch\\":\\"fix/login-button\\"}"}}
            {"type":"turn.completed"}
            """
        #expect(ChatNaming.parseCodex(output) == .init(title: "Fix login button", branch: "fix/login-button"))
    }

    // MARK: - Timed commands

    @Test func timedCommandsReportOutputAndStopAtTheirLimit() async throws {
        let exec = LocalExecutor.shared
        let done = try await exec.run(LaunchSpec(command: "/bin/sh", args: ["-c", "echo hi; echo oops >&2; exit 3"],
                                                 cwd: NSTemporaryDirectory(), keepStdinOpen: false), timeout: .seconds(10))
        #expect(done.code == 3 && !done.timedOut && !done.ok)
        #expect(done.stdout == "hi" && done.stderr == "oops" && done.lastLine == "oops")

        let start = Date()
        let slow = try await exec.run(LaunchSpec(command: "/bin/sleep", args: ["20"], cwd: NSTemporaryDirectory(),
                                                 keepStdinOpen: false), timeout: .milliseconds(300))
        #expect(slow.timedOut && !slow.ok)
        #expect(Date().timeIntervalSince(start) < 5)
    }

    // MARK: - Worktrees

    @Test func sparseProjectsGetSparseWorktrees() async throws {
        let exec = LocalExecutor.shared
        let root = try await Self.makeRepo(exec)
        defer {
            try? FileManager.default.removeItem(atPath: root)
            try? FileManager.default.removeItem(atPath: root + "-wt")
        }
        let project = Project(name: "sparse", rootPath: root, defaultBaseRef: "main",
                              sparseCheckout: ["apps/web/", "./docs", ""])
        let ws = try await Workspace.provision(executor: exec, project: project, name: "Try sparse", baseRef: nil,
                                               template: root + "-wt/{slug}", prefix: "abstract/", slug: "feat/Sparse Try")
        #expect(ws.branch == "abstract/feat/sparse-try")
        #expect(ws.path == root + "-wt/feat-sparse-try")
        #expect(try await Git.currentBranch(exec, root: ws.path) == "abstract/feat/sparse-try")

        let files = Self.files(ws.path)
        // Cone mode: the folders, files at the root, and files directly in
        // a listed folder's parents; never a sibling folder (apps/api).
        #expect(files == ["README.md", "apps/root-of-apps.txt", "apps/web/index.ts", "docs/guide.md"],
                "only the listed folders and root files, got \(files)")
        let status = try await exec.run("git", ["status", "--porcelain"], cwd: ws.path)
        #expect(status.ok && status.stdout.isEmpty, "a sparse worktree is clean")

        // The main tree and later full worktrees are untouched.
        #expect(Self.files(root).count == 5)
        let full = try await Workspace.provision(executor: exec, project: Project(name: "full", rootPath: root, defaultBaseRef: "main"),
                                                 name: "Full", baseRef: nil, template: root + "-wt/{slug}", prefix: "abstract/")
        #expect(Self.files(full.path).count == 5)
    }

    @Test func cityFolderIsIndependentOfDescriptiveBranch() async throws {
        let exec = LocalExecutor.shared
        let root = try await Self.makeRepo(exec)
        defer {
            try? FileManager.default.removeItem(atPath: root)
            try? FileManager.default.removeItem(atPath: root + "-wt")
        }
        let project = Project(name: "app", rootPath: root, defaultBaseRef: "main")
        let first = try await Workspace.provision(executor: exec, project: project, name: "Fix login button", baseRef: nil,
                                                  template: root + "-wt/{slug}", prefix: "abstract/",
                                                  slug: "fix/Login Button", worktreeName: "Oslo")
        #expect(first.path == root + "-wt/oslo")
        #expect(first.branch == "abstract/fix/login-button")

        let second = try await Workspace.provision(executor: exec, project: project, name: "Improve search", baseRef: nil,
                                                   template: root + "-wt/{slug}", prefix: "abstract/",
                                                   slug: "feat/search", worktreeName: "Oslo")
        #expect(second.path == root + "-wt/oslo-1")
        #expect(second.branch == "abstract/feat/search-1")

        let fallback = try await Workspace.provision(executor: exec, project: project, name: "Improve cache", baseRef: nil,
                                                     template: root + "-wt/{slug}", prefix: "abstract/",
                                                     worktreeName: "Lima")
        #expect(fallback.path == root + "-wt/lima")
        #expect(fallback.branch == "abstract/improve-cache")
    }

    @Test func aFailedSparseCheckoutLeavesNothingBehind() async throws {
        let exec = LocalExecutor.shared
        let root = try await Self.makeRepo(exec)
        defer {
            try? FileManager.default.removeItem(atPath: root)
            try? FileManager.default.removeItem(atPath: root + "-wt")
        }
        // A cone pattern git rejects: a folder with a glob.
        await #expect(throws: AbstractError.self) {
            try await Git.addWorktree(exec, root: root, path: root + "-wt/bad", branch: "abstract/bad", baseRef: "main",
                                      sparse: ["apps/*"])
        }
        #expect(!FileManager.default.fileExists(atPath: root + "-wt/bad"))
        #expect(await !Git.branchExists(exec, root: root, branch: "abstract/bad"))
        #expect(try await Git.worktrees(exec, root: root).count == 1)
    }

    @Test func originAndHistoryIdentifyTheRepository() async throws {
        let exec = LocalExecutor.shared
        let root = try await Self.makeRepo(exec)
        defer { try? FileManager.default.removeItem(atPath: root) }
        #expect(await Git.originURL(exec, root: root) == nil)
        _ = try await exec.run("git", ["remote", "add", "origin", "git@github.com:wes/sparse.git"], cwd: root)
        #expect(await Git.originURL(exec, root: root) == "git@github.com:wes/sparse.git")
        #expect(await Git.rootCommits(exec, root: root).count == 1)
    }

    // MARK: - Fixtures

    static func makeRepo(_ exec: any Executor) async throws -> String {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("abstract-sparse-\(UUID().uuidString)").path
        for dir in ["apps/web", "apps/api", "docs"] {
            try FileManager.default.createDirectory(atPath: root + "/" + dir, withIntermediateDirectories: true)
        }
        for (path, text) in [("README.md", "# r\n"), ("apps/web/index.ts", "web\n"), ("apps/api/main.go", "api\n"),
                             ("docs/guide.md", "guide\n"), ("apps/root-of-apps.txt", "apps\n")] {
            try text.write(toFile: root + "/" + path, atomically: true, encoding: .utf8)
        }
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@abstract.local"], ["config", "user.name", "t"],
                     ["config", "commit.gpgsign", "false"], ["add", "-A"], ["commit", "-qm", "init"]] {
            let out = try await exec.run("git", args, cwd: root)
            try #require(out.ok, "git \(args): \(out.stderr)")
        }
        return root
    }

    /// Checked-out files, relative and sorted, `.git` left out.
    static func files(_ root: String) -> [String] {
        let enumerator = FileManager.default.enumerator(atPath: root)
        var out: [String] = []
        while let path = enumerator?.nextObject() as? String {
            if path == ".git" || path.hasPrefix(".git/") { continue }
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: root + "/" + path, isDirectory: &isDir), !isDir.boolValue { out.append(path) }
        }
        return out.sorted()
    }
}

/// The real naming call. Opt-in: it needs the `claude` binary and a signed-in
/// account (`ABSTRACT_E2E=1 swift test --filter RealNaming`).
@Suite("Real naming", .enabled(if: ProcessInfo.processInfo.environment["ABSTRACT_E2E"] != nil))
struct RealNamingTests {
    @Test(.timeLimit(.minutes(1)))
    func claudeSuggestsATitleAndABranchFollowingTheInstructions() async throws {
        let suggestion = try #require(await ChatNaming.suggest(
            executor: LocalExecutor.shared, binary: nil,
            instructions: "Branches start with a type folder: fix/ for bugs, feat/ for features. Titles are in sentence case.",
            task: "The login button is misaligned on small screens; it overlaps the password field."))
        #expect(!suggestion.title.isEmpty)
        #expect(suggestion.branch.hasPrefix("fix/"), "got \(suggestion.branch)")
        #expect(WorktreeNaming.branchSlug(suggestion.branch) == suggestion.branch)
    }
}
