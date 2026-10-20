import Foundation
import Testing
@testable import AbstractCore

@Suite struct ProfilesTests {
    /// The ticket's own example: a Reviewer on Codex, high effort,
    /// asking before acting, with review instructions. One fixed
    /// profile, so every mention below is the same one.
    let reviewer = AgentProfile(
        id: "reviewer-1", name: "Reviewer", iconSymbol: "magnifyingglass", providerId: "codex",
        model: "gpt-5", effort: "high", permissionPolicy: .ask,
        instructions: "You review changes; report risks, most serious first.",
        createdAt: Date(timeIntervalSinceReferenceDate: 800_000_000))

    private func settings(history: Bool = false) -> LaunchSettings {
        var settings = LaunchSettings(providerOverrides: [:], outputStyle: .default, claudeProfile: nil,
                                      attachmentsDirectory: "/tmp/attachments")
        if history { settings.codeHistory = CodeHistorySettings(command: "/bin/abstract") }
        return settings
    }

    private func chat(from profile: AgentProfile) -> Session {
        var session = Session(projectId: nil, name: "Chat", providerId: "claude", worktreePath: "/w")
        session.apply(profile)
        return session
    }

    // MARK: Launch specs

    @Test func aChatStartsWithItsProfilesSetup() {
        let session = chat(from: reviewer)
        #expect(session.providerId == "codex")
        #expect(session.model == "gpt-5")
        #expect(session.effort == "high")
        #expect(session.permissionPolicy == .ask)
        #expect(session.profileName == "Reviewer")
        #expect(session.profileInstructions == reviewer.instructions)
    }

    @Test func codexGetsTheInstructionsAsDeveloperInstructions() {
        let spec = AgentLaunch.spec(for: chat(from: reviewer), provider: CodexProvider(), prompt: "Review this",
                                    resumeId: nil, settings: settings(), home: "/tmp")
        #expect(spec.args.contains { $0.hasPrefix("developer_instructions=") && $0.contains("most serious first") })
        // And the rest of the profile, on the same command line.
        #expect(spec.args.contains("-m") && spec.args.contains("gpt-5"))
        #expect(spec.args.contains(#"model_reasoning_effort="high""#))
        #expect(spec.args.contains("workspace-write"))
    }

    @Test func claudeGetsTheInstructionsAppendedToItsSystemPrompt() throws {
        var profile = reviewer
        profile.providerId = "claude"
        let spec = AgentLaunch.spec(for: chat(from: profile), provider: ClaudeProvider(), prompt: "Review this",
                                    resumeId: nil, settings: settings(history: true), home: "/tmp")
        let index = try #require(spec.args.firstIndex(of: "--append-system-prompt"))
        let appended = spec.args[index + 1]
        // One argument carries the profile's instructions and the
        // code-history instruction after them.
        #expect(spec.args.filter { $0 == "--append-system-prompt" }.count == 1)
        #expect(appended.hasPrefix("You review changes"))
        #expect(appended.contains(CodeHistory.instruction))
        #expect(spec.args.contains("--mcp-config"))
    }

    @Test func openCodeGetsTheInstructionsAsItsAgentsPrompt() {
        var profile = reviewer
        profile.providerId = "opencode"
        let spec = AgentLaunch.spec(for: chat(from: profile), provider: OpenCodeProvider(), prompt: "Review this",
                                    resumeId: nil, settings: settings(history: true), home: "/tmp")
        #expect(spec.args.contains("--agent") && spec.args.contains(OpenCodeProvider.profileAgent))
        let config = spec.env["OPENCODE_CONFIG_CONTENT"] ?? ""
        #expect(config.contains("most serious first"))
        // The code-history server rides in the same config.
        #expect(config.contains(CodeHistory.serverName))
    }

    @Test func openCodesPlanAgentKeepsTheAgentSlotOverAProfile() {
        // Plan and Ask run on OpenCode's built-in plan agent, which
        // cannot edit; a profile's instructions ride on the prompt then.
        var session = chat(from: reviewer)
        session.providerId = "opencode"
        session.permissionPolicy = .plan
        let spec = AgentLaunch.spec(for: session, provider: OpenCodeProvider(), prompt: "Plan this",
                                    resumeId: nil, settings: settings(), home: "/tmp")
        #expect(spec.args.contains("plan") && !spec.args.contains(OpenCodeProvider.profileAgent))
        #expect(spec.args.last?.contains("most serious first") == true)
        #expect(spec.args.last?.hasSuffix("Plan this") == true)
    }

    @Test func aChatFromNoProfileLaunchesAsBefore() {
        let session = Session(projectId: nil, name: "Chat", providerId: "claude", worktreePath: "/w")
        let spec = AgentLaunch.spec(for: session, provider: ClaudeProvider(), prompt: "hi",
                                    resumeId: nil, settings: settings(), home: "/tmp")
        #expect(!spec.args.contains("--append-system-prompt"))
        let opencode = AgentLaunch.spec(for: session, provider: OpenCodeProvider(), prompt: "hi",
                                        resumeId: nil, settings: settings(), home: "/tmp")
        #expect(!opencode.args.contains("--agent"))
        #expect(opencode.env.isEmpty)
    }

    @Test func editingAProfileChangesLaterChatsNotARunningOne() {
        let running = chat(from: reviewer)
        var edited = reviewer
        edited.model = "gpt-5-mini"
        edited.instructions = "Be brief."
        // The running chat kept what it started with; the next one
        // starts from the edited profile.
        #expect(running.model == "gpt-5")
        #expect(running.profileInstructions?.contains("most serious first") == true)
        let later = chat(from: edited)
        #expect(later.model == "gpt-5-mini")
        #expect(later.profileInstructions == "Be brief.")
    }

