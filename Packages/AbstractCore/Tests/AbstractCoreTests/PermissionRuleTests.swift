import Foundation
import Testing
@testable import AbstractCore

/// Remembered permission answers: matching, precedence, expiry and storage.
@Suite struct PermissionRuleTests {
    static let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func rule(_ kind: PermissionRuleKind, _ pattern: String, _ decision: PermissionDecision = .allow,
                      expires: Date? = nil, project: String = "p1") -> PermissionRule {
        PermissionRule(id: "\(kind)-\(pattern)-\(decision)", projectId: project, kind: kind, pattern: pattern,
                       decision: decision, expiresAt: expires, createdAt: Self.now)
    }

    private func bash(_ command: String) -> JSONValue { .object(["command": .string(command)]) }
    private func file(_ path: String) -> JSONValue { .object(["file_path": .string(path)]) }

    // MARK: - Matching

    @Test func commandPatternsMatchCommands() {
        let npm = rule(.command, "npm test*")
        #expect(npm.matches(toolName: "Bash", input: bash("npm test -- --watch=false"), at: Self.now))
        #expect(npm.matches(toolName: "Bash", input: bash("npm test"), at: Self.now))
        #expect(!npm.matches(toolName: "Bash", input: bash("npm run test"), at: Self.now))
        #expect(!npm.matches(toolName: "Bash", input: bash("npm tes"), at: Self.now))
        // A command rule never answers a request with no command.
        #expect(!npm.matches(toolName: "Read", input: file("npm test"), at: Self.now))
        // The shell wrapper some agents add doesn't hide the command.
        #expect(npm.matches(toolName: "Bash", input: bash(#"/bin/zsh -lc "npm test""#), at: Self.now))
        // An exact pattern is the whole command, nothing more.
        #expect(!rule(.command, "npm test").matches(toolName: "Bash", input: bash("npm test --watch"), at: Self.now))
        #expect(rule(.command, "make ?est").matches(toolName: "Bash", input: bash("make test"), at: Self.now))
    }

    @Test func pathPatternsMatchPaths() {
        let src = rule(.path, "src/**")
        #expect(src.matches(toolName: "Edit", input: file("/wt/chat/src/app/main.swift"), root: "/wt/chat", at: Self.now))
        #expect(src.matches(toolName: "Write", input: file("src/new.swift"), at: Self.now))
        #expect(!src.matches(toolName: "Edit", input: file("/wt/chat/lib/main.swift"), root: "/wt/chat", at: Self.now))
        #expect(!src.matches(toolName: "Edit", input: file("/wt/chat/src2/main.swift"), root: "/wt/chat", at: Self.now))
        // One star stays inside its folder; `**` crosses folders.
        #expect(rule(.path, "src/*.swift").matches(toolName: "Edit", input: file("src/a.swift"), at: Self.now))
        #expect(!rule(.path, "src/*.swift").matches(toolName: "Edit", input: file("src/app/a.swift"), at: Self.now))
        #expect(rule(.path, "src/**/*.swift").matches(toolName: "Edit", input: file("src/app/a.swift"), at: Self.now))
        // A full-path pattern matches the full path; other path keys count too.
        #expect(rule(.path, "/wt/**").matches(toolName: "Edit", input: .object(["filePath": .string("/wt/a.swift")]), root: "/wt", at: Self.now))
        #expect(rule(.path, "docs/**").matches(toolName: "Edit", input: .object(["path": .string("./docs/guide.md")]), at: Self.now))
        // A path rule never answers a request with no path.
        #expect(!src.matches(toolName: "Bash", input: bash("cat src/a.swift"), at: Self.now))
    }

    @Test func toolPatternsMatchToolNames() {
        #expect(rule(.tool, "mcp__linear__get_issue").matches(toolName: "mcp__linear__get_issue", input: .object([:]), at: Self.now))
        #expect(!rule(.tool, "mcp__linear__get_issue").matches(toolName: "mcp__linear__list_issues", input: .object([:]), at: Self.now))
        #expect(rule(.tool, "mcp__linear__*").matches(toolName: "mcp__linear__list_issues", input: .object([:]), at: Self.now))
        #expect(!rule(.tool, "").matches(toolName: "Bash", input: bash("ls"), at: Self.now))
    }

