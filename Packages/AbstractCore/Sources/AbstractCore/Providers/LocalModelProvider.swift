import Foundation
import Synchronization

/// A server that runs models on your own hardware.
public enum LocalModelKind: String, Codable, Sendable, CaseIterable, Hashable {
    case ollama
    case lmstudio

    public var name: String { self == .ollama ? "Ollama" : "LM Studio" }
    public var defaultPort: UInt16 { self == .ollama ? 11434 : 1234 }
    public var defaultURL: URL { URL(string: "http://127.0.0.1:\(defaultPort)")! }
    /// The agent that runs on it.
    public var providerId: String { rawValue }
}

/// Where each local model server is reached: this Mac, an address on the
/// network, or (through Abstract) a paired Mac. Set by the app; read when an
/// agent launches or lists its models.
public enum LocalModelEndpoints {
    private static let urls = Mutex<[LocalModelKind: URL]>([:])

    public static func url(_ kind: LocalModelKind) -> URL {
        urls.withLock { $0[kind] } ?? kind.defaultURL
    }

    public static func set(_ kind: LocalModelKind, _ url: URL?) {
        urls.withLock { $0[kind] = url }
    }
}

/// What a local model server says about itself.
public struct LocalModelServerStatus: Sendable, Equatable {
    public var reachable: Bool
    public var models: [String]
    public var error: String?

    public init(reachable: Bool, models: [String], error: String? = nil) {
        self.reachable = reachable; self.models = models; self.error = error
    }
}

public enum LocalModelServer {
    /// The server's language models, or why it couldn't be reached.
    public static func status(_ kind: LocalModelKind, at base: URL) async -> LocalModelServerStatus {
        let path = kind == .ollama ? "api/tags" : "v1/models"
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.timeoutInterval = 3
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                return LocalModelServerStatus(reachable: false, models: [], error: "The server answered, but not like \(kind.name).")
            }
            return LocalModelServerStatus(reachable: true, models: models(kind, from: data), error: nil)
        } catch {
            return LocalModelServerStatus(reachable: false, models: [], error: error.localizedDescription)
        }
    }

    /// Model names from Ollama's `/api/tags` or the OpenAI-style `/v1/models`,
    /// leaving out embedding models, which can't chat.
    static func models(_ kind: LocalModelKind, from data: Data) -> [String] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let entries = (json[kind == .ollama ? "models" : "data"] as? [[String: Any]]) ?? []
        return entries.compactMap { entry -> String? in
            guard let name = (entry["name"] ?? entry["id"] ?? entry["model"]) as? String else { return nil }
            let lowered = name.lowercased()
            if lowered.contains("embed") || (entry["type"] as? String) == "embeddings" { return nil }
            return name
        }
    }
}

/// An agent on a local model server. Codex does the agent's work (reading,
/// editing, running commands) against the server's OpenAI-style `/v1` API,
/// so everything a Codex chat can do, a local one can too.
public struct LocalModelProvider: ProviderDefinition {
    public let kind: LocalModelKind
    private let codex = CodexProvider()

    public init(_ kind: LocalModelKind) { self.kind = kind }

    public var id: String { kind.providerId }
    public var name: String { kind.name }
    public var logoAsset: String { kind == .ollama ? "ProviderOllama" : "ProviderLMStudio" }
    public var binary: String { codex.binary }
    public var detectArgs: [String] { codex.detectArgs }
    public var followUpMode: FollowUpMode { codex.followUpMode }

    /// Codex's own config, pointing at the server: a model provider of
    /// Abstract's, so the user's `~/.codex/config.toml` is left alone.
    func serverArgs() -> [String] {
        let key = "abstract_\(kind.rawValue)"
        let base = LocalModelEndpoints.url(kind).appendingPathComponent("v1").absoluteString
        return ["-c", "model_provider=\"\(key)\"",
                "-c", "model_providers.\(key).name=\(CodexProvider.tomlString(kind.name))",
                "-c", "model_providers.\(key).base_url=\(CodexProvider.tomlString(base))"]
    }

    private func withServer(_ ctx: LaunchContext) -> LaunchContext {
        var ctx = ctx
        ctx.extraArgs = serverArgs() + ctx.extraArgs
        // The server needs a model; its own first one if none was chosen.
        if ctx.model == nil { ctx.model = LocalModelCatalogs.first(kind) }
        return ctx
    }

    public func buildLaunch(_ ctx: LaunchContext) -> LaunchSpec { codex.buildLaunch(withServer(ctx)) }
    public func buildResume(_ ctx: LaunchContext, resumeId: String) -> LaunchSpec { codex.buildResume(withServer(ctx), resumeId: resumeId) }
    public func makeParser() -> OutputParser { LocalModelParser(codex.makeParser()) }
    public func buildUserMessage(_ text: String) -> String? { nil }
    public func buildPermissionResponse(requestId: String, allow: Bool, input: JSONValue?) -> String? { nil }

    public var fallbackModels: ModelCatalog { .empty }

    public func discoverModels(executor: any Executor, binary: String?) async -> ModelCatalog? {
        let status = await LocalModelServer.status(kind, at: LocalModelEndpoints.url(kind))
        guard status.reachable else { return nil }
        LocalModelCatalogs.remember(kind, status.models)
        return ModelCatalog(models: status.models.map { ModelOption(id: $0, label: $0) })
    }

    public func configuredDefaultModel(home: String) -> String? { nil }
}

/// The last model lists seen, so a launch without a chosen model can pick one.
public enum LocalModelCatalogs {
    private static let lists = Mutex<[LocalModelKind: [String]]>([:])
    public static func remember(_ kind: LocalModelKind, _ models: [String]) { lists.withLock { $0[kind] = models } }
    static func first(_ kind: LocalModelKind) -> String? { lists.withLock { $0[kind]?.first } }
}

/// Codex's parser, less the notices it gives about every model that isn't
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
