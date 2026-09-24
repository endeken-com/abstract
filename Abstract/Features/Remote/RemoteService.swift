import Foundation
import Network
import CryptoKit
import AbstractCore

/// Abstract on other Macs on the local network: finding them, pairing once,
/// then driving their agents from here (as a controller) or letting paired
/// Macs drive this one's (as a host). Works for every agent, because the host
/// streams its chats' raw output and this Mac parses it with the same
/// provider code (see `RemoteMessage`).
@Observable
final class RemoteService {
    struct PairedDevice: Codable, Identifiable, Hashable {
        var peer: PeerInfo
        var pairedAt: Date
        var lastSeen: Date?
        /// "host:port" for a Mac paired by address, reached directly rather than found on the network.
        var address: String?
        var id: String { peer.id }
    }

    struct Nearby: Identifiable, Hashable {
        let id: String
        let name: String
        let endpoint: NWEndpoint
    }

    /// A pairing waiting on you: another Mac asking to pair (incoming), or
    /// this one waiting for the other Mac to accept.
    struct PairingPrompt: Identifiable, Equatable {
        let id = UUID()
        let peer: PeerInfo
        let code: String
        let incoming: Bool
        var declined = false
    }

    /// Whether paired Macs may use this one. Off until you turn it on.
    var hosting: Bool {
        didSet {
            save()
            hosting ? startListening() : stopListening()
        }
    }
    private(set) var identity: DeviceIdentity
    private(set) var paired: [PairedDevice] { didSet { save() } }

    // Advanced: most people never need these.

    /// What other Macs see this one as; nil is the Mac's own name.
    var customName: String? {
        didSet {
            identity = DeviceIdentity(id: identity.id, name: Self.name(customName), signingKey: identity.signingKey)
            save()
            restartListening()
        }
    }
    /// A fixed port to listen on, for firewall rules or connecting by
    /// address; nil lets the system pick one.
    var fixedPort: UInt16? { didSet { save(); restartListening() } }
    /// Also reach Macs over the direct Wi-Fi link, with no network between them.
    var peerToPeer: Bool { didSet { save(); restartListening(); restartBrowsing() } }
    /// The port this Mac is listening on right now.
    private(set) var listeningPort: UInt16?
    private(set) var nearby: [Nearby] = []
    var prompt: PairingPrompt?
    private(set) var links: [String: RemoteLink] = [:]
    @ObservationIgnored var executors: [String: RemoteExecutor] = [:]
    private(set) var listening = false
    /// Paired Macs connected to this one right now.
    private(set) var hosted: [String: HostedPeer] = [:]
    var lastError: String?

    @ObservationIgnored weak var model: AppModel?
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var decision: CheckedContinuation<Bool, Never>?
    @ObservationIgnored private var pushTask: Task<Void, Never>?
    /// Hosting and paired Macs, beside the identity they belong to.
    @ObservationIgnored private let settingsURL: URL

    private struct Settings: Codable {
        var hosting = false
        var paired: [PairedDevice] = []
        var name: String?
        var port: UInt16?
        var peerToPeer: Bool?
    }

    init(dataDirectory: URL) {
        settingsURL = dataDirectory.appendingPathComponent("remote-devices.json")
        let settings = (try? Data(contentsOf: settingsURL)).flatMap { try? JSONDecoder().decode(Settings.self, from: $0) } ?? Settings()
        let stored = Self.loadIdentity(in: dataDirectory)
        identity = DeviceIdentity(id: stored.id, name: Self.name(settings.name), signingKey: stored.signingKey)
        hosting = settings.hosting
        paired = settings.paired
        customName = settings.name
        fixedPort = settings.port
        peerToPeer = settings.peerToPeer ?? true
    }

    private static func name(_ custom: String?) -> String {
        let custom = custom?.trimmingCharacters(in: .whitespaces) ?? ""
        return custom.isEmpty ? (Host.current().localizedName ?? "Mac") : custom
    }

    private var parameters: NWParameters { RemoteNetwork.parameters(peerToPeer: peerToPeer) }

    /// Starts what's needed: hosting if it's on, and looking for paired Macs.
    func start(model: AppModel) {
        self.model = model
        if hosting { startListening() }
        if !paired.isEmpty { startBrowsing() }
        startReachingByAddress()
    }

    // MARK: Identity

