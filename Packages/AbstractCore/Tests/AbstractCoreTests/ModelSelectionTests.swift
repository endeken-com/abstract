import Foundation
import Testing
@testable import AbstractCore

@Suite("Model selection")
struct ModelSelectionTests {
    @Test func claudePassesTheChosenModel() {
        let spec = ClaudeProvider().buildLaunch(LaunchContext(cwd: "/w", prompt: "p", permissionPolicy: .autoEdits, model: "sonnet"))
        let i = try? #require(spec.args.firstIndex(of: "--model"))
        #expect(i.map { spec.args[$0 + 1] } == "sonnet")
    }

    @Test func codexPassesTheChosenModelBeforeThePrompt() {
        let spec = CodexProvider().buildLaunch(LaunchContext(cwd: "/w", prompt: "do it", permissionPolicy: .autoEdits, model: "gpt-6-astra"))
        let i = try? #require(spec.args.firstIndex(of: "-m"))
        #expect(i.map { spec.args[$0 + 1] } == "gpt-6-astra")
        #expect(spec.args.last == "do it")
    }

    @Test func blankModelMeansTheAgentsOwnDefault() {
        let spec = ClaudeProvider().buildLaunch(LaunchContext(cwd: "/w", prompt: "p", permissionPolicy: .ask, model: "  "))
        #expect(!spec.args.contains("--model"))
        let resume = ClaudeProvider().buildResume(LaunchContext(cwd: "/w", prompt: "p", permissionPolicy: .ask, model: "opus"), resumeId: "abc")
        #expect(resume.args.contains("--model") && resume.args.contains("--resume"))
    }

    @Test func configuredDefaultsAreReadFromEachCLIsOwnConfig() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("home-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: home + "/.claude", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: home + "/.codex", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: home) }
        try #"{"model": "opus[1m]", "theme": "dark"}"#.write(toFile: home + "/.claude/settings.json", atomically: true, encoding: .utf8)
        try "model_reasoning_effort = \"high\"\nmodel = \"gpt-6-astra\"\n\n[profiles.fast]\nmodel = \"other\"\n"
            .write(toFile: home + "/.codex/config.toml", atomically: true, encoding: .utf8)
        #expect(ClaudeProvider().configuredDefaultModel(home: home) == "opus[1m]")
        #expect(CodexProvider().configuredDefaultModel(home: home) == "gpt-6-astra")
        #expect(ClaudeProvider().configuredDefaultModel(home: home + "/missing") == nil)
    }
}

@Suite("Model persistence")
struct ModelPersistenceTests {
    @Test func sessionsAndAutomationsRememberTheirModel() throws {
        let store = try Store.inMemory()
        let project = Project(name: "p", rootPath: "/tmp/p")
        try store.save(project)
        try store.save(Session(id: "s", projectId: project.id, name: "chat", providerId: "claude", model: "sonnet"))
        try store.save(Session(id: "d", projectId: project.id, name: "default", providerId: "claude"))
        try store.save(Automation(id: "a", name: "nightly", prompt: "x", providerId: "codex", projectId: project.id,
                                  rrule: "FREQ=DAILY", timezone: "UTC", model: "gpt-6-astra"))
        #expect(try store.session("s")?.model == "sonnet")
        #expect(try store.session("d")?.model == nil)
        #expect(try store.automation("a")?.model == "gpt-6-astra")
    }
}

@Suite("Claude profiles")
struct ClaudeProfileConversationTests {
    @Test func conversationsFollowYouToAnotherAccount() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent(".claude"), new = root.appendingPathComponent(".claude-work")
        let folder = old.appendingPathComponent("projects/-Users-me-wt")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("abc/subagents"), withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: folder.appendingPathComponent("abc.jsonl"))
        #expect(ClaudeAccounts.carryConversation("abc", into: new.path, from: [old.path, new.path]))
        let copied = new.appendingPathComponent("projects/-Users-me-wt")
        #expect(FileManager.default.fileExists(atPath: copied.appendingPathComponent("abc.jsonl").path))
        #expect(FileManager.default.fileExists(atPath: copied.appendingPathComponent("abc/subagents").path))
        // Already there: nothing to do. Nowhere: false.
        #expect(ClaudeAccounts.carryConversation("abc", into: new.path, from: [old.path]))
        #expect(!ClaudeAccounts.carryConversation("zzz", into: new.path, from: [old.path, new.path]))
    }

    @Test func signInFailuresAreRecognised() {
        #expect(ClaudeAccounts.isSignInFailure("Failed to authenticate: OAuth session expired and could not be refreshed"))
        #expect(ClaudeAccounts.isSignInFailure("Invalid API key · Please run /login"))
        #expect(!ClaudeAccounts.isSignInFailure("No conversation found with session ID: x"))
    }
}
