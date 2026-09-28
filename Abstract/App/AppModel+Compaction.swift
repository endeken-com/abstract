import Foundation
import AbstractCore

extension AppModel {
    static let compactingDetail = "Compacting…"

    /// Compacts the chat's agent context the agent's own way, logging a row
    /// that shows it running and then what it did.
    func compact(_ sessionId: String) {
        do {
            try startCompaction(sessionId)
        } catch {
            flash(error.localizedDescription, isError: true)
        }
    }

    private func startCompaction(_ id: String) throws {
        guard !id.hasPrefix(RemoteService.mirrorPrefix) else { throw AbstractError.message("Compact this chat on the Mac it runs on.") }
        if isDrivenFromCLI(id) { throw Self.drivenFromCLI }
        guard let session = session(id), let provider = ProviderRegistry.provider(session.providerId),
              let compaction = provider.compaction else { return }
        if setups[id] != nil { throw AbstractError.message("“\(session.name)” is still being set up.") }
        if handingOff.contains(id) { throw AbstractError.message("Still handing this chat over; compact in a moment.") }
        if compacting.contains(id) { throw AbstractError.message("Already compacting.") }
        // Mid-turn, or blocked on a permission or question: its own next status would
        // race a manual compaction, or Claude's queued auto-compact would double up.
        if [.running, .provisioning, .waitingInput].contains(session.status) {
            throw AbstractError.message("Wait for the agent to finish its turn, then compact.")
        }
        // A side channel also waits out the exit after the turn (Codex reports
        // `finished` before its exec ends), which would overwrite "Compacting…".
        if case .sideChannel = compaction, alive.contains(id) {
            throw AbstractError.message("Wait for the agent to finish its turn, then compact.")
        }
        // The conversation is still the outgoing agent's until a message hands it over.
        if session.handoffFrom != nil { throw AbstractError.message("Send a message first to hand the chat over, then compact.") }
        guard let conversation = session.providerSessionId else {
            throw AbstractError.message("There's no conversation to compact yet.")
        }

        beginCompacting(id)
        engine.record(sessionId: id, CompactionMarker.started(.manual).line)
        markTurnStarted(id)
        // Restored once the compaction ends, instead of leaving the chat `.idle`
        // (alive, awaiting a follow-up) when it wasn't.
        compactionReturnStatus[id] = (session.status, session.statusDetail)
        setStatus(id, .running, detail: Self.compactingDetail)

        switch compaction {
        case .inStream(let prompt):
            manualCompactionTurns.insert(id)
            do {
                if provider.followUpMode == .stdin, isAlive(id), let line = provider.buildUserMessage(prompt) {
                    try engine.write(sessionId: id, line)
                } else {
                    try launch(session, prompt: prompt, resume: true)
                    // `launch` marks the chat running with no detail.
                    setStatus(id, .running, detail: Self.compactingDetail)
                }
            } catch {
                manualCompactionTurns.remove(id)
                finishCompaction(id, CompactionMarker.failed(error.localizedDescription))
                throw error
            }
        case .sideChannel(let compactor):
            let override = providerOverrides[provider.id]?.path.flatMap { $0.isEmpty ? nil : $0 }
            let request = CompactionRequest(sessionId: conversation, cwd: session.worktreePath ?? executor.homeDirectory,
                                            model: session.model ?? agentDefaults[provider.id]?.model, binaryOverride: override)
            let executor = self.executor
            let started = Date()
            compactions[id] = Task { [weak self] in
                let marker: CompactionMarker
                do {
                    let result = try await compactor.compact(request, executor: executor)
                    marker = .finished(result, trigger: .manual, durationMs: Int(Date().timeIntervalSince(started) * 1000))
                } catch is CancellationError {
                    marker = .failed("Stopped.")
                } catch {
                    marker = .failed(error.localizedDescription)
                }
                self?.finishCompaction(id, marker)
            }
        }
    }

    /// A side channel compacting: no agent runs, but Stop cancels it.
    func isCompactingAside(_ id: String) -> Bool { compacting.contains(id) && compactions[id] != nil }

    /// Quitting: cancels every side-channel compaction and waits, briefly, for
    /// each to stop its helpers (`opencode serve` runs in its own session, so
    /// Abstract exiting doesn't hang it up).
    func stopAllCompactions() async {
        let tasks = Array(compactions.values)
        for task in tasks { task.cancel() }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { for task in tasks { await task.value } }
            group.addTask { try? await Task.sleep(for: .seconds(2)) }
            await group.next()
            group.cancelAll()
        }
    }

    /// Logs how a compaction ended, when Abstract ran it, and frees the chat,
    /// back to the status it had before compacting started (its agent may
    /// not be running any more, so never `.idle`, which means alive and waiting).
    func finishCompaction(_ id: String, _ marker: CompactionMarker) {
        engine.record(sessionId: id, marker.line)
        let restore = compactionReturnStatus[id]
        endCompacting(id)
        setStatus(id, restore?.0 ?? .finished, detail: restore?.1)
    }
}
