import CryptoKit
import Foundation
import Network
import Testing
@testable import AbstractCore

@Suite("Remote pairing and channel")
struct RemoteTests {
    private let host = DeviceIdentity.generate(name: "Mac mini")
    private let controller = DeviceIdentity.generate(name: "MacBook")

    /// A handshake run in memory, returning both sides' outcomes.
    private func handshake(pairing: Bool, pinnedHost: PeerInfo?, pinnedController: PeerInfo?) throws -> (Handshake.Outcome, Handshake.Outcome) {
        let initiator = Handshake.Initiator(identity: controller, pairing: pairing)
        let responder = Handshake.Responder(identity: host)
        let (reply, _, _) = try responder.respond(to: try initiator.start(), lookup: { _ in pinnedController })
        let (finish, mine) = try initiator.finish(reply: reply, expected: pinnedHost)
        return (mine, try responder.complete(finish: finish))
    }

    @Test func pairingShowsTheSameCodeOnBothScreens() throws {
        let (a, b) = try handshake(pairing: true, pinnedHost: nil, pinnedController: nil)
        #expect(a.code == b.code)
        #expect(a.code.count == 7 && a.code.contains(" "))
        #expect(a.peer == host.peer && b.peer == controller.peer)
    }

    @Test func framesOpenOnlyOnTheOtherSideInOrder() throws {
        var (a, b) = try handshake(pairing: true, pinnedHost: nil, pinnedController: nil)
        var mine = a.cipher, theirs = b.cipher
        let first = try mine.seal(Data("hello".utf8))
        let second = try mine.seal(Data("again".utf8))
        #expect(try theirs.open(first) == Data("hello".utf8))
        // A replayed frame fails: its number was used.
        #expect(throws: SecureChannelError.tampered) { try theirs.open(first) }
        _ = second
        // And the other way.
        (a, b) = try handshake(pairing: true, pinnedHost: nil, pinnedController: nil)
        mine = a.cipher; theirs = b.cipher
        let reply = try theirs.seal(Data("back".utf8))
        #expect(try mine.open(reply) == Data("back".utf8))
    }

    @Test func alteredFramesAreRefused() throws {
        let (a, b) = try handshake(pairing: true, pinnedHost: nil, pinnedController: nil)
        var mine = a.cipher, theirs = b.cipher
        var frame = try mine.seal(Data("run rm -rf".utf8))
        frame[frame.count / 2] ^= 0xFF
        #expect(throws: SecureChannelError.tampered) { try theirs.open(frame) }
    }

    @Test func unpairedDevicesCantConnectOutsidePairing() {
        #expect(throws: SecureChannelError.unknownPeer) { try handshake(pairing: false, pinnedHost: host.peer, pinnedController: nil) }
    }

    @Test func aChangedIdentityIsRefused() {
        let impostor = DeviceIdentity(id: host.id, name: host.name, signingKey: Curve25519.Signing.PrivateKey())
        #expect(throws: SecureChannelError.keyChanged) {
            try handshake(pairing: false, pinnedHost: impostor.peer, pinnedController: controller.peer)
        }
    }

    @Test func pairedDevicesReconnectWithoutACode() throws {
        let (a, b) = try handshake(pairing: false, pinnedHost: host.peer, pinnedController: controller.peer)
        #expect(!a.pairing && !b.pairing)
    }

    @Test func messagesCrossARealConnection() async throws {
        let listener = try NWListener(using: RemoteNetwork.parameters, on: .any)
        let accepted = AsyncStream<NWConnection>.makeStream()
        listener.newConnectionHandler = { accepted.continuation.yield($0) }
        let ready = AsyncStream<UInt16>.makeStream()
        listener.stateUpdateHandler = { state in
            if case .ready = state, let port = listener.port?.rawValue { ready.continuation.yield(port) }
        }
        listener.start(queue: .global())
        defer { listener.cancel() }
        var ports = ready.stream.makeAsyncIterator()
        let port = try #require(await ports.next())

        let hostIdentity = host, controllerIdentity = controller
        async let served: RemoteMessage = {
            var incoming = accepted.stream.makeAsyncIterator()
            let channel = RemoteChannel(connection: await incoming.next()!)
            try await channel.open()
            let outcome = try await channel.accept(as: hostIdentity, lookup: { _ in nil })
            #expect(outcome.pairing)
            let request = try await channel.receive()
            try await channel.send(.event(.paired(true)))
            return request
        }()

        let client = RemoteChannel(connection: NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: RemoteNetwork.parameters))
        try await client.open()
        _ = try await client.handshake(as: controllerIdentity, pairing: true, expected: nil)
        try await client.send(.request(id: 1, .send(sessionId: "s1", text: "Add a test")))
        guard case .event(.paired(true)) = try await client.receive() else { Issue.record("no pairing answer"); return }
        guard case .request(1, .send("s1", "Add a test")) = try await served else { Issue.record("request didn't arrive"); return }
        client.close()
    }

    @Test func framesStateTheirLength() {
        let framed = RemoteFraming.frame(Data([1, 2, 3]))
        #expect(framed.count == 7)
        #expect(RemoteFraming.length(framed.prefix(4)) == 3)
        #expect(RemoteFraming.length(Data([0xFF, 0xFF, 0xFF, 0xFF])) == nil)
    }
}

