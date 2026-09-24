import Foundation
import Network
import Synchronization
import AbstractCore

/// Where a local model server is: this Mac, an address on the network (a
/// GPU box, another computer), or a paired Mac running Abstract, which
/// carries the connection over the pairing link.
enum LocalModelSource: Codable, Hashable, Sendable {
    case thisMac
    case address(String)
    case pairedMac(deviceId: String)
}

extension AppModel {
    func localModelSource(_ kind: LocalModelKind) -> LocalModelSource { localModelSources[kind] ?? .thisMac }

    func setLocalModelSource(_ kind: LocalModelKind, _ source: LocalModelSource) {
        localModelSources[kind] = source
        Task { await refreshLocalModels() }
    }

    /// Looks at each server where it's set to be, and makes its agent
    /// available only while the server answers (and Codex, which runs the
    /// agent against it, is installed).
    func refreshLocalModels() async {
        for kind in LocalModelKind.allCases {
            let url = await endpoint(kind)
            LocalModelEndpoints.set(kind, url)
            let status = if let url, pairedMacOnline(kind) { await LocalModelServer.status(kind, at: url) }
                else { LocalModelServerStatus(reachable: false, models: [], error: "That Mac isn't connected, or doesn't share \(kind.name).") }
            if localModelStatus[kind] != status { localModelStatus[kind] = status }
            let codex = providerStatus["codex"]
            let available = status.reachable && !status.models.isEmpty && (codex?.available ?? false)
            let next = ProviderStatus(available: available, path: codex?.path, version: codex?.version)
            if providerStatus[kind.providerId] != next { providerStatus[kind.providerId] = next }
            if status.reachable {
                LocalModelCatalogs.remember(kind, status.models)
                let catalog = ModelCatalog(models: status.models.map { ModelOption(id: $0, label: $0) })
                if modelCatalogs[kind.providerId] != catalog { updateModelCatalog(catalog, for: kind.providerId) }
            }
        }
    }

    /// Servers come and go (an app quit, a Mac asleep): look again every half minute.
    func watchLocalModels() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(30))
            await refreshLocalModels()
        }
    }

    private func endpoint(_ kind: LocalModelKind) async -> URL? {
        switch localModelSource(kind) {
        case .thisMac:
            closeRelay(kind)
            return kind.defaultURL
        case .address(let address):
            closeRelay(kind)
            let trimmed = address.trimmingCharacters(in: .whitespaces)
            return URL(string: trimmed.contains("://") ? trimmed : "http://" + trimmed)
        case .pairedMac(let deviceId):
            return await relay(kind, device: deviceId)?.url
        }
    }

    /// False while the paired Mac a server is reached through is away (its relay is kept, but can't carry anything).
    private func pairedMacOnline(_ kind: LocalModelKind) -> Bool {
        guard case .pairedMac(let deviceId) = localModelSource(kind) else { return true }
        return remote.links[deviceId]?.state == .online
    }

    private func relay(_ kind: LocalModelKind, device: String) async -> LocalModelRelay? {
        // Once open, a relay stays on its port while that Mac is still paired:
        // a running Codex has the address baked in, so a link that dropped for
        // a moment, or a server slow to answer there, mustn't move it.
        if let existing = localRelays[kind], existing.deviceId == device, existing.isOpen, remote.links[device] != nil { return existing }
        closeRelay(kind)
        guard let link = remote.links[device], link.state == .online, link.snapshot?.localModels?.contains(kind) == true else { return nil }
        guard let relay = await LocalModelRelay.start(kind, link: link) else { return nil }
        localRelays[kind] = relay
        return relay
    }

    private func closeRelay(_ kind: LocalModelKind) {
        localRelays.removeValue(forKey: kind)?.close()
    }

    /// The servers on this Mac that paired Macs may use.
    var sharedLocalModels: [LocalModelKind] {
        LocalModelKind.allCases.filter { sharesLocalModel($0) && localModelStatus[$0]?.reachable == true }
    }

    /// Whether paired Macs may connect to this server, answering or not: a
    /// check that timed out (a model loading) mustn't cut them off mid-request.
    func sharesLocalModel(_ kind: LocalModelKind) -> Bool {
        guard shareLocalModels else { return false }
        // Only its own: a server reached through another Mac isn't passed on.
        if case .pairedMac = localModelSource(kind) { return false }
        return true
    }
}

/// A paired Mac's local model server, reachable here at a loopback address:
/// each connection Codex makes to it is carried to that Mac over the
/// encrypted pairing link, and made there to its own server.
@MainActor
final class LocalModelRelay {
    let kind: LocalModelKind
    let deviceId: String
    private weak var link: RemoteLink?
    private let listener: NWListener
    private(set) var port: UInt16 = 0
    private var connections: [Int: NWConnection] = [:]
    private(set) var isOpen = true

    var url: URL { URL(string: "http://127.0.0.1:\(port)")! }

    private init(kind: LocalModelKind, link: RemoteLink, listener: NWListener) {
        self.kind = kind
        self.deviceId = link.device.id
        self.link = link
        self.listener = listener
    }

    static func start(_ kind: LocalModelKind, link: RemoteLink) async -> LocalModelRelay? {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        guard let listener = try? NWListener(using: parameters) else { return nil }
        let relay = LocalModelRelay(kind: kind, link: link, listener: listener)
        listener.newConnectionHandler = { [weak relay] connection in
            Task { @MainActor in relay?.accept(connection) }
        }
        let ready: UInt16? = await withCheckedContinuation { continuation in
            let resumed = Mutex(false)
            listener.stateUpdateHandler = { state in
                let port: UInt16?? = switch state {
                case .ready: .some(listener.port?.rawValue)
                case .failed, .cancelled: .some(nil)
                default: nil
                }
                guard let port, resumed.withLock({ done in defer { done = true }; return !done }) else { return }
                continuation.resume(returning: port)
            }
            listener.start(queue: .main)
        }
        guard let ready else { listener.cancel(); return nil }
        relay.port = ready
        return relay
    }

    private func accept(_ connection: NWConnection) {
        guard let link, link.state == .online else { connection.cancel(); return }
        let id = link.openTunnel(kind, onData: { data in
            connection.send(content: data, completion: .idempotent)
        }, onClose: { [weak self] id in
            connection.cancel()
            self?.connections[id] = nil
        })
        connections[id] = connection
        connection.start(queue: .main)
        pump(connection, id: id)
    }

    /// Bytes from Codex to the other Mac, until either side closes.
    private func pump(_ connection: NWConnection, id: Int) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self else { return }
                if let data, !data.isEmpty { self.link?.tunnelSend(id, data) }
                if complete || error != nil {
                    self.link?.tunnelClose(id)
                    self.connections[id] = nil
                    connection.cancel()
                } else {
                    self.pump(connection, id: id)
                }
            }
        }
    }

    func close() {
        isOpen = false
        listener.cancel()
        for (id, connection) in connections {
            link?.tunnelClose(id)
            connection.cancel()
        }
        connections = [:]
    }
}
