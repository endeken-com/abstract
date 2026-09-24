import CryptoKit
import Foundation

/// How two Abstracts on a local network trust each other.
///
/// Each device has a long-lived Ed25519 identity. A connection starts with a
/// fresh X25519 exchange; both sides sign the transcript (both identities and
/// both exchange keys) with their identity, so neither can be impersonated or
/// have the exchange swapped underneath it. The shared secret, salted with the
/// transcript, gives one ChaCha20-Poly1305 key per direction.
///
/// The first connection between two devices is a pairing: neither knows the
/// other's identity yet, so both show a six-digit code derived from the
/// exchange. A device in the middle would produce different codes on the two
/// screens; when they match, each side pins the other's identity, and later
/// connections accept only pinned identities.
public struct DeviceIdentity: Sendable {
    public let id: String
    public let name: String
    public let signingKey: Curve25519.Signing.PrivateKey

    public init(id: String, name: String, signingKey: Curve25519.Signing.PrivateKey) {
        self.id = id; self.name = name; self.signingKey = signingKey
    }

    public static func generate(name: String) -> DeviceIdentity {
        DeviceIdentity(id: UUID().uuidString, name: name, signingKey: Curve25519.Signing.PrivateKey())
    }

    public var publicKey: Data { signingKey.publicKey.rawRepresentation }
    public var peer: PeerInfo { PeerInfo(id: id, name: name, publicKey: publicKey) }
}

/// Another device, as it introduced itself.
public struct PeerInfo: Codable, Sendable, Hashable {
    public var id: String
    public var name: String
    public var publicKey: Data

    public init(id: String, name: String, publicKey: Data) { self.id = id; self.name = name; self.publicKey = publicKey }

    /// A short, stable form of the key, for comparing by eye.
    public var fingerprint: String {
        SHA256.hash(data: publicKey).prefix(6).map { String(format: "%02X", $0) }.joined(separator: ":")
    }
}

public enum SecureChannelError: Error, LocalizedError, Equatable {
    case malformed, badSignature, versionMismatch, unknownPeer, keyChanged, tampered

    public var errorDescription: String? {
        switch self {
        case .malformed: "The other device sent something unreadable."
        case .badSignature: "The other device couldn't prove who it is."
        case .versionMismatch: "The other device runs a different version of Abstract's remote protocol."
        case .unknownPeer: "That device isn't paired with this one."
        case .keyChanged: "That device's identity changed since it was paired. Unpair it and pair again."
        case .tampered: "A message was altered on the way, so the connection was closed."
        }
    }
}

public enum Handshake {
    public static let version = 1

    struct Hello: Codable {
        var v: Int
        var peer: PeerInfo
        var ephemeral: Data
        var pairing: Bool
    }

    struct Reply: Codable {
        var v: Int
        var peer: PeerInfo
        var ephemeral: Data
        var signature: Data?
    }

    struct Finish: Codable {
        var signature: Data
    }

    /// What a finished handshake leaves: the keys, who is on the other end,
    /// and the code both screens show when pairing.
    public struct Outcome: Sendable {
        public let peer: PeerInfo
        public let pairing: Bool
        public let code: String
        public let cipher: FrameCipher
    }

    // MARK: The side that connects

    public final class Initiator {
        private let identity: DeviceIdentity
        private let pairing: Bool
        private let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        private var hello = Data()

        public init(identity: DeviceIdentity, pairing: Bool) {
            self.identity = identity; self.pairing = pairing
        }

        public func start() throws -> Data {
            hello = try JSONEncoder.sorted.encode(Hello(v: Handshake.version, peer: identity.peer,
                                                        ephemeral: ephemeral.publicKey.rawRepresentation, pairing: pairing))
            return hello
        }

