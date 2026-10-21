import Foundation

// Tools a plugin gives agents (ABS-97). A plugin declares them in its
// manifest; Abstract lists them on each chat's `abstract-plugins` MCP
// server and runs every call in the plugin's background script. Each
// tool is Allowed, Ask first or Off per project. The rules live here.

/// One tool a plugin offers agents, as its manifest declares it.
public struct PluginAgentTool: Sendable, Hashable, Codable {
    public var name: String
    public var description: String
    /// The JSON schema of its input; nil takes any object.
    public var inputSchema: JSONValue?

    public init(name: String, description: String, inputSchema: JSONValue? = nil) {
        self.name = name; self.description = description; self.inputSchema = inputSchema
    }

    public static let nameLimit = 28
    public static let descriptionLimit = 1_000
    public static let schemaLimit = 8_000

    /// Letters, digits, `_` and `-` only: every agent's model API refuses
    /// any other tool name.
    public var hasSoundName: Bool {
        !name.isEmpty && name.count <= Self.nameLimit
            && name.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-") }
    }

    /// The schema as agents get it: an object schema, or one that takes any object.
    public var schema: JSONValue { inputSchema ?? .object(["type": .string("object")]) }
}

/// What a project lets a plugin tool do.
public enum PluginToolMode: String, Sendable, Hashable, Codable, CaseIterable {
    case allowed
    case ask
    case off

    /// A tool nobody has set yet asks first, like a plugin action.
    public static let `default` = PluginToolMode.ask

    public var title: String {
        switch self {
        case .allowed: "Allowed"
        case .ask: "Ask first"
        case .off: "Off"
        }
    }

    public var detail: String {
        switch self {
        case .allowed: "Agents use it without asking."
        case .ask: "Each call waits for you in the chat."
        case .off: "Agents in this project don't get it."
        }
    }
}

extension Project {
    /// A plugin tool's setting here; unset asks first.
    public func pluginToolMode(pluginId: String, tool: String) -> PluginToolMode {
        pluginTools?[PluginTools.key(pluginId: pluginId, tool: tool)] ?? .default
    }
}

/// One usable plugin's tools, as the host finds them now.
public struct PluginToolOffer: Sendable, Hashable {
    public var pluginId: String
    public var pluginName: String
    public var tools: [PluginAgentTool]

    public init(pluginId: String, pluginName: String, tools: [PluginAgentTool]) {
        self.pluginId = pluginId; self.pluginName = pluginName; self.tools = tools
    }
}

/// A plugin tool as one project's agents see it.
public struct PublishedPluginTool: Sendable, Hashable {
    /// What agents call it: `<plugin>_<tool>`.
    public var name: String
    public var pluginId: String
    public var pluginName: String
    public var tool: PluginAgentTool
    public var mode: PluginToolMode

    public var key: String { PluginTools.key(pluginId: pluginId, tool: tool.name) }
    /// "Echo: echo", the way a tool row names it.
    public var label: String { "\(pluginName): \(tool.name)" }

    /// Its `tools/list` entry. It says it's read-only because `codex exec`
    /// refuses any MCP call that would need Codex's own approval; Abstract
    /// asks itself, per the project's setting, before the call runs.
    public var listing: JSONValue {
        .object([
            "name": .string(name),
            "description": .string("From the \(pluginName) plugin. \(tool.description)"),
            "inputSchema": tool.schema,
            "annotations": .object(["title": .string(label), "readOnlyHint": .bool(true)]),
        ])
    }
}

public enum PluginTools {
    /// The MCP server's name in each agent's config.
    public static let serverName = "abstract-plugins"
    /// How long a plugin's script may take to answer one call.
    public static let timeout: TimeInterval = 30
    /// How long an Ask first call waits for you before it's declined.
    public static let askTimeout: TimeInterval = 600
    /// The most a tool result may hold, in characters.
    public static let resultLimit = 50_000
    /// Tools one plugin may declare.
    public static let limit = 16
    static let slugLimit = 12

    public static func key(pluginId: String, tool: String) -> String { "\(pluginId)/\(tool)" }

    /// Every plugin's tools with the names agents call them, whatever the
    /// project says, in a stable order.
    public static func all(_ offers: [PluginToolOffer], project: Project?) -> [PublishedPluginTool] {
        let slugs = slugs(offers)
        return offers.sorted { $0.pluginId < $1.pluginId }.flatMap { offer in
            offer.tools.map { tool in
                PublishedPluginTool(name: "\(slugs[offer.pluginId] ?? "plugin")_\(tool.name)", pluginId: offer.pluginId,
                                    pluginName: offer.pluginName, tool: tool,
                                    mode: project?.pluginToolMode(pluginId: offer.pluginId, tool: tool.name) ?? .default)
            }
        }
    }

