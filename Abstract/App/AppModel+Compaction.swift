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
        if session.status == .running { throw AbstractError.message("Wait for the agent to finish its turn, then compact.") }
        guard let conversation = session.providerSessionId else {
            throw AbstractError.message("There's no conversation to compact yet.")
        }

        beginCompacting(id)
        engine.record(sessionId: id, CompactionMarker.started(.manual).line)
        markTurnStarted(id)
        setStatus(id, .running, detail: Self.compactingDetail)

        switch compaction {
        case .inStream(let prompt):
            do {
                if provider.followUpMode == .stdin, isAlive(id), let line = provider.buildUserMessage(prompt) {
                    try engine.write(sessionId: id, line)
                } else {
                    try launch(session, prompt: prompt, resume: true)
                    // `launch` marks the chat running with no detail.
                    setStatus(id, .running, detail: Self.compactingDetail)
                }
            } catch {
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

    /// Logs how a compaction ended, when Abstract ran it, and frees the chat.
    func finishCompaction(_ id: String, _ marker: CompactionMarker) {
        engine.record(sessionId: id, marker.line)
        endCompacting(id)
        setStatus(id, .idle)
    }
}
