import Testing
@testable import AbstractCore

@Suite struct WorktreeNamingTests {
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
