import Foundation
import AbstractCore

/// Messages sent while the agent works (ABS-103). They wait in the chat's
/// queue and go as the next turn, joined into one message. Steer sends them
/// into the running turn (Claude); Interrupt stops the turn and sends them at
/// once. The engine keeps the queue beside the chat's log, so a relaunch
/// neither loses nor repeats one.
extension AppModel {
    /// The chat's queued messages, oldest first; a chat on another Mac's as
    /// that Mac last said.
    func queuedMessages(_ sessionId: String) -> [QueuedMessage] {
        if let (_, host) = RemoteService.split(sessionId) {
            return remote.link(for: sessionId)?.snapshot?.queuedMessages?[host] ?? []
        }
        return queues[sessionId] ?? []
    }

    /// A message now would land mid-turn, so it waits instead.
    func turnInProgress(_ sessionId: String) -> Bool {
        // Until a handover, the live process is still the outgoing agent's.
        guard let session = session(sessionId),
              let provider = ProviderRegistry.provider(session.handoffFrom ?? session.providerId) else { return false }
        return FollowUp.route(provider.followUpMode, alive: isAlive(sessionId), status: session.status,
                              handingOff: handingOff.contains(sessionId)) == .queue
    }

    /// Steer can reach the running turn: an agent that reads messages
    /// mid-turn, not about to be handed to another.
    func canSteer(_ sessionId: String) -> Bool {
        guard let session = session(sessionId), let provider = ProviderRegistry.provider(session.providerId) else { return false }
        if sessionId.hasPrefix(RemoteService.mirrorPrefix), remote.link(for: sessionId)?.snapshot?.messageQueue != true { return false }
        return session.handoffFrom == nil && !handingOff.contains(sessionId)
            && FollowUp.canSteer(provider.followUpMode, alive: isAlive(sessionId), status: session.status)
    }

    /// Why Steer is greyed out for the chat's agent; nil when it can steer.
    func steerUnavailable(_ sessionId: String) -> String? {
        guard let provider = session(sessionId).flatMap({ ProviderRegistry.provider($0.providerId) }) else { return nil }
        return FollowUp.steerUnavailable(provider)
    }

    /// A chat on another Mac that doesn't queue messages: Steer, Interrupt
    /// and the queue's controls aren't offered for it.
    func queueUnsupported(_ sessionId: String) -> Bool {
        sessionId.hasPrefix(RemoteService.mirrorPrefix) && remote.link(for: sessionId)?.snapshot?.messageQueue != true
    }

    func loadQueues() {
        for session in sessions {
            let queue = engine.queued(sessionId: session.id)
            if !queue.isEmpty { queues[session.id] = queue }
        }
    }

    func refreshQueue(_ sessionId: String) {
        let queue = engine.queued(sessionId: sessionId)
        if queues[sessionId] ?? [] != queue { queues[sessionId] = queue.isEmpty ? nil : queue }
    }

    /// Puts back messages the agent didn't get after all, first in line.
    func requeue(_ sessionId: String, _ messages: [QueuedMessage]) {
        guard !messages.isEmpty else { return }
        engine.requeue(sessionId: sessionId, messages)
        refreshQueue(sessionId)
    }

    func enqueue(_ sessionId: String, _ message: QueuedMessage) {
        engine.enqueue(sessionId: sessionId, message)
        refreshQueue(sessionId)
    }

    /// False when the message has already been sent.
    @discardableResult
    func editQueued(_ sessionId: String, id: String, text: String) -> Bool {
        let edited = engine.editQueued(sessionId: sessionId, id: id, text: text)
        refreshQueue(sessionId)
        return edited
    }

    /// Takes a message off the queue; nil when it has already been sent.
    @discardableResult
    func removeQueued(_ sessionId: String, id: String) -> QueuedMessage? {
        let message = engine.removeQueued(sessionId: sessionId, id: id)
        refreshQueue(sessionId)
        return message
    }

    /// Takes a message off the queue to edit in the composer, here or on
    /// another Mac; nil when it has already been sent.
    func takeQueued(_ sessionId: String, id: String) async -> QueuedMessage? {
        guard let (_, host) = RemoteService.split(sessionId) else { return removeQueued(sessionId, id: id) }
        let message = queuedMessages(sessionId).first { $0.id == id }
        do { try await remote.perform(sessionId, .removeQueued(sessionId: host, id: id)) } catch { return nil }
        return message
    }

