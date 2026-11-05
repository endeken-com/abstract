import Foundation
import Synchronization
import Testing
@testable import AbstractCore

/// A GitHub that lives in memory: repositories, their refs and the files at
/// each commit. No network.
final class FakeGitHub: PluginGitFetching {
    struct Repo {
        var head: String
        var refs: [String: String] = [:]
        /// Commit → path in the repository → contents (`+x` suffix: executable).
        var trees: [String: [String: String]] = [:]
        var isPrivate = false
    }

    private let state: Mutex<[String: Repo]>
    /// Whether this Mac's GitHub access reaches private repositories.
    let signedIn: Bool

    init(_ repos: [String: Repo] = [:], signedIn: Bool = true) {
        state = Mutex(repos); self.signedIn = signedIn
    }

    func set(_ key: String, _ change: (inout Repo) -> Void) {
        state.withLock { change(&$0[key]!) }
    }

    private func repo(_ source: PluginGitSource) throws -> Repo {
        guard let repo = state.withLock({ $0["\(source.owner)/\(source.repo)"] }), !repo.isPrivate || signedIn else {
            throw PluginGitError.unreachable(source.repository)
        }
        return repo
    }

    func resolve(_ source: PluginGitSource) async throws -> String {
        let repo = try repo(source)
        guard let ref = source.ref else { return repo.head }
        if repo.trees[ref] != nil { return ref }
        guard let commit = repo.refs[ref] else { throw PluginGitError.noSuchRef(ref, source.repository) }
        return commit
    }

    func download(_ source: PluginGitSource, commit: String, into folder: URL) async throws {
        guard let tree = try repo(source).trees[commit] else { throw PluginGitError.unreachable(source.repository) }
        let prefix = source.path.map { $0 + "/" } ?? ""
        let files = tree.filter { $0.key.hasPrefix(prefix) }
        guard !files.isEmpty else { throw PluginGitError.noSuchFolder(source.path ?? "", source.repository) }
        for (path, contents) in files {
            let executable = contents.hasSuffix("+x")
            let url = folder.appendingPathComponent(String(path.dropFirst(prefix.count)))
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data((executable ? String(contents.dropLast(2)) : contents).utf8).write(to: url)
            if executable { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
        }
    }

    func compare(_ source: PluginGitSource, from: String, to: String) async throws -> PluginGitChanges {
        let repo = try repo(source)
        let prefix = source.path.map { $0 + "/" } ?? ""
        let old = repo.trees[from] ?? [:], new = repo.trees[to] ?? [:]
        let files = Set(old.keys).union(new.keys).filter { $0.hasPrefix(prefix) && old[$0] != new[$0] }
        return PluginGitChanges(commits: 1, files: files.map { String($0.dropFirst(prefix.count)) }.sorted())
    }

    static func manifest(id: String = "dev.example.kanban", version: String = "1.0.0",
                         capabilities: [String] = ["chats.read"]) -> String {
        let manifest = PluginManifest(id: id, name: "Kanban", version: version, capabilities: capabilities,
                                      views: [.init(id: "main", title: "Kanban")])
        return String(decoding: try! JSONEncoder().encode(manifest), as: UTF8.self)
    }
}

@Suite struct PluginGitSourceTests {
    // MARK: Parsing

