import Foundation
import Network
import Synchronization

/// The chat feed's socket (ABS-217): plain HTTP on 127.0.0.1 only, so
/// nothing on the network can reach it; a tunnel on the same Mac is how it
/// reaches the internet. One request per connection, answered by
/// `ChatFeedEndpoint`, then the connection closes.
public final class ChatFeedListener: Sendable {
    public enum State: Sendable, Equatable {
        case starting
        case ready(port: UInt16)
        case failed(String)
        case stopped
    }

    /// A connection that hasn't sent a whole request by then is dropped.
    static let requestTimeout: TimeInterval = 15

    let endpoint: ChatFeedEndpoint
    let port: UInt16
    private let onState: @Sendable (State) -> Void
    private let listener = Mutex<NWListener?>(nil)
    private let queue = DispatchQueue(label: "sh.abstract.chat-feed")

    /// `port` 0 lets the system pick one (tests).
    public init(endpoint: ChatFeedEndpoint, port: UInt16, onState: @escaping @Sendable (State) -> Void = { _ in }) {
        self.endpoint = endpoint
        self.port = port
        self.onState = onState
    }

    public func start() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.acceptLocalOnly = true
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port) ?? .any)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self else { return }
            switch state {
            case .ready: self.onState(.ready(port: listener?.port?.rawValue ?? self.port))
            case .failed(let error): self.onState(.failed(error.localizedDescription)); listener?.cancel()
            case .cancelled: self.onState(.stopped)
            default: break
            }
        }
        self.listener.withLock { $0?.cancel(); $0 = listener }
        onState(.starting)
        listener.start(queue: queue)
    }

    public func stop() {
        listener.withLock { $0?.cancel(); $0 = nil }
    }

    private func serve(_ connection: NWConnection) {
        // Only loopback peers, whatever the parameters let through.
        if case let .hostPort(host, _) = connection.endpoint, !Self.isLoopback(host) {
            connection.cancel()
            return
        }
        connection.start(queue: queue)
        let timeout = DispatchWorkItem { connection.cancel() }
        queue.asyncAfter(deadline: .now() + Self.requestTimeout, execute: timeout)
        receive(connection, buffer: Data(), timeout: timeout)
    }

    private func receive(_ connection: NWConnection, buffer: Data, timeout: DispatchWorkItem) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 << 10) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            switch FeedHTTPParser.parse(buffer) {
            case .request(let request):
                timeout.cancel()
                // Reading chats can take a moment: off the socket's queue, on GCD (never the cooperative pool).
                DispatchQueue.global(qos: .utility).async {
                    self.send(self.endpoint.respond(to: request), on: connection)
                }
            case .invalid(let status):
                timeout.cancel()
                send(endpoint.reject(status: status), on: connection)
            case .incomplete:
                if isComplete || error != nil || buffer.count > FeedHTTPParser.maxHead + FeedHTTPParser.maxBody + 1024 {
                    timeout.cancel()
                    connection.cancel()
                } else {
                    receive(connection, buffer: buffer, timeout: timeout)
                }
            }
        }
    }

    private func send(_ response: FeedHTTPResponse, on connection: NWConnection) {
        connection.send(content: response.serialized(), contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { _ in connection.cancel() })
    }

    static func isLoopback(_ host: NWEndpoint.Host) -> Bool {
        switch host {
        case .ipv4(let address): address == .loopback
        case .ipv6(let address): address == .loopback || address.asIPv4 == .loopback
        case .name(let name, _): name == "localhost" || name == "127.0.0.1"
        @unknown default: false
        }
    }
}
