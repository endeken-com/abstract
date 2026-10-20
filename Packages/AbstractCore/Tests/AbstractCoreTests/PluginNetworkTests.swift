import Foundation
import Testing
@testable import AbstractCore

@Suite struct PluginNetworkTests {
    let fm = FileManager.default

    /// Records what would have gone on the wire, answers from a script.
    final class FakeTransport: PluginNetworkTransport, @unchecked Sendable {
        private(set) var sent: [URLRequest] = []
        var respond: (URLRequest) -> (Data, HTTPURLResponse)
        init(respond: @escaping (URLRequest) -> (Data, HTTPURLResponse) = { _ in
            (Data("ok".utf8), HTTPURLResponse(url: URL(string: "https://hooks.slack.com/x")!,
                                              statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }) { self.respond = respond }
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            sent.append(request)
            return respond(request)
        }
        func response(_ url: URL, _ status: Int, headers: [String: String]? = nil, body: String = "ok") -> (Data, HTTPURLResponse) {
            (Data(body.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!)
        }
    }

    func service(transport: FakeTransport, secrets: [String: String] = [:],
                 log: PluginNetworkLog? = nil) -> PluginFetchService {
        PluginFetchService(pluginId: "sh.example.slack", allowedHosts: ["hooks.slack.com", "api.slack.com"],
                           secretNames: ["slackToken"], secrets: DictionaryPluginSecrets(secrets),
                           transport: transport, log: log)
    }

    func expectRefused(_ body: () async throws -> Void) async {
        do {
            try await body()
            Issue.record("expected a refusal")
        } catch is PluginFetchError {
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    // MARK: Manifest

    @Test func manifestDeclaresExactHostsAndNamedSecrets() throws {
        let manifest = PluginManifest(id: "sh.example.slack", name: "Slack", version: "1.0.0",
                                      capabilities: ["network", "secrets"],
                                      networkHosts: ["Hooks.Slack.com"],
                                      secrets: [.init(name: "slackToken", title: "Slack bot token")],
                                      views: [.init(id: "main", title: "Slack")])
        try manifest.validate()
        #expect(manifest.networkHosts == ["hooks.slack.com"])
        #expect(manifest.networkSentences == ["Reach hooks.slack.com.", "Use your Slack bot token, without seeing it."])

        // Wildcards, URLs-as-hosts, and grants with nothing listed fail closed.
        for bad in [["*.slack.com"], ["https://hooks.slack.com"], ["hooks.slack.com:8443"], ["slack"]] {
            let manifest = PluginManifest(id: "sh.example.slack", name: "Slack", version: "1.0.0",
                                          capabilities: ["network"], networkHosts: bad,
                                          views: [.init(id: "main", title: "Slack")])
            #expect(throws: PluginValidationError.self) { try manifest.validate() }
        }
        let noHosts = PluginManifest(id: "sh.example.slack", name: "Slack", version: "1.0.0",
                                     capabilities: ["network"], views: [.init(id: "main", title: "Slack")])
        #expect(throws: PluginValidationError.self) { try noHosts.validate() }
        let hostsNoGrant = PluginManifest(id: "sh.example.slack", name: "Slack", version: "1.0.0",
                                          capabilities: ["chats.read"], networkHosts: ["hooks.slack.com"],
                                          views: [.init(id: "main", title: "Slack")])
        #expect(throws: PluginValidationError.self) { try hostsNoGrant.validate() }
        let secretsNoGrant = PluginManifest(id: "sh.example.slack", name: "Slack", version: "1.0.0",
                                            capabilities: ["chats.read"],
                                            secrets: [.init(name: "slackToken", title: "Slack bot token")],
                                            views: [.init(id: "main", title: "Slack")])
        #expect(throws: PluginValidationError.self) { try secretsNoGrant.validate() }
    }

    // MARK: Fetch rules

    @Test func aListedHostCanBePostedToAndAnUnlistedOneIsRefused() async throws {
        let transport = FakeTransport()
        let fetch = PluginFetchRequest(url: "https://hooks.slack.com/services/T/B/x", method: "POST",
                                       headers: ["Content-Type": "application/json"], body: #"{"text":"hi"}"#)
        let response = try await service(transport: transport).perform(fetch)
        #expect(response.status == 200)
        #expect(transport.sent.count == 1)
        #expect(transport.sent.first?.httpMethod == "POST")
        #expect(transport.sent.first?.httpBody.map { String(decoding: $0, as: UTF8.self) } == #"{"text":"hi"}"#)

        await expectRefused { _ = try await service(transport: transport).perform(
            .init(url: "https://example.com/collect", method: "POST", body: "stolen")) }
        #expect(transport.sent.count == 1) // nothing more was sent

        // Subdomains, plain http, odd ports and userinfo don't sneak past the exact host.
        for url in ["https://evil.hooks.slack.com/x", "http://hooks.slack.com/x",
                    "https://hooks.slack.com:8443/x", "https://hooks.slack.com@example.com/x"] {
            await expectRefused { _ = try await service(transport: transport).perform(.init(url: url)) }
        }
        #expect(transport.sent.count == 1)
    }

    @Test func cookiesAreNeverSent() async throws {
        let transport = FakeTransport()
        _ = try await service(transport: transport).perform(
            .init(url: "https://api.slack.com/api/test", headers: ["Cookie": "session=abc", "X-Plugin": "1"]))
        let sent = try #require(transport.sent.first)
        #expect(sent.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(sent.value(forHTTPHeaderField: "X-Plugin") == "1")
        #expect(sent.httpShouldHandleCookies == false)
    }

    @Test func bodiesOverTheLimitAreRefused() async throws {
        let transport = FakeTransport()
        let big = String(repeating: "x", count: PluginFetchService.bodyByteLimit + 1)
        await expectRefused { _ = try await service(transport: transport).perform(
            .init(url: "https://hooks.slack.com/x", method: "POST", body: big)) }
        #expect(transport.sent.isEmpty)

        let fatReply = FakeTransport { _ in
            (Data(repeating: 0x61, count: PluginFetchService.bodyByteLimit + 1),
             HTTPURLResponse(url: URL(string: "https://hooks.slack.com/x")!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        await expectRefused { _ = try await service(transport: fatReply).perform(.init(url: "https://hooks.slack.com/x")) }
    }

    @Test func aRedirectToAnUnlistedHostIsRefusedAndToAListedOneIsFollowed() async throws {
        let escaping = FakeTransport { request in
            (Data(), HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: nil,
                                     headerFields: ["Location": "https://example.com/collect"])!)
        }
        await expectRefused { _ = try await service(transport: escaping).perform(.init(url: "https://hooks.slack.com/x")) }
        #expect(escaping.sent.count == 1) // the redirect was never followed

        let staying = FakeTransport()
        var calls = 0
        staying.respond = { request in
            calls += 1
            if calls == 1 {
                return (Data(), HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: nil,
                                                headerFields: ["Location": "/moved"])!)
            }
            return (Data("landed".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let response = try await service(transport: staying).perform(.init(url: "https://hooks.slack.com/x"))
        #expect(response.body == "landed")
        #expect(staying.sent.last?.url?.absoluteString == "https://hooks.slack.com/moved")
    }

    // MARK: Secrets

    @Test func aSecretIsInsertedByTheHostAndNeverReachesThePlugin() async throws {
        let transport = FakeTransport()
        let fetch = PluginFetchRequest(
            url: "https://api.slack.com/chat.postMessage", method: "POST",
            secretHeaders: ["Authorization": .init(secret: "slackToken", prefix: "Bearer ")],
            body: #"{"text":"hi"}"#)
        let reply = try await service(transport: transport, secrets: ["slackToken": "xoxb-test-value"]).perform(fetch)

        // The wire carries the value; everything the plugin can see does not.
        #expect(transport.sent.first?.value(forHTTPHeaderField: "Authorization") == "Bearer xoxb-test-value")
        #expect(!reply.jsonValue().compact().contains("xoxb-test-value"))

        // Naming a secret the plugin wasn't granted, or one never entered, is refused.
        await expectRefused { _ = try await service(transport: transport, secrets: ["slackToken": "x"]).perform(
            .init(url: "https://api.slack.com/x", secretHeaders: ["Authorization": .init(secret: "otherToken")])) }
        await expectRefused { _ = try await service(transport: transport).perform(fetch) }
        #expect(transport.sent.count == 1)
    }

    @Test func aTestPluginCannotReadASecretThroughTheBridge() throws {
        let root = fm.temporaryDirectory.appendingPathComponent("abstract-net-tests-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let storage = PluginStorage(directory: root, pluginId: "sh.example.slack")
        var bridge = PluginBridge(capabilities: [.network, .secrets],
                                  allowedHosts: ["hooks.slack.com"], secretNames: ["slackToken"])

        // There is no message that returns a secret value.
        for type in ["secrets.get", "secret", "getSecret"] {
            let outcome = bridge.handle(#"{"api":1,"type":"\#(type)","id":"1","payload":{"name":"slackToken"}}"#, storage: storage)
            if case .refused = outcome {} else { Issue.record("\(type) wasn't refused: \(outcome)") }
        }
        // A fetch naming a granted secret passes the bridge carrying only the name.
        let outcome = bridge.handle(
            #"{"api":1,"type":"fetch","id":"2","payload":{"url":"https://hooks.slack.com/x","secretHeaders":{"Authorization":{"secret":"slackToken","prefix":"Bearer "}}}}"#,
            storage: storage)
        #expect(outcome == .fetch(id: "2", PluginFetchRequest(
            url: "https://hooks.slack.com/x",
            secretHeaders: ["Authorization": .init(secret: "slackToken", prefix: "Bearer ")])))
        // Unlisted host and no-network-grant fetches are refused at the bridge.
        let unlisted = bridge.handle(#"{"api":1,"type":"fetch","id":"3","payload":{"url":"https://example.com/x"}}"#, storage: storage)
        if case .refused = unlisted {} else { Issue.record("unlisted host wasn't refused: \(unlisted)") }
        var noGrant = PluginBridge(capabilities: [.chatsRead])
        let denied = noGrant.handle(#"{"api":1,"type":"fetch","id":"4","payload":{"url":"https://hooks.slack.com/x"}}"#, storage: storage)
        if case .refused = denied {} else { Issue.record("fetch without the grant wasn't refused: \(denied)") }
    }

    // MARK: Activity log

    @Test func everyRequestIsLoggedWithTimeHostAndStatus() async throws {
        let root = fm.temporaryDirectory.appendingPathComponent("abstract-net-tests-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let log = PluginNetworkLog(directory: root, pluginId: "sh.example.slack")
        let at = Date(timeIntervalSince1970: 5_000)
        let transport = FakeTransport()
        _ = try await service(transport: transport, secrets: ["slackToken": "xoxb-hidden"], log: log).perform(
            .init(url: "https://hooks.slack.com/services/T/B/x", method: "POST", body: "hi"), now: at)
        await expectRefused { _ = try await service(transport: transport, log: log).perform(
            .init(url: "https://example.com/x"), now: at) }

        let entries = log.entries()
        #expect(entries.contains(.init(at: at, host: "hooks.slack.com", status: 200)))
        #expect(entries.contains(.init(at: at, host: "example.com", status: 0)))
        // The log file holds no path, body or secret.
        let raw = try String(contentsOf: log.fileURL, encoding: .utf8)
        #expect(!raw.contains("services") && !raw.contains("xoxb"))
    }

    // MARK: Update grants

    @Test func anUpdateAddingAHostOrSecretLandsDisabled() throws {
        let root = fm.temporaryDirectory.appendingPathComponent("abstract-net-tests-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let host = PluginManager(store: try Store.inMemory(),
                                 pluginsRoot: root.appendingPathComponent("Plugins"),
                                 dataRoot: root.appendingPathComponent("PluginData"))
        func package(version: String, hosts: [String]) throws -> URL {
            let folder = root.appendingPathComponent("pkg-\(UUID().uuidString)")
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let manifest: [String: Any] = [
                "api": 1, "id": "sh.example.slack", "name": "Slack", "version": version,
                "entry": "index.html", "capabilities": ["network"],
                "network": ["hosts": hosts],
                "contributes": ["views": [["id": "main", "title": "Slack", "location": "main"]]],
            ]
            try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent("manifest.json"))
            try "<html></html>".write(to: folder.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
            return folder
        }
        // Records written before ABS-94 (no host grants in the JSON) still read.
        let old = #"{"id":"sh.example.old","name":"Old","version":"1.0.0","source":"user","enabled":true,"grantedCapabilities":["chats.read"],"packageHash":"x","installedAt":0}"#
        #expect(try JSONDecoder().decode(PluginRecord.self, from: Data(old.utf8)).grantedNetworkHosts.isEmpty)

        let record = try host.install(from: package(version: "1.0.0", hosts: ["hooks.slack.com"]), sourceKind: .user)
        host.setEnabled(record.id, true)
        #expect(host.records().first?.grantedNetworkHosts == ["hooks.slack.com"])

        let grown = try host.install(from: package(version: "1.1.0", hosts: ["hooks.slack.com", "api.slack.com"]), sourceKind: .user)
        #expect(grown.enabled == false)
        #expect(grown.grantedNetworkHosts.isEmpty)

        host.setEnabled(record.id, true)
        let same = try host.install(from: package(version: "1.2.0", hosts: ["api.slack.com", "hooks.slack.com"]), sourceKind: .user)
        #expect(same.enabled == true)
        #expect(Set(same.grantedNetworkHosts) == ["hooks.slack.com", "api.slack.com"])
    }
}