    /// The tools a chat's agent gets: all but those the project has off.
    /// A chat outside any project gets none, as nothing could set them.
    public static func published(_ offers: [PluginToolOffer], project: Project?) -> [PublishedPluginTool] {
        guard let project else { return [] }
        return all(offers, project: project).filter { $0.mode != .off }
    }

    /// A short, unique prefix per plugin, from its name: "Echo Tools" →
    /// `echo-tools`. Two plugins with the same name are told apart by a
    /// hash of their ids. Never holds `_`, which separates it from the tool.
    public static func slugs(_ offers: [PluginToolOffer]) -> [String: String] {
        var used: Set<String> = []
        var out: [String: String] = [:]
        for offer in offers.sorted(by: { $0.pluginId < $1.pluginId }) {
            var slug = slug(offer.pluginName)
            if used.contains(slug) {
                slug = String(slug.prefix(slugLimit - 5)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
                    + "-" + String(WorktreeNaming.shortHash(offer.pluginId).prefix(4))
            }
            used.insert(slug)
            out[offer.pluginId] = slug
        }
        return out
    }

    static func slug(_ name: String) -> String {
        var slug = ""
        for scalar in name.lowercased().unicodeScalars {
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) {
                slug.unicodeScalars.append(scalar)
            } else if !slug.hasSuffix("-"), !slug.isEmpty {
                slug += "-"
            }
        }
        slug = String(slug.prefix(slugLimit)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? "plugin" : slug
    }

    /// The name a tool call carries under any agent's spelling
    /// (`mcp__abstract-plugins__echo_echo`, OpenCode's
    /// `abstract-plugins_echo_echo`), as the server lists it; nil for
    /// any other tool.
    public static func toolName(inStreamName name: String) -> String? {
        for prefix in ["mcp__\(serverName)__", "\(serverName)_"] where name.hasPrefix(prefix) && name.count > prefix.count {
            return String(name.dropFirst(prefix.count))
        }
        return nil
    }

    /// What a plugin's answer reads as to the agent: text as it is,
    /// anything else as compact JSON, cut to `resultLimit`.
    public static func resultText(_ value: JSONValue) -> String {
        let text = switch value {
        case .string(let s): s
        case .null: ""
        default: value.compact()
        }
        return text.count > resultLimit ? String(text.prefix(resultLimit)) + "…" : text
    }

    /// What happens to one call, before anything runs.
    public enum Route: Sendable, Equatable {
        case run(PublishedPluginTool)
        case ask(PublishedPluginTool)
        case refused(String)
    }

    /// Looks the call up among every tool the chat's project knows, so a
    /// tool switched Off since the agent listed it is refused by name.
    public static func route(_ name: String, among tools: [PublishedPluginTool]) -> Route {
        guard let tool = tools.first(where: { $0.name == name }) else {
            return .refused("There's no plugin tool called “\(name)” any more.")
        }
        switch tool.mode {
        case .off: return .refused("\(tool.label) is turned off in this project.")
        case .ask: return .ask(tool)
        case .allowed: return .run(tool)
        }
    }
}

/// How one call to a plugin's script ended.
public enum PluginToolOutcome: Sendable, Equatable {
    case result(String)
    case failed(String)
}

/// The calls a background script hasn't answered yet, each with its
/// time limit. The host sends a call and waits here; the script's
/// `tools.result` message, the limit, or the script stopping ends it.
public actor PluginToolCalls {
    private var waiting: [String: CheckedContinuation<PluginToolOutcome, Never>] = [:]
    private let timeout: TimeInterval
    private let pluginName: String

    public init(pluginName: String, timeout: TimeInterval = PluginTools.timeout) {
        self.pluginName = pluginName; self.timeout = timeout
    }

    /// Sends a call through `send` (given its id) and waits for its end.
    /// `send` returns false when the script can't take it.
    public func call(_ send: @Sendable @escaping (String) async -> Bool) async -> PluginToolOutcome {
        let id = UUID().uuidString
        let limit = timeout
        let name = pluginName
        return await withCheckedContinuation { continuation in
            waiting[id] = continuation
            Task {
                guard await send(id) else {
                    self.finish(id, .failed("\(name) isn't running, so its tool can't answer."))
                    return
                }
                try? await Task.sleep(for: .seconds(limit))
                self.finish(id, .failed("\(name) didn't answer within \(Int(limit)) seconds."))
            }
        }
    }

    /// Ends a call; a second end, or one for an unknown id, does nothing.
    public func finish(_ id: String, _ outcome: PluginToolOutcome) {
        waiting.removeValue(forKey: id)?.resume(returning: outcome)
    }

    /// Ends every call still waiting: the script stopped.
    public func failAll(_ reason: String) {
        let all = waiting
        waiting = [:]
        for continuation in all.values { continuation.resume(returning: .failed(reason)) }
    }

    public var pending: Int { waiting.count }
}