        /// Checks the reply; `expected` is the pinned identity (nil only when pairing).
        public func finish(reply data: Data, expected: PeerInfo?) throws -> (finish: Data, outcome: Outcome) {
            guard let reply = try? JSONDecoder().decode(Reply.self, from: data), let signature = reply.signature else { throw SecureChannelError.malformed }
            guard reply.v == Handshake.version else { throw SecureChannelError.versionMismatch }
            try Handshake.check(reply.peer, expected: expected, pairing: pairing)
            let transcript = try Handshake.transcript(hello: hello, reply: reply)
            guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: reply.peer.publicKey),
                  key.isValidSignature(signature, for: Handshake.signed("responder", transcript)) else { throw SecureChannelError.badSignature }
            let finish = try JSONEncoder.sorted.encode(Finish(signature: try identity.signingKey.signature(for: Handshake.signed("initiator", transcript))))
            let secret = try Handshake.secret(ephemeral, reply.ephemeral)
            return (finish, Outcome(peer: reply.peer, pairing: pairing, code: Handshake.code(secret, transcript),
                                    cipher: FrameCipher(secret: secret, transcript: transcript, initiator: true)))
        }
    }

    // MARK: The side that listens

    public final class Responder {
        private let identity: DeviceIdentity
        private let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        private var hello: Hello?
        private var helloData = Data()
        private var reply: Reply?

        public init(identity: DeviceIdentity) { self.identity = identity }

        /// Reads the hello; `lookup` gives the pinned identity for the device's id, if paired.
        public func respond(to data: Data, lookup: (String) -> PeerInfo?) throws -> (reply: Data, peer: PeerInfo, pairing: Bool) {
            guard let hello = try? JSONDecoder().decode(Hello.self, from: data) else { throw SecureChannelError.malformed }
            guard hello.v == Handshake.version else { throw SecureChannelError.versionMismatch }
            try Handshake.check(hello.peer, expected: lookup(hello.peer.id), pairing: hello.pairing)
            self.hello = hello
            helloData = data
            var reply = Reply(v: Handshake.version, peer: identity.peer, ephemeral: ephemeral.publicKey.rawRepresentation, signature: nil)
            let transcript = try Handshake.transcript(hello: data, reply: reply)
            reply.signature = try identity.signingKey.signature(for: Handshake.signed("responder", transcript))
            self.reply = reply
            return (try JSONEncoder.sorted.encode(reply), hello.peer, hello.pairing)
        }

        public func complete(finish data: Data) throws -> Outcome {
            guard let hello, let reply, let finish = try? JSONDecoder().decode(Finish.self, from: data) else { throw SecureChannelError.malformed }
            let transcript = try Handshake.transcript(hello: helloData, reply: reply)
            guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: hello.peer.publicKey),
                  key.isValidSignature(finish.signature, for: Handshake.signed("initiator", transcript)) else { throw SecureChannelError.badSignature }
            let secret = try Handshake.secret(ephemeral, hello.ephemeral)
            return Outcome(peer: hello.peer, pairing: hello.pairing, code: Handshake.code(secret, transcript),
                           cipher: FrameCipher(secret: secret, transcript: transcript, initiator: false))
        }
    }

    // MARK: Shared steps

    /// Outside pairing, only the identity pinned at pairing is accepted.
    static func check(_ peer: PeerInfo, expected: PeerInfo?, pairing: Bool) throws {
        if let expected {
            guard expected.publicKey == peer.publicKey else { throw SecureChannelError.keyChanged }
        } else if !pairing {
            throw SecureChannelError.unknownPeer
        }
    }

    /// Both identities and both exchange keys, as sent, before any signature.
    static func transcript(hello: Data, reply: Reply) throws -> Data {
        var unsigned = reply
        unsigned.signature = nil
        var hash = SHA256()
        hash.update(data: Data("abstract-remote-v\(version)".utf8))
        hash.update(data: hello)
        hash.update(data: try JSONEncoder.sorted.encode(unsigned))
        return Data(hash.finalize())
    }

    static func signed(_ role: String, _ transcript: Data) -> Data { Data(role.utf8) + transcript }

    static func secret(_ mine: Curve25519.KeyAgreement.PrivateKey, _ theirs: Data) throws -> SharedSecret {
        guard let key = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: theirs) else { throw SecureChannelError.malformed }
        return try mine.sharedSecretFromKeyAgreement(with: key)
    }

    /// Six digits both screens show; the same only when no one sits in between.
    static func code(_ secret: SharedSecret, _ transcript: Data) -> String {
        let bytes = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: transcript, sharedInfo: Data("abstract pairing code".utf8), outputByteCount: 8)
            .withUnsafeBytes { Array($0) }
        let value = bytes.reduce(UInt64(0)) { $0 << 8 | UInt64($1) } % 1_000_000
        let digits = String(format: "%06llu", value)
        return digits.prefix(3) + " " + digits.suffix(3)
    }
}

/// Seals and opens a connection's frames. TCP keeps them in order, so each
/// side counts its own frames for the nonce: a dropped, repeated or
/// reordered frame fails to open.
public struct FrameCipher: Sendable {
    private let sendKey: SymmetricKey
    private let receiveKey: SymmetricKey
    private var sent: UInt64 = 0
    private var received: UInt64 = 0

    init(secret: SharedSecret, transcript: Data, initiator: Bool) {
        func key(_ direction: String) -> SymmetricKey {
            secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: transcript, sharedInfo: Data("abstract \(direction)".utf8), outputByteCount: 32)
        }
        sendKey = key(initiator ? "i2r" : "r2i")
        receiveKey = key(initiator ? "r2i" : "i2r")
    }

    public mutating func seal(_ plaintext: Data) throws -> Data {
        defer { sent += 1 }
        return try ChaChaPoly.seal(plaintext, using: sendKey, nonce: Self.nonce(sent)).combined
    }

    public mutating func open(_ frame: Data) throws -> Data {
        defer { received += 1 }
        guard let box = try? ChaChaPoly.SealedBox(combined: frame), Self.same(box.nonce, Self.nonce(received)),
              let plaintext = try? ChaChaPoly.open(box, using: receiveKey) else { throw SecureChannelError.tampered }
        return plaintext
    }

    private static func same(_ a: ChaChaPoly.Nonce, _ b: ChaChaPoly.Nonce) -> Bool {
        a.withUnsafeBytes { x in b.withUnsafeBytes { y in x.elementsEqual(y) } }
    }

    private static func nonce(_ counter: UInt64) -> ChaChaPoly.Nonce {
        var bytes = Data(count: 4)
        withUnsafeBytes(of: counter.bigEndian) { bytes.append(contentsOf: $0) }
        return try! ChaChaPoly.Nonce(data: bytes)
    }
}

extension JSONEncoder {
    /// Stable output, so both sides hash the same bytes.
    static var sorted: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }
}