    /// This Mac's key, made once and kept beside Abstract's database, readable only by you.
    private static func loadIdentity(in directory: URL) -> DeviceIdentity {
        struct Stored: Codable { var id: String; var key: Data }
        let url = directory.appendingPathComponent("remote-identity.json")
        let name = Host.current().localizedName ?? "Mac"
        if let data = try? Data(contentsOf: url), let stored = try? JSONDecoder().decode(Stored.self, from: data),
           let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: stored.key) {
            return DeviceIdentity(id: stored.id, name: name, signingKey: key)
        }
        let identity = DeviceIdentity.generate(name: name)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(Stored(id: identity.id, key: identity.signingKey.rawRepresentation)) {
            FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600])
        }
        return identity
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(Settings(hosting: hosting, paired: paired, name: customName, port: fixedPort,
                                                            peerToPeer: peerToPeer)) else { return }
        try? data.write(to: settingsURL, options: .atomic)
    }

    func unpair(_ id: String) {
        links[id]?.disconnect()
        links[id] = nil
        hosted[id]?.channel.close()
        hosted[id] = nil
        paired.removeAll { $0.id == id }
    }

    // MARK: Being found, and hosting

    private func startListening() {
        let port = fixedPort.flatMap(NWEndpoint.Port.init(rawValue:)) ?? .any
        guard listener == nil, let listener = try? NWListener(using: parameters, on: port) else {
            if fixedPort != nil { lastError = "Port \(fixedPort!) is taken or not allowed; choose another, or Automatic." }
            return
        }
        listener.service = NWListener.Service(name: identity.name, type: RemoteNetwork.serviceType,
                                              txtRecord: NWTXTRecord(["id": identity.id]))
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in await self?.accept(connection) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready:
                    self?.listening = true
                    self?.listeningPort = listener.port?.rawValue
                case .failed(let error):
                    self?.listening = false
                    self?.lastError = "This Mac couldn't be offered on the network: \(error.localizedDescription)"
                case .cancelled: self?.listening = false
                default: break
                }
            }
        }
        listener.start(queue: .main)
        self.listener = listener
        startPushing()
    }

    private func stopListening() {
        listener?.cancel()
        listener = nil
        listening = false
        listeningPort = nil
        for peer in hosted.values { peer.channel.close() }
        hosted = [:]
    }

    /// A Mac connecting to this one: a paired Mac straight in, a new one only after you accept its code.
    private func accept(_ connection: NWConnection) async {
        guard hosting else { connection.cancel(); return }
        let channel = RemoteChannel(connection: connection)
        let pins = Dictionary(uniqueKeysWithValues: paired.map { ($0.id, $0.peer) })
        do {
            try await channel.open()
            let outcome = try await channel.accept(as: identity, lookup: { pins[$0] })
            if outcome.pairing {
                // One pairing at a time; a second knock waits for none.
                guard prompt == nil else { channel.close(); return }
                prompt = PairingPrompt(peer: outcome.peer, code: outcome.code, incoming: true)
                let accepted = await withCheckedContinuation { decision = $0 }
                prompt = nil
                try await channel.send(.event(.paired(accepted)))
                guard accepted else { channel.close(); return }
                remember(outcome.peer)
                startBrowsing()
            } else {
                touch(outcome.peer.id)
            }
            let peer = HostedPeer(channel: channel, peer: outcome.peer, service: self)
            hosted[outcome.peer.id]?.channel.close()
            hosted[outcome.peer.id] = peer
            peer.run()
        } catch {
            channel.close()
        }
    }

    /// Your answer to an incoming pairing.
    func answerPairing(_ accept: Bool) {
        decision?.resume(returning: accept)
        decision = nil
    }

    private func remember(_ peer: PeerInfo, address: String? = nil) {
        let known = paired.first { $0.id == peer.id }
        paired.removeAll { $0.id == peer.id }
        paired.append(PairedDevice(peer: peer, pairedAt: Date(), lastSeen: Date(), address: address ?? known?.address))
    }

    private func touch(_ id: String) {
        if let i = paired.firstIndex(where: { $0.id == id }) { paired[i].lastSeen = Date() }
    }

    func hostedPeerEnded(_ peer: HostedPeer) {
        if hosted[peer.peer.id] === peer { hosted[peer.peer.id] = nil }
    }

    /// Keeps connected Macs' view of projects and chats current.
    private func startPushing() {
        pushTask?.cancel()
        pushTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, let snapshot = self.snapshot() else { continue }
                for peer in self.hosted.values { peer.push(snapshot) }
            }
        }
    }

    func snapshot() -> RemoteSnapshot? {
        guard let model else { return nil }
        return RemoteSnapshot(projects: model.projects.filter { $0.archivedAt == nil },
                              sessions: model.sessions.filter { $0.archivedAt == nil && !$0.id.hasPrefix(Self.mirrorPrefix) },
                              providers: ProviderRegistry.all.map(\.id).filter { model.providerStatus[$0]?.available ?? false },
                              alive: Array(model.alive), localModels: model.sharedLocalModels,
                              home: model.executor.homeDirectory, modelCatalogs: model.modelCatalogs)
    }

    /// A chat's new output, to the Macs watching it.
    func forward(sessionId: String, seq: Int, line: OutputLine) {
        guard hosted.values.contains(where: { $0.watches(sessionId) }) else { return }
        // A line longer than the link carries is cut, not a dropped link.
        let lines = RemoteLine.batches([RemoteLine(seq: seq, line: line)], bytes: .max).first ?? []
        for peer in hosted.values where peer.watches(sessionId) {
            peer.post(.event(.lines(sessionId: sessionId, lines)))
        }
    }

    func forwardExit(sessionId: String, code: Int32?) {
        for peer in hosted.values where peer.watches(sessionId) {
            peer.post(.event(.exit(sessionId: sessionId, code: code)))
        }
    }

    // MARK: Finding other Macs

    func startBrowsing() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: RemoteNetwork.serviceType, domain: nil), using: parameters)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let found = results.compactMap { result -> Nearby? in
                guard case let .service(name, _, _, _) = result.endpoint, case let .bonjour(txt) = result.metadata,
                      let id = txt["id"] else { return nil }
                return Nearby(id: id, name: name, endpoint: result.endpoint)
            }
            Task { @MainActor in self?.found(found) }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    private func found(_ devices: [Nearby]) {
        nearby = devices.filter { $0.id != identity.id }
        // Paired Macs that came online get a connection.
        for device in nearby {
            guard let pairing = paired.first(where: { $0.id == device.id }) else { continue }
            let link = links[device.id] ?? RemoteLink(device: pairing, service: self)
            links[device.id] = link
            if !link.isConnected { link.connect(to: device.endpoint, as: identity) }
        }
        for (id, link) in links where !nearby.contains(where: { $0.id == id }) {
            link.markOffline()
        }
    }

    // MARK: Pairing from this side

    func pair(with device: Nearby) { pair(at: device.endpoint, address: nil) }

    /// Pairs with a Mac by "host:port", for when it can't be found on the
    /// network (another subnet, a VPN). It's reached there from then on.
    func pair(address: String) {
        guard let endpoint = RemoteNetwork.endpoint(address) else {
            lastError = "Use an address like 192.168.1.20:52000, or name.local:52000."
            return
        }
        lastError = nil
        pair(at: endpoint, address: address.trimmingCharacters(in: .whitespaces))
    }

    private func pair(at endpoint: NWEndpoint, address: String?) {
        guard prompt == nil else { return }
        Task {
            let channel = RemoteChannel(connection: NWConnection(to: endpoint, using: parameters))
            do {
                try await channel.open()
                let outcome = try await channel.handshake(as: identity, pairing: true, expected: nil)
                prompt = PairingPrompt(peer: outcome.peer, code: outcome.code, incoming: false)
                guard case .event(.paired(let accepted)) = try await channel.receive(), accepted else {
                    prompt?.declined = true
                    channel.close()
                    return
                }
                prompt = nil
                remember(outcome.peer, address: address)
                let link = RemoteLink(device: PairedDevice(peer: outcome.peer, pairedAt: Date(), lastSeen: Date(), address: address), service: self)
                links[outcome.peer.id] = link
                link.adopt(channel)
            } catch {
                if prompt != nil { prompt?.declined = true } else { lastError = error.localizedDescription }
                channel.close()
            }
        }
    }

    // MARK: Macs paired by address

    @ObservationIgnored private var reaching: Task<Void, Never>?

    /// Keeps paired Macs connected: every few seconds, each one that isn't
    /// gets another try, where the network announces it or at the address it
    /// was paired by. A Mac that restarted, slept or dropped off Wi-Fi comes
    /// back on its own.
    private func startReachingByAddress() {
        reaching?.cancel()
        reaching = Task { [weak self] in
            while !Task.isCancelled {
                self?.reconnectAll()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func reconnectAll() {
        for device in paired { reconnect(device.id) }
    }

    /// Tries a paired Mac now, unless it's connected or on its way.
    func reconnect(_ id: String) {
        guard let device = paired.first(where: { $0.id == id }) else { return }
        let endpoint = nearby.first { $0.id == id }?.endpoint ?? device.address.flatMap(RemoteNetwork.endpoint)
        guard let endpoint else { return }
        let link = links[id] ?? RemoteLink(device: device, service: self)
        links[id] = link
        if !link.isConnected { link.connect(to: endpoint, as: identity) }
    }

    /// The link to a chat's Mac when it's up; otherwise says so, starts
    /// reconnecting, and returns nil, so nothing is lost without a word.
    func onlineLink(for id: String) -> RemoteLink? {
        guard let link = link(for: id) else { return nil }
        if link.state == .online { return link }
        reconnect(link.device.id)
        model?.flash("\(link.device.peer.name) isn't connected. Reconnecting…", isError: true)
        return nil
    }

    // MARK: Changing settings

    private func restartListening() {
        guard hosting, listener != nil else { return }
        stopListening()
        startListening()
    }

    private func restartBrowsing() {
        guard browser != nil else { return }
        browser?.cancel()
        browser = nil
        startBrowsing()
    }

    /// This Mac's IPv4 addresses on its networks, for pairing by address.
    var localAddresses: [String] {
        var out: [String] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  entry.ifa_flags & UInt32(IFF_UP) != 0, entry.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                out.append(String(cString: host))
            }
        }
        return out
    }

    func dismissPrompt() {
        if prompt?.incoming == true { answerPairing(false) }
        prompt = nil
    }

    // MARK: Chats on other Macs

    static let mirrorPrefix = "remote:"

    /// The id a chat on another Mac has here.
    static func mirrorId(device: String, session: String) -> String { mirrorPrefix + device + ":" + session }

    static func split(_ mirrorId: String) -> (device: String, session: String)? {
        guard mirrorId.hasPrefix(mirrorPrefix) else { return nil }
        let rest = mirrorId.dropFirst(mirrorPrefix.count)
        guard let colon = rest.firstIndex(of: ":") else { return nil }
        return (String(rest[..<colon]), String(rest[rest.index(after: colon)...]))
    }

    /// A chat on another Mac, under its id here.
    func mirror(_ id: String) -> Session? {
        guard let (device, session) = Self.split(id), var s = links[device]?.snapshot?.sessions.first(where: { $0.id == session }) else { return nil }
        s.id = id
        return s
    }

    func isAlive(_ id: String) -> Bool {
        guard let (device, session) = Self.split(id) else { return false }
        return links[device]?.snapshot?.alive.contains(session) ?? false
    }

    func link(for id: String) -> RemoteLink? { Self.split(id).flatMap { links[$0.device] } }

    func subscribe(_ id: String) {
        guard let (_, session) = Self.split(id) else { return }
        link(for: id)?.subscribe(session)
    }

    /// Files go along with the message, for the other Mac to keep beside its own.
    func send(_ id: String, text: String, attachments: [PromptAttachment] = []) throws {
        guard let (_, session) = Self.split(id) else { return }
        guard let link = link(for: id), link.state == .online else {
            reconnectAll()
            throw AbstractError.message("\(self.link(for: id)?.device.peer.name ?? "That Mac") isn't connected, so your message wasn't sent. Reconnecting…")
        }
        guard !attachments.isEmpty else { link.fire(.send(sessionId: session, text: text)); return }
        var files: [String: Data] = [:]
        for a in attachments where a.kind == .file || a.kind == .image {
            guard let path = a.path else { continue }
            files[a.id] = try Data(contentsOf: URL(fileURLWithPath: path))
        }
        guard files.values.reduce(0, { $0 + $1.count }) <= 10 << 20 else {
            throw AbstractError.message("Attachments can go to another Mac up to 10 MB at a time.")
        }
        link.fire(.sendAttachments(sessionId: session, text: text, attachments: attachments, files: files))
    }

    func stop(_ id: String) {
        guard let (_, session) = Self.split(id) else { return }
        onlineLink(for: id)?.fire(.stop(sessionId: session))
    }

    @discardableResult
    func answer(_ id: String, requestId: String, allow: Bool) -> Bool {
        guard let (_, session) = Self.split(id), let link = onlineLink(for: id) else { return false }
        link.fire(.answer(sessionId: session, requestId: requestId, allow: allow))
        return true
    }

    @discardableResult
    func answerQuestion(_ id: String, requestId: String, answers: [String: String]) -> Bool {
        guard let (_, session) = Self.split(id), let link = onlineLink(for: id) else { return false }
        link.fire(.answerQuestion(sessionId: session, requestId: requestId, answers: answers))
        return true
    }

    /// Starts a chat on another Mac and returns its id here.
    func startChat(on device: String, projectId: String, providerId: String, prompt: String, policy: PermissionPolicy) async throws -> String {
        guard let link = links[device] else { throw AbstractError.message("That Mac isn't connected.") }
        switch try await link.request(.start(projectId: projectId, providerId: providerId, prompt: prompt, policy: policy)) {
        case .started(let session): return Self.mirrorId(device: device, session: session)
        case .failed(let message): throw AbstractError.message(message)
        default: throw AbstractError.message("The other Mac didn't say which chat it started.")
        }
    }

    /// Starts a chat as the New Chat window set it up, on the Mac its project
    /// is on; attached files travel with it. Returns its id here.
    func startChat(on device: String, _ start: RemoteStart) async throws -> String {
        guard let link = links[device] else { throw AbstractError.message("That Mac isn't connected.") }
        var start = start
        for a in start.attachments where a.kind == .file || a.kind == .image {
            guard let path = a.path else { continue }
            start.files[a.id] = try Data(contentsOf: URL(fileURLWithPath: path))
        }
        guard start.files.values.reduce(0, { $0 + $1.count }) <= 10 << 20 else {
            throw AbstractError.message("Attachments can go to another Mac up to 10 MB at a time.")
        }
        switch try await link.request(.startChat(start)) {
        case .started(let session): return Self.mirrorId(device: device, session: session)
        case .failed(let message): throw AbstractError.message(message)
        default: throw AbstractError.message("The other Mac didn't say which chat it started.")
        }
    }
}

