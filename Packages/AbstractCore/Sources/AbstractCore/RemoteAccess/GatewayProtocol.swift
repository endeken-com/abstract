import Foundation

/// A client asking, through the gateway's authorize page, to read this Mac.
public struct RemoteConsentRequest: Sendable, Hashable {
    public var id: String
    public var clientName: String
    /// Set only for a client whose identity is a verified metadata URL.
    public var clientDomain: String?
    /// Where its tokens go.
    public var redirectHost: String
    /// The tokens go to an app on the asking computer.
    public var loopback: Bool
    public var scope: [String]
    public var expiresAt: Date
}

/// What the gateway knows about one of this Mac's grants.
public struct GatewayGrant: Sendable, Hashable {
    public var id: String
    public var revokedAt: Date?
    public var lastUsedAt: Date?
}

/// A frame from the gateway (infra/mcp-gateway/PROTOCOL.md, version 1).
public enum GatewayMessage: Sendable, Hashable {
    case hello(macId: String, grants: [GatewayGrant])
    case call(id: String, grantId: String, projects: RemoteProjects, phi: Bool, body: String)
    case consentRequest(RemoteConsentRequest)
    case connectCode(id: String, code: String, expiresAt: Date)
    case ack(id: String)
    case error(id: String?, message: String)
    case grantRevoked(grantId: String)
}

/// Frames to and from `wss://mcp.useabstract.app/connect`.
public enum GatewayProtocol {
    public static let version = 1
    public static let heartbeat = "ping"
    public static let heartbeatReply = "pong"

    /// 1–64 characters of `[A-Za-z0-9_-]`.
    static func validId(_ s: String?) -> String? {
        guard let s, (1...64).contains(s.count),
              s.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) else { return nil }
        return s
    }

    /// A lowercase UUID.
    static func validGrant(_ s: String?) -> String? {
        guard let s, UUID(uuidString: s) != nil, s == s.lowercased() else { return nil }
        return s
    }

    private static func date(_ value: JSONValue?) -> Date? {
        value?.double.map { Date(timeIntervalSince1970: $0 / 1000) }
    }

    /// A frame, or nil when it isn't one this version understands.
    public static func parse(_ text: String) -> GatewayMessage? {
        guard let m = JSONValue.parse(text), m["v"]?.int == version, let type = m["type"]?.string else { return nil }
        switch type {
        case "hello":
            guard let macId = m["macId"]?.string, let list = m["grants"]?.array else { return nil }
            return .hello(macId: macId, grants: list.compactMap { g in
                validGrant(g["id"]?.string).map { GatewayGrant(id: $0, revokedAt: date(g["revokedAt"]), lastUsedAt: date(g["lastUsedAt"])) }
            })
        case "call":
            guard let id = validId(m["id"]?.string), let grant = validGrant(m["grantId"]?.string),
                  let projects = RemoteProjects(json: m["projects"]), let phi = m["phi"]?.bool,
                  let body = m["body"]?.string else { return nil }
            return .call(id: id, grantId: grant, projects: projects, phi: phi, body: body)
        case "consent_request":
            guard let id = validId(m["id"]?.string), let client = m["client"], let name = client["name"]?.string,
                  let host = client["redirectHost"]?.string, let loopback = client["loopback"]?.bool,
                  let expires = date(m["expiresAt"]) else { return nil }
            return .consentRequest(RemoteConsentRequest(
                id: id, clientName: name, clientDomain: client["domain"]?.string, redirectHost: host, loopback: loopback,
                scope: m["scope"]?.array?.compactMap(\.string) ?? [], expiresAt: expires))
        case "connect_code":
            guard let id = validId(m["id"]?.string), let code = m["code"]?.string, let expires = date(m["expiresAt"]) else { return nil }
            return .connectCode(id: id, code: code, expiresAt: expires)
        case "ack":
            return validId(m["id"]?.string).map { .ack(id: $0) }
        case "error":
            return .error(id: m["id"]?.string, message: m["message"]?.string ?? "")
        case "grant_revoked":
            return validGrant(m["grantId"]?.string).map { .grantRevoked(grantId: $0) }
        default:
            return nil
        }
    }

    private static func frame(_ type: String, _ fields: [String: JSONValue]) -> String {
        var all = fields
        all["v"] = .number(Double(version))
        all["type"] = .string(type)
        return JSONValue.object(all).compact()
    }

    public static func result(id: String, status: Int, body: String) -> String {
        frame("result", ["id": .string(id), "status": .number(Double(status)), "body": .string(body)])
    }

    public static func approve(id: String, grant: RemoteGrant) -> String {
        frame("consent_response", ["id": .string(id), "approve": .bool(true), "grantId": .string(grant.id),
                                   "projects": grant.projects.json, "phi": .bool(grant.redactsHealthData)])
    }

    public static func deny(id: String) -> String {
        frame("consent_response", ["id": .string(id), "approve": .bool(false)])
    }

    public static func connectCodeRequest(id: String) -> String {
        frame("connect_code_request", ["id": .string(id)])
    }

    public static func revoke(id: String, grantId: String) -> String {
        frame("revoke", ["id": .string(id), "grantId": .string(grantId)])
    }

    public static func update(id: String, grant: RemoteGrant) -> String {
        frame("grant_update", ["id": .string(id), "grantId": .string(grant.id), "projects": grant.projects.json,
                               "phi": .bool(grant.redactsHealthData)])
    }
}
