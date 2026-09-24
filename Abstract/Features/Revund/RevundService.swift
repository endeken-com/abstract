import AppKit
import Synchronization
import AbstractCore

/// Revund in Abstract: reviews of a chat's changes through the Revund CLI,
/// the review loop after each of the agent's turns, what Revund said on the
/// chat's pull request, and the account the CLI uses.
@Observable
final class RevundService {
    static let shared = RevundService()

    /// What happens when an agent finishes a turn.
    enum AfterTurn: String, CaseIterable, Identifiable {
        case off, review, fix
        var id: String { rawValue }
        var title: String {
            switch self {
            case .off: "Nothing"
            case .review: "Review the changes"
            case .fix: "Review and send findings to the agent"
            }
        }
    }

    static let afterTurnKey = "revund.afterTurn"
    /// The least severe finding the loop sends back.
    static let sendAtKey = "revund.sendAt"
    static let keyStoredKey = "integrations.revund.key"
    /// Rounds the loop sends before it leaves the rest to you.
    static let maxRounds = 2

    enum Phase: Equatable {
        case running(String?)
        case done(RevundReport)
        case nothing
        case failed(String)
    }

    /// A local review of one chat's changes.
    struct Run: Equatable {
        var scope: String
        var phase: Phase
        var at: Date
        var automatic: Bool
    }

    private(set) var runs: [String: Run] = [:]
    /// Findings taken off the list: dismissed, or added to your review.
    private(set) var handled: [String: Set<String>] = [:]
    /// Revund's check runs and findings on each chat's pull request.
    private(set) var pullRequests: [String: RevundPullRequestReview] = [:]

    private(set) var cliVersion: String?
    private(set) var cliChecked = false
    private(set) var account: RevundAccount?
    private(set) var signingIn = false
    private(set) var signInOutput: [String] = []

    @ObservationIgnored private var processes: [String: RunningProcess] = [:]
    @ObservationIgnored private var rounds: [String: Int] = [:]
    @ObservationIgnored private var cachedKey: String??

    var isInstalled: Bool { cliVersion != nil }
    var afterTurn: AfterTurn { UserDefaults.standard.string(forKey: Self.afterTurnKey).flatMap(AfterTurn.init) ?? .off }
    var sendAt: RevundFinding.Severity { UserDefaults.standard.string(forKey: Self.sendAtKey).flatMap(RevundFinding.Severity.init) ?? .warning }

    // MARK: Status

    func refreshStatus(_ executor: any Executor) async {
        if await executor.which(Revund.binary) != nil,
           let out = try? await executor.run(Revund.binary, ["--version"], cwd: nil), out.ok {
            // "revund 0.4.1 · abc1234 · 2026-07-21"
            cliVersion = out.stdout.split(separator: " ").dropFirst().first.map(String.init) ?? out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            cliVersion = nil
        }
        account = RevundAccount.read(home: executor.homeDirectory)
        cliChecked = true
    }

    // MARK: API key

    var hasKey: Bool { UserDefaults.standard.bool(forKey: Self.keyStoredKey) }

    private func apiKey() -> String? {
        guard hasKey else { return nil }
        if let cachedKey { return cachedKey }
        let key = Keychain.read("revund-api-key")
        cachedKey = .some(key)
        return key
    }

    func saveKey(_ key: String?) {
        let key = key?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = key?.isEmpty == false ? key : nil
        Keychain.write("revund-api-key", value)
        cachedKey = .some(value)
        UserDefaults.standard.set(value != nil, forKey: Self.keyStoredKey)
    }

    private func environment() -> [String: String] {
        apiKey().map { ["REVUND_API_KEY": $0] } ?? [:]
    }

    // MARK: Sign in

    /// `revund login`: it opens the browser and prints a code to confirm there.
    func signIn(_ executor: any Executor) {
        guard !signingIn else { return }
        signingIn = true
        signInOutput = []
        let spec = LaunchSpec(command: Revund.binary, args: ["login"], cwd: executor.homeDirectory, keepStdinOpen: false)
        do {
            _ = try executor.spawn(spec, onLine: { line in
                let text = line.line.trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { return }
                Task { @MainActor in self.signInOutput.append(text) }
            }, onExit: { _ in
                Task { @MainActor in
                    self.signingIn = false
                    await self.refreshStatus(executor)
                }
            })
        } catch {
            signingIn = false
            signInOutput = [error.localizedDescription]
        }
    }

