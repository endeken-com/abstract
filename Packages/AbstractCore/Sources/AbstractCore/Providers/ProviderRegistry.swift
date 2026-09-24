/// Every agent Abstract can run.
///
/// Adding a provider = one file conforming to `ProviderDefinition` plus one
/// entry in `all`.
public enum ProviderRegistry {
    public static let all: [any ProviderDefinition] = [
        ClaudeProvider(),
        CodexProvider(),
        LocalModelProvider(.ollama),
        LocalModelProvider(.lmstudio),
    ]

    public static func provider(_ id: String) -> (any ProviderDefinition)? {
        all.first { $0.id == id }
    }
}