// MARK: - A paired Mac using this one

/// A paired Mac connected to this one: its requests run here, and the chats
/// it watches stream to it.
final class HostedPeer {
    let channel: RemoteChannel
    let peer: PeerInfo
    weak var service: RemoteService?
    /// What the other Mac started here: processes, folder watches, shells.
    var processes: [Int: RunningProcess] = [:]
    var watchers: [Int: WorktreeWatcher] = [:]
    var terminals: [Int: HostTerminal] = [:]
    private var subscriptions: Set<String> = []
    private var lastSnapshot: RemoteSnapshot?
    /// Connections to this Mac's local model servers, made for the other Mac.
    private var tunnels: [Int: NWConnection] = [:]
    private let outbox = AsyncStream<RemoteMessage>.makeStream()

    init(channel: RemoteChannel, peer: PeerInfo, service: RemoteService) {
        self.channel = channel; self.peer = peer; self.service = service
    }

    func watches(_ session: String) -> Bool { subscriptions.contains(session) }

    /// Queues a message; one sender keeps them in order.
    func post(_ message: RemoteMessage) { outbox.continuation.yield(message) }

    func push(_ snapshot: RemoteSnapshot) {
        guard snapshot != lastSnapshot else { return }
        lastSnapshot = snapshot
        post(.event(.snapshot(snapshot)))
    }

