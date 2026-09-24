import Foundation
import Synchronization

/// Everything a model picker offers for one agent.
public struct ModelCatalog: Sendable, Hashable, Codable {
    /// What the account runs when neither the CLI's config nor Abstract names
    /// a model (Claude's "default" entry). nil when the CLI doesn't say.
    public var accountDefault: ModelOption?
    /// The account's models, in the CLI's own order.
    public var models: [ModelOption]
    /// Pinned versions offered on top of the account's aliases.
    public var versions: [ModelOption]

    public init(accountDefault: ModelOption? = nil, models: [ModelOption], versions: [ModelOption] = []) {
        self.accountDefault = accountDefault; self.models = models; self.versions = versions
    }

    public static let empty = ModelCatalog(models: [])

    public func option(_ id: String) -> ModelOption? {
        models.first { $0.id == id } ?? versions.first { $0.id == id }
    }

    /// What runs when no model is passed: the model named in the CLI's own
    /// config (`configured`) when there is one, else the account default.
    public func defaultOption(configured: String?) -> ModelOption? {
        guard let configured, !configured.isEmpty else { return accountDefault }
        return option(configured) ?? ModelOption(id: configured, label: configured)
    }

    /// Name for an option that says which concrete model it runs: an alias's
    /// pinned version when the catalogue has one ("Opus 5.5 · 1M context"
    /// for "opus[1m]"), else its own label.
    public func resolvedLabel(_ option: ModelOption) -> String {
        option.resolvedId.flatMap { id in versions.first { $0.id == id }?.label } ?? option.label
    }
}

/// Spawn-and-wait plumbing for asking a CLI about itself.
enum ModelDiscovery {
    /// Spawns `spec` and returns the first stdout line `match` accepts, then
    /// stops the process. nil when it exits first, fails to spawn or times out.
    static func firstLine(_ executor: any Executor, _ spec: LaunchSpec, timeout: Duration,
                          where match: @escaping @Sendable (String) -> Bool) async -> String? {
        let gate = ProbeGate()
        let timer = Task {
            try? await Task.sleep(for: timeout)
            gate.finish(nil)
        }
        defer { timer.cancel() }
        return await withCheckedContinuation { continuation in
            guard gate.arm(continuation) else { return }
            do {
                let process = try executor.spawn(
                    spec,
                    onLine: { line in if line.stream == .stdout, match(line.line) { gate.finish(line.line) } },
                    onExit: { _ in gate.finish(nil) })
                gate.attach(process)
            } catch {
                gate.finish(nil)
            }
        }
    }
}

/// Resumes the probe's continuation exactly once, from whichever of line,
/// exit, spawn failure or timeout comes first, and stops the process.
private final class ProbeGate: Sendable {
    private struct State {
        var continuation: CheckedContinuation<String?, Never>?
        var process: (any RunningProcess)?
        var done = false
    }

    private let state = Mutex(State())

    /// false when the probe already finished (the timeout beat the spawn).
    func arm(_ continuation: CheckedContinuation<String?, Never>) -> Bool {
        let armed = state.withLock { s in
            if s.done { return false }
            s.continuation = continuation
            return true
        }
        if !armed { continuation.resume(returning: nil) }
        return armed
    }

    /// Lines can arrive before `spawn` returns, so a probe that is already
    /// over stops the process here.
    func attach(_ process: any RunningProcess) {
        let done = state.withLock { s in
            s.process = process
            return s.done
        }
        if done { stop(process) }
    }

    func finish(_ value: String?) {
        let pending = state.withLock { s -> (CheckedContinuation<String?, Never>?, (any RunningProcess)?)? in
            if s.done { return nil }
            s.done = true
            defer { s.continuation = nil }
            return (s.continuation, s.process)
        }
        guard let (continuation, process) = pending else { return }
        continuation?.resume(returning: value)
        if let process { stop(process) }
    }

    private func stop(_ process: any RunningProcess) {
        process.closeStdin()
        process.terminate()
    }
}
