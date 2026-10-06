import Foundation
import Network
import CryptoKit
import AbstractCore
import AbstractInternet

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
        var internetAddress: InternetAddress?
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
            updateInternetHosting()
        }
    }
    var internetHosting: Bool { didSet { save(); updateInternetHosting() } }
    private(set) var internetAddress: InternetAddress?
    private(set) var invitation: InternetInvitation?
    @ObservationIgnored private var internet: InternetEndpoint?
    @ObservationIgnored private var internetStarting: Task<InternetEndpoint, any Error>?
    @ObservationIgnored private var internetAccepting: Task<Void, Never>?
    @ObservationIgnored private var internetChannels: [UUID: RemoteChannel] = [:]
    @ObservationIgnored private var outgoingPair: RemoteChannel?
    @ObservationIgnored private var pairingTask: Task<Void, Never>?

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
    @ObservationIgnored private var incomingPairingChannel: RemoteChannel?
    @ObservationIgnored private var pushTask: Task<Void, Never>?
    /// Hosting and paired Macs, beside the identity they belong to.
    @ObservationIgnored private let settingsURL: URL

    private struct Settings: Codable {
        var hosting = false
        var paired: [PairedDevice] = []
        var name: String?
        var port: UInt16?
        var peerToPeer: Bool?
        var internetHosting: Bool?
    }

    init(dataDirectory: URL) {
        settingsURL = dataDirectory.appendingPathComponent("remote-devices.json")
        let settings = (try? Data(contentsOf: settingsURL)).flatMap { try? JSONDecoder().decode(Settings.self, from: $0) } ?? Settings()
        let stored = Self.loadIdentity(in: dataDirectory)
        identity = DeviceIdentity(id: stored.id, name: Self.name(settings.name), signingKey: stored.signingKey)
        hosting = settings.hosting
        internetHosting = settings.internetHosting ?? false
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
        updateInternetHosting()
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
                                                            peerToPeer: peerToPeer, internetHosting: internetHosting)) else { return }
        try? data.write(to: settingsURL, options: .atomic)
    }

    func unpair(_ id: String) {
        if prompt?.peer.id == id { dismissPrompt() }
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
        pushTask?.cancel(); pushTask = nil
        listener?.cancel()
        listener = nil
        listening = false
        listeningPort = nil
        answerPairing(false)
        for peer in hosted.values { peer.channel.close() }
        hosted = [:]
    }

    /// A Mac connecting to this one: a paired Mac straight in, a new one only after you accept its code.
    private func accept(_ connection: NWConnection) async {
        guard hosting else { connection.cancel(); return }
        await accept(RemoteChannel(connection: connection))
    }

    private func accept(_ channel: RemoteChannel, internetPeer: PeerInfo? = nil) async {
        let pins = Dictionary(uniqueKeysWithValues: paired.map { ($0.id, $0.peer) })
        let watchdog = Task {
            do { try await Task.sleep(for: .seconds(10)); channel.close() } catch {}
        }
        defer { watchdog.cancel() }
        do {
            try await channel.open()
            let outcome = try await channel.accept(as: identity, lookup: { pins[$0] })
            watchdog.cancel()
            guard hosting, internetPeer == nil || (internetHosting && internetPeer == outcome.peer) else { channel.close(); return }
            if outcome.pairing {
                // One pairing at a time; a second knock waits for none.
                guard prompt == nil else { channel.close(); return }
                incomingPairingChannel = channel
                defer { if incomingPairingChannel === channel { incomingPairingChannel = nil } }
                prompt = PairingPrompt(peer: outcome.peer, code: outcome.code, incoming: true)
                let promptID = prompt?.id
                let expiry = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(60)) } catch { return }
                    if self?.prompt?.id == promptID { self?.answerPairing(false) }
                }
                let approved = await withCheckedContinuation { decision = $0 }
                let accepted = approved && hosting && (internetPeer == nil || internetHosting)
                expiry.cancel()
                prompt = nil
                try await channel.send(.event(.paired(accepted)))
                guard accepted else { channel.close(); return }
                remember(outcome.peer)
                startBrowsing()
            } else {
                // Revocation or disabling sharing may have happened during the handshake.
                guard paired.contains(where: { $0.peer.id == outcome.peer.id && $0.peer.publicKey == outcome.peer.publicKey }) else { channel.close(); return }
                touch(outcome.peer)
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
        paired.append(PairedDevice(peer: peer, pairedAt: Date(), lastSeen: Date(), address: address ?? known?.address, internetAddress: known?.internetAddress))
    }

    private func touch(_ peer: PeerInfo) {
        if let i = paired.firstIndex(where: { $0.id == peer.id }) {
            paired[i].lastSeen = Date()
            // A paired phone can change its name without changing its identity.
            paired[i].peer.name = peer.name
        }
    }

    func rememberInternet(_ address: InternetAddress?, for id: String) {
        guard address == nil || address?.isValid == true,
              let index = paired.firstIndex(where: { $0.id == id }), paired[index].internetAddress != address else { return }
        paired[index].internetAddress = address
    }

    private func internetEndpoint() async throws -> InternetEndpoint {
        if let internet { return internet }
        if let internetStarting { return try await internetStarting.value }
        let key = InternetEndpoint.networkKey(signingKey: identity.signingKey.rawRepresentation)
        let starting = Task { try await InternetEndpoint.bind(key: key) }
        internetStarting = starting
        defer { internetStarting = nil }
        let endpoint = try await starting.value
        internet = endpoint
        return endpoint
    }

    func internetChannel(to address: InternetAddress, invitation: String? = nil) async throws -> RemoteChannel {
        guard address.isValid else { throw SecureChannelError.malformed }
        let endpoint = try await internetEndpoint()
        let stream = try await withThrowingTaskGroup(of: InternetStream.self) { group in
            group.addTask { try await endpoint.connect(to: address.endpointId) }
            group.addTask {
                try await Task.sleep(for: .seconds(15))
                throw InternetError.relayUnavailable
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
        guard !Task.isCancelled else { stream.close(); throw CancellationError() }
        let channel = RemoteChannel(transport: IrohRemoteTransport(stream: stream))
        do {
            let hello = try InternetHello(identity: identity, host: address.endpointId, client: endpoint.id, invitation: invitation)
            try await channel.sendPlain(JSONEncoder().encode(hello))
            return channel
        } catch { channel.close(); throw error }
    }

    private func updateInternetHosting() {
        guard hosting && internetHosting else {
            internetAddress = nil; invitation = nil
            if let incomingPairingChannel, internetChannels.values.contains(where: { $0 === incomingPairingChannel }) {
                answerPairing(false)
            }
            for channel in internetChannels.values { channel.close() }
            internetChannels.removeAll()
            // The endpoint may still be used to control another Mac. The accept loop
            // keeps rejecting incoming connections until hosting is enabled again.
            return
        }
        guard internetAccepting == nil else {
            if let internet { internetAddress = InternetAddress(endpointId: internet.id) }
            return
        }
        internetAccepting = Task { [weak self] in
            guard let self else { return }
            defer { self.internetAccepting = nil }
            do {
                let endpoint = try await internetEndpoint()
                if hosting && internetHosting { internetAddress = InternetAddress(endpointId: endpoint.id) }
                while !Task.isCancelled {
                    // Failed or abandoned incoming handshakes must not stop the listener.
                    let stream: InternetStream
                    do {
                        guard let next = try await endpoint.accept() else { return }
                        stream = next
                    } catch { continue }
                    guard hosting && internetHosting, internetChannels.count < 16 else { stream.close(); continue }
                    let channel = RemoteChannel(transport: IrohRemoteTransport(stream: stream))
                    let id = UUID(); internetChannels[id] = channel
                    Task {
                        let timeout = Task {
                            do { try await Task.sleep(for: .seconds(10)); channel.close() } catch {}
                        }
                        defer {
                            timeout.cancel()
                            if !hosted.values.contains(where: { $0.channel === channel }) { internetChannels[id] = nil }
                        }
                        do {
                            let data = try await channel.receivePlain(maximumLength: 4096)
                            let hello = try JSONDecoder().decode(InternetHello.self, from: data)
                            guard hello.verify(host: endpoint.id, client: stream.remoteID) else { throw SecureChannelError.badSignature }
                            let known = paired.contains { $0.peer.id == hello.peer.id && $0.peer.publicKey == hello.peer.publicKey }
                            let invited = invitation.map { $0.expires > Int(Date().timeIntervalSince1970) && $0.token == hello.invitation } ?? false
                            guard known || invited else { throw SecureChannelError.unknownPeer }
                            if !known { invitation = nil } // One invitation permits one pairing attempt.
                            timeout.cancel()
                            await accept(channel, internetPeer: hello.peer)
                        } catch { channel.close() }
                    }
                }
            } catch { lastError = error.localizedDescription; internetAddress = nil }
        }
    }

    func makeInvitation() {
        guard let internetAddress else { return }
        invitation = InternetInvitation(peer: identity.peer, address: internetAddress)
    }

    func hostedPeerEnded(_ peer: HostedPeer) {
        if hosted[peer.peer.id] === peer { hosted[peer.peer.id] = nil }
        internetChannels = internetChannels.filter { $0.value !== peer.channel }
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
                              sessions: model.sessions.filter { !$0.id.hasPrefix(Self.mirrorPrefix) },
                              providers: ProviderRegistry.all.map(\.id).filter { model.providerStatus[$0]?.available ?? false },
                              alive: Array(model.alive),
                              home: model.executor.homeDirectory, modelCatalogs: model.modelCatalogs,
                              defaultModelNames: Dictionary(uniqueKeysWithValues: ProviderRegistry.all.compactMap { provider in
                                  model.defaultModelName(for: provider.id).map { (provider.id, $0) }
                              }),
                              pullRequests: model.pullRequests.mapValues { pr in
                                  RemotePullRequest(number: pr.number, title: pr.title, state: pr.state.rawValue,
                                                    isDraft: pr.isDraft, url: pr.url, standing: pr.standing,
                                                    reviewDecision: pr.reviewDecision?.rawValue, hasConflicts: pr.hasConflicts,
                                                    checks: pr.checks.map { check in
                                      let outcome: String = switch check.outcome {
                                      case .passed: "passed"
                                      case .failed: "failed"
                                      case .pending: "pending"
                                      case .skipped: "skipped"
                                      }
                                      return RemotePullRequestCheck(name: check.name, workflow: check.workflow,
                                                                    outcome: outcome, url: check.url)
                                  }, head: pr.head, base: pr.base, author: pr.author,
                                                    additions: pr.additions, deletions: pr.deletions, body: pr.body,
                                                    reviews: pr.reviews.map { review in
                                      RemotePullRequestReview(author: review.author, verdict: review.verdict.rawValue,
                                                              body: review.body, submittedAt: review.submittedAt)
                                  }, comments: pr.comments.map { comment in
                                      RemotePullRequestComment(author: comment.author, body: comment.body,
                                                               createdAt: comment.createdAt, isBot: comment.isBot)
                                  }, threads: pr.threads.map { thread in
                                      RemotePullRequestThread(id: thread.id, path: thread.path, line: thread.line,
                                                              isResolved: thread.isResolved, isOutdated: thread.isOutdated,
                                                              comments: thread.comments.map { comment in
                                          RemotePullRequestComment(author: comment.author, body: comment.body,
                                                                   createdAt: comment.createdAt, isBot: false)
                                      })
                                  })
                              }, automations: model.automations,
                              pendingPermissions: Dictionary(uniqueKeysWithValues: model.sessions.map { session in
                                  (session.id, model.pendingPermissions(session.id).map {
                                      RemotePendingPermission(requestId: $0.requestId, toolName: $0.toolName, input: $0.input)
                                  })
                              }), turnStartedAt: model.turnStartedAt, pagedHistory: true, internetAddress: internetAddress)
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
            if !link.isConnected { reconnect(device.id) }
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
        if address.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("abstract://") { pair(invitation: address); return }
        guard let endpoint = RemoteNetwork.endpoint(address) else {
            lastError = "Use an address like 192.168.1.20:52000, or name.local:52000."
            return
        }
        lastError = nil
        pair(at: endpoint, address: address.trimmingCharacters(in: .whitespaces))
    }

    private func pair(at endpoint: NWEndpoint, address: String?) {
        beginPair(address: address, invitation: nil) {
            RemoteChannel(connection: NWConnection(to: endpoint, using: self.parameters))
        }
    }

    func pair(invitation text: String) {
        do {
            let invite = try InternetInvitation.parse(text)
            beginPair(address: nil, invitation: invite) {
                try await self.internetChannel(to: invite.address, invitation: invite.token)
            }
        } catch { lastError = "This invitation is invalid or expired. Copy a new one from the host Mac." }
    }

    private func beginPair(address: String?, invitation: InternetInvitation?, makeChannel: @escaping () async throws -> RemoteChannel) {
        guard prompt == nil, pairingTask == nil else { return }
        pairingTask = Task {
            defer { pairingTask = nil; outgoingPair = nil }
            do {
                let channel = try await makeChannel()
                guard !Task.isCancelled else { channel.close(); return }
                outgoingPair = channel
                let timeout = Task {
                    do { try await Task.sleep(for: .seconds(70)); channel.close() } catch {}
                }
                defer { timeout.cancel() }
                try await channel.open()
                let outcome = try await channel.handshake(as: identity, pairing: true, expected: nil)
                if let invitation, outcome.peer.id != invitation.peer.id || outcome.peer.publicKey != invitation.peer.publicKey {
                    throw SecureChannelError.keyChanged
                }
                prompt = PairingPrompt(peer: outcome.peer, code: outcome.code, incoming: false)
                guard case .event(.paired(let accepted)) = try await channel.receive(), accepted else {
                    prompt?.declined = true
                    channel.close()
                    return
                }
                guard !Task.isCancelled else { channel.close(); return }
                prompt = nil
                remember(outcome.peer, address: address)
                if let invitation { rememberInternet(invitation.address, for: outcome.peer.id) }
                let link = RemoteLink(device: paired.first { $0.id == outcome.peer.id }!, service: self)
                links[outcome.peer.id] = link
                link.adopt(channel)
            } catch {
                if !Task.isCancelled {
                    if prompt != nil { prompt?.declined = true } else { lastError = error.localizedDescription }
                }
                outgoingPair?.close()
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
        if hosting && internetHosting && internetAccepting == nil { updateInternetHosting() }
        for device in paired { reconnect(device.id) }
    }

    /// Tries a paired Mac now, unless it's connected or on its way.
    func reconnect(_ id: String) {
        guard let device = paired.first(where: { $0.id == id }) else { return }
        let endpoint = nearby.first { $0.id == id }?.endpoint ?? device.address.flatMap(RemoteNetwork.endpoint)
        guard endpoint != nil || device.internetAddress != nil else { return }
        let link = links[id] ?? RemoteLink(device: device, service: self)
        links[id] = link
        if !link.isConnected { link.connect(to: endpoint, internet: device.internetAddress, as: identity) }
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
        pairingTask?.cancel(); outgoingPair?.close(); outgoingPair = nil
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
                endStreams()
                service?.hostedPeerEnded(self)
            }
            while true {
                guard let message = try? await channel.receive() else { return }
                switch message {
                // Each on its own, so a slow git command doesn't hold up the rest.
                case let .request(id, request): Task { post(.response(id: id, await handle(request, id: id))) }
                // An older version asking for a local model server: none here.
                case let .tunnel(id, .open): post(.tunnel(id: id, .close))
                default: break
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
        case let .subscribeRecent(session, limit):
            subscriptions.insert(session)
            let page = model.engine.replayPage(sessionId: session, limit: limit)
            let lines = page.lines.map { RemoteLine(seq: $0.seq, line: $0.line) }
            for batch in RemoteLine.batches(lines, bytes: 2 << 20) { post(.event(.lines(sessionId: session, batch))) }
            return .historyPage(beforeSeq: page.beforeSeq, hasMore: page.hasMore)
        case let .history(session, before, limit):
            let page = model.engine.replayPage(sessionId: session, beforeSeq: before, limit: limit)
            let lines = page.lines.map { RemoteLine(seq: $0.seq, line: $0.line) }
            for batch in RemoteLine.batches(lines, bytes: 2 << 20) { post(.event(.lines(sessionId: session, batch))) }
            return .historyPage(beforeSeq: page.beforeSeq, hasMore: page.hasMore)
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
                let id = try await model.startChat(projectId: project, providerId: RetiredAgents.current(provider), prompt: prompt, baseRef: nil,
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
                // An older version may still ask for a retired agent: OpenCode
                // runs it instead, on its own default model.
                let agent = RetiredAgents.current(start.providerId)
                let retired = agent != start.providerId
                let id = try await model.startChat(projectId: start.projectId, providerId: agent, prompt: start.prompt,
                                                   attachments: kept, baseRef: start.baseRef, policy: start.policy,
                                                   model: retired ? nil : start.model, effort: retired ? nil : start.effort,
                                                   existing: existing, select: false)
                return .started(sessionId: id)
            } catch {
                return .failed(error.localizedDescription)
            }
        case let .startStandalone(provider, prompt, policy):
            do {
                let id = try await model.startChat(projectId: nil, providerId: RetiredAgents.current(provider),
                                                   prompt: prompt, baseRef: nil, policy: policy, select: false)
                return .started(sessionId: id)
            } catch { return .failed(error.localizedDescription) }
        case let .startStandaloneConfigured(provider, prompt, policy, attachments, files, name, effort):
            do {
                let kept = try attachments.map { a in try files[a.id].map { try AttachmentStore.keep($0, for: a) } ?? a }
                let agent = RetiredAgents.current(provider)
                let id = try await model.startChat(projectId: nil, providerId: agent,
                                                   prompt: prompt, attachments: kept, baseRef: nil,
                                                   policy: policy, model: agent == provider ? name : nil,
                                                   effort: agent == provider ? effort : nil, select: false)
                return .started(sessionId: id)
            } catch { return .failed(error.localizedDescription) }
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
            let agent = RetiredAgents.current(provider)
            model.setAgent(session, providerId: agent, model: agent == provider ? name : nil, effort: agent == provider ? effort : nil)
            return .ok
        case let .setPolicy(session, policy):
            model.setPolicy(session, policy)
            return .ok
        case let .stopTask(session, taskId):
            model.stopTask(session, taskId: taskId)
            return .ok
        case let .moveToBackground(session, toolUseId):
            model.moveToBackground(session, toolUseId: toolUseId)
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
        case let .deleteChat(session, removeWorktree):
            guard model.session(session) != nil else { return .failed("Chat not found.") }
            await model.delete(session, removeWorktree: removeWorktree)
            return .ok
        case let .removeWorktree(projectId, path, deleteBranch):
            guard let project = model.project(projectId),
                  let worktree = await model.reusableWorktrees(projectId: projectId).first(where: {
                      AppModel.canonical($0.path) == AppModel.canonical(path)
                  }) else { return .failed("That worktree is unavailable.") }
            for session in model.sessions where session.worktreePath.map({ AppModel.canonical($0) }) == AppModel.canonical(path) {
                model.stop(session.id)
            }
            await model.runTeardownScript(project, worktree: worktree.path)
            do {
                try await Git.removeWorktree(model.executor, root: project.rootPath, path: worktree.path,
                                             deleteBranch: deleteBranch ? worktree.branch : nil)
                return .ok
            } catch { return .failed(error.localizedDescription) }
        case .saveAutomation(let automation):
            do { return .automation(try model.saveAutomation(automation)) }
            catch { return .failed(error.localizedDescription) }
        case .deleteAutomation(let id):
            guard model.automations.contains(where: { $0.id == id }) else { return .failed("Automation not found.") }
            model.deleteAutomation(id)
            return .ok
        case .runAutomation(let id):
            guard let automation = model.automations.first(where: { $0.id == id }) else { return .failed("Automation not found.") }
            guard let run = await model.runAutomationNow(automation) else { return .failed("Automations are not running yet.") }
            return .automationRuns([run])
        case .automationRuns(let id):
            return .automationRuns(model.automationRuns(id))
        case let .review(session, committed):
            do {
                let files = try await reviewFiles(session: session, committed: committed, model: model)
                return .review(files.map { file in
                    let patch = Diff.buildPatch(file, hunks: [])
                    return RemoteReviewFile(path: file.path, status: file.status.rawValue, additions: file.additions,
                                            deletions: file.deletions, binary: file.isBinary,
                                            patch: String(patch.prefix(128_000)))
                })
            } catch { return .failed(error.localizedDescription) }
        case let .reviewFile(session, path, committed, accept):
            do {
                guard !committed || accept else { return .failed("Committed changes cannot be discarded from review.") }
                guard case .ready(let context) = model.diffAvailability(session) else { return .failed("The chat's worktree is unavailable.") }
                guard let file = try await reviewFiles(session: session, committed: committed, model: model).first(where: { $0.path == path })
                else { return .failed("That changed file is no longer in the review. Refresh and try again.") }
                let repoRoot = file.repo.isEmpty ? context.root : context.root + "/" + file.repo
                let repoWorktree = file.repo.isEmpty ? context.worktree : context.worktree + "/" + file.repo
                if accept {
                    guard !file.isBinary else { return .failed("Accept this binary file in the Mac app.") }
                    _ = try await Diff.accept(context.executor, root: repoRoot, patch: Diff.buildPatch(file, hunks: []))
                } else {
                    try await Diff.discard(context.executor, worktree: repoWorktree,
                                           paths: [file.repoPath] + (file.repoOldPath.map { [$0] } ?? []))
                }
                return .ok
            } catch { return .failed(error.localizedDescription) }
        case let .createPullRequest(session, title, body, base, draft, commitFirst):
            do {
                try await model.createPullRequest(session, title: title, body: body, base: base,
                                                  draft: draft, commitFirst: commitFirst)
                return .ok
            } catch { return .failed(error.localizedDescription) }
        case let .pushChanges(session, message):
            do { try await model.pushChanges(session, message: message); return .ok }
            catch { return .failed(error.localizedDescription) }
        case let .mergePullRequest(session, method):
            guard let method = MergeMethod(rawValue: method) else { return .failed("Unknown merge method.") }
            do { try await model.mergePullRequest(session, method: method); return .ok }
            catch { return .failed(error.localizedDescription) }
        case .markPullRequestReady(let session):
            do { try await model.markPullRequestReady(session); return .ok }
            catch { return .failed(error.localizedDescription) }
        case .closePullRequest(let session):
            do { try await model.closePullRequest(session); return .ok }
            catch { return .failed(error.localizedDescription) }
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

    private func reviewFiles(session: String, committed: Bool, model: AppModel) async throws -> [FileDiff] {
        guard case .ready(let context) = model.diffAvailability(session) else {
            throw AbstractError.message("The chat's worktree is unavailable.")
        }
        let repos = await Submodules.list(context.reader, worktree: context.worktree)
        var files: [FileDiff] = []
        for repo in repos {
            let compare: DiffCompare
            if committed {
                let state = await RepoReview.state(context.reader, worktree: context.worktree, repo: repo,
                                                   preferredBase: repo.isSubmodule ? nil : context.baseRef)
                guard let base = state.base else { continue }
                compare = .committed(base: base)
            } else {
                compare = .uncommitted
            }
            files += try await RepoReview.changes(context.reader, worktree: context.worktree, repo: repo, repos: repos,
                                                  exclude: context.exclude, compare: compare).files
        }
        return files
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
    /// Processes, folder watches and shells running there for chats here.
    @ObservationIgnored var processes: [Int: (line: @Sendable (OutputLine) -> Void, exit: @Sendable (Int32?) -> Void)] = [:]
    @ObservationIgnored var watchers: [Int: () -> Void] = [:]
    @ObservationIgnored var terminals: [Int: (output: (Data) -> Void, exit: (Int32?) -> Void)] = [:]

    init(device: RemoteService.PairedDevice, service: RemoteService) {
        self.device = device; self.service = service
    }

    var isConnected: Bool { state == .online || state == .connecting }

    @ObservationIgnored private var dial: Task<Void, Never>?
    @ObservationIgnored private var dialChannel: RemoteChannel?
    @ObservationIgnored private var generation = UUID()

    func connect(to endpoint: NWEndpoint?, internet: InternetAddress?, as identity: DeviceIdentity) {
        guard !isConnected else { return }
        state = .connecting
        let attempt = UUID(); generation = attempt
        dial = Task {
            do {
                var connected: RemoteChannel?
                if let endpoint {
                    let local = RemoteChannel(connection: NWConnection(to: endpoint, using: RemoteNetwork.parameters(peerToPeer: service?.peerToPeer ?? true)))
                    dialChannel = local
                    let timeout = Task {
                        do { try await Task.sleep(for: .seconds(3)); local.close() } catch {}
                    }
                    do {
                        try await local.open()
                        _ = try await local.handshake(as: identity, pairing: false, expected: device.peer)
                        connected = local
                    } catch { local.close() }
                    timeout.cancel()
                }
                guard generation == attempt, !Task.isCancelled else { connected?.close(); return }
                if connected == nil, let internet, let service {
                    let remote = try await service.internetChannel(to: internet)
                    dialChannel = remote
                    let timeout = Task {
                        do { try await Task.sleep(for: .seconds(10)); remote.close() } catch {}
                    }
                    defer { timeout.cancel() }
                    do {
                        _ = try await remote.handshake(as: identity, pairing: false, expected: device.peer)
                        connected = remote
                    } catch { remote.close(); throw error }
                }
                guard let connected else { throw RemoteChannel.Failure.closed }
                guard generation == attempt, !Task.isCancelled else { connected.close(); return }
                dialChannel = nil
                adopt(connected)
            } catch {
                if generation == attempt { dialChannel?.close(); dialChannel = nil; state = .failed(error.localizedDescription) }
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
                guard let message = try? await channel.receive(), self.channel === channel else { break }
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
        generation = UUID(); dial?.cancel(); dial = nil
        dialChannel?.close(); dialChannel = nil
        channel?.close()
        ended()
    }

    func markOffline() {
        guard !isConnected else { return }
        state = .offline
    }

    private func ended() {
        channel = nil
        outbox.continuation.finish()
        if state == .online || state == .connecting { state = .offline }
        for (_, waiter) in waiting { waiter.resume(throwing: RemoteChannel.Failure.closed) }
        waiting = [:]
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
            service?.rememberInternet(snapshot.internetAddress, for: device.id)
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
        case .event(let event):
            received(event)
        case .request, .tunnel:
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

private struct IrohRemoteTransport: RemoteTransport {
    let stream: InternetStream
    nonisolated func open() async throws {}
    nonisolated func close() { stream.close() }
    nonisolated func read(_ count: Int) async throws -> Data { try await stream.read(count) }
    nonisolated func write(_ data: Data, completion: @escaping @Sendable ((any Error)?) -> Void) {
        stream.write(data, completion: completion)
    }
}
