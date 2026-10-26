import Foundation
import Testing
@testable import AbstractCore

@Suite struct WorktreeNamingTests {
    @Test func cityNamesStayShortAndAvoidExistingChats() {
        #expect(WorktreeNaming.cities.count >= 250)
        #expect(Set(WorktreeNaming.cities.map { $0.lowercased() }).count == WorktreeNaming.cities.count)
        #expect(WorktreeNaming.cities.allSatisfy { $0.count <= 10 })
        #expect(WorktreeNaming.pairCities.count * (WorktreeNaming.pairCities.count - 1) >= 40_000)

        let first = WorktreeNaming.cityName(avoiding: [])
        #expect(WorktreeNaming.cities.contains(first))
        #expect(first.count <= 10)
        #expect(WorktreeNaming.slugify(first).count <= 10)

        let next = WorktreeNaming.cityName(avoiding: [first.lowercased()])
        #expect(next != first)
        #expect(WorktreeNaming.cities.contains(next))

        let used = Set(WorktreeNaming.cities)
        let pair = WorktreeNaming.cityName(avoiding: used)
        let parts = pair.split(separator: "-").map(String.init)
        #expect(parts.count == 2)
        #expect(parts.count == 2 && parts[0] != parts[1])
        #expect(parts.allSatisfy { WorktreeNaming.pairCities.contains($0) })
        #expect(pair.count <= 15)

        let another = WorktreeNaming.cityName(avoiding: used.union([pair.lowercased()]))
        #expect(another != pair)
    }

    @Test func slugIsFilesystemSafe() {
        #expect(WorktreeNaming.slugify("Add OAuth login!") == "add-oauth-login")
        #expect(WorktreeNaming.slugify("   ") == "session")
        #expect(WorktreeNaming.slugify(String(repeating: "x", count: 200)).count <= 40)
    }

    @Test func slugCollapsesSeparatorsAndDropsNonASCII() {
        #expect(WorktreeNaming.slugify("--Fix   the__Bug--") == "fix-the-bug")
        #expect(WorktreeNaming.slugify("configuração") == "configura-o")
        #expect(WorktreeNaming.slugify("!!!") == "session")
        #expect(!WorktreeNaming.slugify(String(repeating: "ab ", count: 50)).hasSuffix("-"))
    }

    @Test func templateExpandsEveryToken() {
        let out = WorktreeNaming.render(
            template: WorktreeNaming.defaultTemplate, home: "/Users/w", repo: "api", hash: "ab12cd34",
            slug: "fix-login", branch: "abstract/fix-login", prefix: "abstract/")
        #expect(out == "/Users/w/.abstract/worktrees/api-ab12cd34/fix-login")
        let branch = WorktreeNaming.render(
            template: "{prefix}{slug}", home: "", repo: "", hash: "", slug: "fix-login", branch: "", prefix: "abstract/")
        #expect(branch == "abstract/fix-login")
        #expect(WorktreeNaming.defaultBranchPrefix == "abstract/")
    }

    @Test func hashIsStableAndShort() {
        #expect(WorktreeNaming.shortHash("/repo/a").count == 8)
        #expect(WorktreeNaming.shortHash("/repo/a") == WorktreeNaming.shortHash("/repo/a"))
        #expect(WorktreeNaming.shortHash("/repo/a") != WorktreeNaming.shortHash("/repo/b"))
        // SHA-256("abc") = ba7816bf…
        #expect(WorktreeNaming.shortHash("abc") == "ba7816bf")
    }

    // MARK: Automation runs

    private let utc = TimeZone(identifier: "UTC")!
    /// 2026-10-11 09:00 UTC.
    private let nine = Date(timeIntervalSince1970: 1_791_709_200)

    @Test func aRunBranchIsNamedForItsAutomationAndWhenItStarted() {
        #expect(WorktreeNaming.runBranch(automationName: "Roadmap: build the next ticket", at: nine, timeZone: utc)
            == "auto/roadmap-build-the-next-ticket/2026-10-11-0900")
    }

    @Test func aLongAutomationNameIsCutButNeverTheTime() {
        let branch = WorktreeNaming.runBranch(
            automationName: "Every morning, review the open pull requests and summarise them", at: nine, timeZone: utc)
        #expect(branch == "auto/every-morning-review-the-open/2026-10-11-0900")
        let parts = branch.split(separator: "/")
        #expect(parts.count == 3 && parts[1].count <= 30 && !parts[1].hasSuffix("-"))
        // Made safe as a new chat's branch is, it stays whole.
        #expect(WorktreeNaming.branchSlug(branch) == branch)
        #expect(WorktreeNaming.runBranch(automationName: "Nightly", at: nine.addingTimeInterval(14 * 3600 + 7 * 60), timeZone: utc)
            == "auto/nightly/2026-10-11-2307")
    }

    @Test func runsCollideOnlyWithinTheSameMinute() async throws {
        let exec = LocalExecutor.shared
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("abstract-runs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "test@abstract.local"],
                     ["config", "user.name", "Abstract Test"], ["config", "commit.gpgsign", "false"],
                     ["commit", "-q", "--allow-empty", "-m", "init"]] {
            let out = try await exec.run("git", args, cwd: root.path)
            try #require(out.ok, "git \(args): \(out.stderr)")
        }
        let project = Project(name: "repo", rootPath: root.path, defaultBaseRef: "main")
        func run(at date: Date, in city: String) async throws -> String {
            try await Workspace.provision(
                executor: exec, project: project, name: "Nightly · Oct 11", baseRef: nil, template: dir.path + "/wt/{slug}",
                prefix: "", slug: WorktreeNaming.runBranch(automationName: "Nightly", at: date, timeZone: utc),
                worktreeName: city).branch
        }
        #expect(try await run(at: nine, in: "Oslo") == "auto/nightly/2026-10-11-0900")
        #expect(try await run(at: nine.addingTimeInterval(3600), in: "Lima") == "auto/nightly/2026-10-11-1000")
        #expect(try await run(at: nine.addingTimeInterval(20), in: "Cork") == "auto/nightly/2026-10-11-0900-1")
    }
}
