import CryptoKit
import Foundation
import Testing
@testable import AbstractCore

@Suite struct PluginCatalogTests {
    private func package() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("plugin-catalog-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let manifest = PluginManifest(id: "sh.abstract.example", name: "Example", version: "1.0.0",
                                      capabilities: ["chats.read"],
                                      views: [.init(id: "main", title: "Example")])
        try JSONEncoder().encode(manifest).write(to: folder.appendingPathComponent("manifest.json"))
        try Data("<html></html>".utf8).write(to: folder.appendingPathComponent("index.html"))
        return folder
    }

    @Test func signatureIsBoundToPackageHash() throws {
        let folder = try package()
        defer { try? FileManager.default.removeItem(at: folder) }
        let before = try PluginPackage.inspect(folder: folder).hash
        #expect(try PluginSignature.publisher(in: folder, hash: before) == nil)

        let key = Curve25519.Signing.PrivateKey()
        let signature = try key.signature(for: Data(before.utf8)).base64EncodedString()
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
        try Data(#"{"publisher":"Abstract","signature":"\#(signature)"}"#.utf8)
            .write(to: folder.appendingPathComponent("signature.json"))
        #expect(try PluginPackage.inspect(folder: folder).hash == before)
        #expect(try PluginSignature.publisher(in: folder, hash: before, publicKey: publicKey) == "Abstract")

        do {
            _ = try PluginSignature.publisher(in: folder, hash: String(repeating: "0", count: 64), publicKey: publicKey)
            Issue.record("a signature for a different hash was accepted")
        } catch PluginCatalogError.invalidSignature {}
        try Data("broken".utf8).write(to: folder.appendingPathComponent("signature.json"))
        do {
            _ = try PluginSignature.publisher(in: folder, hash: before, publicKey: publicKey)
            Issue.record("a broken signature was accepted")
        } catch PluginCatalogError.invalidSignature {}
    }

    @Test func catalogIndexAcceptsOnlyProjectReleaseAssets() throws {
        #expect(PluginCatalog.url(for: .stable).path == "/endeken-com/abstract/releases/latest/download/plugins.json")
        #expect(PluginCatalog.url(for: .nightly).path == "/endeken-com/abstract/releases/download/nightly/plugins.json")
        let valid = #"{"plugins":[{"id":"sh.abstract.example","name":"Example","version":"1.0.0","url":"https://github.com/endeken-com/abstract/releases/download/v1.0.0/example.zip","hash":"\#(String(repeating: "a", count: 64))","archiveHash":"\#(String(repeating: "b", count: 64))","archiveSignature":"\#(Data(repeating: 0, count: 64).base64EncodedString())"}]}"#
        #expect(try PluginCatalog.decode(Data(valid.utf8)).plugins.count == 1)
        let foreign = valid.replacingOccurrences(of: "endeken-com/abstract", with: "someone/else")
        #expect(throws: PluginCatalogError.self) { try PluginCatalog.decode(Data(foreign.utf8)) }
        let duplicate = valid.replacingOccurrences(of: "]}", with: "," + String(valid.dropFirst(#"{"plugins":["#.count).dropLast(2)) + "]}")
        #expect(throws: PluginCatalogError.self) { try PluginCatalog.decode(Data(duplicate.utf8)) }
    }

    @Test func updatesShowOnlyNewGrantsAndKeepOldVersionPending() throws {
        let record = PluginRecord(id: "sh.abstract.example", name: "Example", version: "1.0.0",
                                  source: .catalog, enabled: true, grantedCapabilities: [.chatsRead, .network],
                                  grantedNetworkHosts: ["api.example.com"], packageHash: "old")
        let manifest = PluginManifest(id: record.id, name: record.name, version: "1.1.0",
                                      capabilities: ["chats.read", "network"],
                                      networkHosts: ["api.example.com", "new.example.com"])
        let changes = PluginGrantChanges(new: manifest, old: record)
        #expect(changes.asksForMore)
        #expect(changes.capabilities.isEmpty)
        #expect(changes.networkHosts == ["new.example.com"])
        #expect(record.enabled && record.version == "1.0.0")

        let previous = PluginManifest(id: record.id, name: record.name, version: record.version,
                                      capabilities: ["chats.read"],
                                      views: [.init(id: "main", title: "Example")])
        let withPlace = PluginManifest(id: record.id, name: record.name, version: "1.1.0",
                                       capabilities: ["chats.read"],
                                       views: [.init(id: "main", title: "Example"), .init(id: "more", title: "More")])
        let placeChanges = PluginGrantChanges(new: withPlace, old: record, previous: previous)
        #expect(placeChanges.places.count == 1)
        #expect(placeChanges.places[0].contains("More"))
    }

    @Test func catalogRejectsArchivesWithoutTrustedSignature() throws {
        let folder = try package()
        defer { try? FileManager.default.removeItem(at: folder) }
        let inspection = try PluginPackage.inspect(folder: folder)
        let entry = PluginCatalog.Entry(
            id: inspection.manifest.id, name: inspection.manifest.name,
            version: inspection.manifest.version,
            url: URL(string: "https://github.com/endeken-com/abstract/releases/download/v1/example.zip")!,
            hash: inspection.hash, archiveHash: String(repeating: "0", count: 64),
            archiveSignature: Data(repeating: 0, count: 64).base64EncodedString())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("plugin-catalog-host-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = PluginManager(store: try Store.inMemory(), pluginsRoot: root.appendingPathComponent("Plugins"),
                                    dataRoot: root.appendingPathComponent("PluginData"))
        let zip = root.appendingPathComponent("package.zip")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        func archive() throws {
            let ditto = Process()
            ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            ditto.arguments = ["-c", "-k", "--keepParent", folder.path, zip.path]
            try ditto.run()
            ditto.waitUntilExit()
            #expect(ditto.terminationStatus == 0)
        }
        try archive()
        #expect(throws: PluginCatalogError.self) { try manager.inspectCatalogZip(zip, entry: entry) }
        #expect(throws: PluginCatalogError.self) { try manager.install(from: folder, sourceKind: .catalog) }
        #expect(manager.records().isEmpty)

        try Data(#"{"publisher":"Abstract","signature":"broken"}"#.utf8)
            .write(to: folder.appendingPathComponent("signature.json"))
        try FileManager.default.removeItem(at: zip)
        try archive()
        #expect(throws: PluginCatalogError.self) { try manager.inspectCatalogZip(zip, entry: entry) }
        #expect(throws: PluginCatalogError.self) { try manager.install(from: folder, sourceKind: .catalog) }
        #expect(manager.records().isEmpty)
    }

    @Test func archiveMustBeSignedBeforeExtraction() throws {
        let bytes = Data("zip bytes".utf8)
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let key = Curve25519.Signing.PrivateKey()
        let signature = try key.signature(for: Data(hash.utf8)).base64EncodedString()
        let entry = PluginCatalog.Entry(
            id: "sh.abstract.example", name: "Example", version: "1.0.0",
            url: URL(string: "https://github.com/endeken-com/abstract/releases/download/v1/example.zip")!,
            hash: hash, archiveHash: hash, archiveSignature: signature)
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
        try entry.verifyArchive(bytes, publicKey: publicKey)
        #expect(throws: PluginCatalogError.self) {
            try entry.verifyArchive(Data("modified zip bytes".utf8), publicKey: publicKey)
        }
    }
}