    func run() {
        Task { [channel, outbox] in
            for await message in outbox.stream {
                do { try await channel.send(message) } catch { channel.close(); break }
            }
        }
        Task {
            defer {
                outbox.continuation.finish()
                for connection in tunnels.values { connection.cancel() }
                tunnels = [:]
                endStreams()
                service?.hostedPeerEnded(self)
            }
            while true {
                guard let message = try? await channel.receive() else { return }
                switch message {
                // Each on its own, so a slow git command doesn't hold up the rest.
                case let .request(id, request): Task { post(.response(id: id, await handle(request, id: id))) }
                case let .tunnel(id, frame): tunnel(id, frame)
                default: break
                }
            }
        }
    }

    /// The other Mac using this one's local model server: each tunnel is a
    /// connection to the server here, carried over the pairing link. Only
    /// the servers this Mac shares, only to their own address.
    private func tunnel(_ id: Int, _ frame: TunnelFrame) {
        switch frame {
        case .open(let kind):
            guard let service, service.hosting, service.model?.sharedLocalModels.contains(kind) == true,
                  let host = LocalModelEndpoints.url(kind).host, let port = NWEndpoint.Port(rawValue: UInt16(LocalModelEndpoints.url(kind).port ?? Int(kind.defaultPort))) else {
                post(.tunnel(id: id, .close))
                return
            }
            let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
            tunnels[id] = connection
            connection.start(queue: .main)
            pump(connection, id: id)
        case .data(let data):
            tunnels[id]?.send(content: data, completion: .idempotent)
        case .close:
            tunnels.removeValue(forKey: id)?.cancel()
        }
    }

