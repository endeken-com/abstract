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
}
