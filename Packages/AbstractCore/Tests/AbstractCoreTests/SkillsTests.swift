import Foundation
import Testing
@testable import AbstractCore

/// A library folder, a home with each agent's own config, and Abstract's
/// data folder, all under one temporary folder. Nothing in it is real.
private struct SkillFixture {
    let root: String
    var library: String { root + "/library" }
    var home: String { root + "/home" }
    var data: String { root + "/data" }

    static func make() throws -> SkillFixture {
        let f = SkillFixture(root: NSTemporaryDirectory() + "skills-" + UUID().uuidString)
        try f.write("library/review/SKILL.md", "---\nname: review\ndescription: \"Review a diff\"\n---\n\nRead the diff.\n")
        try f.write("library/nested/skills/release/SKILL.md", "---\nname: release-notes\n---\nWrite notes.\n")
        try f.write("library/plain/SKILL.md", "No front matter.\n")
        try f.write("library/.git/hooks/SKILL.md", "Never a skill.\n")
        try f.write("library/docs/README.md", "Not a skill.\n")
        // The agents' own config, which no launch may change.
        try f.write("home/.codex/auth.json", "{}")
        try f.write("home/.codex/config.toml", "model = \"gpt-5\"\n")
        try f.write("home/.codex/sessions/2026/10/20/rollout.jsonl", "{}\n")
        try f.write("home/.codex/skills/mine/SKILL.md", "---\nname: mine\n---\n")
        try f.write("home/.codex/skills/review/SKILL.md", "---\nname: review\n---\nThe user's own.\n")
        try f.write("home/.claude/skills/theirs/SKILL.md", "---\nname: theirs\n---\n")
        try f.write("home/.config/opencode/opencode.json", "{}")
        try FileManager.default.createDirectory(atPath: f.data, withIntermediateDirectories: true)
        return f
    }

    func write(_ relative: String, _ text: String) throws {
        let path = root + "/" + relative
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Every path under the home with its contents, links not followed.
    func homeSnapshot() -> [String: String] {
        var snapshot: [String: String] = [:]
        let fm = FileManager.default
        for relative in (try? fm.subpathsOfDirectory(atPath: home)) ?? [] {
            let path = home + "/" + relative
            snapshot[relative] = (try? fm.destinationOfSymbolicLink(atPath: path)).map { "-> " + $0 }
                ?? (try? String(contentsOfFile: path, encoding: .utf8)) ?? "dir"
        }
        return snapshot
    }

    func source() -> SkillSource { SkillSource(id: "src", kind: .folder, location: library) }

    func remove() { try? FileManager.default.removeItem(atPath: root) }
}

@Suite struct SkillsTests {
    // MARK: The library

    @Test func everyFolderWithASkillFileIsASkill() throws {
        let f = try SkillFixture.make()
        defer { f.remove() }
        let skills = SkillScanner.skills(in: f.library, sourceId: "src")
        #expect(skills.map(\.name) == ["plain", "release-notes", "review"], "the folder's name stands in for a missing one")
        #expect(skills.map(\.id) == ["src/plain", "src/nested/skills/release", "src/review"])
        #expect(skills.first { $0.name == "review" }?.description == "Review a diff")
        #expect(skills.allSatisfy { !$0.folder.contains("/.git/") })
    }

    @Test func aProjectsOwnSkillsAreReadFromItsAgentFolders() throws {
        let f = try SkillFixture.make()
        defer { f.remove() }
        try f.write("repo/.claude/skills/deploy/SKILL.md", "---\nname: deploy\n---\n")
        try f.write("repo/.agents/skills/lint/SKILL.md", "---\nname: lint\n---\n")
        let skills = SkillScanner.projectSkills(root: f.root + "/repo")
        #expect(skills.map(\.name) == ["deploy", "lint"])
        #expect(skills.map(\.id) == ["project/.claude/skills/deploy", "project/.agents/skills/lint"])
    }

