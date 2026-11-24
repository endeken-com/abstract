import AppKit
import Foundation
import AbstractCore

/// The chat feed (ABS-217): a read-only MCP endpoint on 127.0.0.1 that lets
/// another assistant follow this Mac's open chats. Off by default; it only
/// answers requests that carry the token, which lives in the Keychain.
@MainActor @Observable
final class ChatFeedService {
    /// What Settings shows about the server right now.
    enum Status: Equatable {
        case off
        case needsToken
        case starting
        case listening(port: UInt16)
        case failed(String)
    }

    private(set) var settings: ChatFeedSettings
    private(set) var status: Status = .off
    private(set) var hasToken: Bool
    private(set) var lastCalls: [ChatFeedLog.Entry] = []

    @ObservationIgnored private let store: Store
    @ObservationIgnored private let logsURL: URL
    @ObservationIgnored let log: ChatFeedLog
    /// nil in a demo: its token stays in memory and never reaches the Keychain.
    @ObservationIgnored private let keychainAccount: String?
    @ObservationIgnored private var demoToken: String?
    @ObservationIgnored private var endpoint: ChatFeedEndpoint?
    @ObservationIgnored private var listener: ChatFeedListener?

    init(store: Store, logsURL: URL, dataDirectory: URL, isDemo: Bool) {
        self.store = store
        self.logsURL = logsURL
        log = ChatFeedLog(url: ChatFeedLog.defaultURL(dataDirectory: dataDirectory))
        keychainAccount = isDemo ? nil : "chat-feed-token"
        settings = store.setting(ChatFeedSettings.storeKey, as: ChatFeedSettings.self) ?? ChatFeedSettings()
        hasToken = keychainAccount.flatMap(Keychain.read) != nil
    }

    var endpointURL: String { settings.endpointURL }

    // MARK: Changing it

    func update(_ change: (inout ChatFeedSettings) -> Void) {
        var next = settings
        change(&next)
        guard next != settings else { return }
        let restart = next.enabled != settings.enabled || next.port != settings.port
        settings = next
        try? store.setSetting(ChatFeedSettings.storeKey, next)
        if restart { apply() } else { endpoint?.configuration = configuration(token: endpoint?.configuration.token) }
    }

    /// A new token, replacing any old one at once. Returned once, for you to
    /// copy; Settings never shows it again.
    func rotateToken() -> String {
        let token = ChatFeedEndpoint.makeToken()
        writeToken(token)
        hasToken = true
        if let endpoint { endpoint.configuration = configuration(token: token) } else { apply() }
        return token
    }

    /// Turns it off and forgets the token: every later request is refused.
    func revoke() {
        endpoint?.configuration.token = nil
        writeToken(nil)
        hasToken = false
        update { $0.enabled = false }
        apply()
    }

    // MARK: Running it

    /// Starts or stops the server to match the settings and the token.
    func apply() {
        listener?.stop()
        listener = nil
        endpoint = nil
        guard settings.enabled else { status = .off; return }
        guard let token = readToken() else { status = .needsToken; return }
        guard let path = store.databasePath else { status = .failed("Abstract's database isn't on disk."); return }
        do {
            let reader = try ChatFeedStore(databasePath: path, logsURL: logsURL)
            let endpoint = ChatFeedEndpoint(reader: reader, configuration: configuration(token: token), log: log)
            let port = settings.port
            let listener = ChatFeedListener(endpoint: endpoint, port: port) { [weak self] state in
                Task { @MainActor in self?.listenerChanged(state, port: port) }
            }
            try listener.start()
            self.endpoint = endpoint
            self.listener = listener
            status = .starting
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func stop() {
        listener?.stop()
        listener = nil
        endpoint = nil
    }

    private func listenerChanged(_ state: ChatFeedListener.State, port: UInt16) {
        guard listener != nil, port == settings.port else { return }
        switch state {
        case .starting: status = .starting
        case .ready(let port): status = .listening(port: port)
        case .failed(let message): status = .failed("Port \(port) couldn't be opened: \(message)")
        case .stopped: if case .listening = status { status = .off }
        }
    }

    private func readToken() -> String? {
        if let keychainAccount { return Keychain.read(keychainAccount) }
        return demoToken
    }

    private func writeToken(_ token: String?) {
        if let keychainAccount { Keychain.write(keychainAccount, token) } else { demoToken = token }
    }

    private func configuration(token: String?) -> ChatFeedEndpoint.Configuration {
        .init(token: token, filter: settings.filter, allowedOrigins: settings.allowedOrigins)
    }

    func refreshLastCalls() {
        let log = log
        Task.detached(priority: .utility) {
            let calls = log.recent(10)
            await MainActor.run { self.lastCalls = calls }
        }
    }
}