    private func pump(_ connection: NWConnection, id: Int) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self else { return }
                if let data, !data.isEmpty { self.post(.tunnel(id: id, .data(data))) }
                if complete || error != nil {
                    self.post(.tunnel(id: id, .close))
                    self.tunnels.removeValue(forKey: id)?.cancel()
                } else {
                    self.pump(connection, id: id)
                }
            }
        }
    }

    private func handle(_ request: RemoteRequest, id: Int) async -> RemoteResponse {
        guard let service, let model = service.model, service.hosting else { return .failed("This Mac stopped sharing its agents.") }
        switch request {
        case .snapshot:
            if let snapshot = service.snapshot() { lastSnapshot = snapshot; post(.event(.snapshot(snapshot))) }
            return .ok
        case let .subscribe(session, after):
            // Watch first, then catch up: anything in between arrives twice and the controller drops repeats.
            subscriptions.insert(session)
            let lines = model.engine.replay(sessionId: session, after: after).map { RemoteLine(seq: $0.seq, line: $0.line) }
            // In batches of about 2 MB: a batch of huge tool outputs must never
            // pass the link's frame limit (which would drop the link, and the chat
            // would never show there).
            for batch in RemoteLine.batches(lines, bytes: 2 << 20) { post(.event(.lines(sessionId: session, batch))) }
            return .ok
        case .unsubscribe(let session):
            subscriptions.remove(session)
            return .ok
        case let .send(session, text):
            do { try model.sendFollowUp(session, text: text); return .ok } catch { return .failed(error.localizedDescription) }
        case let .sendAttachments(session, text, attachments, files):
            do {
                // Their files, kept here, where this Mac's agent can read them.
                let kept = try attachments.map { a in try files[a.id].map { try AttachmentStore.keep($0, for: a) } ?? a }
                try model.sendFollowUp(session, text: text, attachments: kept)
                return .ok
            } catch {
                return .failed(error.localizedDescription)
            }
        case let .start(project, provider, prompt, policy):
            do {
                let id = try await model.startChat(projectId: project, providerId: provider, prompt: prompt, baseRef: nil,
                                                   policy: policy, select: false)
                // Not watched yet: the controller subscribes from the start, so it gets the prompt too.
                return .started(sessionId: id)
            } catch {
                return .failed(error.localizedDescription)
            }
        case .startChat(let start):
            do {
                let kept = try start.attachments.map { a in try start.files[a.id].map { try AttachmentStore.keep($0, for: a) } ?? a }
                let existing = start.worktree == nil ? nil : await model.reusableWorktrees(projectId: start.projectId)
                    .first { AppModel.canonical($0.path) == AppModel.canonical(start.worktree!) }
                if start.worktree != nil, existing == nil { return .failed("That worktree isn't on this Mac any more.") }
                let id = try await model.startChat(projectId: start.projectId, providerId: start.providerId, prompt: start.prompt,
                                                   attachments: kept, baseRef: start.baseRef, policy: start.policy, model: start.model,
                                                   effort: start.effort, existing: existing, select: false)
                return .started(sessionId: id)
            } catch {
                return .failed(error.localizedDescription)
            }
        case .stop(let session):
            model.stop(session)
            return .ok
        case let .answer(session, requestId, allow):
            model.answerPermission(session, requestId: requestId, allow: allow)
            return .ok
        case let .answerQuestion(session, requestId, answers):
            model.answerQuestion(session, requestId: requestId, answers: answers)
            return .ok
        case let .setAgent(session, provider, name, effort):
            model.setAgent(session, providerId: provider, model: name, effort: effort)
            return .ok
        case let .setPolicy(session, policy):
            model.setPolicy(session, policy)
            return .ok
        case .resume(let session):
            model.resume(session)
            return .ok
        case let .rename(session, name):
            model.rename(session, to: name)
            return .ok
        case let .setArchived(session, archived):
            model.setArchived(session, archived)
            return .ok
        case let .exec(command, args, cwd):
            return await exec(command, args, cwd: cwd)
        case .spawn(let spec):
            return spawn(id, spec)
        case .stopProcess(let process):
            processes.removeValue(forKey: process)?.terminate()
            return .ok
        case .readFile(let path):
            return await readFile(path)
        case let .writeFile(path, data):
            return writeFile(path, data)
        case .fileInfo(let path):
            return fileInfo(path)
        case .listFiles(let root):
            return await listFiles(root)
        case let .watch(watch, paths):
            return self.watch(watch, paths)
        case .unwatch(let watch):
            watchers[watch] = nil
            return .ok
        case let .openTerminal(terminal, cwd, cols, rows):
            return openTerminal(terminal, cwd: cwd, cols: cols, rows: rows)
        case let .terminalInput(terminal, data):
            terminals[terminal]?.send(data)
            return .ok
        case let .resizeTerminal(terminal, cols, rows):
            terminals[terminal]?.resize(cols: cols, rows: rows)
            return .ok
        case .closeTerminal(let terminal):
            terminals.removeValue(forKey: terminal)?.close()
            return .ok
        }
    }
}