    @Test func aChatGetsItsProjectsSkillsThenItsProfilesEachNameOnce() throws {
        let f = try SkillFixture.make()
        defer { f.remove() }
        let available = SkillLibrary.skills(sources: [f.source()], library: f.data + "/skills")
        let skills = SkillLibrary.chatSkills(project: ["src/review", "gone/skill"], profile: ["src/plain", "src/review"],
                                             available: available)
        #expect(skills.map(\.name) == ["review", "plain"], "an id the library no longer holds is left out")
    }

    @Test func aRepositoryIsReadFromWhatYouPaste() {
        #expect(GitHubRepository.parse("anthropics/skills") == "anthropics/skills")
        #expect(GitHubRepository.parse("https://github.com/anthropics/skills") == "anthropics/skills")
        #expect(GitHubRepository.parse("https://github.com/anthropics/skills.git") == "anthropics/skills")
        #expect(GitHubRepository.parse("https://github.com/anthropics/skills/tree/main/document-skills") == "anthropics/skills")
        #expect(GitHubRepository.parse("git@github.com:anthropics/skills.git") == "anthropics/skills")
        #expect(GitHubRepository.parse("skills") == nil)
        #expect(GitHubRepository.parse("owner/na me") == nil)
        #expect(GitHubRepository.cloneURL("anthropics/skills") == "https://github.com/anthropics/skills.git")
    }

    // MARK: Project assignment

    @Test func aProjectsSkillsRoundTripThroughTheStore() throws {
        let store = try Store.inMemory()
        var project = Project(id: "p1", name: "abstract", rootPath: "/r/abstract")
        try store.save(project)
        #expect(try store.project("p1")?.skillIds == nil)
        #expect(try store.project("p1")?.assignedSkills == [])
        project.skillIds = ["src/review", "src/plain"]
        try store.save(project)
        #expect(try store.project("p1")?.assignedSkills == ["src/review", "src/plain"])
    }

    @Test func projectsFromBeforeSkillsLoadWithNone() throws {
        let store = try Store.inMemory(migratedTo: "v17-reviewer-chats", thenRunning: """
            INSERT INTO projects (id, name, root_path, created_at)
            VALUES ('p1', 'abstract', '/r/abstract', '2026-10-01 12:00:00.000');
            """)
        #expect(try store.project("p1")?.assignedSkills == [])
        // A project from a Mac on an older version has no such field.
        let json = #"{"id":"p2","name":"x","rootPath":"/x","defaultBaseRef":"HEAD","defaultProviderId":"claude","defaultPermissionPolicy":"ask","nestedRepos":[],"sortOrder":0,"createdAt":0,"sparseCheckout":[]}"#
        #expect(try JSONDecoder().decode(Project.self, from: Data(json.utf8)).assignedSkills == [])
    }

    // MARK: Delivery

    private func launch(_ provider: any ProviderDefinition, _ f: SkillFixture, project: [String] = ["src/review", "src/plain"],
                        profile: AgentProfile? = nil, resumeId: String? = nil) -> LaunchSpec {
        var session = Session(id: "chat-1", projectId: "p1", name: "Chat", providerId: provider.id, worktreePath: f.root + "/w")
        if let profile { session.apply(profile) }
        var settings = LaunchSettings(providerOverrides: [:], outputStyle: .default, claudeProfile: nil,
                                      attachmentsDirectory: f.data + "/attachments", agentConfigRoot: f.data + "/agent-config")
        var p = Project(id: "p1", name: "abstract", rootPath: f.root + "/repo")
        p.skillIds = project
        settings.addSkills(for: session, project: p, profile: profile, sources: [f.source()], dataDirectory: f.data)
        return AgentLaunch.spec(for: session, provider: provider, prompt: "hi", resumeId: resumeId, settings: settings, home: f.home)
    }

