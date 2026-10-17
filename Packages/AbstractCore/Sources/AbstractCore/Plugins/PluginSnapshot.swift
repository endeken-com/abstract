import Foundation

/// The whole snapshot a plugin may see (ABS-84 §4). Sections appear only
/// under their capability; no field outside this allowlist is ever encoded.
public struct PluginSnapshot: Sendable, Hashable, Codable {
    public var revision: Int
    public var generatedAt: String
    public var macs: [Mac]
    public var projects: [Project]?
    public var chats: [Chat]?

    public struct Mac: Sendable, Hashable, Codable {
        public var id: String
        public var name: String
        public var isThisMac: Bool
        public var reachable: Bool
        public init(id: String, name: String, isThisMac: Bool, reachable: Bool) {
            self.id = id; self.name = name; self.isThisMac = isThisMac; self.reachable = reachable
        }
    }

    public struct Project: Sendable, Hashable, Codable {
        /// Opaque, stable per Mac + project.
        public var key: String
        public var name: String
        public var macId: String
        public var archived: Bool
        public init(key: String, name: String, macId: String, archived: Bool) {
            self.key = key; self.name = name; self.macId = macId; self.archived = archived
        }
    }

    public enum Progress: String, Sendable, Hashable, Codable, CaseIterable {
        case needsYou, working, readyToReview, done
    }

    public struct PullRequest: Sendable, Hashable, Codable {
        public var number: Int
        public var state: String
        public var isDraft: Bool
        public var checks: String?
        public var changesRequested: Bool
        public init(number: Int, state: String, isDraft: Bool, checks: String?, changesRequested: Bool) {
            self.number = number; self.state = state; self.isDraft = isDraft
            self.checks = checks; self.changesRequested = changesRequested
        }
        public init(_ facts: SidebarChats.PullRequestFacts) {
            self.init(number: facts.number, state: facts.state.rawValue.lowercased(), isDraft: facts.isDraft,
                      checks: facts.checks?.rawValue, changesRequested: facts.changesRequested)
        }
    }

    public struct Chat: Sendable, Hashable, Codable {
        public var id: String
        public var title: String
        public var projectKey: String?
        public var agentId: String
        public var branch: String?
        public var status: String
        public var progress: Progress
        public var pinned: Bool
        public var archived: Bool
        public var createdAt: String
        public var lastActivityAt: String
        public var hasChanges: Bool?
        public var backgroundTasks: Int
        public var pullRequest: PullRequest?
        public var macId: String
    }

    /// One chat the host knows, before the allowlist is applied.
    public struct ChatInput: Sendable {
        public var chat: SidebarChats.Chat
        public var projectKey: String?
        public var macId: String
        public init(chat: SidebarChats.Chat, projectKey: String?, macId: String) {
            self.chat = chat; self.projectKey = projectKey; self.macId = macId
        }
    }

    /// A project key that tells same-named projects on two Macs apart and
    /// carries no path.
    public static func projectKey(macId: String, projectId: String) -> String {
        "\(macId):\(projectId)"
    }

    public static func build(revision: Int, now: Date = Date(), capabilities: Set<PluginCapability>,
                             macs: [Mac], projects: [Project], chats: [ChatInput]) -> PluginSnapshot {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let projectRows = capabilities.contains(.projectsRead) ? projects : nil
        let chatRows: [Chat]? = capabilities.contains(.chatsRead) ? chats.map { input in
            let session = input.chat.session
            // Progress is host-derived, pins aside, the way the sidebar groups.
            let progress: Progress = switch SidebarChats.status(of: input.chat) {
            case .needsYou: .needsYou
            case .working: .working
            case .readyToReview: .readyToReview
            default: .done
            }
            return Chat(id: session.id, title: session.name, projectKey: input.projectKey,
                        agentId: session.providerId, branch: session.branch, status: session.status.rawValue,
                        progress: progress, pinned: session.pinnedAt != nil, archived: session.archivedAt != nil,
                        createdAt: iso.string(from: session.createdAt),
                        lastActivityAt: iso.string(from: input.chat.activeAt),
                        hasChanges: input.chat.hasChanges, backgroundTasks: input.chat.backgroundTasks,
                        pullRequest: input.chat.pullRequest.map(PullRequest.init), macId: input.macId)
        } : nil
        return PluginSnapshot(revision: revision, generatedAt: iso.string(from: now),
                              macs: macs, projects: projectRows, chats: chatRows)
    }

    public func jsonValue() -> JSONValue {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self),
              let object = try? JSONSerialization.jsonObject(with: data) else { return .object([:]) }
        return JSONValue(any: object)
    }
}

/// Theme and locale handed to every plugin without a grant (ABS-84 §4).
public enum PluginContext {
    public static func jsonValue(theme: Theme, locale: String, pluginId: String, pluginVersion: String,
                                 capabilities: Set<PluginCapability>) -> JSONValue {
        let roles: [PaletteRole] = [.canvas, .sidebar, .surface, .surfaceRaised, .inset, .hover, .selection,
                                    .field, .border, .borderStrong, .text, .prose, .textSecondary, .textTertiary,
                                    .accent, .onAccent, .added, .removed]
        var tokens: [String: JSONValue] = [:]
        for role in roles {
            let swatch = role.swatch(in: theme)
            tokens[role.rawValue] = .string(css(swatch))
        }
        return .object([
            "theme": .string(theme.rawValue),
            "tokens": .object(tokens),
            "fontFamily": .string("-apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif"),
            "locale": .string(locale),
            "pluginId": .string(pluginId),
            "pluginVersion": .string(pluginVersion),
            "capabilities": .array(capabilities.map(\.rawValue).sorted().map(JSONValue.string)),
        ])
    }

    static func css(_ swatch: Swatch) -> String {
        let hex = String(format: "%06x", swatch.hex)
        return swatch.alpha >= 1 ? "#\(hex)" : "#\(hex)\(String(format: "%02x", Int((swatch.alpha * 255).rounded())))"
    }
}
