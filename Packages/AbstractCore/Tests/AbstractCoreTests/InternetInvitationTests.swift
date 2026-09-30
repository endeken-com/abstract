import Foundation
import Testing
@testable import AbstractCore

struct InternetInvitationTests {
    @Test func invitationsExpireAndRejectOtherOrigins() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let identity = DeviceIdentity.generate(name: "Host")
        let invite = InternetInvitation(peer: identity.peer, address: InternetAddress(endpointId: String(repeating: "a", count: 64)), now: now)
        let decoded = try InternetInvitation.parse(invite.link, now: now)
        #expect(decoded.peer == identity.peer)
        #expect(decoded.token == invite.token)
        #expect(throws: (any Error).self) { try InternetInvitation.parse(invite.link, now: now.addingTimeInterval(601)) }
        #expect(throws: (any Error).self) { try InternetInvitation.parse(invite.link.replacingOccurrences(of: "abstract://", with: "https://"), now: now) }
        #expect(throws: (any Error).self) { try InternetInvitation.parse("abstract://connect/" + String(repeating: "a", count: 5000), now: now) }
    }

    @Test func admissionProofIsBoundToBothTransportKeysAndTime() throws {
        let identity = DeviceIdentity.generate(name: "Phone")
        let hello = try InternetHello(identity: identity, host: "host", client: "client")
        #expect(hello.verify(host: "host", client: "client"))
        #expect(!hello.verify(host: "other", client: "client"))
        #expect(!hello.verify(host: "host", client: "attacker"))
        #expect(!hello.verify(host: "host", client: "client", now: Date().addingTimeInterval(121)))
        var forged = hello
        forged.peer = DeviceIdentity.generate(name: "Phone").peer
        #expect(!forged.verify(host: "host", client: "client"))
    }

    @Test func oldSnapshotsStillDecodeWithoutInternetMetadata() throws {
        let old = Data(#"{"projects":[],"sessions":[],"providers":[],"alive":[]}"#.utf8)
        #expect(try JSONDecoder().decode(RemoteSnapshot.self, from: old).internetAddress == nil)
    }
}
