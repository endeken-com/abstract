import Foundation
import CryptoKit
import IrohLib

/// Transport only. Abstract's signed pairing handshake still authorizes every session.
public final class InternetEndpoint: Sendable {
    public static let relay = "https://relay.useabstract.app"
    private static let alpn = Data("abstract/remote/1".utf8)
    private let endpoint: Endpoint
    private let key: Data
    private let relayURL: String
    private let renewal: Task<Void, Never>
    public var id: String { endpoint.id().toBytes().map { String(format: "%02x", $0) }.joined() }

    /// Derive a separate network identity without storing another private key.
    public static func networkKey(signingKey: Data) -> Data {
        Data(SHA256.hash(data: Data("abstract-internet-identity-v1".utf8) + signingKey))
    }

    public static func bind(key: Data, relayURL: String = relay) async throws -> InternetEndpoint {
        try await register(key: key, relayURL: relayURL)
        let endpoint = try await Endpoint.bind(options: EndpointOptions(
            preset: presetMinimal(), secretKey: key, alpns: [alpn],
            relayMode: try RelayMode.customFromUrls(urls: [relayURL])))
        return InternetEndpoint(endpoint: endpoint, key: key, relayURL: relayURL)
    }

    private init(endpoint: Endpoint, key: Data, relayURL: String) {
        self.endpoint = endpoint; self.key = key; self.relayURL = relayURL
        renewal = Task {
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { return }
                try? await Self.register(key: key, relayURL: relayURL)
            }
        }
    }

    public func connect(to id: String) async throws -> InternetStream {
        try await Self.register(key: key, relayURL: relayURL)
        let addr = EndpointAddr(id: try EndpointId.fromString(s: id), relayUrl: relayURL, addresses: [])
        let connection = try await withThrowingTaskGroup(of: Connection.self) { group in
            group.addTask { try await self.endpoint.connect(addr: addr, alpn: Self.alpn) }
            group.addTask { try await Task.sleep(nanoseconds: 15_000_000_000); throw InternetError.relayUnavailable }
            defer { group.cancelAll() }
            return try await group.next()!
        }
        do { return InternetStream(connection: connection, stream: try await connection.openBi()) }
        catch { try? connection.close(errorCode: 0, reason: Data()); throw error }
    }

    public func accept() async throws -> InternetStream? {
        guard let incoming = await endpoint.acceptNext() else { return nil }
        let accepting = try await incoming.accept()
        let connection = try await accepting.connect()
        let timeout = Task {
            do { try await Task.sleep(nanoseconds: 10_000_000_000); try? connection.close(errorCode: 0, reason: Data()) } catch {}
        }
        defer { timeout.cancel() }
        do { return InternetStream(connection: connection, stream: try await connection.acceptBi()) }
        catch { try? connection.close(errorCode: 0, reason: Data()); throw error }
    }

    public func close() async {
        renewal.cancel()
        try? await endpoint.close()
    }

    private static func register(key: Data, relayURL: String) async throws {
        let signer = try Curve25519.Signing.PrivateKey(rawRepresentation: key)
        let timestamp = Int(Date().timeIntervalSince1970)
        let proof = Data("abstract-relay-register-v1\n\(timestamp)".utf8)
        var request = URLRequest(url: URL(string: relayURL + "/v1/register")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "key": signer.publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined(),
            "timestamp": timestamp, "signature": try signer.signature(for: proof).base64EncodedString()
        ])
        let (_, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw InternetError.relayUnavailable }
    }
}

public enum InternetError: LocalizedError {
    case relayUnavailable, closed
    public var errorDescription: String? {
        switch self {
        case .relayUnavailable: "The internet relay is unavailable. Local connections still work."
        case .closed: "The internet connection closed."
        }
    }
}

public final class InternetStream: Sendable {
    private struct Write: Sendable {
        let data: Data
        let completion: @Sendable ((any Error)?) -> Void
    }
    private let connection: Connection
    private let stream: BiStream
    private let writes: AsyncStream<Write>.Continuation
    public var remoteID: String { connection.remoteId().toBytes().map { String(format: "%02x", $0) }.joined() }

    fileprivate init(connection: Connection, stream: BiStream) {
        self.connection = connection; self.stream = stream
        let queue = AsyncStream<Write>.makeStream()
        writes = queue.continuation
        Task {
            for await write in queue.stream {
                do { try await stream.send().writeAll(buf: write.data); write.completion(nil) }
                catch { write.completion(error); try? connection.close(errorCode: 0, reason: Data()) }
            }
        }
    }

    public func read(_ count: Int) async throws -> Data {
        guard count > 0 else { return Data() }
        return try await stream.recv().readExact(size: UInt32(count))
    }

    /// Synchronously queues writes so cipher counters remain in wire order.
    public func write(_ data: Data, completion: @escaping @Sendable ((any Error)?) -> Void) {
        if case .terminated = writes.yield(Write(data: data, completion: completion)) {
            completion(InternetError.closed)
        }
    }

    public func close() {
        writes.finish()
        try? connection.close(errorCode: 0, reason: Data())
    }
    deinit { writes.finish(); try? connection.close(errorCode: 0, reason: Data()) }
}