    /// Sends what's typed and the queue into the running turn now.
    func steer(_ sessionId: String, text: String, attachments: [PromptAttachment] = []) async throws {
        if let (_, host) = RemoteService.split(sessionId) {
            guard !attachments.isEmpty else { try await remote.perform(sessionId, .steer(sessionId: host, text: text)); return }
            // The attachments wait in that Mac's queue first; whatever happens next, they're sent once.
            try await sendRemoteFollowUp(sessionId, text: text, attachments: attachments)
            do { try await remote.perform(sessionId, .steer(sessionId: host, text: "")) }
            catch { flash("Queued instead; it goes when this turn ends. \(error.localizedDescription)", isError: true) }
            return
        }
        guard let session = session(sessionId), let provider = ProviderRegistry.provider(session.providerId) else { return }
        guard canSteer(sessionId) else {
            // The turn ended meanwhile: it goes as the next one.
            try sendFollowUp(sessionId, text: text, attachments: attachments)
            return
        }
        try send(engine.queued(sessionId: sessionId), plus: QueuedMessage(text: text, attachments: attachments), in: session, provider)
    }

    /// Stops the turn the way Stop does, then sends what's typed and the queue.
    func interrupt(_ sessionId: String, text: String, attachments: [PromptAttachment] = []) async throws {
        if let (_, host) = RemoteService.split(sessionId) {
            guard !attachments.isEmpty else { try await remote.perform(sessionId, .interrupt(sessionId: host, text: text)); return }
            try await sendRemoteFollowUp(sessionId, text: text, attachments: attachments)
            do { try await remote.perform(sessionId, .interrupt(sessionId: host, text: "")) }
            catch { flash("Queued instead; it goes when this turn ends. \(error.localizedDescription)", isError: true) }
            return
        }
        if isDrivenFromCLI(sessionId) { throw Self.drivenFromCLI }
        guard session(sessionId) != nil else { return }
        if handingOff.contains(sessionId) || relaunching.contains(sessionId) {
            throw AbstractError.message("The agent is restarting; interrupt again in a moment.")
        }
        if Self.hasContent(text, attachments) { enqueue(sessionId, QueuedMessage(text: text, attachments: attachments)) }
        guard turnInProgress(sessionId) else { sendQueue(sessionId); return }
        interrupting.insert(sessionId)
        stop(sessionId)
        // Nothing to stop after all (its process had already gone): send now.
        if !turnInProgress(sessionId) { turnEnded(sessionId, .idle, stopped: true) }
    }

    /// Called as each turn ends. A finished or interrupted turn sends the
    /// queue as the next one; after Stop or a failure it waits for you.
    func turnEnded(_ sessionId: String, _ status: SessionStatus, stopped: Bool) {
        guard !handingOff.contains(sessionId), !relaunching.contains(sessionId), !turnInProgress(sessionId) else { return }
        let interrupted = interrupting.remove(sessionId) != nil
        guard FollowUp.sendsQueue(after: status, stopped: stopped, interrupting: interrupted) else { return }
        guard engine.queued(sessionId: sessionId).isEmpty else { sendQueue(sessionId); return }
        // Done, unless its workflow hands it on: the chat waits for you.
        if !stopped, !workflowTurnEnded(sessionId, status, stopped: stopped), runningBackgroundTasks(sessionId) == 0 {
            automationEvent(.turnFinished, in: sessionId)
        }
    }

    /// The queue goes now, as the chat's next turn.
    func sendQueue(_ sessionId: String) {
        guard !sessionId.hasPrefix(RemoteService.mirrorPrefix), !isDrivenFromCLI(sessionId), setups[sessionId] == nil,
              let session = session(sessionId), let provider = ProviderRegistry.provider(session.providerId),
              !turnInProgress(sessionId) else { return }
        do { try send(engine.queued(sessionId: sessionId), in: session, provider) }
        catch { flash(error.localizedDescription, isError: true) }
    }

    /// Delivers queued messages as one, with `extra` (what's typed) last.
    /// Queued ones the agent didn't get wait again; `extra` stays yours.
    func send(_ queue: [QueuedMessage], plus extra: QueuedMessage? = nil, in session: Session,
              _ provider: any ProviderDefinition) throws {
        let extra = extra.flatMap { Self.hasContent($0.text, $0.attachments) ? $0 : nil }
        guard !queue.isEmpty || extra != nil else { return }
        let joined = FollowUp.joined(queue + (extra.map { [$0] } ?? []))
        do {
            try deliver(session, provider, message: PromptAttachments.message(joined.text, joined.attachments),
                        images: PromptAttachments.images(joined.attachments), queued: queue)
        } catch {
            requeue(session.id, queue)
            throw error
        }
    }

    private static func hasContent(_ text: String, _ attachments: [PromptAttachment]) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }
}
