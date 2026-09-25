import Testing
import AbstractCore

@Suite("Slash commands")
struct SlashCommandsTests {
    let claude = ProviderCommands(extra: [.tasks], replaces: ["permissions": .mode])

    func names(_ entries: [SlashEntry]) -> [String] { entries.map(\.name) }

    @Test func opensOnlyWhileTypingACommandName() {
        #expect(SlashCommands.query(forDraft: "/") == "")
        #expect(SlashCommands.query(forDraft: "/re") == "re")
        #expect(SlashCommands.query(forDraft: "/plugin:do-it") == "plugin:do-it")
        #expect(SlashCommands.query(forDraft: "/re x") == nil)
        #expect(SlashCommands.query(forDraft: "/usr/local is full") == nil)
        #expect(SlashCommands.query(forDraft: "/re\nmore") == nil)
        #expect(SlashCommands.query(forDraft: "a/b") == nil)
        #expect(SlashCommands.query(forDraft: " /re") == nil)
        #expect(SlashCommands.query(forDraft: "") == nil)
    }

    @Test func aBareSlashListsTheAppsCommandsThenTheAgents() {
        let entries = SlashCommands.entries(query: "", agentCommands: [AgentCommand(name: "compact"), AgentCommand(name: "deep-dive", kind: .skill)],
                                            provider: .none, excluding: [])
        #expect(names(entries) == ["agent", "model", "effort", "mode", "stop", "diff", "rename", "attach", "compact", "deep-dive"])
    }

    @Test func agentCommandsTheAppHandlesAreDropped() {
        let entries = SlashCommands.entries(query: "", agentCommands: [AgentCommand(name: "model"), AgentCommand(name: "permissions"), AgentCommand(name: "review")],
                                            provider: claude, excluding: [])
        #expect(entries.contains(.app(.model)))
        #expect(!entries.contains(.agent(AgentCommand(name: "model"))))
        #expect(!names(entries).contains("permissions"))
        #expect(entries.contains(.agent(AgentCommand(name: "review"))))
    }

    @Test func providerExtrasOnlyForThatProvider() {
        #expect(SlashCommands.entries(query: "", agentCommands: [], provider: claude, excluding: []).contains(.app(.tasks)))
        #expect(!SlashCommands.entries(query: "", agentCommands: [], provider: .none, excluding: []).contains(.app(.tasks)))
        // Without the extra, an agent's own "tasks" stays its own.
        #expect(SlashCommands.entries(query: "", agentCommands: [AgentCommand(name: "tasks")], provider: .none, excluding: [])
            .contains(.agent(AgentCommand(name: "tasks"))))
    }

    @Test func unavailableCommandsAreLeftOut() {
        #expect(AppCommand.unavailable(working: false, remote: false) == [.stop])
        #expect(AppCommand.unavailable(working: true, remote: false).isEmpty)
        #expect(AppCommand.unavailable(working: true, remote: true) == [.rename])
        let entries = SlashCommands.entries(query: "", agentCommands: [AgentCommand(name: "stop")], provider: .none, excluding: [.stop])
        #expect(!names(entries).contains("stop")) // neither the app's nor the agent's
    }

    @Test func filtersFuzzilyAppCommandsFirstThenByScore() {
        let agent = [AgentCommand(name: "review"), AgentCommand(name: "security-review"), AgentCommand(name: "compact")]
        #expect(names(SlashCommands.entries(query: "rev", agentCommands: agent, provider: .none, excluding: [])) == ["review", "security-review"])
        #expect(names(SlashCommands.entries(query: "m", agentCommands: [AgentCommand(name: "memory")], provider: .none, excluding: []))
            == ["model", "mode", "rename", "memory"])
        #expect(SlashCommands.entries(query: "zzz", agentCommands: agent, provider: .none, excluding: []).isEmpty)
    }

    @Test func anExactNameComesFirst() {
        // "mode" scores the same against "model", which is listed first.
        #expect(SlashCommands.entries(query: "mode", agentCommands: [], provider: .none, excluding: []).first == .app(.mode))
        // An agent's exact name beats an app command that only loosely matches.
        #expect(SlashCommands.entries(query: "re", agentCommands: [AgentCommand(name: "re")], provider: .none, excluding: []).first
            == .agent(AgentCommand(name: "re")))
    }

    @Test func namespacedNamesMatch() {
        let entries = SlashCommands.entries(query: "plug:do", agentCommands: [AgentCommand(name: "plugin:do-it")], provider: .none, excluding: [])
        #expect(entries == [.agent(AgentCommand(name: "plugin:do-it"))])
    }

    @Test func aFullAppCommandRunsInsteadOfBeingSent() {
        #expect(SlashCommands.appCommand(forDraft: "/model", provider: .none, excluding: []) == .model)
        #expect(SlashCommands.appCommand(forDraft: "/model \n", provider: .none, excluding: []) == .model)
        #expect(SlashCommands.appCommand(forDraft: "/model x", provider: .none, excluding: []) == nil)
        #expect(SlashCommands.appCommand(forDraft: "/compact", provider: .none, excluding: []) == nil)
        #expect(SlashCommands.appCommand(forDraft: "/tasks", provider: .none, excluding: []) == nil)
        #expect(SlashCommands.appCommand(forDraft: "/tasks", provider: claude, excluding: []) == .tasks)
        #expect(SlashCommands.appCommand(forDraft: "/stop", provider: .none, excluding: [.stop]) == nil)
    }

    @Test func claudeAddsTasksAndTakesOverPermissions() {
        #expect(ClaudeProvider().commands == ProviderCommands(extra: [.tasks], replaces: ["permissions": .mode]))
        #expect(CodexProvider().commands == .none)
    }

    @Test func fuzzyScoreRewardsRunsAndWordStarts() {
        #expect(FuzzyScore.score("review", "rev") > FuzzyScore.score("security-review", "rev"))
        #expect(FuzzyScore.score("show changes", "sc") > 0)
        #expect(FuzzyScore.score("model", "x") == 0)
    }
}