    // MARK: Local reviews

    func run(_ sessionId: String) -> Run? { runs[sessionId] }

    var isRunningAny: Bool { runs.values.contains { if case .running = $0.phase { true } else { false } } }

    func isRunning(_ sessionId: String) -> Bool {
        if case .running = runs[sessionId]?.phase { return true }
        return false
    }

    /// The findings still to look at.
    func findings(_ sessionId: String) -> [RevundFinding] {
        guard case .done(let report) = runs[sessionId]?.phase else { return [] }
        let gone = handled[sessionId] ?? []
        return report.findings.filter { !gone.contains($0.id) }
    }

    func findings(_ sessionId: String, path: String, line: Int) -> [RevundFinding] {
        findings(sessionId).filter { $0.file == path && $0.line == line }
    }

    /// Reviews the chat's changes: what isn't committed, or everything on its
    /// branch. Returns when the review is done.
    func review(_ sessionId: String, branch: Bool, model: AppModel, automatic: Bool = false) async {
        guard !isRunning(sessionId), case .ready(let context) = model.diffAvailability(sessionId) else { return }
        guard isInstalled else {
            runs[sessionId] = Run(scope: "", phase: .failed("Install the Revund CLI to review here: \(Revund.install)"), at: Date(),
                                  automatic: automatic)
            return
        }
        var scope = Revund.Scope.uncommitted
        var label = "uncommitted changes"
        if branch, let base = await Diff.resolveBase(context.executor, worktree: context.worktree, preferred: context.baseRef),
           let sha = await Diff.mergeBase(context.executor, worktree: context.worktree, base: base) {
            scope = .since(sha)
            label = "this branch"
        }
        handled[sessionId] = nil
        runs[sessionId] = Run(scope: label, phase: .running(nil), at: Date(), automatic: automatic)
        let result = await execute(sessionId, context: context, scope: scope)
        processes[sessionId] = nil
        guard isRunning(sessionId) else { return } // cancelled
        runs[sessionId]?.phase = result
        runs[sessionId]?.at = Date()
    }

    func cancel(_ sessionId: String) {
        processes[sessionId]?.terminate()
        processes[sessionId] = nil
        runs[sessionId] = nil
    }

    func clear(_ sessionId: String) {
        guard !isRunning(sessionId) else { return }
        runs[sessionId] = nil
        handled[sessionId] = nil
    }

    private func execute(_ sessionId: String, context: DiffContext, scope: Revund.Scope) async -> Phase {
        let spec = LaunchSpec(command: Revund.binary, args: Revund.reviewArgs(repo: context.worktree, scope: scope),
                              cwd: context.worktree, env: environment(), keepStdinOpen: false)
        let output = Output()
        let code: Int32? = await withCheckedContinuation { continuation in
            do {
                processes[sessionId] = try context.executor.spawn(spec, onLine: { line in
                    if line.stream == .stderr {
                        output.lines.withLock { $0.err.append(line.line) }
                        if let progress = Revund.progress(line.line) {
                            Task { @MainActor in
                                if case .running = self.runs[sessionId]?.phase { self.runs[sessionId]?.phase = .running(progress) }
                            }
                        }
                    } else {
                        output.lines.withLock { $0.out.append(line.line) }
                    }
                }, onExit: { code in continuation.resume(returning: code) })
            } catch {
                output.lines.withLock { $0.err.append(error.localizedDescription) }
                continuation.resume(returning: -1)
            }
        }
        let (out, err) = output.lines.withLock { ($0.out.joined(separator: "\n"), $0.err.joined(separator: "\n")) }
        if code == 0, let report = try? Revund.decode(stdout: out) { return .done(report) }
        if Revund.isNothingToReview(err) { return .nothing }
        let reason = err.split(separator: "\n").map(String.init).last { $0.hasPrefix("Error:") }
            ?? err.split(separator: "\n").last.map(String.init) ?? "Revund exited with code \(code ?? -1)."
        return .failed(reason.replacingOccurrences(of: "Error: ", with: ""))
    }

    // MARK: Findings