    @Test func readsEveryGitHubForm() throws {
        let plain = try PluginGitSource.parse("abstract-ade/abstract-plugin-kanban")
        #expect(plain == PluginGitSource(owner: "abstract-ade", repo: "abstract-plugin-kanban"))
        #expect(plain.isGitHub && plain.remote() == "https://github.com/abstract-ade/abstract-plugin-kanban.git")

        let folder = try PluginGitSource.parse("owner/monorepo/plugins/x@v1.2")
        #expect(folder == PluginGitSource(owner: "owner", repo: "monorepo", path: "plugins/x", ref: "v1.2"))
        #expect(folder.repository == "owner/monorepo/plugins/x")

        #expect(try PluginGitSource.parse("  owner/repo.git@main ") == PluginGitSource(owner: "owner", repo: "repo", ref: "main"))
        #expect(try PluginGitSource.parse("github:owner/repo") == PluginGitSource(owner: "owner", repo: "repo"))
        #expect(try PluginGitSource.parse("git:owner/repo/a") == PluginGitSource(owner: "owner", repo: "repo", path: "a"))
        #expect(try PluginGitSource.parse("https://github.com/owner/repo") == PluginGitSource(owner: "owner", repo: "repo"))
        #expect(try PluginGitSource.parse("github.com/owner/repo.git") == PluginGitSource(owner: "owner", repo: "repo"))
        #expect(try PluginGitSource.parse("https://github.com/owner/repo/tree/main/plugins/x")
                == PluginGitSource(owner: "owner", repo: "repo", path: "plugins/x", ref: "main"))
        #expect(try PluginGitSource.parse("https://github.com/owner/repo@0123456789abcdef0123456789abcdef01234567")
                == PluginGitSource(owner: "owner", repo: "repo", ref: "0123456789abcdef0123456789abcdef01234567"))
        // --ref wins over a suffix.
        #expect(try PluginGitSource.parse("owner/repo@main", ref: "v2").ref == "v2")
        // An ssh address on GitHub is still GitHub.
        #expect(try PluginGitSource.parse("git@github.com:owner/repo.git") == PluginGitSource(owner: "owner", repo: "repo"))
    }

    @Test func readsGitURLsForOtherHosts() throws {
        let https = try PluginGitSource.parse("git:https://git.example.com:8443/acme/monorepo.git:plugins/review@main")
        #expect(https.url == "https://git.example.com:8443/acme/monorepo.git")
        #expect(https.owner == "acme" && https.repo == "monorepo" && https.path == "plugins/review" && https.ref == "main")
        #expect(!https.isGitHub && https.remote() == "https://git.example.com:8443/acme/monorepo.git")

        let port = try PluginGitSource.parse("https://git.example.com:8443/acme/review.git")
        #expect(port.path == nil && port.url == "https://git.example.com:8443/acme/review.git")

        let scp = try PluginGitSource.parse("git@git.example.com:acme/review.git")
        #expect(scp.url == "git@git.example.com:acme/review.git" && scp.owner == "acme" && scp.repo == "review" && scp.ref == nil)
        let scpFolder = try PluginGitSource.parse("git@git.example.com:acme/mono.git:plugins/x@v1")
        #expect(scpFolder.url == "git@git.example.com:acme/mono.git" && scpFolder.path == "plugins/x" && scpFolder.ref == "v1")

        let file = try PluginGitSource.parse("file:///srv/repos/monorepo:plugins/review")
        #expect(file.url == "file:///srv/repos/monorepo" && file.path == "plugins/review")
        #expect(try PluginGitSource.parse("ssh://git@git.example.com/acme/review.git").repo == "review")
    }

    @Test func refusesWhatIsntARepository() {
        for text in ["", "   ", "kanban", "owner", "/Users/someone/plugin", "./plugin", "~/plugin", "../x",
                     "owner/repo/../escape", "owner/repo/./x", "owner/re po", "-owner/repo", "owner/repo@-x",
                     "owner/repo@a..b", "http://github.com/owner/repo", "git://host/acme/review.git",
                     "http://git.example.com/acme/review.git", "ftp://host/acme/review", "github:https://host/a/b.git",
                     "https://github.com/owner/repo/blob/main/manifest.json", "https://github.com/owner",
                     "owner/repo@main branch"] {
            #expect(throws: PluginSourceError.self, "\(text)") { try PluginGitSource.parse(text) }
        }
        #expect(throws: PluginSourceError.localFolder) { try PluginGitSource.parse("./plugin") }
        #expect(throws: PluginSourceError.insecure) { try PluginGitSource.parse("http://github.com/owner/repo") }
    }

    @Test func sourcesKeepReadingOlderRecords() throws {
        let old = #"{"id":"a","name":"A","version":"1","source":"bundled","enabled":true,"grantedCapabilities":[],"packageHash":"h","installedAt":0}"#
        let record = try JSONDecoder().decode(PluginRecord.self, from: Data(old.utf8))
        #expect(record.source == .bundled)

        let git = PluginSource.git(PluginGitSource(owner: "o", repo: "r", path: "p", ref: "main",
                                                   commit: String(repeating: "a", count: 40)))
        for source in [PluginSource.bundled, .user, .catalog, git] {
            let data = try JSONEncoder().encode([source])
            #expect(try JSONDecoder().decode([PluginSource].self, from: data) == [source])
        }
        #expect(String(decoding: try JSONEncoder().encode([PluginSource.user]), as: UTF8.self) == #"["user"]"#)
        #expect(git.rawValue == "git" && git.plainWords == "From o/r/p")
    }

    // MARK: Installing from a fake GitHub

    private func host() throws -> (PluginManager, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("plugin-git-\(UUID().uuidString)")
        let manager = PluginManager(store: try Store.inMemory(), pluginsRoot: root.appendingPathComponent("Plugins"),
                                    dataRoot: root.appendingPathComponent("PluginData"))
        return (manager, root)
    }

    private let c1 = String(repeating: "1", count: 40)
    private let c2 = String(repeating: "2", count: 40)
    private let c3 = String(repeating: "3", count: 40)

    @Test func installsAFolderAtATagPinnedToItsCommit() async throws {
        let (manager, root) = try host()
        defer { try? FileManager.default.removeItem(at: root) }
        let github = FakeGitHub(["owner/monorepo": .init(head: c2, refs: ["v1.2": c1], trees: [
            c1: ["plugins/x/manifest.json": FakeGitHub.manifest(), "plugins/x/index.html": "<html></html>", "README.md": "hi"],
            c2: ["plugins/x/manifest.json": FakeGitHub.manifest(version: "2.0.0"), "plugins/x/index.html": "<html></html>"],
        ])])
        let candidate = try await manager.inspectGit(try PluginGitSource.parse("owner/monorepo/plugins/x@v1.2"), fetcher: github)
        defer { try? FileManager.default.removeItem(at: candidate.cleanup) }
        #expect(candidate.source.commit == c1 && candidate.inspection.manifest.version == "1.0.0")
        // Only the folder is the package.
        #expect(candidate.inspection.fileCount == 2)

        let record = try manager.install(candidate)
        #expect(!record.enabled)
        #expect(record.source.git?.commit == c1 && record.source.git?.ref == "v1.2" && record.source.git?.path == "plugins/x")
        let installed = manager.installed()
        #expect(installed.first?.problem == nil)
        #expect(installed.first?.record.source.git?.shortCommit == "1111111")
    }

    @Test func refusesAnInvalidPackageFromARepository() async throws {
        let (manager, root) = try host()
        defer { try? FileManager.default.removeItem(at: root) }
        let github = FakeGitHub([
            "owner/tool": .init(head: c1, trees: [c1: ["manifest.json": FakeGitHub.manifest(), "index.html": "x",
                                                     "run.sh": "echo+x"]]),
            "owner/empty": .init(head: c1, trees: [c1: ["README.md": "nothing here"]]),
        ])
        await #expect(throws: PluginValidationError.self) {
            try await manager.inspectGit(PluginGitSource(owner: "owner", repo: "tool"), fetcher: github)
        }
        await #expect(throws: PluginValidationError.self) {
            try await manager.inspectGit(PluginGitSource(owner: "owner", repo: "empty"), fetcher: github)
        }
        await #expect(throws: PluginGitError.self) {
            try await manager.inspectGit(PluginGitSource(owner: "owner", repo: "empty", ref: "nope"), fetcher: github)
        }
        #expect(manager.records().isEmpty)
    }

    @Test func privateRepositoriesNeedYourGitHubAccess() async throws {
        let (manager, root) = try host()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = FakeGitHub.Repo(head: c1, trees: [c1: ["manifest.json": FakeGitHub.manifest(), "index.html": "x"]],
                                   isPrivate: true)
        let source = PluginGitSource(owner: "acme", repo: "private-plugin")
        await #expect(throws: PluginGitError.unreachable("acme/private-plugin")) {
            try await manager.inspectGit(source, fetcher: FakeGitHub(["acme/private-plugin": repo], signedIn: false))
        }
        let candidate = try await manager.inspectGit(source, fetcher: FakeGitHub(["acme/private-plugin": repo]))
        defer { try? FileManager.default.removeItem(at: candidate.cleanup) }
        #expect(try manager.install(candidate).source.git?.commit == c1)
    }

    @Test func updatesAreFoundAndAnUpdateAskingForMoreWaitsForReview() async throws {
        let (manager, root) = try host()
        defer { try? FileManager.default.removeItem(at: root) }
        let github = FakeGitHub(["owner/kanban": .init(head: c1, trees: [
            c1: ["manifest.json": FakeGitHub.manifest(), "index.html": "one"],
            c2: ["manifest.json": FakeGitHub.manifest(version: "1.1.0"), "index.html": "two"],
            c3: ["manifest.json": FakeGitHub.manifest(version: "1.2.0", capabilities: ["chats.read", "chats.create"]),
                 "index.html": "three"],
        ]), "owner/pinned": .init(head: c1, trees: [c1: ["manifest.json": FakeGitHub.manifest(id: "dev.example.pinned"),
                                                           "index.html": "x"]])])
        for source in [PluginGitSource(owner: "owner", repo: "kanban"),
                       PluginGitSource(owner: "owner", repo: "pinned", ref: c1)] {
            let candidate = try await manager.inspectGit(source, fetcher: github)
            try manager.install(candidate)
            try FileManager.default.removeItem(at: candidate.cleanup)
            manager.setEnabled(candidate.inspection.manifest.id, true)
        }
        #expect(await manager.checkGitUpdates(fetcher: github).updates.isEmpty)

        // Nothing new asked: the update keeps it on.
        github.set("owner/kanban") { $0.head = c2 }
        let found = await manager.checkGitUpdates(fetcher: github)
        #expect(found.problems.isEmpty)
        #expect(found.updates.map(\.pluginId) == ["dev.example.kanban"])
        let update = try #require(found.updates.first)
        #expect(update.fromCommit == c1 && update.candidate.source.commit == c2)
        #expect(update.changes?.files == ["index.html", "manifest.json"])
        #expect(!update.grants.asksForMore)
        #expect(update.summary == "1111111 → 2222222: 1 commit, 2 files changed, no new access.")
        // Nothing installs by itself.
        #expect(manager.records().first { $0.id == "dev.example.kanban" }?.source.git?.commit == c1)
        let kept = try manager.install(update.candidate)
        try FileManager.default.removeItem(at: update.candidate.cleanup)
        #expect(kept.enabled && kept.source.git?.commit == c2 && kept.grantedCapabilities == [.chatsRead])

        // A new capability: off until it's reviewed again.
        github.set("owner/kanban") { $0.head = c3 }
        let grown = try #require(await manager.checkGitUpdates(fetcher: github).updates.first)
        #expect(grown.grants.asksForMore && grown.grants.capabilities == [.chatsCreate])
        let waiting = try manager.install(grown.candidate)
        try FileManager.default.removeItem(at: grown.candidate.cleanup)
        #expect(!waiting.enabled && waiting.grantedCapabilities.isEmpty && waiting.source.git?.commit == c3)
    }

    @Test func anUpdateCantSwapInAnotherPlugin() async throws {
        let (manager, root) = try host()
        defer { try? FileManager.default.removeItem(at: root) }
        let github = FakeGitHub(["owner/kanban": .init(head: c1, trees: [
            c1: ["manifest.json": FakeGitHub.manifest(), "index.html": "one"],
            c2: ["manifest.json": FakeGitHub.manifest(id: "dev.example.other"), "index.html": "two"],
        ])])
        let candidate = try await manager.inspectGit(PluginGitSource(owner: "owner", repo: "kanban"), fetcher: github)
        try manager.install(candidate)
        github.set("owner/kanban") { $0.head = c2 }
        let found = await manager.checkGitUpdates(fetcher: github)
        #expect(found.updates.isEmpty && found.problems["dev.example.kanban"] != nil)
    }

    @Test func commandLineAddsAPluginPinnedAndOff() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("plugin-git-cli-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try Store.inMemory()
        let commands = Commands(store: store, storePath: root.appendingPathComponent("abstract.sqlite").path,
                                locks: root.appendingPathComponent("locks"), executable: "/bin/abstract")
        let github = FakeGitHub(["abstract-ade/abstract-plugin-kanban": .init(head: c1, trees: [
            c1: ["manifest.json": FakeGitHub.manifest(), "index.html": "x"]])])
        let added = try await commands.addPlugin("abstract-ade/abstract-plugin-kanban", ref: nil, fetcher: github, registry: nil)
        #expect(added.id == "dev.example.kanban" && added.commit == c1 && !added.enabled)
        #expect(added.repository == "abstract-ade/abstract-plugin-kanban" && added.capabilities == ["chats.read"])
        let record = try #require(commands.plugins.records().first)
        #expect(record.source.git?.commit == c1)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Plugins/dev.example.kanban/1.0.0/manifest.json").path))

        await #expect(throws: CLIError(.invalidArguments, PluginSourceError.localFolder.localizedDescription)) {
            try await commands.addPlugin("./kanban", ref: nil, fetcher: github, registry: nil)
        }
        do {
            _ = try await commands.addPlugin("abstract-ade/missing", ref: nil, fetcher: github, registry: nil)
            Issue.record("a missing repository installed")
        } catch let error as CLIError {
            #expect(error.code == .pluginFailed)
        }
    }
}

