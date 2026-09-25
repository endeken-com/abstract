import Foundation
import Testing
@testable import AbstractCore

/// Ollama and LM Studio were agents once: Codex against a local model server.
/// A local server is now each agent's own configuration, so their work moves
/// to OpenCode and only their old transcripts still need reading.
@Suite struct RetiredAgentsTests {
    @Test func onlyAgentsAreOffered() {
        #expect(ProviderRegistry.all.map(\.id) == ["claude", "codex", "opencode"])
        #expect(ProviderRegistry.provider("ollama") == nil)
        #expect(ProviderRegistry.provider("lmstudio") == nil)
    }

    @Test func oldTranscriptsStillReadBack() {
        let parser = try? #require(ProviderRegistry.makeParser("lmstudio"))
        let line = #"{"type":"item.completed","item":{"id":"item_1","type":"agent_message","text":"Done."}}"#
        #expect(parser?.feed(line, stream: .stdout).contains { event in
            if case .text(.assistant, "Done.", _, _) = event { true } else { false }
        } == true)
        // The notices Codex gave about every model that isn't OpenAI's stay out.
        let notice = #"{"type":"error","message":"Model metadata for `qwen3` not found."}"#
        #expect(parser?.feed(notice, stream: .stdout).contains { if case .error = $0 { true } else { false } } == false)
        #expect(ProviderRegistry.makeParser("missing") == nil)
        #expect(ProviderRegistry.name("ollama") == "Codex · Ollama")
        #expect(ProviderRegistry.name("lmstudio") == "Codex · LM Studio")
        #expect(ProviderRegistry.name("opencode") == "OpenCode")
    }

    @Test func olderPeersAskingForThemGetOpenCode() {
        #expect(RetiredAgents.current("ollama") == "opencode")
        #expect(RetiredAgents.current("lmstudio") == "opencode")
        #expect(RetiredAgents.current("codex") == "codex")
    }

    @Test func migrationMovesTheirWorkToOpenCode() throws {
        let store = try Store.inMemory(migratedTo: "v6-handoff", thenRunning: """
            INSERT INTO projects (id, name, root_path, default_provider_id, created_at)
            VALUES ('p1', 'local', '/r/local', 'ollama', '2026-09-01 00:00:00.000'),
                   ('p2', 'cloud', '/r/cloud', 'codex', '2026-09-01 00:00:00.000');
            INSERT INTO sessions (id, project_id, name, provider_id, provider_session_id, model, effort, handoff_from, created_at)
            VALUES ('ran', 'p1', 'Ran', 'lmstudio', 'thread-1', 'qwen/qwen3', 'high', NULL, '2026-09-02 00:00:00.000'),
                   ('unused', 'p1', 'Unused', 'ollama', NULL, 'llama3', NULL, NULL, '2026-09-02 00:00:00.000'),
                   ('switched', 'p1', 'Switched', 'ollama', NULL, NULL, NULL, 'claude', '2026-09-02 00:00:00.000'),
                   ('codex', 'p2', 'Codex', 'codex', 'thread-2', 'gpt-5', 'high', NULL, '2026-09-02 00:00:00.000');
            INSERT INTO automations (id, name, prompt, provider_id, rrule, timezone, dtstart, created_at, updated_at, model)
            VALUES ('a1', 'Nightly', 'Bump deps', 'ollama', 'FREQ=DAILY', 'UTC', '2026-09-01 00:00:00.000',
                    '2026-09-01 00:00:00.000', '2026-09-01 00:00:00.000', 'llama3');
            INSERT INTO settings (key, value) VALUES ('localModelSources', '{}'), ('shareLocalModels', 'true'),
                                                     ('outputStyle', '"default"');
            """)
        #expect(try store.project("p1")?.defaultProviderId == "opencode")
        #expect(try store.project("p2")?.defaultProviderId == "codex")

        // A chat that ran hands over to OpenCode with your next message, as
        // switching agents mid-chat does; the server's model name means
        // nothing to OpenCode, so it starts on OpenCode's default.
        let ran = try #require(try store.session("ran"))
        #expect(ran.providerId == "opencode" && ran.handoffFrom == "lmstudio")
        #expect(ran.providerSessionId == nil && ran.model == nil && ran.effort == nil)
        let unused = try #require(try store.session("unused"))
        #expect(unused.providerId == "opencode" && unused.handoffFrom == nil && unused.model == nil)
        // A handover already waiting now goes to OpenCode instead.
        #expect(try store.session("switched")?.handoffFrom == "claude")
        let codex = try #require(try store.session("codex"))
        #expect(codex.providerId == "codex" && codex.providerSessionId == "thread-2" && codex.model == "gpt-5")

        let automation = try #require(try store.automation("a1"))
        #expect(automation.providerId == "opencode" && automation.model == nil)
        #expect(store.setting("localModelSources", as: [String: String].self) == nil)
        #expect(store.setting("shareLocalModels", as: Bool.self) == nil)
        #expect(store.setting("outputStyle", as: OutputStyle.self) == .default)
    }
}

@Suite("Local model pricing")
struct LocalModelPricingTests {
    @Test func localModelsHaveNoPrice() {
        #expect(ModelPricing.rates(provider: .codex, model: "qwen3-coder:30b") == nil)
        #expect(ModelPricing.rates(provider: .codex, model: "openai/gpt-oss-20b") == nil)
        #expect(ModelPricing.rates(provider: .codex, model: "o4-mini")?.known == false)
    }
}