    /// What's in `dir`: each link's target, or "copy" for a folder of its own.
    private func linked(_ dir: String) -> [String: String] {
        let fm = FileManager.default
        return Dictionary(uniqueKeysWithValues: ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).compactMap { name in
            if let target = try? fm.destinationOfSymbolicLink(atPath: dir + "/" + name) { return (name, target) }
            return name.hasPrefix(".") || !fm.fileExists(atPath: dir + "/" + name + "/SKILL.md") ? nil : (name, "copy")
        })
    }

    @Test func claudeGetsTheSkillsInAFolderItAdds() throws {
        let f = try SkillFixture.make()
        defer { f.remove() }
        let before = f.homeSnapshot()
        let spec = launch(ClaudeProvider(), f)
        let folder = f.data + "/agent-config/chat-1/claude"
        #expect(spec.args.contains(folder))
        #expect(spec.args[spec.args.firstIndex(of: folder)! - 1] == "--add-dir")
        #expect(linked(folder + "/.claude/skills") == ["review": "copy", "plain": "copy"])
        // The resume gets them too.
        #expect(launch(ClaudeProvider(), f, resumeId: "s1").args.contains(folder))
        #expect(f.homeSnapshot() == before, "nothing in the user's own config changes")
    }

    @Test func codexGetsAStandInHomeWithTheUsersOwnAndTheLibrarys() throws {
        let f = try SkillFixture.make()
        defer { f.remove() }
        let before = f.homeSnapshot()
        let spec = launch(CodexProvider(), f)
        let overlay = f.data + "/agent-config/chat-1/codex-home"
        #expect(spec.env["CODEX_HOME"] == overlay)
        #expect(linked(overlay) == ["auth.json": f.home + "/.codex/auth.json", "config.toml": f.home + "/.codex/config.toml",
                                    "sessions": f.home + "/.codex/sessions"],
                "its sign-in, settings and sessions are the real ones")
        #expect(linked(overlay + "/skills") == ["mine": f.home + "/.codex/skills/mine", "review": "copy", "plain": "copy"],
                "a skill the project chose wins over the user's own of the same name")
        #expect(launch(CodexProvider(), f, resumeId: "s1").env["CODEX_HOME"] == overlay, "resuming finds the same sessions")
        #expect(f.homeSnapshot() == before)
    }

    @Test func museReadsTheSameStandInHome() throws {
        let f = try SkillFixture.make()
        defer { f.remove() }
        let before = f.homeSnapshot()
        let spec = launch(MuseProvider(), f)
        #expect(spec.env["CODEX_HOME"] == f.data + "/agent-config/chat-1/codex-home")
        #expect(f.homeSnapshot() == before)
    }

    @Test func openCodeGetsTheSkillsFolderInItsConfigForThisRun() throws {
        let f = try SkillFixture.make()
        defer { f.remove() }
        let before = f.homeSnapshot()
        let spec = launch(OpenCodeProvider(), f)
        let folder = f.data + "/agent-config/chat-1/skills"
        let config = try JSONDecoder().decode(JSONValue.self, from: Data(try #require(spec.env["OPENCODE_CONFIG_CONTENT"]).utf8))
        #expect(config["skills"]?["paths"] == .array([.string(folder)]))
        #expect(linked(folder) == ["review": "copy", "plain": "copy"])
        #expect(!FileManager.default.fileExists(atPath: f.root + "/w/.opencode"), "nothing is written into the worktree")
        #expect(f.homeSnapshot() == before)
    }

    @Test func aChatWithNoSkillsStartsAsBefore() throws {
        let f = try SkillFixture.make()
        defer { f.remove() }
        #expect(!launch(ClaudeProvider(), f, project: []).args.contains { $0.contains("agent-config") })
        #expect(launch(CodexProvider(), f, project: []).env["CODEX_HOME"] == nil)
        #expect(launch(MuseProvider(), f, project: []).env["CODEX_HOME"] == nil)
        #expect(launch(OpenCodeProvider(), f, project: []).env["OPENCODE_CONFIG_CONTENT"] == nil)
    }

    @Test func aSkillTakenOutOfTheProjectIsGoneFromTheNextLaunch() throws {
        let f = try SkillFixture.make()
        defer { f.remove() }
        _ = launch(ClaudeProvider(), f)
        _ = launch(ClaudeProvider(), f, project: ["src/plain"])
        #expect(linked(f.data + "/agent-config/chat-1/claude/.claude/skills") == ["plain": "copy"])
        _ = launch(CodexProvider(), f)
        _ = launch(CodexProvider(), f, project: ["src/plain"])
        #expect(linked(f.data + "/agent-config/chat-1/codex-home/skills") == ["mine": f.home + "/.codex/skills/mine",
                                                                            "review": f.home + "/.codex/skills/review",
                                                                            "plain": "copy"],
                "the user's own review is back once the library's is gone")
    }

    @Test func aProfileAddsItsSkills() throws {
        let f = try SkillFixture.make()
        defer { f.remove() }
        let profile = AgentProfile(id: "rev", name: "Reviewer", skills: ["src/nested/skills/release"])
        _ = launch(ClaudeProvider(), f, project: ["src/review"], profile: profile)
        #expect(Set(linked(f.data + "/agent-config/chat-1/claude/.claude/skills").keys) == ["review", "release-notes"])
    }

    @Test func aChatGetsACopySoItsAgentCantChangeTheLibrary() throws {
        let f = try SkillFixture.make()
        defer { f.remove() }
        _ = launch(ClaudeProvider(), f)
        let copy = f.data + "/agent-config/chat-1/claude/.claude/skills/review/SKILL.md"
        #expect(try String(contentsOfFile: copy, encoding: .utf8) == String(contentsOfFile: f.library + "/review/SKILL.md", encoding: .utf8))
        try "Changed by an agent.".write(toFile: copy, atomically: false, encoding: .utf8)
        #expect(try String(contentsOfFile: f.library + "/review/SKILL.md", encoding: .utf8).contains("Read the diff."))
        // The library changed: the next launch gets the new version.
        try f.write("library/review/SKILL.md", "---\nname: review\n---\nVersion two.\n")
        _ = launch(ClaudeProvider(), f)
        #expect(try String(contentsOfFile: copy, encoding: .utf8).contains("Version two."))
    }

    @Test func theStandInHomeKeepsWhatTheAgentWroteThereAndFollowsTheRealOne() throws {
        let f = try SkillFixture.make()
        defer { f.remove() }
        _ = launch(CodexProvider(), f)
        let overlay = f.data + "/agent-config/chat-1/codex-home"
        try "codex's own".write(toFile: overlay + "/installation_id", atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(atPath: overlay + "/skills/.system", withIntermediateDirectories: true)
        try f.write("home/.codex/history.jsonl", "{}\n")
        try FileManager.default.removeItem(atPath: f.home + "/.codex/auth.json")
        _ = launch(CodexProvider(), f)
        #expect(try String(contentsOfFile: overlay + "/installation_id", encoding: .utf8) == "codex's own")
        #expect(FileManager.default.fileExists(atPath: overlay + "/skills/.system"), "Codex's built-in skills stay where it put them")
        #expect(linked(overlay)["history.jsonl"] == f.home + "/.codex/history.jsonl")
        #expect(linked(overlay)["auth.json"] == nil, "a link to something gone goes too")
    }

    @Test func aDeletedChatsFolderGoes() throws {
        let f = try SkillFixture.make()
        defer { f.remove() }
        _ = launch(ClaudeProvider(), f)
        ChatConfigFiles.remove(root: f.data + "/agent-config", chatId: "chat-1")
        #expect(!FileManager.default.fileExists(atPath: f.data + "/agent-config/chat-1"))
        #expect(FileManager.default.fileExists(atPath: f.library + "/review/SKILL.md"), "the library's skills stay")
    }

    @Test func anAgentThatCantTakeSkillsIsAnnounced() throws {
        struct NoSkills: ProviderDefinition {
            var id: String { "none" }
            var name: String { "Plain Agent" }
            var logoAsset: String { "" }
            var binary: String { "plain" }
            var detectArgs: [String] { [] }
            var followUpMode: FollowUpMode { .respawn }
            func buildLaunch(_ ctx: LaunchContext) -> LaunchSpec { LaunchSpec(command: binary, args: [], cwd: ctx.cwd, keepStdinOpen: false) }
            func buildResume(_ ctx: LaunchContext, resumeId: String) -> LaunchSpec { buildLaunch(ctx) }
            func makeParser() -> OutputParser { ClaudeParser() }
            func buildUserMessage(_ text: String) -> String? { nil }
            func buildPermissionResponse(requestId: String, allow: Bool, input: JSONValue?) -> String? { nil }
            var fallbackModels: ModelCatalog { ModelCatalog(models: []) }
            func discoverModels(executor: any Executor, binary: String?) async -> ModelCatalog? { nil }
            func configuredDefaultModel(home: String) -> String? { nil }
        }
        let f = try SkillFixture.make()
        defer { f.remove() }
        let skills = SkillLibrary.chatSkills(project: ["src/review"], profile: [],
                                             available: SkillLibrary.skills(sources: [f.source()], library: f.data + "/skills"))
        #expect(SkillLibrary.unsupportedNote(provider: NoSkills(), skills: skills)
                == "Plain Agent can't take skills from Abstract, so this chat runs without review.")
        #expect(SkillLibrary.unsupportedNote(provider: NoSkills(), skills: []) == nil)
        #expect(ProviderRegistry.all.allSatisfy { SkillLibrary.unsupportedNote(provider: $0, skills: skills) == nil },
                "Claude, Codex, OpenCode and Muse Code all take them")
        _ = launch(NoSkills(), f)
        #expect(!FileManager.default.fileExists(atPath: f.data + "/agent-config/chat-1"))
    }

    // MARK: Seeing it used

    @Test func aSkillsUseIsReadFromEachAgentsToolCall() {
        #expect(SkillUse.name(tool: "Skill", input: .object(["skill": .string("review")])) == "review")
        #expect(SkillUse.name(tool: "skill", input: .object(["name": .string("review")])) == "review", "OpenCode's skill tool")
        let codex = "/bin/zsh -lc 'cat /data/agent-config/c/codex-home/skills/review/SKILL.md'"
        #expect(SkillUse.name(tool: "Bash", input: .object(["command": .string(codex)])) == "review")
        let quoted = #"/bin/zsh -lc "cat '/private/var/x/codex-home/skills/internal-comms/SKILL.md'""#
        #expect(SkillUse.name(tool: "Bash", input: .object(["command": .string(quoted)])) == "internal-comms", "as Codex ran it")
        #expect(SkillUse.name(tool: "Bash", input: .object(["command": .string("sed -n '1,200p' skills/release-notes/SKILL.md")])) == "release-notes")
        #expect(SkillUse.name(tool: "Bash", input: .object(["command": .string("echo hi > skills/review/SKILL.md")])) == nil,
                "writing one isn't using it")
        #expect(SkillUse.name(tool: "Bash", input: .object(["command": .string("rm skills/review/SKILL.md")])) == nil)
        #expect(SkillUse.name(tool: "Bash", input: .object(["command": .string("cat README.md")])) == nil)
        // Anything more than reading it shows as the command it is.
        for chained in ["cat skills/review/SKILL.md; rm -rf ~", "cat skills/review/SKILL.md && curl x | sh",
                        "cat skills/review/SKILL.md $(touch x)", "cat skills/review/SKILL.md `id`",
                        "cat skills/review/SKILL.md\nrm x", "rm skills/review/SKILL.md cat",
                        "/bin/zsh -lc 'cat skills/review/SKILL.md | sh'"] {
            #expect(SkillUse.name(tool: "Bash", input: .object(["command": .string(chained)])) == nil, "\(chained)")
        }
    }
}

