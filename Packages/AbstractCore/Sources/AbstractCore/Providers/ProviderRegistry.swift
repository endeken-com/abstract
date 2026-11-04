/// Every agent Abstract can run.
///
/// Agents are plugins (ABS-185): adding one is one plugin with an agent
/// script, bundled or installed, read through `AgentPlugins`. Where an
/// agent's models come from, a local model server included, is the agent's
/// own configuration.
public enum ProviderRegistry {
    /// Agents still written in Swift, until they move to plugins.
    static let builtIn: [any ProviderDefinition] = [
        ClaudeProvider(),
        CodexProvider(),
    ]

    public static var all: [any ProviderDefinition] {
        let builtIn = Self.builtIn
        let ids = Set(builtIn.map(\.id))
        return builtIn + AgentPlugins.shared.agents.filter { !ids.contains($0.id) }
    }

    public static func provider(_ id: String) -> (any ProviderDefinition)? {
        all.first { $0.id == id }
    }

    /// Reads output logged under `id`, a retired agent's or a turned-off
    /// plugin's included, so its chats still read back.
    public static func makeParser(_ id: String) -> (any OutputParser)? {
        (provider(id) ?? AgentPlugins.shared.anyAgent(id))?.makeParser() ?? RetiredAgents.makeParser(id)
    }

    public static func name(_ id: String) -> String {
        (provider(id) ?? AgentPlugins.shared.anyAgent(id))?.name ?? RetiredAgents.name(id) ?? id
    }
}
