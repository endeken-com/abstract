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

    @Test func unpairedMacExplainsWhyReconnectFailed() async throws {
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

        let hostIdentity = host
        async let refusal: Void = {
            var incoming = accepted.stream.makeAsyncIterator()
            let channel = RemoteChannel(connection: await incoming.next()!)
            try await channel.open()
            await #expect(throws: SecureChannelError.unknownPeer) {
                try await channel.accept(as: hostIdentity, lookup: { _ in nil })
            }
            channel.close()
        }()

        let client = RemoteChannel(connection: NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: RemoteNetwork.parameters))
        try await client.open()
        await #expect(throws: SecureChannelError.unknownPeer) {
            try await client.handshake(as: controller, pairing: false, expected: host.peer)
        }
        try await refusal
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
        // git's own options Abstract passes before the command.
        #expect(RemoteAccess.refusal("git", ["--no-optional-locks", "status"], cwd: "/work/repo", allowed: allowed) == nil)
        #expect(RemoteAccess.refusal("git", ["-c", "core.quotePath=false", "--no-pager", "diff", "HEAD"], cwd: "/work/repo", allowed: allowed) == nil)
        #expect(RemoteAccess.refusal("git", ["--literal-pathspecs", "reset", "-q", "--", "a"], cwd: "/work/repo", allowed: allowed) == nil)
        // What Accept runs: a binary diff of the file there, then its patch applied from input.
        #expect(RemoteAccess.refusal("git", ["--no-pager", "--literal-pathspecs", "diff", "HEAD", "--binary", "--no-color", "--no-ext-diff",
                                             "--ignore-submodules=all", "-M", "--", "a.png"], cwd: "/work/repo", allowed: allowed) == nil)
        for args in [["apply", "--check", "-"], ["apply", "-"], ["apply", "--3way", "-"], ["apply", "-R", "--3way", "-"]] {
            #expect(RemoteAccess.refusal("git", args, cwd: "/work/repo", input: true, allowed: allowed) == nil)
        }
    }

    @Test func searchInFilesRunsForAChatOnAnotherMac() {
        for options in [WorktreeSearch.Options(), .init(matchCase: true, wholeWord: true, regex: true)] {
            for isGit in [true, false] {
                let args = WorktreeSearch.arguments("-O3 refreshBranch", options, isGit: isGit)
                #expect(RemoteAccess.refusal("git", args, cwd: "/work/repo/wt", allowed: allowed) == nil)
            }
        }
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
        // git grep opens matches in a program with -O, bundled or abbreviated too.
        for args in [["grep", "-Oid", "-e", "x", "--"], ["grep", "-nOid", "-e", "x", "--"], ["grep", "--open-files-in-pager=id", "-e", "x", "--"],
                     ["grep", "--open-f=id", "-e", "x", "--"], ["grep", "-n", "-e", "x", "--", "-Oid"], ["grep", "-e", "x"],
                     ["-c", "color.ui=never", "grep", "-Oid", "-e", "x", "--"], ["--no-pager", "grep", "-Oid", "-e", "x", "--"],
                     ["--namespace", "x", "grep", "-Oid", "-e", "x", "--"], ["-p", "grep", "-Oid", "-e", "x", "--"]] {
            #expect(RemoteAccess.refusal("git", args, cwd: "/work/repo", allowed: allowed) != nil, "\(args)")
        }
        // Long options git would take abbreviated.
        #expect(RemoteAccess.refusal("git", ["diff", "--out=/tmp/x"], cwd: "/work/repo", allowed: allowed) != nil)
        #expect(RemoteAccess.refusal("git", ["fetch", "--upload=evil"], cwd: "/work/repo", allowed: allowed) != nil)
        #expect(RemoteAccess.refusal("git", ["diff", "--ext"], cwd: "/work/repo", allowed: allowed) != nil)
        // A patch from another Mac writes only inside the repository, and nothing else takes input.
        for args in [["apply", "--unsafe-paths", "-"], ["apply", "--unsafe", "-"], ["apply", "--directory=../..", "-"],
                     ["apply", "--dir", "..", "-"], ["apply", "--include=*", "-"]] {
            #expect(RemoteAccess.refusal("git", args, cwd: "/work/repo", input: true, allowed: allowed) != nil, "\(args)")
        }
        #expect(RemoteAccess.refusal("git", ["apply", "--unsafe-paths", "p.diff"], cwd: "/work/repo", allowed: allowed) != nil)
        for (command, args) in [("git", ["hash-object", "-w", "--stdin"]), ("git", ["apply", "x.diff"]), ("gh", ["api", "--input", "-"])] {
            #expect(RemoteAccess.refusal(command, args, cwd: "/work/repo", input: true, allowed: allowed) != nil, "\(args)")
        }
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
        // A patch to accept goes as the command's input.
        let patch = Data("diff --git a/x b/x\n".utf8)
        let exec = RemoteMessage.request(id: 6, .exec(command: "git", args: ["apply", "-"], cwd: "/w", stdin: patch))
        guard case let .request(_, .exec(command, args, cwd, stdin)) = try JSONDecoder().decode(RemoteMessage.self, from: JSONEncoder().encode(exec)) else {
            Issue.record("wrong request"); return
        }
        #expect(command == "git" && args == ["apply", "-"] && cwd == "/w" && stdin == patch)
        // Without input, the request is the one older Macs send and read.
        let plain = try JSONEncoder().encode(RemoteMessage.request(id: 7, .exec(command: "git", args: ["status"], cwd: "/w")))
        #expect(!String(decoding: plain, as: UTF8.self).contains("stdin"))
        guard case .request(_, .exec(_, _, _, nil)) = try JSONDecoder().decode(RemoteMessage.self, from: plain) else {
            Issue.record("plain exec failed to decode"); return
        }
        let mobileRequests: [RemoteRequest] = [
            .subscribeRecent(sessionId: "chat", limit: 160),
            .history(sessionId: "chat", beforeSeq: 320, limit: 160),
            .startStandalone(providerId: "claude", prompt: "hello", policy: .ask),
            .startStandaloneConfigured(providerId: "claude", prompt: "see file", policy: .ask,
                                       attachments: [PromptAttachment(kind: .file, title: "note.txt")],
                                       files: ["bytes": Data([1, 2, 3])], model: "opus", effort: "high"),
            .deleteChat(sessionId: "chat", removeWorktree: true),
            .removeWorktree(projectId: "project", path: "/worktree", deleteBranch: false),
            .review(sessionId: "chat", committed: true),
            .reviewFile(sessionId: "chat", path: "file.swift", committed: false, accept: true),
            .createPullRequest(sessionId: "chat", title: "Title", body: "Body", base: "main", draft: true, commitFirst: true),
            .pushChanges(sessionId: "chat", message: "Update"),
            .mergePullRequest(sessionId: "chat", method: "squash"),
            .markPullRequestReady(sessionId: "chat"),
            .closePullRequest(sessionId: "chat")
        ]
        for request in mobileRequests {
            let encoded = try JSONEncoder().encode(RemoteMessage.request(id: 5, request))
            guard case .request(id: 5, _) = try JSONDecoder().decode(RemoteMessage.self, from: encoded) else {
                Issue.record("mobile request failed to decode")
                return
            }
        }
        let page = RemoteMessage.response(id: 6, .historyPage(beforeSeq: 161, hasMore: true))
        let pageData = try JSONEncoder().encode(page)
        let wire = try #require(JSONSerialization.jsonObject(with: pageData) as? [String: Any])
        let responseBody = try #require(wire["response"] as? [String: Any])
        let responseCase = try #require(responseBody["_1"] as? [String: Any])
        let historyBody = try #require(responseCase["historyPage"] as? [String: Any])
        #expect(historyBody["beforeSeq"] as? Int == 161)
        #expect(historyBody["hasMore"] as? Bool == true)
        guard case .response(id: 6, .historyPage(let before, let hasMore)) = try JSONDecoder().decode(RemoteMessage.self, from: pageData) else {
            Issue.record("history response failed to decode")
            return
        }
        #expect(before == 161 && hasMore)
    }

    @Test func profilesCrossTheWire() throws {
        let profile = AgentProfile(name: "Reviewer", iconSymbol: "magnifyingglass", providerId: "codex",
                                   effort: "high", permissionPolicy: .ask, instructions: "Review it.")
        // A snapshot carries the profiles a paired device may start from.
        let snapshot = RemoteSnapshot(projects: [], sessions: [], providers: ["codex"], alive: [], profiles: [profile])
        guard case .event(.snapshot(let decoded)) = try JSONDecoder().decode(
            RemoteMessage.self, from: JSONEncoder().encode(RemoteMessage.event(.snapshot(snapshot)))) else {
            Issue.record("snapshot failed to decode"); return
        }
        #expect(decoded.profiles == [profile])
        // A snapshot from before profiles still decodes, offering none.
        let plain = try JSONEncoder().encode(RemoteMessage.event(.snapshot(
            RemoteSnapshot(projects: [], sessions: [], providers: [], alive: []))))
        #expect(!String(decoding: plain, as: UTF8.self).contains("profiles"))
        guard case .event(.snapshot(let older)) = try JSONDecoder().decode(RemoteMessage.self, from: plain) else {
            Issue.record("older snapshot failed to decode"); return
        }
        #expect(older.profiles == nil)

        // Saving and deleting one from a paired device.
        for request: RemoteRequest in [.saveProfile(profile), .deleteProfile(id: profile.id)] {
            let encoded = try JSONEncoder().encode(RemoteMessage.request(id: 8, request))
            guard case .request(id: 8, _) = try JSONDecoder().decode(RemoteMessage.self, from: encoded) else {
                Issue.record("profile request failed to decode"); return
            }
        }
        guard case let .request(_, .saveProfile(saved)) = try JSONDecoder().decode(
            RemoteMessage.self, from: JSONEncoder().encode(RemoteMessage.request(id: 8, .saveProfile(profile)))) else {
            Issue.record("saveProfile lost its profile"); return
        }
        #expect(saved == profile)

        // A standalone chat can start from a profile; without one, the
        // request is the one older Macs send and read.
        let started = RemoteMessage.request(id: 9, .startStandaloneConfigured(
            providerId: "codex", prompt: "hi", policy: .ask, attachments: [], files: [:],
            model: nil, effort: "high", profile: profile.snapshot))
        guard case let .request(_, .startStandaloneConfigured(_, _, _, _, _, _, _, kept)) = try JSONDecoder().decode(
            RemoteMessage.self, from: JSONEncoder().encode(started)) else {
            Issue.record("standalone start failed to decode"); return
        }
        #expect(kept == profile.snapshot)
        let bare = try JSONEncoder().encode(RemoteMessage.request(id: 10, .startStandaloneConfigured(
            providerId: "claude", prompt: "hi", policy: .ask, attachments: [], files: [:], model: nil, effort: nil)))
        #expect(!String(decoding: bare, as: UTF8.self).contains("profile"))
        guard case .request(_, .startStandaloneConfigured(_, _, _, _, _, _, _, nil)) = try JSONDecoder().decode(
            RemoteMessage.self, from: bare) else {
            Issue.record("plain standalone start failed to decode"); return
        }
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
