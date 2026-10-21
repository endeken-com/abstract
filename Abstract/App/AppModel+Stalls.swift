import AppKit
import Foundation
import AbstractCore

/// A working chat that goes quiet: after the quiet threshold its working
/// line says so, after the stalled threshold it is marked Stalled and you
/// are told once, with Keep waiting, Stop and Stop and retry. Nothing is
/// restarted on its own. Chats on a paired Mac aren't watched here; their
/// own Mac watches them.
extension AppModel {
    /// How often working chats are checked for silence.
    static var stallCheckInterval: Duration { .seconds(5) }

    func watchForStalls() async {
        while !Task.isCancelled {
            checkStalls(now: Date())
            try? await Task.sleep(for: Self.stallCheckInterval)
        }
    }

    func stallState(_ sessionId: String) -> StallState? { stallStates[sessionId] }

    /// One pass over this Mac's chats. A chat's clock runs from its turn's
    /// start or its last output line, as its log's times say, and pauses
    /// while a permission or question waits or a task runs in the background.
    func checkStalls(now: Date) {
        for session in sessions {
            let id = session.id
            guard session.status == .running || session.status == .provisioning else {
                if stallStates[id] != nil { stallStates[id] = nil }
                if stallWatches[id] != nil { stallWatches[id]?.endTurn() }
                continue
            }
            let feed = feed(id)
            var watch = stallWatches[id] ?? StallWatch()
            if watch.lastOutputAt == nil {
                watch.beginTurn(at: feed.turnStartedAt ?? turnStarts[id] ?? now)
            }
            if let last = feed.lastOutputAt { watch.noteOutput(at: last) }
            let paused = !pendingPermissions(id).isEmpty || runningBackgroundTasks(id) > 0
            watch.setPaused(paused, at: now)
            let state = watch.state(at: now, thresholds: stallThresholds)
            // Looking at the chat already? Its working line says it, with the same actions.
            let onScreen = NSApp.isActive && selectedSessionId == id
            if watch.consumeStallNotification(at: now, thresholds: stallThresholds), notifyStalled, !onScreen {
                let minutes = state.quietMinutes(at: now) ?? stallThresholds.stalledMinutes
                Notifier.shared.postStalled(title: session.name,
                                            body: "\(session.name) has been quiet for \(minutes) minutes",
                                            sessionId: id)
            }
            stallWatches[id] = watch
            let shown: StallState? = state == .working ? nil : state
            if stallStates[id] != shown { stallStates[id] = shown }
        }
    }

    /// Keep waiting: the flag clears and the clock restarts.
    func keepWaiting(_ sessionId: String) {
        stallWatches[sessionId]?.keepWaiting(at: Date())
        stallStates[sessionId] = nil
    }

    /// Stop and retry: end the stuck turn, then send your last message again
    /// once the turn is over.
    func stopAndRetry(_ sessionId: String) {
        if let (_, host) = RemoteService.split(sessionId) {
            remoteAction(sessionId, .stopAndRetry(sessionId: host))
            stallStates[sessionId] = nil
            return
        }
        let message = feed(sessionId).lastUserMessage ?? session(sessionId)?.prompt
        stallStates[sessionId] = nil
        guard let message, !message.isEmpty else { stop(sessionId); return }
        // As Interrupt does: the message goes again once the turn has stopped.
        Task {
            do { try await interrupt(sessionId, text: message) }
            catch { flash(error.localizedDescription, isError: true) }
        }
    }

    /// What you chose on a stalled chat's notification.
    func stallAction(_ sessionId: String, _ action: StallAction) {
        switch action {
        case .keepWaiting: keepWaiting(sessionId)
        case .stop: stop(sessionId); stallStates[sessionId] = nil
        case .stopAndRetry: stopAndRetry(sessionId)
        }
    }
}
