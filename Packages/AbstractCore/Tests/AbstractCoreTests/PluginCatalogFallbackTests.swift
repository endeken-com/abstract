import Foundation
import Testing
@testable import AbstractCore

/// Serves canned responses by URL. Each session carries its own table,
/// found through a header, so suites running in parallel don't share one.
private final class CatalogStub: URLProtocol {
    nonisolated(unsafe) private static var tables: [String: [URL: (Int, Data)]] = [:]
    private static let lock = NSLock()
    private static let header = "X-Catalog-Stub"

    static func session(_ responses: [URL: (Int, Data)]) -> URLSession {
        let key = UUID().uuidString
        lock.withLock { tables[key] = responses }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CatalogStub.self]
        configuration.httpAdditionalHeaders = [header: key]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let key = request.value(forHTTPHeaderField: Self.header) ?? ""
        let (status, body) = Self.lock.withLock { Self.tables[key]?[request.url!] } ?? (404, Data("Not Found".utf8))
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

@Suite struct PluginCatalogFallbackTests {
    private let stable = PluginCatalog.url(for: .stable)
    private let nightly = PluginCatalog.url(for: .nightly)

    private func index(version: String) -> Data {
        Data(#"{"plugins":[{"id":"sh.abstract.bitbucket","name":"Bitbucket","version":"\#(version)","url":"https://github.com/endeken-com/abstract/releases/download/v0.12.0/sh.abstract.bitbucket-\#(version).zip","hash":"\#(String(repeating: "a", count: 64))","archiveHash":"\#(String(repeating: "b", count: 64))","archiveSignature":"\#(Data(repeating: 0, count: 64).base64EncodedString())"}]}"#.utf8)
    }

    @Test func nightlyReadsItsOwnCatalog() async throws {
        let session = CatalogStub.session([nightly: (200, index(version: "1.0.2")), stable: (200, index(version: "1.0.1"))])
        #expect(try await PluginCatalog.load(channel: .nightly, session: session).plugins.map(\.version) == ["1.0.2"])
    }

    @Test func missingNightlyCatalogFallsBackToStable() async throws {
        let session = CatalogStub.session([stable: (200, index(version: "1.0.1"))])
        #expect(try await PluginCatalog.load(channel: .nightly, session: session).plugins.map(\.version) == ["1.0.1"])
    }

    @Test func invalidNightlyCatalogFallsBackToStable() async throws {
        let session = CatalogStub.session([nightly: (200, Data("{}".utf8)), stable: (200, index(version: "1.0.1"))])
        #expect(try await PluginCatalog.load(channel: .nightly, session: session).plugins.map(\.version) == ["1.0.1"])
    }

    @Test func bothFailingReportsTheNightlyCatalog() async {
        let session = CatalogStub.session([nightly: (200, Data("not json".utf8))])
        do {
            _ = try await PluginCatalog.load(channel: .nightly, session: session)
            Issue.record("loaded a catalog when neither could be read")
        } catch {
            #expect(error == .init(catalog: .nightly, reason: .invalidIndex, stableAlsoFailed: true))
            #expect(error.localizedDescription
                == "The nightly plugin catalog couldn't be read. The stable catalog didn't load either.")
        }
    }

    @Test func stableNeverFallsBack() async {
        let session = CatalogStub.session([nightly: (200, index(version: "1.0.2"))])
        do {
            _ = try await PluginCatalog.load(channel: .stable, session: session)
            Issue.record("the stable channel read the nightly catalog")
        } catch {
            #expect(error == .init(catalog: .stable, reason: .unavailable, stableAlsoFailed: false))
            #expect(error.localizedDescription == "The stable plugin catalog isn't available right now.")
        }
    }
}
