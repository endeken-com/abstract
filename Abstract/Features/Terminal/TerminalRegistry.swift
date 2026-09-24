import Foundation

/// Keeps each terminal pane's shell alive while its tab or chat is hidden,
/// and ends it when the pane closes. Keyed by pane id: a chat can have
/// several terminal panes, each with its own shell.
@MainActor
final class TerminalRegistry {
    static let shared = TerminalRegistry()

    private var hosts: [String: TerminalHost] = [:]

    /// The pane's terminal, created (and its shell started) on first use.
    /// `directory` only matters then; later calls return the same terminal.
    func host(for paneId: String, directory: String?, remote: RemoteLink? = nil) -> TerminalHost {
        if let host = hosts[paneId] { return host }
        let host = TerminalHost(paneId: paneId, directory: directory, remote: remote)
        hosts[paneId] = host
        return host
    }

    /// The pane's shell if it has been started, for its tab's title.
    func existingHost(for paneId: String) -> TerminalHost? { hosts[paneId] }

    /// Terminate the shell behind a pane, if one is running.
    func close(paneId: String) {
        hosts.removeValue(forKey: paneId)?.shutdown()
    }

    /// Terminate every shell (app quit).
    func closeAll() {
        let all = hosts.values
        hosts.removeAll()
        for host in all { host.shutdown() }
    }
}
