import Foundation
import AbstractCore

/// Remote access (ABS-219): assistants like Grok reach this Mac's chat feed
/// through `mcp.useabstract.app`, over an outbound WebSocket this Mac keeps
/// open. Off by default. Turning it on registers the Mac; turning it off
/// unregisters it, which voids its credential, grants and their tokens.
@MainActor @Observable
final class RemoteAccessService {
    enum Status: Equatable {
        case off
        case registering
        case connecting
        case connected
        case retrying(at: Date)
        /// Another connection with this Mac's credential took over.
        case replaced(retryAt: Date)
        /// Turned off while offline: the gateway is told when it's back.
        case turningOff
        case failed(String)
    }

    private(set) var enabled: Bool
    private(set) var status: Status = .off
    private(set) var grants: [RemoteGrant] = []

    /// The address to give an assistant.
    var mcpURL: String { gateway.base.appendingPathComponent("mcp").absoluteString }

    /// Answers "may this assistant read your chats?". ABS-220 shows the sheet;
    /// until then nothing is allowed, and demo mode's probe can set one.
    @ObservationIgnored var consentHandler: (@Sendable (RemoteConsentRequest) async -> RemoteGrant?)?

    @ObservationIgnored private let store: Store
    @ObservationIgnored private let logsURL: URL
    @ObservationIgnored private let log: ChatFeedLog
    @ObservationIgnored private let gateway: RemoteGateway
    @ObservationIgnored private let api: RemoteAccessAPI
    @ObservationIgnored private let grantStore: StoreRemoteGrants
    /// nil in a demo: its credential stays in memory and never reaches the Keychain.
    @ObservationIgnored private let keychainAccount: String?
    @ObservationIgnored private var demoCredential: String?
    @ObservationIgnored private var client: RemoteAccessClient?

    private static let enabledKey = "remoteAccess.enabled"
    private static let pendingUnregisterKey = "remoteAccess.pendingUnregister"

    init(store: Store, logsURL: URL, log: ChatFeedLog, isDemo: Bool, gateway: RemoteGateway = .fromEnvironment()) {
        self.store = store
        self.logsURL = logsURL
        self.log = log
        self.gateway = gateway
        api = RemoteAccessAPI(gateway: gateway)
        grantStore = StoreRemoteGrants(store: store)
        keychainAccount = isDemo ? nil : "remote-access-credential"
        enabled = store.setting(Self.enabledKey, as: Bool.self) ?? false
        grants = grantStore.load()
    }

    // MARK: Turning it on and off

    /// At launch: reconnect if it was on, or finish turning it off.
    func resume() {
        if store.setting(Self.pendingUnregisterKey, as: Bool.self) == true {
            Task { await finishTurningOff() }
        } else if enabled {
            Task { await connect() }
        }
    }

    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        try? store.setSetting(Self.enabledKey, on)
        Task { on ? await connect() : await turnOff() }
    }

    private func connect() async {
        guard enabled, client == nil else { return }
        let credential: RemoteCredential
        if let saved = readCredential() {
            credential = saved
        } else {
            status = .registering
            do {
                credential = try await api.register()
                writeCredential(credential)
            } catch {
                status = .failed(error.localizedDescription)
                return
            }
        }
        guard enabled, let path = store.databasePath else { return }
        let reader: ChatFeedStore
        do { reader = try ChatFeedStore(databasePath: path, logsURL: logsURL) } catch {
            status = .failed("Abstract's chats couldn't be opened for reading.")
            return
        }
        let client = RemoteAccessClient(
            gateway: gateway, credential: credential, store: grantStore,
            handler: RemoteCallHandler(reader: reader, log: log),
            consent: { [weak self] request in
                guard let handler = await self?.consentHandler else { return nil }
                return await handler(request)
            },
            onState: { [weak self] state in Task { @MainActor in self?.clientChanged(state) } },
            onGrants: { [weak self] grants in Task { @MainActor in self?.grants = grants } })
        self.client = client
        status = .connecting
        await client.start()
    }

    private func clientChanged(_ state: RemoteAccessState) {
        guard client != nil else { return }
        switch state {
        case .connecting: status = .connecting
        case .connected: status = .connected
        case .waiting(let until): status = .retrying(at: until)
        case .replaced(let until): status = .replaced(retryAt: until)
        case .unregistered:
            // The gateway forgot this Mac (turned off elsewhere, or reset): start over next time.
            writeCredential(nil)
            client = nil
            enabled = false
            try? store.setSetting(Self.enabledKey, false)
            revokeAllLocally()
            status = .off
        case .stopped: break
        }
    }

    private func turnOff() async {
        let client = client
        self.client = nil
        await client?.stop()
        revokeAllLocally()
        try? store.setSetting(Self.pendingUnregisterKey, true)
        await finishTurningOff()
    }

    /// Unregisters at the gateway; offline, it stays pending and is tried again at the next launch.
    private func finishTurningOff() async {
        guard let credential = readCredential() else {
            try? store.setSetting(Self.pendingUnregisterKey, false)
            status = .off
            return
        }
        status = .turningOff
        do {
            try await api.unregister(credential)
            writeCredential(nil)
            try? store.setSetting(Self.pendingUnregisterKey, false)
            if !enabled { status = .off }
        } catch {
            status = .turningOff
        }
    }

    private func revokeAllLocally() {
        let now = Date()
        grants = grants.map { var g = $0; if g.isActive { g.revokedAt = now }; return g }
        grantStore.save(grants)
    }

    // MARK: Grants

    func revoke(_ grantId: String) {
        guard let client else {
            grants = grants.map { var g = $0; if g.id == grantId, g.isActive { g.revokedAt = Date() }; return g }
            grantStore.save(grants)
            return
        }
        Task { await client.revoke(grantId) }
    }

    func setHealthRedaction(_ on: Bool, for grantId: String) {
        guard var grant = grants.first(where: { $0.id == grantId }), grant.isActive else { return }
        grant.redactsHealthData = on
        if let client {
            Task { await client.update(grant) }
        } else {
            grants = grants.map { $0.id == grantId ? grant : $0 }
            grantStore.save(grants)
        }
    }

    /// Revoked grants out of the list.
    func clearRevoked() {
        if let client {
            Task { await client.forgetRevoked() }
        } else {
            grants = grants.filter(\.isActive)
            grantStore.save(grants)
        }
    }

    /// For "Connect an assistant" (ABS-220).
    func connectionCode() async throws -> (code: String, expiresAt: Date) {
        guard let client else { throw RemoteAccessError.notConnected }
        return try await client.connectionCode()
    }

    // MARK: The credential

    private func readCredential() -> RemoteCredential? {
        let text = if let keychainAccount { Keychain.read(keychainAccount) } else { demoCredential }
        return text.flatMap(RemoteCredential.init)
    }

    private func writeCredential(_ credential: RemoteCredential?) {
        if let keychainAccount { Keychain.write(keychainAccount, credential?.text) } else { demoCredential = credential?.text }
    }
}