    /// A finding as one of your review comments, sent with the rest.
    func addToReview(_ finding: RevundFinding, sessionId: String, model: AppModel) {
        guard let line = finding.line else { return }
        var text = "Revund (\(finding.severity.rawValue), \(finding.pass)): \(finding.body)"
        if let why = finding.why { text += "\n\(why)" }
        if let suggest = finding.suggest { text += "\nSuggested fix:\n\(suggest)" }
        let code = finding.snippet?.first { $0.hit == true }?.text ?? ""
        model.addComment(sessionId, on: LineRef(path: finding.file, line: line, side: .new), code: code, text: text, source: "revund")
        handled[sessionId, default: []].insert(finding.id)
    }

    func hide(_ finding: RevundFinding, sessionId: String) {
        handled[sessionId, default: []].insert(finding.id)
    }

    /// Tells Revund not to flag it again in this repository.
    func dismiss(_ finding: RevundFinding, reason: String, sessionId: String, model: AppModel) async {
        hide(finding, sessionId: sessionId)
        guard let fingerprint = finding.fingerprint, case .ready(let context) = model.diffAvailability(sessionId) else { return }
        let out = try? await context.executor.run(Revund.binary, ["feedback", "dismiss", fingerprint, "--reason", reason,
                                                                  "--repo", context.worktree], cwd: context.worktree)
        if out?.ok != true { model.flash("Revund couldn't record the dismissal.", isError: true) }
    }

    /// Sends findings to the chat's agent to fix.
    func send(_ findings: [RevundFinding], scope: String, to sessionId: String, model: AppModel) {
        guard !findings.isEmpty else { return }
        do {
            try model.sendFollowUp(sessionId, text: "Revund reviewed \(scope). Fix what it found; if a finding doesn't apply, say why.",
                                   attachments: [Revund.attachment(findings, scope: scope)])
            for f in findings { handled[sessionId, default: []].insert(f.id) }
        } catch {
            model.flash(error.localizedDescription, isError: true)
        }
    }

    // MARK: The loop

    /// You wrote to the agent yourself: the loop starts counting again.
    func userWrote(_ sessionId: String) { rounds[sessionId] = 0 }

    /// The agent finished a turn: review what it did and, if asked, send it
    /// back what Revund found, for a few rounds at most.
    func turnEnded(_ sessionId: String, model: AppModel) {
        let mode = afterTurn
        guard mode != .off, !model.isDemo, isInstalled, !isRunning(sessionId),
              !sessionId.hasPrefix(RemoteService.mirrorPrefix), case .ready(let context) = model.diffAvailability(sessionId) else { return }
        Task {
            // What this turn left uncommitted; if the agent committed it all, its branch.
            let dirty = await Diff.isDirty(context.executor, worktree: context.worktree)
            await review(sessionId, branch: !dirty, model: model, automatic: true)
            guard mode == .fix, let run = runs[sessionId] else { return }
            let due = findings(sessionId).filter { $0.severity <= sendAt }
            guard !due.isEmpty, model.session(sessionId)?.status != .running else { return }
            let round = rounds[sessionId, default: 0]
            guard round < Self.maxRounds else {
                model.flash("Revund still finds \(Revund.summary(due)). The rest is up to you.")
                return
            }
            rounds[sessionId] = round + 1
            send(due, scope: run.scope, to: sessionId, model: model)
        }
    }

    // MARK: Pull requests

    func loadPullRequest(_ sessionId: String, number: Int, model: AppModel) async {
        guard let root = model.project(model.session(sessionId)?.projectId)?.rootPath else { return }
        if let review = try? await Revund.pullRequestReview(model.executor, repo: root, number: number) {
            pullRequests[sessionId] = review
        } else {
            pullRequests[sessionId] = nil
        }
    }

    // MARK: Demo

    func seed(_ sessionId: String, scope: String, report: RevundReport) {
        runs[sessionId] = Run(scope: scope, phase: .done(report), at: Date(), automatic: false)
    }

    func seedPullRequest(_ sessionId: String, _ review: RevundPullRequestReview) { pullRequests[sessionId] = review }
}

/// What a review process prints, gathered from its background queue.
private final class Output: Sendable {
    let lines = Mutex<(out: [String], err: [String])>(([], []))
}