extension GitHeavy {
    /// The real git fetcher, against bare repositories on disk standing in
    /// for github.com. A dozen git processes per test: serialized with the
    /// other process-heavy suites so CI's timing-bound tests keep their limits.
    @Suite("Plugin git fetcher")
    struct PluginGitFetcherTests {
        /// A folder standing in for github.com: `<owner>/<repo>.git` bare repositories.
        private func gitHubOnDisk(_ root: URL) async throws -> (base: String, commits: [String]) {
            let exec = LocalExecutor.shared
            let work = root.appendingPathComponent("work").path
            try FileManager.default.createDirectory(atPath: work + "/plugins/x", withIntermediateDirectories: true)
            func git(_ args: [String], in dir: String = work) async throws -> String {
                let result = try await exec.run("git", ["-c", "user.email=test@example.com", "-c", "user.name=Test",
                                                        "-c", "commit.gpgsign=false", "-c", "tag.gpgsign=false"] + args,
                                                cwd: dir, stdin: nil)
                #expect(result.ok, "git \(args): \(result.stderr)")
                return GitText.trimmed(result.stdout)
            }
            _ = try await git(["init", "--quiet", "--initial-branch=main"])
            try FakeGitHub.manifest().write(toFile: work + "/plugins/x/manifest.json", atomically: true, encoding: .utf8)
            try "<html></html>".write(toFile: work + "/plugins/x/index.html", atomically: true, encoding: .utf8)
            try "elsewhere".write(toFile: work + "/README.md", atomically: true, encoding: .utf8)
            _ = try await git(["add", "."])
            _ = try await git(["commit", "--quiet", "-m", "one"])
            _ = try await git(["tag", "-a", "v1.2", "-m", "v1.2"])
            let first = try await git(["rev-parse", "HEAD"])
            try FakeGitHub.manifest(version: "1.1.0").write(toFile: work + "/plugins/x/manifest.json", atomically: true, encoding: .utf8)
            try "changed".write(toFile: work + "/README.md", atomically: true, encoding: .utf8)
            _ = try await git(["commit", "--quiet", "-am", "two"])
            let second = try await git(["rev-parse", "HEAD"])
            let hub = root.appendingPathComponent("github")
            try FileManager.default.createDirectory(at: hub.appendingPathComponent("owner"), withIntermediateDirectories: true)
            _ = try await git(["clone", "--quiet", "--bare", work, hub.appendingPathComponent("owner/monorepo.git").path], in: root.path)
            return (hub.absoluteURL.absoluteString + "/", [first, second])
        }