@Suite("Remote access")
struct RemoteAccessTests {
    private let allowed: (String?) -> Bool = { $0?.hasPrefix("/work/repo") == true }

    @Test func gitGhAndRevundRunInProjectsOnly() {
        #expect(RemoteAccess.refusal("git", ["status"], cwd: "/work/repo/wt", allowed: allowed) == nil)
        #expect(RemoteAccess.refusal("git", ["-c", "core.quotePath=false", "diff"], cwd: "/work/repo", allowed: allowed) == nil)
        #expect(RemoteAccess.refusal("gh", ["pr", "view", "1"], cwd: "/work/repo", allowed: allowed) == nil)
        #expect(RemoteAccess.refusal("revund", ["review", "--json", "--repo", "/work/repo"], cwd: "/work/repo", allowed: allowed) == nil)
        #expect(RemoteAccess.refusal("git", ["--version"], cwd: nil, allowed: allowed) == nil)
        #expect(RemoteAccess.refusal("gh", ["auth", "status"], cwd: nil, allowed: allowed) == nil)
    }

    @Test func anythingThatCouldRunAProgramIsRefused() {
        #expect(RemoteAccess.refusal("sh", ["-c", "id"], cwd: "/work/repo", allowed: allowed) != nil)
        #expect(RemoteAccess.refusal("/usr/bin/git", ["status"], cwd: "/work/repo", allowed: allowed) != nil)
        #expect(RemoteAccess.refusal("git", ["status"], cwd: "/etc", allowed: allowed) != nil)
        #expect(RemoteAccess.refusal("git", ["-C", "/etc", "status"], cwd: "/work/repo", allowed: allowed) != nil)
        #expect(RemoteAccess.refusal("git", ["-c", "core.fsmonitor=touch /tmp/x", "status"], cwd: "/work/repo", allowed: allowed) != nil)
        #expect(RemoteAccess.refusal("git", ["diff", "--output=/tmp/x"], cwd: "/work/repo", allowed: allowed) != nil)
        #expect(RemoteAccess.refusal("git", ["fetch", "--upload-pack=evil"], cwd: "/work/repo", allowed: allowed) != nil)
        #expect(RemoteAccess.refusal("gh", ["alias", "set", "x", "!id"], cwd: "/work/repo", allowed: allowed) != nil)
        #expect(RemoteAccess.refusal("gh", ["extension", "exec", "x"], cwd: "/work/repo", allowed: allowed) != nil)
        #expect(RemoteAccess.refusal("revund", ["review", "--repo", "/etc"], cwd: "/work/repo", allowed: allowed) != nil)
        #expect(RemoteAccess.refusal("git", ["status"], cwd: nil, allowed: allowed) != nil)
    }

    @Test func onlyARevundKeyCrossesInTheEnvironment() {
        let env = RemoteAccess.environment(["REVUND_API_KEY": "revund_x", "GIT_SSH_COMMAND": "evil", "DYLD_INSERT_LIBRARIES": "x"])
        #expect(env == ["REVUND_API_KEY": "revund_x"])
    }

    @Test func newRequestsSurviveTheWire() throws {
        let start = RemoteStart(projectId: "p", providerId: "claude", prompt: "hi", files: ["a": Data([1, 2])], baseRef: "main",
                                policy: .autoEdits, model: "opus", effort: "high", worktree: "/wt")
        let message = RemoteMessage.request(id: 3, .startChat(start))
        let decoded = try JSONDecoder().decode(RemoteMessage.self, from: JSONEncoder().encode(message))
        guard case let .request(id, .startChat(back)) = decoded else { Issue.record("wrong message"); return }
        #expect(id == 3)
        #expect(back.files["a"] == Data([1, 2]))
        #expect(back.worktree == "/wt")
        let result = RemoteMessage.response(id: 4, .exec(ExecResult(code: 0, stdout: "ok", stderr: "")))
        guard case .response(_, .exec(let r)) = try JSONDecoder().decode(RemoteMessage.self, from: JSONEncoder().encode(result)) else {
            Issue.record("wrong response"); return
        }
        #expect(r.stdout == "ok")
    }
}

@Suite("Remote history batches")
struct RemoteBatchTests {
    @Test func batchesStayUnderTheirSizeAndKeepOrder() {
        let big = String(repeating: "x", count: 900_000)
        let lines = (1...10).map { RemoteLine(seq: $0, line: OutputLine(stream: .stdout, line: big)) }
        let batches = RemoteLine.batches(lines, bytes: 2 << 20)
        #expect(batches.count == 5)
        #expect(batches.flatMap { $0 }.map(\.seq) == Array(1...10))
        #expect(batches.allSatisfy { $0.reduce(0) { $0 + $1.line.line.utf8.count } <= 2 << 20 })
    }

    @Test func aHugeLineIsCutRatherThanDroppingTheLink() {
        let huge = RemoteLine(seq: 1, line: OutputLine(stream: .stdout, line: String(repeating: "y", count: 6 << 20)))
        let batches = RemoteLine.batches([huge], bytes: 2 << 20)
        #expect(batches.count == 1)
        #expect(batches[0][0].line.line.utf8.count == RemoteLine.maxLine)
    }
}
