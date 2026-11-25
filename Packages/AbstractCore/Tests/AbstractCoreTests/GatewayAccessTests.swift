import Foundation
import Synchronization
import Testing
@testable import AbstractCore

/// ABS-219: this Mac's side of remote access. Made-up chats and ids only.
@Suite struct GatewayAccessTests {
    static let grantId = "6f1c2b9e-4d3a-4e8b-9c1d-2a3b4c5d6e7f"
    static let otherGrant = "0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d"

    // MARK: The protocol

    @Test func parsesEveryGatewayFrame() {
        #expect(GatewayProtocol.parse(#"{"v":1,"type":"call","id":"c-1","grantId":"\#(Self.grantId)","projects":["p1"],"phi":true,"body":"{}"}"#)
                == .call(id: "c-1", grantId: Self.grantId, projects: .only(["p1"]), phi: true, body: "{}"))
        #expect(GatewayProtocol.parse(#"{"v":1,"type":"call","id":"c-2","grantId":"\#(Self.grantId)","projects":"*","phi":false,"body":""}"#)
                == .call(id: "c-2", grantId: Self.grantId, projects: .all, phi: false, body: ""))
        let consent = GatewayProtocol.parse(#"{"v":1,"type":"consent_request","id":"r1","expiresAt":1800000000000,"scope":["chats:read"],"client":{"name":"Grok","domain":"x.ai","redirectHost":"grok.com","loopback":false}}"#)
        guard case .consentRequest(let request) = consent else { Issue.record("no consent"); return }
        #expect(request.clientName == "Grok" && request.clientDomain == "x.ai" && request.redirectHost == "grok.com" && !request.loopback)
        #expect(request.expiresAt == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(GatewayProtocol.parse(#"{"v":1,"type":"hello","macId":"m","grants":[{"id":"\#(Self.grantId)","createdAt":1,"lastUsedAt":2000}]}"#)
                == .hello(macId: "m", grants: [GatewayGrant(id: Self.grantId, revokedAt: nil, lastUsedAt: Date(timeIntervalSince1970: 2))]))
        #expect(GatewayProtocol.parse(#"{"v":1,"type":"grant_revoked","grantId":"\#(Self.grantId)"}"#) == .grantRevoked(grantId: Self.grantId))
        #expect(GatewayProtocol.parse(#"{"v":1,"type":"ack","id":"a"}"#) == .ack(id: "a"))
    }

    @Test(arguments: [
        #"{"v":2,"type":"ack","id":"a"}"#,
        #"{"v":1,"type":"call","id":"bad id!","grantId":"6f1c2b9e-4d3a-4e8b-9c1d-2a3b4c5d6e7f","projects":"*","phi":false,"body":""}"#,
        #"{"v":1,"type":"call","id":"c","grantId":"6F1C2B9E-4D3A-4E8B-9C1D-2A3B4C5D6E7F","projects":"*","phi":false,"body":""}"#,
        #"{"v":1,"type":"call","id":"c","grantId":"6f1c2b9e-4d3a-4e8b-9c1d-2a3b4c5d6e7f","projects":[],"phi":false,"body":""}"#,
        #"{"v":1,"type":"call","id":"c","grantId":"6f1c2b9e-4d3a-4e8b-9c1d-2a3b4c5d6e7f","projects":[1],"phi":false,"body":""}"#,
        #"{"v":1,"type":"unknown","id":"c"}"#,
        "not json",
    ])
    func refusesFramesItDoesNotUnderstand(_ frame: String) {
        #expect(GatewayProtocol.parse(frame) == nil)
    }

    @Test func writesFramesThePeerReads() throws {
        let grant = RemoteGrant(id: Self.grantId, clientName: "Grok", projects: .only(["b", "a"]), redactsHealthData: true)
        let approve = try #require(JSONValue.parse(GatewayProtocol.approve(id: "r1", grant: grant)))
        #expect(approve == .object(["v": .number(1), "type": .string("consent_response"), "id": .string("r1"), "approve": .bool(true),
                                    "grantId": .string(Self.grantId), "projects": .array([.string("a"), .string("b")]), "phi": .bool(true)]))
        #expect(JSONValue.parse(GatewayProtocol.deny(id: "r2"))?["approve"] == .bool(false))
        #expect(JSONValue.parse(GatewayProtocol.result(id: "c", status: 202, body: ""))?["status"]?.int == 202)
        #expect(JSONValue.parse(GatewayProtocol.update(id: "u", grant: RemoteGrant(id: Self.grantId, clientName: "x", projects: .all)))?["projects"] == .string("*"))
    }

    @Test func credentialsAndGatewaysParseStrictly() {
        let secret = String(repeating: "A", count: 43)
        let credential = RemoteCredential("6F1C2B9E-4D3A-4E8B-9C1D-2A3B4C5D6E7F.\(secret)")
        #expect(credential?.macId == Self.grantId && credential?.authorization == "Device \(Self.grantId).\(secret)")
        #expect(RemoteCredential("not-a-uuid.\(secret)") == nil)
        #expect(RemoteCredential("\(Self.grantId).short") == nil)
        #expect(RemoteCredential("\(Self.grantId).\(String(repeating: "/", count: 43))") == nil)
        #expect(RemoteGateway.fromEnvironment([:]) == .production)
        #expect(RemoteGateway.fromEnvironment(["ABSTRACT_REMOTE_ACCESS_URL": "http://localhost:8787"]).connectURL.absoluteString == "ws://localhost:8787/connect")
        #expect(RemoteGateway.fromEnvironment(["ABSTRACT_REMOTE_ACCESS_URL": "http://evil.example"]) == .production)
        #expect(RemoteGateway.production.connectURL.absoluteString == "wss://mcp.useabstract.app/connect")
    }

    @Test func backoffDoublesToAMinuteWithJitter() {
        #expect([0, 1, 2, 3, 5, 6, 20].map { RemoteBackoff.delay(attempt: $0, jitter: 1) } == [1, 2, 4, 8, 32, 60, 60])
        for attempt in 0..<10 {
            let d = RemoteBackoff.delay(attempt: attempt)
            let base = min(60, pow(2, Double(attempt)))
            #expect(d >= base * 0.8 && d <= base * 1.2)
        }
    }

    // MARK: Answering on this Mac, by project

    /// The chat feed fixture: open-1 in p1 (payments-api), open-2 in p2
    /// (marketing-site, with a planted patient), open-3 in no project.
    static func answer(_ fixture: ChatFeedTests.Fixture, _ grant: RemoteGrant?, _ tool: String,
                       _ arguments: [String: JSONValue] = [:], envelope: RemoteProjects = .all) throws -> (status: Int, value: JSONValue?) {
        let handler = RemoteCallHandler(reader: try fixture.reader(), log: ChatFeedLog(url: fixture.logURL))
        let answer = handler.answer(ChatFeedTests.call(tool, arguments).compact(), grant: grant, projects: envelope)
        let body = JSONValue.parse(answer.body)
        return (answer.status, body?["result"]?["structuredContent"] ?? body?["result"]?["content"]?.array?.first?["text"] ?? body)
    }

    static func ids(_ value: JSONValue?, _ key: String) -> [String] {
        value?[key]?.array?.compactMap { $0["chat_id"]?.string }.sorted() ?? []
    }

    @Test func aGrantSeesOnlyItsProjectsInAllFourTools() throws {
        let fixture = try ChatFeedTests.Fixture()
        let p1 = RemoteGrant(id: Self.grantId, clientName: "Grok", projects: .only(["p1"]))
        #expect(Self.ids(try Self.answer(fixture, p1, ChatFeedMCPServer.listTool).value, "chats") == ["open-1"])
        #expect(Self.ids(try Self.answer(fixture, p1, ChatFeedMCPServer.recentTool, ["desde": .string("2020-01-01T00:00:00Z")]).value, "chats") == ["open-1"])
        #expect(Self.ids(try Self.answer(fixture, p1, ChatFeedMCPServer.searchTool, ["consulta": .string("hero")]).value, "resultados") == [])
        #expect(Self.ids(try Self.answer(fixture, p1, ChatFeedMCPServer.searchTool, ["consulta": .string("webhook")]).value, "resultados").allSatisfy { $0 == "open-1" })
        #expect(try Self.answer(fixture, p1, ChatFeedMCPServer.readTool, ["chat_id": .string("open-1")]).value?["mensagens"]?.array?.count == 2)
        for outside in ["open-2", "open-3"] {
            let (status, value) = try Self.answer(fixture, p1, ChatFeedMCPServer.readTool, ["chat_id": .string(outside)])
            #expect(status == 200 && value?.string == "Chat não encontrado.")
        }
        let all = RemoteGrant(id: Self.grantId, clientName: "Grok", projects: .all)
        #expect(Self.ids(try Self.answer(fixture, all, ChatFeedMCPServer.listTool).value, "chats") == ["open-1", "open-2", "open-3"])
    }

    @Test func theGatewaysCopyCanNarrowAGrantButNeverWidenIt() throws {
        let fixture = try ChatFeedTests.Fixture()
        let all = RemoteGrant(id: Self.grantId, clientName: "Grok", projects: .all)
        #expect(Self.ids(try Self.answer(fixture, all, ChatFeedMCPServer.listTool, envelope: .only(["p2"])).value, "chats") == ["open-2"])
        let p1 = RemoteGrant(id: Self.grantId, clientName: "Grok", projects: .only(["p1"]))
        #expect(Self.ids(try Self.answer(fixture, p1, ChatFeedMCPServer.listTool, envelope: .all).value, "chats") == ["open-1"])
        #expect(Self.ids(try Self.answer(fixture, p1, ChatFeedMCPServer.listTool, envelope: .only(["p2"])).value, "chats") == [])
    }

    @Test func unknownAndRevokedGrantsAreRefusedWithoutReadingAnything() throws {
        let fixture = try ChatFeedTests.Fixture()
        let (status, value) = try Self.answer(fixture, nil, ChatFeedMCPServer.listTool)
        #expect(status == 403 && value?["error"]?["code"]?.int == -32001)
        let revoked = RemoteGrant(id: Self.grantId, clientName: "Grok", projects: .all, revokedAt: Date())
        #expect(try Self.answer(fixture, revoked, ChatFeedMCPServer.listTool).status == 403)
        #expect(!FileManager.default.fileExists(atPath: fixture.logURL.path))
    }

    @Test func redactionAlwaysHidesCodeAndSecretsAndHealthDataPerGrant() throws {
        let fixture = try ChatFeedTests.Fixture()
        let plain = RemoteGrant(id: Self.grantId, clientName: "Grok", projects: .all, redactsHealthData: false)
        let one = try Self.answer(fixture, plain, ChatFeedMCPServer.readTool, ["chat_id": .string("open-1")]).value?.compact() ?? ""
        #expect(one.contains("[bloco de código: swift, 2 linhas]") && !one.contains("hunter2planted") && !one.contains("PLANTEDfake"))
        let patient = try Self.answer(fixture, plain, ChatFeedMCPServer.readTool, ["chat_id": .string("open-2")]).value?.compact() ?? ""
        #expect(patient.contains("Maria da Silva"))
        let phi = RemoteGrant(id: Self.grantId, clientName: "Grok", projects: .all, redactsHealthData: true)
        let hidden = try Self.answer(fixture, phi, ChatFeedMCPServer.readTool, ["chat_id": .string("open-2")]).value?.compact() ?? ""
        #expect(!hidden.contains("Maria da Silva") && !hidden.contains("123.456.789-09"))
    }

    // MARK: The client, over fake sockets

    final class MemoryGrants: RemoteGrantStore, @unchecked Sendable {
        let grants: Mutex<[RemoteGrant]>
        init(_ grants: [RemoteGrant] = []) { self.grants = Mutex(grants) }
        func load() -> [RemoteGrant] { grants.withLock { $0 } }
        func save(_ list: [RemoteGrant]) { grants.withLock { $0 = list } }
    }

    final class FakeSocket: RemoteSocket, @unchecked Sendable {
        let inbox = AsyncStream<String?>.makeStream()
        let sent = Mutex<[String]>([])
        let reason = Mutex<String?>(nil)
        /// One iterator for the socket's life: only the client's run loop receives.
        private var iterator: AsyncStream<String?>.Iterator
        init() { iterator = inbox.stream.makeAsyncIterator() }
        func send(_ text: String) async throws { sent.withLock { $0.append(text) } }
        func receive() async throws -> String? {
            guard let item = await iterator.next() else { return nil }
            return item
        }
        func close() { inbox.continuation.yield(nil) }
        var closeReason: String? { reason.withLock { $0 } }
        func deliver(_ frame: String) { inbox.continuation.yield(frame) }
        func drop(reason text: String? = nil) { reason.withLock { $0 = text }; inbox.continuation.yield(nil) }
        func frames() -> [JSONValue] { sent.withLock { $0 }.compactMap(JSONValue.parse) }
        func frames(_ type: String) -> [JSONValue] { frames().filter { $0["type"]?.string == type } }
    }

    /// Hands out scripted sockets, or fails, in order.
    final class FakeSockets: RemoteSocketFactory, @unchecked Sendable {
        let script: Mutex<[FakeSocket?]>
        let made = Mutex<[FakeSocket]>([])
        init(_ script: [FakeSocket?]) { self.script = Mutex(script) }
        func connect(_ gateway: RemoteGateway, credential: RemoteCredential) async throws -> any RemoteSocket {
            let next = script.withLock { $0.isEmpty ? nil : $0.removeFirst() }
            guard let socket = next else { throw RemoteAccessError.http(503) }
            made.withLock { $0.append(socket) }
            return socket
        }
    }

    static let credential = RemoteCredential(macId: "11111111-2222-4333-8444-555555555555", secret: String(repeating: "x", count: 43))

    final class Recorder: Sendable {
        let states = Mutex<[RemoteAccessState]>([])
        let sleeps = Mutex<[TimeInterval]>([])
    }

    struct Harness: Sendable {
        let client: RemoteAccessClient
        let recorder: Recorder
        let grants: MemoryGrants
    }

    static func harness(_ sockets: FakeSockets, grants: [RemoteGrant] = [], fixture: ChatFeedTests.Fixture,
                        heartbeat: TimeInterval = 3600,
                        consent: @escaping RemoteAccessClient.ConsentHandler = { _ in nil }) throws -> Harness {
        let recorder = Recorder()
        let store = MemoryGrants(grants)
        let client = RemoteAccessClient(
            gateway: .production, credential: credential, store: store,
            handler: RemoteCallHandler(reader: try fixture.reader(), log: nil), sockets: sockets, heartbeat: heartbeat,
            consent: consent, onState: { s in recorder.states.withLock { $0.append(s) } },
            sleep: { seconds in
                recorder.sleeps.withLock { $0.append(seconds) }
                // Reconnect delays pass at once; a heartbeat-length sleep waits to be cancelled.
                if seconds >= 3600 { try await Task.sleep(for: .seconds(seconds)) } else { try await Task.sleep(for: .milliseconds(5)) }
            })
        return Harness(client: client, recorder: recorder, grants: store)
    }

    static func until(_ condition: @escaping @Sendable () async -> Bool) async throws {
        for _ in 0..<400 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("timed out waiting")
    }

    static func hello(_ grants: [(String, Bool)] = []) -> String {
        let list = grants.map { #"{"id":"\#($0.0)","createdAt":1\#($0.1 ? #","revokedAt":2"# : "")}"# }.joined(separator: ",")
        return #"{"v":1,"type":"hello","macId":"m","grants":[\#(list)]}"#
    }

    static func callFrame(_ id: String, grant: String, tool: String = ChatFeedMCPServer.listTool, projects: String = #""*""#) -> String {
        let body = ChatFeedTests.call(tool).compact().replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return #"{"v":1,"type":"call","id":"\#(id)","grantId":"\#(grant)","projects":\#(projects),"phi":false,"body":"\#(body)"}"#
    }

    @Test func answersCallsForItsOwnGrantsAndRefusesOthers() async throws {
        let fixture = try ChatFeedTests.Fixture()
        let socket = FakeSocket()
        let h = try Self.harness(FakeSockets([socket]), grants: [RemoteGrant(id: Self.grantId, clientName: "Grok", projects: .only(["p2"]))],
                                 fixture: fixture)
        await h.client.start()
        socket.deliver(Self.hello([(Self.grantId, false)]))
        socket.deliver(Self.callFrame("c1", grant: Self.grantId))
        socket.deliver(Self.callFrame("c2", grant: Self.otherGrant))
        try await Self.until { socket.frames("result").count == 2 }
        let results = Dictionary(uniqueKeysWithValues: socket.frames("result").map { ($0["id"]!.string!, $0) })
        #expect(results["c1"]?["status"]?.int == 200)
        let listed = JSONValue.parse(results["c1"]!["body"]!.string!)?["result"]?["structuredContent"]?["chats"]?.array?.compactMap { $0["chat_id"]?.string }
        #expect(listed == ["open-2"])
        #expect(results["c2"]?["status"]?.int == 403)
        #expect(await h.client.grants.first?.lastUsedAt != nil)
        await h.client.stop()
    }

    @Test func consentIsRecordedHereBeforeItIsSent() async throws {
        let fixture = try ChatFeedTests.Fixture()
        let socket = FakeSocket()
        let h = try Self.harness(FakeSockets([socket]), fixture: fixture, consent: { request in
            request.clientName == "Grok" ? RemoteGrant(id: Self.grantId, clientName: request.clientName, projects: .only(["p1"])) : nil
        })
        await h.client.start()
        socket.deliver(Self.hello())
        socket.deliver(#"{"v":1,"type":"consent_request","id":"r1","expiresAt":\#(Int(Date().timeIntervalSince1970 * 1000) + 60_000),"scope":["chats:read"],"client":{"name":"Grok","redirectHost":"grok.com","loopback":false}}"#)
        socket.deliver(#"{"v":1,"type":"consent_request","id":"r2","expiresAt":\#(Int(Date().timeIntervalSince1970 * 1000) + 60_000),"scope":["chats:read"],"client":{"name":"Other","redirectHost":"x.example","loopback":true}}"#)
        try await Self.until { socket.frames("consent_response").count == 2 }
        let responses = Dictionary(uniqueKeysWithValues: socket.frames("consent_response").map { ($0["id"]!.string!, $0) })
        #expect(responses["r1"]?["approve"] == .bool(true) && responses["r1"]?["grantId"]?.string == Self.grantId)
        #expect(responses["r1"]?["projects"] == .array([.string("p1")]))
        #expect(responses["r2"]?["approve"] == .bool(false))
        #expect(h.grants.load().map(\.id) == [Self.grantId])
        await h.client.stop()
    }

    @Test func reconcilesWithTheGatewayOnEveryConnection() async throws {
        let fixture = try ChatFeedTests.Fixture()
        let socket = FakeSocket()
        let revokedHere = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        let goneThere = "bbbbbbbb-cccc-4ddd-8eee-ffffffffffff"
        let h = try Self.harness(FakeSockets([socket]), grants: [
            RemoteGrant(id: Self.grantId, clientName: "kept", projects: .all),
            RemoteGrant(id: revokedHere, clientName: "revoked here", projects: .all, revokedAt: Date()),
            RemoteGrant(id: goneThere, clientName: "never stored there", projects: .all),
        ], fixture: fixture)
        await h.client.start()
        // The gateway still honours the one revoked here, and one this Mac never made.
        socket.deliver(Self.hello([(Self.grantId, false), (revokedHere, false), (Self.otherGrant, false)]))
        try await Self.until { socket.frames("revoke").count == 2 }
        #expect(Set(socket.frames("revoke").compactMap { $0["grantId"]?.string }) == [revokedHere, Self.otherGrant])
        try await Self.until { await h.client.grants.first { $0.id == goneThere }?.revokedAt != nil }
        #expect(await h.client.grants.first { $0.id == Self.grantId }?.isActive == true)
        // And the gateway revoking one is reflected here.
        socket.deliver(#"{"v":1,"type":"grant_revoked","grantId":"\#(Self.grantId)"}"#)
        try await Self.until { await h.client.grants.first { $0.id == Self.grantId }?.isActive == false }
        await h.client.stop()
    }

    @Test func revokingTakesEffectHereAtOnceAndTellsTheGateway() async throws {
        let fixture = try ChatFeedTests.Fixture()
        let socket = FakeSocket()
        let h = try Self.harness(FakeSockets([socket]), grants: [RemoteGrant(id: Self.grantId, clientName: "Grok", projects: .all)], fixture: fixture)
        await h.client.start()
        socket.deliver(Self.hello([(Self.grantId, false)]))
        try await Self.until { await h.client.isConnected }
        await h.client.revoke(Self.grantId)
        #expect(h.grants.load().first?.isActive == false)
        try await Self.until { socket.frames("revoke").first?["grantId"]?.string == Self.grantId }
        socket.deliver(Self.callFrame("late", grant: Self.grantId))
        try await Self.until { socket.frames("result").count == 1 }
        #expect(socket.frames("result").first?["status"]?.int == 403)
        await h.client.stop()
    }

    @Test func updatesReachTheGateway() async throws {
        let fixture = try ChatFeedTests.Fixture()
        let socket = FakeSocket()
        let h = try Self.harness(FakeSockets([socket]), grants: [RemoteGrant(id: Self.grantId, clientName: "Grok", projects: .all)], fixture: fixture)
        await h.client.start()
        socket.deliver(Self.hello([(Self.grantId, false)]))
        try await Self.until { await h.client.isConnected }
        await h.client.update(RemoteGrant(id: Self.grantId, clientName: "ignored", projects: .only(["p1"]), redactsHealthData: true))
        try await Self.until { !socket.frames("grant_update").isEmpty }
        #expect(socket.frames("grant_update").first?["projects"] == .array([.string("p1")]))
        #expect(h.grants.load().first?.redactsHealthData == true && h.grants.load().first?.clientName == "Grok")
        await h.client.stop()
    }

    @Test func reconnectsWithBackoffAndStopsWhenUnregistered() async throws {
        let fixture = try ChatFeedTests.Fixture()
        let first = FakeSocket(), second = FakeSocket()
        // Two failed attempts, a socket that drops, a failure, then one that's unregistered.
        let sockets = FakeSockets([nil, nil, first, nil, second])
        let h = try Self.harness(sockets, fixture: fixture)
        await h.client.start()
        try await Self.until { sockets.made.withLock { $0.count } == 1 }
        first.deliver(Self.hello())
        try await Self.until { h.recorder.states.withLock { $0 }.contains(.connected) }
        first.drop(reason: "replaced")
        try await Self.until { sockets.made.withLock { $0.count } == 2 }
        second.drop(reason: "unregistered")
        try await Self.until { h.recorder.states.withLock { $0 }.last == .unregistered }
        let sleeps = h.recorder.sleeps.withLock { $0 }.filter { $0 < 3600 }
        // 1 s, 2 s; reset after connecting: 1 s (replaced), 2 s.
        #expect(sleeps.count == 4)
        for (delay, base) in zip(sleeps, [1.0, 2, 1, 2]) { #expect(delay >= base * 0.8 && delay <= base * 1.2) }
        #expect(h.recorder.states.withLock { $0 }.contains { if case .replaced = $0 { true } else { false } })
        #expect(sockets.made.withLock { $0.count } == 2)
    }

    @Test func sendsHeartbeatsAndDropsASilentSocket() async throws {
        let fixture = try ChatFeedTests.Fixture()
        let socket = FakeSocket()
        let states = Mutex<[RemoteAccessState]>([])
        let client = RemoteAccessClient(
            gateway: .production, credential: Self.credential, store: MemoryGrants(),
            handler: RemoteCallHandler(reader: try fixture.reader(), log: nil), sockets: FakeSockets([socket]), heartbeat: 0.05,
            consent: { _ in nil }, onState: { s in states.withLock { $0.append(s) } })
        await client.start()
        socket.deliver(Self.hello())
        try await Self.until { socket.sent.withLock { $0 }.contains("ping") }
        // Nothing heard for three beats: closed, and it goes back to reconnecting.
        try await Self.until { states.withLock { $0 }.contains { if case .waiting = $0 { true } else { false } } }
        await client.stop()
    }

    @Test func asksForAConnectionCode() async throws {
        let fixture = try ChatFeedTests.Fixture()
        let socket = FakeSocket()
        let h = try Self.harness(FakeSockets([socket]), fixture: fixture)
        await h.client.start()
        socket.deliver(Self.hello())
        try await Self.until { await h.client.isConnected }
        async let code = h.client.connectionCode(timeout: 3600)
        try await Self.until { !socket.frames("connect_code_request").isEmpty }
        let id = socket.frames("connect_code_request")[0]["id"]!.string!
        socket.deliver(#"{"v":1,"type":"connect_code","id":"\#(id)","code":"ABCD-EFGH","expiresAt":1800000000000}"#)
        #expect(try await code.code == "ABCD-EFGH")
        await h.client.stop()
    }
}
