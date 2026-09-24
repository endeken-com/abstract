import Foundation
import Network
import Synchronization

/// One encrypted connection to another Abstract, over Network.framework.
/// Handshake first (plain frames), then every frame sealed with the
/// connection's keys.
public final class RemoteChannel: @unchecked Sendable {
    public enum Failure: Error, LocalizedError {
        case closed
        case frameTooLarge
        public var errorDescription: String? {
            switch self {
            case .closed: "The connection closed."
            case .frameTooLarge: "The other device sent a message too large to accept."
            }
        }
    }

    public let connection: NWConnection
    private let queue = DispatchQueue(label: "sh.abstract.remote.channel")
    private let cipher = Mutex<FrameCipher?>(nil)
    /// Encodes outgoing messages one at a time, so sealed frames keep their order.
    private let sending = Mutex<Void>(())

    public init(connection: NWConnection) { self.connection = connection }

    /// Connects (or accepts) and waits until the connection is ready.
    public func open() async throws {
        let resumed = Mutex(false)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.stateUpdateHandler = { state in
                func finish(_ result: Result<Void, any Error>) {
                    guard resumed.withLock({ done in defer { done = true }; return !done }) else { return }
                    continuation.resume(with: result)
                }
                switch state {
                case .ready: finish(.success(()))
                case .failed(let error): finish(.failure(error))
                case .cancelled: finish(.failure(Failure.closed))
                case .waiting(let error): finish(.failure(error))
                default: break
                }
            }
            connection.start(queue: queue)
        }
    }

    public func close() { connection.cancel() }

    // MARK: Frames

    public func sendPlain(_ payload: Data) async throws {
        try await write(RemoteFraming.frame(payload))
    }

    public func receivePlain() async throws -> Data {
        guard let length = RemoteFraming.length(try await read(4)) else { throw Failure.frameTooLarge }
        return try await read(length)
    }

    /// Switches to sealed frames once the handshake has agreed keys.
    public func secure(with cipher: FrameCipher) { self.cipher.withLock { $0 = cipher } }

    public func send(_ message: RemoteMessage) async throws {
        let plain = try JSONEncoder().encode(message)
        // Sealing numbers the frame, so it and handing the frame to the
        // connection happen together; the connection sends in the order given.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            do {
                try sending.withLock { _ in
                    let sealed = try cipher.withLock { cipher -> Data in
                        guard var c = cipher else { throw SecureChannelError.malformed }
                        defer { cipher = c }
                        return try c.seal(plain)
                    }
                    connection.send(content: RemoteFraming.frame(sealed), completion: .contentProcessed { error in
                        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                    })
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    public func receive() async throws -> RemoteMessage {
        let sealed = try await receivePlain()
        let plain = try cipher.withLock { cipher -> Data in
            guard var c = cipher else { throw SecureChannelError.malformed }
            defer { cipher = c }
            return try c.open(sealed)
        }
        return try JSONDecoder().decode(RemoteMessage.self, from: plain)
    }

    // MARK: Bytes

    private func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    private func read(_ count: Int) async throws -> Data {
        guard count > 0 else { return Data() }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, any Error>) in
            connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, isComplete, error in
                if let error { continuation.resume(throwing: error) }
                else if let data, data.count == count { continuation.resume(returning: data) }
                else { continuation.resume(throwing: isComplete ? Failure.closed : Failure.closed) }
            }
        }
    }

    // MARK: Handshakes

    /// The connecting side: proves itself and checks the host against `expected` (nil when pairing).
    public func handshake(as identity: DeviceIdentity, pairing: Bool, expected: PeerInfo?) async throws -> Handshake.Outcome {
        let initiator = Handshake.Initiator(identity: identity, pairing: pairing)
        try await sendPlain(try initiator.start())
        let (finish, outcome) = try initiator.finish(reply: try await receivePlain(), expected: expected)
        try await sendPlain(finish)
        secure(with: outcome.cipher)
        return outcome
    }

    /// The listening side: `lookup` gives a paired device's pinned identity.
    public func accept(as identity: DeviceIdentity, lookup: @Sendable (String) -> PeerInfo?) async throws -> Handshake.Outcome {
        let responder = Handshake.Responder(identity: identity)
        let (reply, _, _) = try responder.respond(to: try await receivePlain(), lookup: lookup)
        try await sendPlain(reply)
        let outcome = try responder.complete(finish: try await receivePlain())
        secure(with: outcome.cipher)
        return outcome
    }
}

/// Parameters every remote connection uses: TCP on the local network only.
public enum RemoteNetwork {
    public static let serviceType = "_abstract._tcp"

    public static var parameters: NWParameters { parameters(peerToPeer: true) }

    /// `peerToPeer` also reaches Macs over Apple's direct Wi-Fi link, with no network between them.
    public static func parameters(peerToPeer: Bool) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 20
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.includePeerToPeer = peerToPeer
        parameters.prohibitedInterfaceTypes = [.cellular]
        return parameters
    }

    /// "host:port" (or "[v6]:port") as an endpoint; nil when it isn't one.
    public static func endpoint(_ address: String) -> NWEndpoint? {
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        guard let colon = trimmed.lastIndex(of: ":"), let port = NWEndpoint.Port(String(trimmed[trimmed.index(after: colon)...])) else { return nil }
        var host = String(trimmed[..<colon])
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        guard !host.isEmpty else { return nil }
        return .hostPort(host: NWEndpoint.Host(host), port: port)
    }
}