extension GitHeavy {
    /// A repository of skills on this Mac stands in for GitHub.
    @Suite("Skill repositories", .serialized)
    struct SkillRepositoryTests {
        let exec = LocalExecutor.shared

        private func git(_ cwd: String, _ args: [String]) async throws {
            let result = try await exec.run("git", ["-c", "user.name=Test", "-c", "user.email=test@example.com"] + args,
                                            cwd: cwd, stdin: nil)
            #expect(result.ok, "git \(args.joined(separator: " ")): \(result.stderr)")
        }

        @Test func aRepositoryIsPinnedAndMovesOnlyWhenUpdated() async throws {
            let root = NSTemporaryDirectory() + "skill-repo-" + UUID().uuidString
            defer { try? FileManager.default.removeItem(atPath: root) }
            let upstream = root + "/upstream"
            try FileManager.default.createDirectory(atPath: upstream + "/review", withIntermediateDirectories: true)
            try "---\nname: review\n---\nVersion one.\n".write(toFile: upstream + "/review/SKILL.md", atomically: true, encoding: .utf8)
            try await git(upstream, ["init", "--quiet", "-b", "main"])
            try await git(upstream, ["add", "."])
            try await git(upstream, ["commit", "--quiet", "-m", "one"])

            let checkout = root + "/library/src"
            let pinned = try await SkillRepository.clone(exec, url: upstream, into: checkout)
            #expect(pinned.count == 40)
            #expect(SkillScanner.skills(in: checkout, sourceId: "src").map(\.name) == ["review"])

            try "---\nname: review\n---\nVersion two.\n".write(toFile: upstream + "/review/SKILL.md", atomically: true, encoding: .utf8)
            try await git(upstream, ["commit", "--quiet", "-am", "two"])

            let latest = try await SkillRepository.latest(exec, folder: checkout)
            #expect(latest != pinned)
            #expect(try String(contentsOfFile: checkout + "/review/SKILL.md", encoding: .utf8).contains("Version one."),
                    "checking for an update changes nothing")
            let diff = try await SkillRepository.diff(exec, folder: checkout, from: pinned, to: latest)
            let files = Diff.parse(diff)
            #expect(files.map(\.path) == ["review/SKILL.md"])
            #expect(diff.contains("-Version one.") && diff.contains("+Version two."))

