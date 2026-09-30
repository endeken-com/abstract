import Foundation
import Testing
import AbstractCore
@testable import AbstractInternet

private struct StreamTransport: RemoteTransport {
    let stream: InternetStream
    func open() async throws {}
    func read(_ count: Int) async throws -> Data { try await stream.read(count) }
    func write(_ data: Data, completion: @escaping @Sendable ((any Error)?) -> Void) { stream.write(data, completion: completion) }
    func close() { stream.close() }
}

struct InternetIntegrationTests {
    @Test(.timeLimit(.minutes(1)), .enabled(if: ProcessInfo.processInfo.environment["ABSTRACT_TEST_RELAY_URL"] != nil))
    func pairedDevicesExchangeEncryptedMessages() async throws {
        let relay = try #require(ProcessInfo.processInfo.environment["ABSTRACT_TEST_RELAY_URL"])
        let hostIdentity = DeviceIdentity.generate(name: "Host")
        let clientIdentity = DeviceIdentity.generate(name: "Phone")
        let host = try await InternetEndpoint.bind(key: InternetEndpoint.networkKey(signingKey: hostIdentity.signingKey.rawRepresentation), relayURL: relay)
        let client = try await InternetEndpoint.bind(key: InternetEndpoint.networkKey(signingKey: clientIdentity.signingKey.rawRepresentation), relayURL: relay)
        let server = Task {
            let stream = try #require(try await host.accept())
            let channel = RemoteChannel(transport: StreamTransport(stream: stream))
            defer { channel.close() }
            let outcome = try await channel.accept(as: hostIdentity, lookup: { $0 == clientIdentity.id ? clientIdentity.peer : nil })
            #expect(outcome.peer == clientIdentity.peer)
            guard case .request(let id, .snapshot) = try await channel.receive() else { Issue.record("Unexpected message"); return }
            try await channel.send(.response(id: id, .ok))
            _ = try await channel.receive()
        }
        do {
            let channel = RemoteChannel(transport: StreamTransport(stream: try await client.connect(to: host.id)))
            defer { channel.close() }
            _ = try await channel.handshake(as: clientIdentity, pairing: false, expected: hostIdentity.peer)
            try await channel.send(.request(id: 1, .snapshot))
            guard case .response(let id, .ok) = try await channel.receive() else { Issue.record("Unexpected response"); return }
            #expect(id == 1)
            try await channel.send(.request(id: 2, .snapshot))
            try await server.value
            await client.close(); await host.close()
        } catch {
            server.cancel(); await client.close(); await host.close(); throw error
        }
    }
}