    @Test func denyBeatsAllowAndExpiryStopsARule() {
        let rules = [rule(.command, "rm *"), rule(.command, "rm -rf*", .deny)]
        let answer = PermissionRule.answer(rules, toolName: "Bash", input: bash("rm -rf build"), at: Self.now)
        #expect(answer?.decision == .deny && answer?.pattern == "rm -rf*")
        #expect(answer?.note == "Denied by rule `rm -rf*`")
        #expect(PermissionRule.answer(rules, toolName: "Bash", input: bash("rm build.log"), at: Self.now)?.decision == .allow)
        #expect(PermissionRule.answer(rules, toolName: "Bash", input: bash("ls"), at: Self.now) == nil)

        let expired = rule(.command, "npm test*", expires: Self.now.addingTimeInterval(-1))
        let later = rule(.command, "npm test*", .deny, expires: Self.now.addingTimeInterval(3600))
        #expect(expired.isExpired(at: Self.now) && !later.isExpired(at: Self.now))
        #expect(PermissionRule.answer([expired], toolName: "Bash", input: bash("npm test"), at: Self.now) == nil)
        #expect(PermissionRule.answer([expired, later], toolName: "Bash", input: bash("npm test"), at: Self.now) == later)
        #expect(PermissionRule.answer([later], toolName: "Bash", input: bash("npm test"),
                                      at: Self.now.addingTimeInterval(7200)) == nil)
    }

    @Test func suggestionsComeFromTheRequest() {
        #expect(PermissionRule.suggested(toolName: "Bash", input: bash("npm test -- --watch=false")).pattern == "npm test -- --watch=false")
        #expect(PermissionRule.suggested(toolName: "Bash", input: bash("npm test -- --watch=false")).kind == .command)
        let edit = PermissionRule.suggested(toolName: "Edit", input: file("/wt/chat/src/app/main.swift"), root: "/wt/chat")
        #expect(edit.kind == .path && edit.pattern == "src/**")
        #expect(PermissionRule.suggested(toolName: "Write", input: file("notes.md")).pattern == "notes.md")
        let mcp = PermissionRule.suggested(toolName: "mcp__linear__get_issue", input: .object(["id": .string("1")]))
        #expect(mcp.kind == .tool && mcp.pattern == "mcp__linear__get_issue")
    }

    // MARK: - Storage

    @Test func rulesRoundTripAndDelete() throws {
        let store = try Store.inMemory()
        try store.save(Project(id: "p1", name: "api", rootPath: "/r/api"))
        try store.save(Project(id: "p2", name: "web", rootPath: "/r/web"))
        let allow = rule(.command, "npm test*")
        var deny = rule(.command, "rm -rf*", .deny, expires: Self.now.addingTimeInterval(86_400))
        deny.id = "deny-1"
        try store.save(allow)
        try store.save(deny)
        try store.save(rule(.tool, "Read", project: "p2"))
        #expect(try store.permissionRules(projectId: "p1") == [allow, deny])
        #expect(try store.permissionRules(projectId: "p2").map(\.pattern) == ["Read"])

        // Editing a rule updates it in place.
        var edited = allow
        edited.pattern = "npm run test*"
        edited.expiresAt = Self.now.addingTimeInterval(3600)
        try store.save(edited)
        #expect(try store.permissionRules(projectId: "p1") == [edited, deny])

        // Deleting it brings the card back: nothing answers the request now.
        try store.deletePermissionRule(edited.id)
        let remaining = try store.permissionRules(projectId: "p1")
        #expect(remaining == [deny])
        #expect(PermissionRule.answer(remaining, toolName: "Bash", input: bash("npm run test"), at: Self.now) == nil)

        // A project's rules go with the project.
        try store.deleteProject("p1")
        #expect(try store.permissionRules(projectId: "p1").isEmpty)
        #expect(try store.permissionRules(projectId: "p2").count == 1)
    }

    @Test func databasesFromBeforeRulesGainAnEmptyTable() throws {
        let store = try Store.inMemory(migratedTo: "v12-automation-device", thenRunning: """
            INSERT INTO projects (id, name, root_path, created_at) VALUES ('p1', 'api', '/r/api', '2026-09-01 12:00:00.000');
            """)
        #expect(try store.permissionRules(projectId: "p1").isEmpty)
        try store.save(rule(.path, "src/**"))
        #expect(try store.permissionRules(projectId: "p1").map(\.pattern) == ["src/**"])
    }

    /// Applying a rule in Claude's permission flow: the answer Abstract
    /// sends for a `can_use_tool` request is the rule's decision, written
    /// by Claude's own response builder.
    @Test func aRuleAnswersAClaudePermissionRequest() throws {
        let store = try Store.inMemory()
        try store.save(Project(id: "p1", name: "api", rootPath: "/r/api"))
        try store.save(rule(.command, "npm test*"))
        try store.save(rule(.command, "rm -rf*", .deny))

        let provider = ClaudeProvider()
        // A new chat in the same project: its `npm test` runs without a card.
        let allowed = PermissionRule.answer(try store.permissionRules(projectId: "p1"), toolName: "Bash",
                                            input: bash("npm test -- --watch=false"), root: "/r/api", at: Self.now)
        let allowLine = try #require(provider.buildPermissionResponse(
            requestId: "req-1", allow: allowed?.decision == .allow, input: bash("npm test -- --watch=false")))
        #expect(allowLine.contains(#""behavior":"allow""#))
        #expect(allowed?.note == "Allowed by rule `npm test*`")

        let denied = PermissionRule.answer(try store.permissionRules(projectId: "p1"), toolName: "Bash",
                                           input: bash("rm -rf /"), root: "/r/api", at: Self.now)
        let denyLine = try #require(provider.buildPermissionResponse(
            requestId: "req-2", allow: denied?.decision == .allow, input: bash("rm -rf /")))
        #expect(denyLine.contains(#""behavior":"deny""#))
    }
}