            try await SkillRepository.pin(exec, folder: checkout, commit: latest)
            #expect(try String(contentsOfFile: checkout + "/review/SKILL.md", encoding: .utf8).contains("Version two."))
            #expect(try await SkillRepository.latest(exec, folder: checkout) == latest, "up to date now")

            // A change the repository's own attributes would hide still shows.
            try "*.md -diff\n".write(toFile: upstream + "/.gitattributes", atomically: true, encoding: .utf8)
            try "---\nname: review\n---\nVersion three.\n".write(toFile: upstream + "/review/SKILL.md", atomically: true, encoding: .utf8)
            try await git(upstream, ["add", "."])
            try await git(upstream, ["commit", "--quiet", "-m", "three"])
            let hidden = try await SkillRepository.latest(exec, folder: checkout)
            let shown = try await SkillRepository.diff(exec, folder: checkout, from: latest, to: hidden)
            #expect(shown.contains("+Version three.") && !shown.contains("Binary files"))
        }

        @Test func aRepositoryThatCantBeClonedSaysWhy() async throws {
            let root = NSTemporaryDirectory() + "skill-repo-" + UUID().uuidString
            defer { try? FileManager.default.removeItem(atPath: root) }
            await #expect(throws: AbstractError.self) {
                try await SkillRepository.clone(exec, url: root + "/missing", into: root + "/library/src")
            }
        }
    }
}
