import Foundation
import CryptoKit

public struct InternetAddress: Codable, Hashable, Sendable {
    public var endpointId: String
    public init(endpointId: String) { self.endpointId = endpointId }
    public var isValid: Bool { endpointId.count == 64 && endpointId.allSatisfy { $0.isHexDigit && $0.isASCII } }
}

/// Contains public identities and a short-lived permission to ask to pair, never a relay credential.
public struct InternetInvitation: Codable, Sendable {
    public var v = 1
    public var peer: PeerInfo
    public var address: InternetAddress
    public var token: String
    public var expires: Int

    public init(peer: PeerInfo, address: InternetAddress, now: Date = Date()) {
        self.peer = peer; self.address = address
        token = Curve25519.Signing.PrivateKey().rawRepresentation.base64EncodedString()
        expires = Int(now.timeIntervalSince1970) + 600
    }
    public var link: String {
        let data = (try? JSONEncoder().encode(self)) ?? Data()
        return "abstract://connect/" + data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    public static func parse(_ text: String, now: Date = Date()) throws -> Self {
        let prefix = "abstract://connect/"
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix(prefix), text.count <= 4096 else { throw SecureChannelError.malformed }
        var encoded = String(text.dropFirst(prefix.count)).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let bytes = Data(base64Encoded: encoded), let invite = try? JSONDecoder().decode(Self.self, from: bytes),
              invite.v == 1, invite.address.isValid, invite.peer.publicKey.count == 32,
              Data(base64Encoded: invite.token)?.count == 32,
              invite.expires > Int(now.timeIntervalSince1970), invite.expires <= Int(now.timeIntervalSince1970) + 660
        else { throw SecureChannelError.malformed }
        return invite
    }
}

/// Proves a known app identity before the host displays anything. The proof is bound
/// to both Iroh identities, so another network endpoint cannot replay it.
public struct InternetHello: Codable, Sendable {
    public var peer: PeerInfo
    public var timestamp: Int
    public var signature: Data
    public var invitation: String?

    public init(identity: DeviceIdentity, host: String, client: String, invitation: String? = nil) throws {
        peer = identity.peer; timestamp = Int(Date().timeIntervalSince1970)
        signature = try identity.signingKey.signature(for: Self.proof(host: host, client: client, timestamp: timestamp))
        self.invitation = invitation
    }
    private static func proof(host: String, client: String, timestamp: Int) -> Data {
        Data("abstract-internet-v1\n\(host)\n\(client)\n\(timestamp)".utf8)
    }
    public func verify(host: String, client: String, now: Date = Date()) -> Bool {
        guard abs(Double(timestamp) - now.timeIntervalSince1970) <= 120,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: peer.publicKey) else { return false }
        return key.isValidSignature(signature, for: Self.proof(host: host, client: client, timestamp: timestamp))
    }
}
