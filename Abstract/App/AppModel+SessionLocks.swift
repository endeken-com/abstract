import Darwin
import Foundation
import AbstractCore

/// Chats driven from the command line (`abstract`), and the app's side of
/// each chat's `SessionLock`. The app holds a chat's lock while the chat
/// shows or the app runs its agent, so `abstract` can't send to or respawn
/// it then. A chat whose lock `abstract` holds shows read-only here, its
/// transcript following the log that agent writes, until the agent stops.
/// Opening such a chat asks for it: its agent stops once idle (at once, or
/// when its turn ends), and the chat carries on here like any other.
extension AppModel {
    static let drivenFromCLI = AbstractError.message(
        "This chat is driven from the command line, so it's read-only here until its agent stops.")

    var locksDirectory: URL { engine.logsURL.deletingLastPathComponent().appendingPathComponent("locks", isDirectory: true) }
    private var storePath: String { engine.logsURL.deletingLastPathComponent().appendingPathComponent("abstract.sqlite").path }

    /// `abstract` drives the chat: its agent runs there, or a command is at work on it.
    func isDrivenFromCLI(_ sessionId: String) -> Bool { cliDriven[sessionId] != nil }

    /// Listens for `abstract` changing the store, and follows the transcript
    /// of a chat it drives while that chat shows.
    func watchCommandLine() {
        storeObserver = StoreChanges.observe(storePath: storePath) { [weak self] in
            MainActor.assumeIsolated { self?.commandLineChanged() }
        }
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self else { return }
                guard let id = self.selectedSessionId, self.isDrivenFromCLI(id) else { continue }
                self.tailLog(id)
                self.refreshCLIDriven()
                // Released: the app takes the chat it shows, and reads the agent's last words.
                if !self.isDrivenFromCLI(id) {
                    self.syncLocks()
                    self.followCLIChat()
                }
            }
        }
    }

    /// `abstract` changed something: chats, their status, who drives them.
    func commandLineChanged() {
        reload()
        syncLocks()
        followCLIChat()
    }

    /// Who drives what from the command line, from the locks folder.
    func refreshCLIDriven() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: locksDirectory.path)) ?? []
        var driven: [String: SessionLockInfo] = [:]
        for name in names where name.hasSuffix(".json") {
            let id = String(name.dropLast(5))
            guard heldLocks[id] == nil, let holder = SessionLock.holder(of: id, in: locksDirectory), holder.driver == .cli else { continue }
            driven[id] = holder
        }
        if driven != cliDriven { cliDriven = driven }
    }

    /// Holds the locks of the chats the app drives now (the one showing, and
    /// those whose agent it runs or is restarting) and lets go of the rest.
    func syncLocks() {
        var wanted = alive.union(relaunching).union(handingOff)
        if let id = selectedSessionId, !id.hasPrefix(RemoteService.mirrorPrefix) { wanted.insert(id) }
        for (id, lock) in heldLocks where !wanted.contains(id) {
            lock.release()
            heldLocks[id] = nil
        }
        for id in wanted where heldLocks[id] == nil { _ = try? holdLock(id) }
        refreshCLIDriven()
        claimShownChat()
    }

    /// The chat showing is one `abstract`'s agent runs: ask its host for it.
    /// Asking again changes nothing, so every look can ask.
    private func claimShownChat() {
        guard let id = selectedSessionId, heldLocks[id] == nil, let holder = cliDriven[id], holder.agent != nil,
              SessionLock.holder(of: id, in: locksDirectory)?.pid == holder.pid else { return }
        kill(holder.pid, SIGUSR1)
    }

    /// The chat's lock, taken now if the app doesn't hold it yet. Throws when
    /// `abstract` drives the chat.
    @discardableResult
    func holdLock(_ sessionId: String) throws -> SessionLock {
        if let lock = heldLocks[sessionId] { return lock }
        do {
            let lock = try SessionLock.acquire(sessionId, as: .app, in: locksDirectory)
            heldLocks[sessionId] = lock
            if let agent = appAgents[sessionId] { try? lock.setAgent(agent) }
            if cliDriven[sessionId] != nil { cliDriven[sessionId] = nil }
            return lock
        } catch SessionLockError.held {
            refreshCLIDriven()
            throw Self.drivenFromCLI
        }
    }

    /// Says (or stops saying) which agent the app runs in the chat, for `abstract agent find`.
    func publishAgent(_ sessionId: String, providerId: String?) {
        appAgents[sessionId] = providerId.map { AgentRecord(sessionId: sessionId, providerId: $0) }
        try? heldLocks[sessionId]?.setAgent(appAgents[sessionId])
    }

    /// The chat showing reads what `abstract`'s agent added to its log since
    /// it last looked: while one runs, and once it's done (a chat seen before
    /// a respawn). Never while the app runs the chat's agent itself.
    func followCLIChat() {
        guard let id = selectedSessionId, !id.hasPrefix(RemoteService.mirrorPrefix), !alive.contains(id) else { return }
        tailLog(id)
    }

    /// Stop for a chat whose agent `abstract` runs: its host stops the agent
    /// and lets go of the chat. False when the app doesn't see one.
    func stopCLIAgent(_ sessionId: String) -> Bool {
        guard cliDriven[sessionId] != nil,
              let holder = SessionLock.holder(of: sessionId, in: locksDirectory), holder.driver == .cli else { return false }
        kill(holder.pid, SIGTERM)
        return true
    }
}