// MARK: - Another Mac, from here

/// A paired Mac this one drives: its projects and chats, and the chats'
/// output parsed here as it streams.
@Observable
final class RemoteLink {
    enum State: Equatable { case offline, connecting, online, failed(String) }

    let device: RemoteService.PairedDevice
    private(set) var state: State = .offline
    private(set) var snapshot: RemoteSnapshot?

    @ObservationIgnored private weak var service: RemoteService?
    @ObservationIgnored private var channel: RemoteChannel?
    @ObservationIgnored private var outbox = AsyncStream<RemoteMessage>.makeStream()
    @ObservationIgnored private var nextId = 1
    @ObservationIgnored private var waiting: [Int: CheckedContinuation<RemoteResponse, any Error>] = [:]
    @ObservationIgnored private var subscribed: Set<String> = []
    @ObservationIgnored private var lastSeq: [String: Int] = [:]
    @ObservationIgnored private var streams: [String: ChatStream] = [:]
    /// Connections to that Mac's local model servers, by tunnel id.
    @ObservationIgnored private var tunnels: [Int: (data: (Data) -> Void, close: (Int) -> Void)] = [:]
    /// Processes, folder watches and shells running there for chats here.
    @ObservationIgnored var processes: [Int: (line: @Sendable (OutputLine) -> Void, exit: @Sendable (Int32?) -> Void)] = [:]
    @ObservationIgnored var watchers: [Int: () -> Void] = [:]
    @ObservationIgnored var terminals: [Int: (output: (Data) -> Void, exit: (Int32?) -> Void)] = [:]