        @Test func gitFetcherReadsAFolderAtATagAndComparesCommits() async throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("plugin-git-disk-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let (base, commits) = try await gitHubOnDisk(root)
            let fetcher = GitPluginFetcher(githubBase: base)
            let tagged = try PluginGitSource.parse("owner/monorepo/plugins/x@v1.2")
            #expect(try await fetcher.resolve(tagged) == commits[0])
            #expect(try await fetcher.resolve(PluginGitSource(owner: "owner", repo: "monorepo")) == commits[1])
            #expect(try await fetcher.resolve(PluginGitSource(owner: "owner", repo: "monorepo", ref: "main")) == commits[1])
            await #expect(throws: PluginGitError.self) {
                try await fetcher.resolve(PluginGitSource(owner: "owner", repo: "monorepo", ref: "nope"))
            }
            await #expect(throws: PluginGitError.self) {
                try await fetcher.resolve(PluginGitSource(owner: "owner", repo: "missing"))
            }

            let host = FileManager.default.temporaryDirectory.appendingPathComponent("plugin-git-disk-host-\(UUID().uuidString)")
            let manager = PluginManager(store: try Store.inMemory(), pluginsRoot: host.appendingPathComponent("Plugins"),
                                        dataRoot: host.appendingPathComponent("PluginData"))
            defer { try? FileManager.default.removeItem(at: host) }
            let candidate = try await manager.inspectGit(tagged, fetcher: fetcher)
            defer { try? FileManager.default.removeItem(at: candidate.cleanup) }
            #expect(candidate.source.commit == commits[0] && candidate.inspection.manifest.version == "1.0.0")
            #expect(candidate.inspection.fileCount == 2)

            let changes = try await fetcher.compare(tagged, from: commits[0], to: commits[1])
            #expect(changes == PluginGitChanges(commits: 1, files: ["manifest.json"]))

            await #expect(throws: PluginGitError.self) {
                try await manager.inspectGit(PluginGitSource(owner: "owner", repo: "monorepo", path: "plugins/none"), fetcher: fetcher)
            }
        }
    }
}
