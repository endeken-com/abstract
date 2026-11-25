import Foundation

/// This Mac's identity at the gateway: its id and its device credential,
/// issued when remote access is turned on and kept in the Keychain. Never
/// the chat feed's `abs_` token, and never an MCP client's token.
public struct RemoteCredential: Sendable, Hashable {
    public var macId: String
    public var secret: String

    public init(macId: String, secret: String) {
        self.macId = macId
        self.secret = secret
    }

    /// `<mac id>.<secret>`, as the gateway issues it and the Keychain keeps it.
    public init?(_ text: String) {
        let parts = text.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2, UUID(uuidString: parts[0]) != nil, parts[1].count == 43,
              parts[1].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return nil }
        self.init(macId: parts[0].lowercased(), secret: parts[1])
    }

    public var text: String { "\(macId).\(secret)" }
    var authorization: String { "Device \(text)" }
}

/// Where the gateway is: `https://mcp.useabstract.app`, or a local
/// `wrangler dev` for testing (`ABSTRACT_REMOTE_ACCESS_URL`).
public struct RemoteGateway: Sendable, Hashable {
    public static let production = RemoteGateway(base: URL(string: "https://mcp.useabstract.app")!)

    public var base: URL

    public init(base: URL) { self.base = base }

    /// The production gateway, or the one in `ABSTRACT_REMOTE_ACCESS_URL` (http only for localhost).
    public static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> RemoteGateway {
        guard let text = environment["ABSTRACT_REMOTE_ACCESS_URL"], let url = URL(string: text),
              url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1"].contains(url.host ?? "")) else {
            return .production
        }
        return RemoteGateway(base: url)
    }

    var registerURL: URL { base.appendingPathComponent("register") }

    var connectURL: URL {
        var components = URLComponents(url: base.appendingPathComponent("connect"), resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        return components.url!
    }
}

public enum RemoteAccessError: Error, LocalizedError, Equatable {
    case http(Int)
    case malformed
    case notConnected
    case timedOut
    case gateway(String)

    public var errorDescription: String? {
        switch self {
        case .http(429): "Too many tries from this network. Wait a few minutes."
        case .http(let code): "The remote access service answered \(code)."
        case .malformed: "The remote access service sent something unexpected."
        case .notConnected: "Remote access isn't connected right now."
        case .timedOut: "The remote access service didn't answer in time."
        case .gateway(let message): message
        }
    }
}

/// Registering and unregistering this Mac (`POST`/`DELETE /register`).
public struct RemoteAccessAPI: Sendable {
    let gateway: RemoteGateway
    let session: URLSession

    public init(gateway: RemoteGateway, session: URLSession = .shared) {
        self.gateway = gateway
        self.session = session
    }

    public func register() async throws -> RemoteCredential {
        var request = URLRequest(url: gateway.registerURL, timeoutInterval: 20)
        request.httpMethod = "POST"
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 201 else { throw RemoteAccessError.http(status) }
        guard let body = JSONValue.parse(String(decoding: data, as: UTF8.self)), let text = body["credential"]?.string,
              let credential = RemoteCredential(text), credential.macId == body["macId"]?.string?.lowercased() else {
            throw RemoteAccessError.malformed
        }
        return credential
    }

    /// Voids the credential, every grant and its tokens at the gateway. A
    /// `401` means it was already gone.
    public func unregister(_ credential: RemoteCredential) async throws {
        var request = URLRequest(url: gateway.registerURL, timeoutInterval: 20)
        request.httpMethod = "DELETE"
        request.setValue(credential.authorization, forHTTPHeaderField: "Authorization")
        let (_, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 204 || status == 401 else { throw RemoteAccessError.http(status) }
    }
}

/// One open socket to the gateway. Abstracted so tests drive the client
/// without a network.
public protocol RemoteSocket: Sendable {
    func send(_ text: String) async throws
    /// The next text frame; nil once the socket has closed.
    func receive() async throws -> String?
    func close()
    /// The reason the gateway gave when it closed: `replaced` (another
    /// connection with this credential took over) or `unregistered`.
    /// `URLSessionWebSocketTask` can't report the custom close codes
    /// (4000, 4001) themselves, so the reason carries them.
    var closeReason: String? { get }
}

public protocol RemoteSocketFactory: Sendable {
    func connect(_ gateway: RemoteGateway, credential: RemoteCredential) async throws -> any RemoteSocket
}

/// `URLSessionWebSocketTask`: async all the way, so nothing blocks a thread
/// of the cooperative pool while it waits.
public struct URLSessionSocketFactory: RemoteSocketFactory {
    public init() {}

    public func connect(_ gateway: RemoteGateway, credential: RemoteCredential) async throws -> any RemoteSocket {
        var request = URLRequest(url: gateway.connectURL, timeoutInterval: 30)
        request.setValue(credential.authorization, forHTTPHeaderField: "Authorization")
        let task = URLSession.shared.webSocketTask(with: request)
        task.maximumMessageSize = 2 << 20
        task.resume()
        let socket = URLSessionSocket(task: task)
        // The first frame is the gateway's hello; a refused upgrade fails here.
        try await socket.waitUntilOpen()
        return socket
    }
}

final class URLSessionSocket: RemoteSocket, @unchecked Sendable {
    let task: URLSessionWebSocketTask
    private var first: String?
    private let lock = NSLock()

    init(task: URLSessionWebSocketTask) { self.task = task }

    func waitUntilOpen() async throws {
        let message = try await task.receive()
        if case .string(let text) = message { lock.withLock { first = text } }
    }

    func send(_ text: String) async throws { try await task.send(.string(text)) }

    func receive() async throws -> String? {
        if let held = lock.withLock({ () -> String? in defer { first = nil }; return first }) { return held }
        do {
            switch try await task.receive() {
            case .string(let text): return text
            case .data: return ""
            @unknown default: return ""
            }
        } catch {
            if task.closeCode != .invalid || task.closeReason != nil { return nil }
            throw error
        }
    }

    func close() { task.cancel(with: .normalClosure, reason: nil) }

    var closeReason: String? { task.closeReason.map { String(decoding: $0, as: UTF8.self) } }
}

/// Reconnecting after a drop: 1 s doubling to 60 s, with ±20 % jitter so many
/// Macs don't come back at once.
public enum RemoteBackoff {
    public static let first: TimeInterval = 1
    public static let longest: TimeInterval = 60

    public static func delay(attempt: Int, jitter: Double = Double.random(in: 0.8...1.2)) -> TimeInterval {
        let base = min(longest, first * pow(2, Double(max(0, min(attempt, 16)))))
        return min(longest * 1.2, base * jitter)
    }
}
