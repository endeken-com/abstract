import Foundation

/// Which projects a remote assistant may read: all of them, or these ids.
/// On the wire (infra/mcp-gateway/PROTOCOL.md) `"*"` or an array of ids.
public enum RemoteProjects: Sendable, Hashable, Codable {
    case all
    case only(Set<String>)

    public func allows(_ projectId: String?) -> Bool {
        switch self {
        case .all: true
        // A chat with no project is readable only under "all projects".
        case .only(let ids): projectId.map(ids.contains) ?? false
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self), s == "*" { self = .all; return }
        self = .only(Set(try c.decode([String].self)))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .all: try c.encode("*")
        case .only(let ids): try c.encode(ids.sorted())
        }
    }

    var json: JSONValue {
        switch self {
        case .all: .string("*")
        case .only(let ids): .array(ids.sorted().map(JSONValue.string))
        }
    }

    init?(json: JSONValue?) {
        if json?.string == "*" { self = .all; return }
        guard let list = json?.array, !list.isEmpty else { return nil }
        let ids = list.compactMap(\.string)
        guard ids.count == list.count else { return nil }
        self = .only(Set(ids))
    }
}

/// A remote assistant this Mac allowed to read its open chats (ABS-219).
/// The Mac made its id when you allowed it, and keeps the list: it answers
/// only calls for grants it made and hasn't revoked.
public struct RemoteGrant: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    public var clientName: String
    /// A verified domain, for a client whose identity is a metadata URL.
    public var clientDomain: String?
    public var projects: RemoteProjects
    /// Health-data redaction for this grant's answers.
    public var redactsHealthData: Bool
    public var createdAt: Date
    public var revokedAt: Date?
    public var lastUsedAt: Date?

    public init(id: String = UUID().uuidString.lowercased(), clientName: String, clientDomain: String? = nil,
                projects: RemoteProjects, redactsHealthData: Bool = false, createdAt: Date = Date(),
                revokedAt: Date? = nil, lastUsedAt: Date? = nil) {
        self.id = id; self.clientName = clientName; self.clientDomain = clientDomain; self.projects = projects
        self.redactsHealthData = redactsHealthData; self.createdAt = createdAt; self.revokedAt = revokedAt
        self.lastUsedAt = lastUsedAt
    }

    public var isActive: Bool { revokedAt == nil }
}