    // MARK: Storing them

    @Test func profilesRoundTripThroughTheStore() throws {
        let store = try Store.inMemory()
        var profile = reviewer
        profile.skills = ["review"]
        profile.mcpServers = ["linear"]
        try store.save(profile)
        #expect(try store.profile(profile.id) == profile)
        #expect(try store.profiles() == [profile])

        let session = chat(from: profile)
        try store.save(session)
        let kept = try #require(try store.session(session.id))
        #expect(kept.profileSnapshot == profile.snapshot)

        try store.deleteProfile(profile.id)
        #expect(try store.profiles().isEmpty)
        // The chat keeps the name and instructions it started with.
        #expect(try store.session(session.id)?.profileSnapshot == profile.snapshot)
    }

    @Test func aProjectKeepsWhichProfilesItOffers() throws {
        let store = try Store.inMemory()
        var project = Project(name: "abstract", rootPath: "/r")
        try store.save(project)
        #expect(try store.project(project.id)?.profileIds == nil)
        project.profileIds = [reviewer.id]
        try store.save(project)
        #expect(try store.project(project.id)?.profileIds == [reviewer.id])
        #expect(AgentProfile.visible(AgentProfile.starters + [reviewer], in: project) == [reviewer])
        #expect(AgentProfile.visible([reviewer], in: nil) == [reviewer])
    }

    @Test func theStartersAreSeededOnceAndCanAllGo() throws {
        let store = try Store.inMemory()
        try store.seedStarterProfilesIfNeeded()
        #expect(try store.profiles().map(\.name) == ["Implementer", "Reviewer", "Planner"])
        for profile in try store.profiles() { try store.deleteProfile(profile.id) }
        try store.seedStarterProfilesIfNeeded()
        #expect(try store.profiles().isEmpty)
    }

    @Test func dataFromBeforeProfilesLoadsAndGainsThem() throws {
        let store = try Store.inMemory(migratedTo: "v13-code-history", thenRunning: """
            INSERT INTO projects (id, name, root_path, created_at)
            VALUES ('p1', 'abstract', '/r/abstract', '2026-09-01 12:00:00.000');
            INSERT INTO sessions (id, project_id, name, provider_id, created_at)
            VALUES ('s1', 'p1', 'Old chat', 'claude', '2026-09-01 12:00:00.000');
            INSERT INTO automations (id, name, prompt, provider_id, project_id, rrule, timezone, dtstart,
                                     created_at, updated_at, triggers)
            VALUES ('a1', 'Nightly', 'Run the tests', 'claude', 'p1', '', 'UTC', '2026-09-01 12:00:00.000',
                    '2026-09-01 12:00:00.000', '2026-09-01 12:00:00.000', '[]');
            """)
        #expect(try store.profiles().isEmpty)
        #expect(try store.project("p1")?.profileIds == nil)
        #expect(try store.session("s1")?.profileSnapshot == nil)
        #expect(try store.automation("a1")?.profileId == nil)

        var session = try #require(try store.session("s1"))
        session.apply(reviewer)
        try store.save(session)
        try store.save(reviewer)
        #expect(try store.session("s1")?.profileSnapshot == reviewer.snapshot)
        #expect(try store.profiles() == [reviewer])
    }

    @Test func aProfileSavedBeforeAFieldExistedStillDecodes() throws {
        let json = #"{"id":"p1","name":"Reviewer","providerId":"codex"}"#
        let profile = try JSONDecoder().decode(AgentProfile.self, from: Data(json.utf8))
        #expect(profile.name == "Reviewer" && profile.providerId == "codex")
        #expect(profile.permissionPolicy == .ask && profile.instructions.isEmpty && profile.skills.isEmpty)
    }

    // MARK: Automations

    @Test func anAutomationRunStartsFromItsProfileAsItIsNow() throws {
        let store = try Store.inMemory()
        var automation = Automation(name: "Nightly review", prompt: "Review today's diff", providerId: "claude",
                                    projectId: nil, triggers: [], permissionPolicy: .bypass, model: "opus")
        automation.profileId = reviewer.id
        try store.save(automation)
        #expect(try store.automation(automation.id)?.profileId == reviewer.id)

        let run = automation.resolved(with: reviewer)
        #expect(run.providerId == "codex" && run.model == "gpt-5" && run.effort == "high")
        #expect(run.permissionPolicy == .ask)
        #expect(run.prompt == automation.prompt)

        // A chat that run starts carries the profile's instructions.
        var session = Session(projectId: nil, name: "Run", providerId: run.providerId, worktreePath: "/w",
                              permissionPolicy: run.permissionPolicy, automationId: run.id,
                              model: run.model, effort: run.effort)
        session.apply(reviewer.snapshot)
        let spec = AgentLaunch.spec(for: session, provider: CodexProvider(), prompt: run.prompt,
                                    resumeId: nil, settings: settings(), home: "/tmp")
        #expect(spec.args.contains { $0.hasPrefix("developer_instructions=") && $0.contains("most serious first") })

        // Editing the profile's model changes the next run.
        var edited = reviewer
        edited.model = "gpt-5-mini"
        #expect(automation.resolved(with: edited).model == "gpt-5-mini")
        // A profile that isn't the automation's changes nothing, and a
        // deleted one leaves the automation on its own settings.
        #expect(automation.resolved(with: AgentProfile(name: "Other")) == automation)
        #expect(automation.resolved(with: nil) == automation)
    }
}