    init(device: RemoteService.PairedDevice, service: RemoteService) {
        self.device = device; self.service = service
    }

    var isConnected: Bool { state == .online || state == .connecting }

    func connect(to endpoint: NWEndpoint, as identity: DeviceIdentity) {
        state = .connecting
        let channel = RemoteChannel(connection: NWConnection(to: endpoint, using: RemoteNetwork.parameters(peerToPeer: service?.peerToPeer ?? true)))
        // A try that hangs (a Mac asleep, a stale address) gives way to the next.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            if self?.channel !== channel, self?.state == .connecting { channel.close() }
        }
        Task {
            do {
                try await channel.open()
                _ = try await channel.handshake(as: identity, pairing: false, expected: device.peer)
                adopt(channel)
            } catch {
                channel.close()
                state = .failed(error.localizedDescription)
            }
        }
    }

    /// Runs a connection that has finished its handshake.
    func adopt(_ channel: RemoteChannel) {
        self.channel = channel
        outbox = AsyncStream<RemoteMessage>.makeStream()
        state = .online
        let stream = outbox.stream
        Task {
            for await message in stream {
                // A write that fails means the link is gone: close it, so it's noticed and remade.
                do { try await channel.send(message) } catch { channel.close(); break }
            }
        }
        Task {
            while true {
                guard let message = try? await channel.receive() else { break }
                handle(message)
            }
            if self.channel === channel { ended() }
        }
        heartbeat(channel)
        fire(.snapshot)
        // Chats already open here pick up where they left off.
        for session in subscribed { outbox.continuation.yield(.request(id: take(), .subscribe(sessionId: session, afterSeq: lastSeq[session] ?? 0))) }
    }

    /// A link that went quiet without closing (a Mac that slept, Wi-Fi that
    /// dropped) is found out within seconds rather than minutes.
    private func heartbeat(_ channel: RemoteChannel) {
        Task { [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(15))
                guard let self, self.channel === channel, self.state == .online else { return }
                // No answer in ten seconds: close it, which remakes it.
                var answered = false
                let watchdog = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(10))
                    if !answered, self.channel === channel { channel.close() }
                }
                _ = try? await self.request(.snapshot)
                answered = true
                watchdog.cancel()
            }
        }
    }

    func disconnect() {
        channel?.close()
        ended()
    }

    func markOffline() {
        guard state != .online else { return }
        state = .offline
    }

    private func ended() {
        channel = nil
        outbox.continuation.finish()
        if state == .online || state == .connecting { state = .offline }
        for (_, waiter) in waiting { waiter.resume(throwing: RemoteChannel.Failure.closed) }
        waiting = [:]
        for (id, tunnel) in tunnels { tunnel.close(id) }
        tunnels = [:]
        dropStreams()
    }

    private func take() -> Int {
        defer { nextId += 1 }
        return nextId
    }

    func nextRequestId() -> Int { take() }

    func send(_ message: RemoteMessage) { outbox.continuation.yield(message) }

    /// A request whose answer doesn't matter here.
    func fire(_ request: RemoteRequest) {
        outbox.continuation.yield(.request(id: take(), request))
    }

    func request(_ request: RemoteRequest) async throws -> RemoteResponse {
        guard state == .online else { throw AbstractError.message("\(device.peer.name) isn't connected.") }
        let id = take()
        return try await withCheckedThrowingContinuation { continuation in
            waiting[id] = continuation
            outbox.continuation.yield(.request(id: id, request))
        }
    }

    // MARK: Tunnels to that Mac's local models

    func openTunnel(_ kind: LocalModelKind, onData: @escaping (Data) -> Void, onClose: @escaping (Int) -> Void) -> Int {
        let id = take()
        tunnels[id] = (onData, onClose)
        outbox.continuation.yield(.tunnel(id: id, .open(kind)))
        return id
    }

    func tunnelSend(_ id: Int, _ data: Data) {
        outbox.continuation.yield(.tunnel(id: id, .data(data)))
    }

    func tunnelClose(_ id: Int) {
        guard tunnels.removeValue(forKey: id) != nil else { return }
        outbox.continuation.yield(.tunnel(id: id, .close))
    }

    func subscribe(_ session: String) {
        guard subscribed.insert(session).inserted else { return }
        fire(.subscribe(sessionId: session, afterSeq: lastSeq[session] ?? 0))
    }

    private func handle(_ message: RemoteMessage) {
        switch message {
        case let .response(id, response):
            if let waiter = waiting.removeValue(forKey: id) { waiter.resume(returning: response) } else { spawnAnswered(id, response) }
        case .event(.snapshot(let snapshot)):
            self.snapshot = snapshot
            service?.model?.remoteSnapshotChanged(device: device.id, snapshot)
            for (session, lines) in early where snapshot.sessions.contains(where: { $0.id == session }) {
                early[session] = nil
                deliver(session, lines)
            }
        case let .event(.lines(session, lines)):
            deliver(session, lines)
        case let .event(.exit(session, code)):
            guard let stream = streams[session] else { return }
            service?.model?.applyRemote(stream.onExit(code: code), to: RemoteService.mirrorId(device: device.id, session: session))
        case let .tunnel(id, .data(data)):
            tunnels[id]?.data(data)
        case let .tunnel(id, .close):
            tunnels.removeValue(forKey: id)?.close(id)
        case .event(let event):
            received(event)
        case .request, .tunnel(_, .open):
            break
        }
    }

    /// Output that arrived before the host said which agent the chat runs.
    @ObservationIgnored private var early: [String: [RemoteLine]] = [:]

    private func deliver(_ session: String, _ lines: [RemoteLine]) {
        guard let providerId = snapshot?.sessions.first(where: { $0.id == session })?.providerId,
              ProviderRegistry.provider(providerId) != nil else {
            early[session, default: []] += lines
            return
        }
        // A chat handed over reads each agent's part with its own parser.
        let stream = streams[session] ?? ChatStream(providerId: ChatStream.firstProvider(in: lines.map(\.line), current: providerId))
        streams[session] = stream
        var events: [AgentEvent] = []
        for line in lines where line.seq > (lastSeq[session] ?? 0) {
            lastSeq[session] = line.seq
            events += stream.feed(line.line)
        }
        service?.model?.applyRemote(events, to: RemoteService.mirrorId(device: device.id, session: session))
    }
}
