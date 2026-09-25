/// Agents Abstract no longer offers, still named in older chats. Ollama and
/// LM Studio were Codex against a local model server; a local server is now
/// the agent's own configuration, and the store's "v7-retire-local-agents"
/// migration moved their chats, automations and projects to OpenCode.
public enum RetiredAgents {
    static let ids: Set<String> = ["ollama", "lmstudio"]
    static let successor = "opencode"

    /// The agent to use for `id`: its successor when a peer on an older
    /// version still asks for a retired one.
    public static func current(_ id: String) -> String {
        ids.contains(id) ? successor : id
    }

    static func name(_ id: String) -> String? {
        switch id {
        case "ollama": "Codex · Ollama"
        case "lmstudio": "Codex · LM Studio"
        default: nil
        }
    }

    static func makeParser(_ id: String) -> (any OutputParser)? {
        ids.contains(id) ? LocalModelParser(CodexProvider().makeParser()) : nil
    }
}

/// Codex's parser, less the notices it gave about every model that isn't
/// OpenAI's: no catalogue entry for it, a service tier it doesn't offer.
final class LocalModelParser: OutputParser {
    private let codex: OutputParser
    init(_ codex: OutputParser) { self.codex = codex }

    func feed(_ line: String, stream: OutputStreamKind) -> [AgentEvent] {
        codex.feed(line, stream: stream).filter { event in
            guard case .error(let message) = event else { return true }
            return !(message.contains("Model metadata for") || message.contains("service tier"))
        }
    }

    func onExit(code: Int32?) -> [AgentEvent] { codex.onExit(code: code) }
}
