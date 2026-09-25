/// Every agent Abstract can run.
///
/// Adding an agent = one file conforming to `ProviderDefinition` plus one
/// entry in `all`. Where an agent's models come from, a local model server
/// included, is the agent's own configuration.
public enum ProviderRegistry {
    public static let all: [any ProviderDefinition] = [
        ClaudeProvider(),
        CodexProvider(),
        OpenCodeProvider(),
    ]

    public static func provider(_ id: String) -> (any ProviderDefinition)? {
        all.first { $0.id == id }
    }

    /// Reads output logged under `id`, a retired agent's included, so its chats still read back.
    public static func makeParser(_ id: String) -> (any OutputParser)? {
        provider(id)?.makeParser() ?? RetiredAgents.makeParser(id)
    }

    public static func name(_ id: String) -> String {
        provider(id)?.name ?? RetiredAgents.name(id) ?? id
    }
}
