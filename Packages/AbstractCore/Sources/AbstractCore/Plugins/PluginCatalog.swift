import CryptoKit
import Foundation

/// The release's list of first-party plugins. The index is a directory, not
/// a trust anchor: every downloaded package must carry its own valid signature.
public struct PluginCatalog: Decodable, Sendable {
    public static func url(for channel: UpdateChannel) -> URL {
        let path = channel == .nightly ? "download/nightly" : "latest/download"
        return URL(string: "https://github.com/endeken-com/abstract/releases/\(path)/plugins.json")!
    }

    public struct Entry: Decodable, Identifiable, Sendable {
        public let id: String
        public let name: String
        public let version: String
        public let url: URL
        public let hash: String
        public let archiveHash: String
        public let archiveSignature: String

        public func verifyArchive(_ data: Data, publicKey: String = PluginSignature.abstractPublicKey) throws {
            let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard actual == archiveHash,
                  PluginSignature.isValid(hash: archiveHash, signature: archiveSignature, publicKey: publicKey) else {
                throw PluginCatalogError.invalidSignature
            }
        }
    }

    public let plugins: [Entry]

    public static func decode(_ data: Data) throws -> PluginCatalog {
        let catalog = try JSONDecoder().decode(Self.self, from: data)
        guard !catalog.plugins.isEmpty,
              Set(catalog.plugins.map(\.id)).count == catalog.plugins.count,
              catalog.plugins.allSatisfy({ entry in
                  entry.id.hasPrefix("sh.abstract.") && !entry.name.isEmpty && !entry.version.isEmpty
                      && entry.hash.count == 64 && entry.hash.allSatisfy(\.isHexDigit)
                      && entry.archiveHash.count == 64 && entry.archiveHash.allSatisfy(\.isHexDigit)
                      && Data(base64Encoded: entry.archiveSignature)?.count == 64
                      && entry.url.scheme == "https" && entry.url.host == "github.com"
                      && entry.url.path.hasPrefix("/endeken-com/abstract/releases/download/")
                      && entry.url.pathExtension == "zip"
              }) else { throw PluginCatalogError.invalidIndex }
        return catalog
    }

    public static func fetch(channel: UpdateChannel = .stable, session: URLSession = .shared) async throws -> PluginCatalog {
        let (data, response) = try await session.data(from: url(for: channel))
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 1_000_000 else {
            throw PluginCatalogError.unavailable
        }
        return try decode(data)
    }
}

public enum PluginCatalogError: Error, LocalizedError, Sendable {
    case invalidIndex, unavailable, invalidPackage, missingSignature, invalidSignature

    public var errorDescription: String? {
        switch self {
        case .invalidIndex: "The plugin catalog couldn't be read."
        case .unavailable: "The plugin catalog isn't available right now."
        case .invalidPackage: "The downloaded plugin doesn't match the catalog."
        case .missingSignature: "This plugin has no publisher signature, so it wasn't installed."
        case .invalidSignature: "This plugin's publisher signature is broken, so it wasn't installed."
        }
    }
}

public enum PluginSignature {
    /// The same release signing identity already trusted by Abstract's updater.
    /// The signature covers the lowercase ASCII package hash, not the zip bytes.
    public static let abstractPublicKey = "trJXw2M/8e15Dvh4dT8gFPtr4mTofkW/NVPXycB9658="

    private struct Envelope: Decodable {
        let publisher: String
        let signature: String
    }

    public static func isValid(hash: String, signature: String, publicKey: String = abstractPublicKey) -> Bool {
        guard let keyData = Data(base64Encoded: publicKey),
              let signatureData = Data(base64Encoded: signature),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else { return false }
        return key.isValidSignature(signatureData, for: Data(hash.utf8))
    }

    /// Missing is permitted for a plugin picked from disk. Catalog installs
    /// require "Abstract" and a valid signature before any file is copied.
    public static func publisher(in folder: URL, hash: String,
                                 publicKey: String = abstractPublicKey) throws -> String? {
        let file = folder.appendingPathComponent("signature.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 4096,
              let data = try? Data(contentsOf: file),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.publisher == "Abstract",
              isValid(hash: hash, signature: envelope.signature, publicKey: publicKey) else {
            throw PluginCatalogError.invalidSignature
        }
        return envelope.publisher
    }
}

/// The precise additional access an update asks for.
public struct PluginGrantChanges: Sendable, Equatable {
    public let capabilities: [PluginCapability]
    public let networkHosts: [String]
    public let secretNames: [String]
    public let places: [String]
    public let background: Bool
    public let cli: Bool

    public init(new manifest: PluginManifest, old record: PluginRecord, previous: PluginManifest? = nil) {
        capabilities = manifest.grantedCapabilities.subtracting(record.grantedCapabilities)
            .sorted { $0.rawValue < $1.rawValue }
        networkHosts = Set(manifest.networkHosts).subtracting(record.grantedNetworkHosts).sorted()
        secretNames = Set(manifest.secretDeclarations.map(\.name)).subtracting(record.grantedSecretNames).sorted()
        places = Set(manifest.appearanceSentences).subtracting(previous?.appearanceSentences ?? []).sorted()
        background = manifest.background != nil && !record.grantedBackground
        cli = manifest.cli.map { wanted in record.grantedCLI.map { !$0.covers(wanted) } ?? true } ?? false
    }

    public var asksForMore: Bool {
        !capabilities.isEmpty || !networkHosts.isEmpty || !secretNames.isEmpty || !places.isEmpty || background || cli
    }
}
