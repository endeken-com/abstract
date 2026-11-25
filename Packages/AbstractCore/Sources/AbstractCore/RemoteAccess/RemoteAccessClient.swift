import Foundation

/// Where this Mac keeps its grants: the store's settings in the app, memory in tests.
public protocol RemoteGrantStore: Sendable {
    func load() -> [RemoteGrant]
    func save(_ grants: [RemoteGrant])
}

public struct StoreRemoteGrants: RemoteGrantStore {
    public static let key = "remoteAccess.grants"
    let store: Store

    public init(store: Store) { self.store = store }

    public func load() -> [RemoteGrant] { store.setting(Self.key, as: [RemoteGrant].self) ?? [] }
    public func save(_ grants: [RemoteGrant]) { try? store.setSetting(Self.key, grants) }
}

/// How the tunnel to the gateway is doing.
public enum RemoteAccessState: Sendable, Equatable {
    case connecting
    case connected
    /// Dropped; trying again at this time.
    case waiting(until: Date)
    /// Another connection with this Mac's credential took over; trying again at this time.
    case replaced(until: Date)
    /// The gateway no longer knows this Mac: remote access was turned off.
    case unregistered
    case stopped
}

/// This Mac's side of remote access (ABS-219): an outbound WebSocket to the
/// gateway, kept up with a heartbeat and exponential backoff, answering each
/// forwarded call from the chat feed, filtered by the grant's projects.
/// It answers only for grants it made itself and hasn't revoked.
public actor RemoteAccessClient {
    public typealias ConsentHandler = @Sendable (RemoteConsentRequest) async -> RemoteGrant?

    let gateway: RemoteGateway
    let credential: RemoteCredential
    let store: any RemoteGrantStore
    let handler: RemoteCallHandler
    let sockets: any RemoteSocketFactory
    let heartbeat: TimeInterval
    let consent: ConsentHandler
    let onState: @Sendable (RemoteAccessState) -> Void
    let onGrants: @Sendable ([RemoteGrant]) -> Void
    let sleep: @Sendable (TimeInterval) async throws -> Void

    public private(set) var grants: [RemoteGrant]
    private var socket: (any RemoteSocket)?
    private var runner: Task<Void, Never>?
    private var lastHeard = Date()
    private var replies: [String: CheckedContinuation<GatewayMessage, any Error>] = [:]
    private var timers: [String: Task<Void, Never>] = [:]

    public init(gateway: RemoteGateway, credential: RemoteCredential, store: any RemoteGrantStore,
                handler: RemoteCallHandler, sockets: any RemoteSocketFactory = URLSessionSocketFactory(),
                heartbeat: TimeInterval = 25,
                consent: @escaping ConsentHandler,
                onState: @escaping @Sendable (RemoteAccessState) -> Void = { _ in },
                onGrants: @escaping @Sendable ([RemoteGrant]) -> Void = { _ in },
                sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.gateway = gateway
        self.credential = credential
        self.store = store
        self.handler = handler
        self.sockets = sockets
        self.heartbeat = heartbeat
        self.consent = consent
        self.onState = onState
        self.onGrants = onGrants
        self.sleep = sleep
        grants = store.load()
    }

    public func start() {
        guard runner == nil else { return }
        runner = Task { await self.run() }
    }

    public func stop() async {
        runner?.cancel()
        socket?.close()
        await runner?.value
        runner = nil
    }

    public var isConnected: Bool { socket != nil }

    // MARK: The connection

    private func run() async {
        var attempt = 0
        while !Task.isCancelled {
            onState(.connecting)
            var reason: String?
            do {
                let socket = try await sockets.connect(gateway, credential: credential)
                self.socket = socket
                attempt = 0
                lastHeard = Date()
                onState(.connected)
                let beat = Task { await self.beat(socket) }
                while let text = try await socket.receive() {
                    lastHeard = Date()
                    handle(text, on: socket)
                }
                beat.cancel()
                reason = socket.closeReason
            } catch {
                reason = socket?.closeReason
            }
            socket = nil
            failReplies()
            if reason == "unregistered" {
                onState(.unregistered)
                return
            }
            if Task.isCancelled { break }
            let delay = RemoteBackoff.delay(attempt: attempt)
            attempt += 1
            let until = Date().addingTimeInterval(delay)
            onState(reason == "replaced" ? .replaced(until: until) : .waiting(until: until))
            do { try await sleep(delay) } catch { break }
        }
        onState(.stopped)
    }

    /// Pings every `heartbeat` seconds; a socket that's been silent three
    /// beats long is dead, whatever TCP thinks, and is closed to reconnect.
    private func beat(_ socket: any RemoteSocket) async {
        while !Task.isCancelled {
            do { try await sleep(heartbeat) } catch { return }
            if Date().timeIntervalSince(lastHeard) > heartbeat * 3 {
                socket.close()
                return
            }
            try? await socket.send(GatewayProtocol.heartbeat)
        }
    }

    private func send(_ text: String, on socket: (any RemoteSocket)?) {
        guard let socket else { return }
        Task { try? await socket.send(text) }
    }

    // MARK: Frames

    func handle(_ text: String, on socket: any RemoteSocket) {
        if text == GatewayProtocol.heartbeatReply { return }
        guard let message = GatewayProtocol.parse(text) else { return }
        switch message {
        case .hello(_, let known):
            reconcile(with: known, on: socket)
        case .call(let id, let grantId, let projects, _, let body):
            let grant = grants.first { $0.id == grantId }
            if grant?.isActive == true { touch(grantId) }
            let handler = handler
            // Reading chats happens off the actor, so calls don't queue behind each other.
            Task.detached(priority: .userInitiated) {
                let answer = handler.answer(body, grant: grant, projects: projects)
                try? await socket.send(GatewayProtocol.result(id: id, status: answer.status, body: answer.body))
            }
        case .consentRequest(let request):
            let consent = consent
            Task {
                if let grant = await consent(request), Date() < request.expiresAt {
                    // Recorded here first: the Mac answers only grants it made.
                    self.add(grant)
                    try? await socket.send(GatewayProtocol.approve(id: request.id, grant: grant))
                } else {
                    try? await socket.send(GatewayProtocol.deny(id: request.id))
                }
            }
        case .connectCode(let id, _, _), .ack(let id):
            reply(id, with: .success(message))
        case .error(let id, let text):
            if let id { reply(id, with: .failure(RemoteAccessError.gateway(text))) }
        case .grantRevoked(let grantId):
            markRevoked(grantId)
        }
    }

    /// After (re)connecting: the gateway's list against this Mac's. A grant
    /// the gateway still honours but this Mac revoked (or never made) is
    /// revoked there too; one the gateway revoked is revoked here.
    private func reconcile(with known: [GatewayGrant], on socket: any RemoteSocket) {
        let mine = Dictionary(grants.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for server in known where server.revokedAt == nil && mine[server.id]?.isActive != true {
            send(GatewayProtocol.revoke(id: UUID().uuidString, grantId: server.id), on: socket)
        }
        let serverIds = Dictionary(known.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var changed = false
        for i in grants.indices where grants[i].isActive {
            let server = serverIds[grants[i].id]
            guard let server, server.revokedAt == nil else {
                // Revoked at the gateway, or never stored there (its consent timed out).
                grants[i].revokedAt = server?.revokedAt ?? Date()
                changed = true
                continue
            }
            if let used = server.lastUsedAt, used > (grants[i].lastUsedAt ?? .distantPast) {
                grants[i].lastUsedAt = used
                changed = true
            }
        }
        if changed { persist() }
    }

    // MARK: Grants

    private func persist() {
        store.save(grants)
        onGrants(grants)
    }

    private func add(_ grant: RemoteGrant) {
        grants.append(grant)
        persist()
    }

    private func touch(_ grantId: String) {
        guard let i = grants.firstIndex(where: { $0.id == grantId }) else { return }
        grants[i].lastUsedAt = Date()
        persist()
    }

    private func markRevoked(_ grantId: String) {
        guard let i = grants.firstIndex(where: { $0.id == grantId }), grants[i].isActive else { return }
        grants[i].revokedAt = Date()
        persist()
    }

    /// Takes effect here at once: the next call for it is refused on this
    /// Mac. The gateway is told now, or on the next connection if it's down.
    public func revoke(_ grantId: String) {
        markRevoked(grantId)
        send(GatewayProtocol.revoke(id: UUID().uuidString, grantId: grantId), on: socket)
    }

    /// Revoked grants out of the list; the gateway already refuses them.
    public func forgetRevoked() {
        grants.removeAll { !$0.isActive }
        persist()
    }

    /// Changes a grant's projects or health-data redaction, here and at the gateway.
    public func update(_ grant: RemoteGrant) {
        guard let i = grants.firstIndex(where: { $0.id == grant.id }), grants[i].isActive else { return }
        grants[i].projects = grant.projects
        grants[i].redactsHealthData = grant.redactsHealthData
        persist()
        send(GatewayProtocol.update(id: UUID().uuidString, grant: grants[i]), on: socket)
    }

    /// A one-use code for "Connect an assistant" (ABS-220), valid 10 minutes.
    public func connectionCode(timeout: TimeInterval = 10) async throws -> (code: String, expiresAt: Date) {
        guard let socket else { throw RemoteAccessError.notConnected }
        let id = UUID().uuidString
        let sleep = sleep
        let reply = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<GatewayMessage, any Error>) in
            replies[id] = continuation
            timers[id] = Task {
                do { try await sleep(timeout) } catch { return }
                await self.reply(id, with: .failure(RemoteAccessError.timedOut))
            }
            Task { try? await socket.send(GatewayProtocol.connectCodeRequest(id: id)) }
        }
        guard case .connectCode(_, let code, let expiresAt) = reply else { throw RemoteAccessError.malformed }
        return (code, expiresAt)
    }

    private func reply(_ id: String, with result: Result<GatewayMessage, any Error>) {
        timers.removeValue(forKey: id)?.cancel()
        replies.removeValue(forKey: id)?.resume(with: result)
    }

    private func failReplies() {
        for id in Array(replies.keys) { reply(id, with: .failure(RemoteAccessError.notConnected)) }
    }
}
