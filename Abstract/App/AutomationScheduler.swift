import Foundation
import AbstractCore

/// Fires automations on schedule while Abstract runs. Closing the window
/// keeps the app (and this loop) alive; quitting stops it, and a fire missed
/// while closed runs on launch only when the automation has catch-up on.
@MainActor
final class AutomationScheduler {
    private unowned let model: AppModel
    private var loop: Task<Void, Never>?
    /// Automations mid-fire, so a re-evaluation cannot launch one twice.
    private var firing: Set<String> = []

    init(model: AppModel) { self.model = model }

    func start() {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let wait = await self.tick()
                try? await Task.sleep(for: .seconds(wait))
            }
        }
    }

    /// Re-evaluate now, e.g. after an automation was edited.
    func poke() { start() }

    /// Fire what is due, persist the next occurrence, return seconds to sleep.
    /// An automation's next run is the earliest next occurrence across its
    /// triggers, so triggers landing on the same minute fire it once.
    private func tick() async -> TimeInterval {
        let now = Date()
        var earliest: Date?
        for a in model.automations where a.enabled {
            guard let due = a.nextRunAt ?? a.nextOccurrence(after: now) else { continue }
            var nextRun = due
            if due <= now {
                guard !firing.contains(a.id) else { continue }
                let missed = now.timeIntervalSince(due) > 300
                if !missed || a.catchUp { await fire(a, trigger: .schedule) }
                guard let after = a.nextOccurrence(after: now) else { recordNextRun(nil, for: a); continue }
                nextRun = after
            }
            recordNextRun(nextRun, for: a)
            earliest = min(earliest ?? nextRun, nextRun)
        }
        model.automations = (try? model.store.automations()) ?? model.automations
        guard let earliest else { return 300 }
        return min(max(earliest.timeIntervalSinceNow, 1), 300)
    }

    /// Write only the next-run time, onto a fresh copy of the automation, so
    /// an edit saved while a run was firing is never overwritten by a stale
    /// one. When the edit changed the triggers, its save already computed the
    /// next run from them; a time worked out from the old ones is dropped.
    private func recordNextRun(_ date: Date?, for a: Automation) {
        guard var fresh = (try? model.store.automation(a.id)) ?? nil, fresh.enabled else { return }
        guard fresh.triggers == a.triggers, fresh.nextRunAt != date else { return }
        fresh.nextRunAt = date
        try? model.store.save(fresh)
    }

    /// Create the run and its workspace, then launch the agent. A run counts
    /// as created once its workspace exists (superset semantics); how the
    /// agent's work went is the session's own status.
    @discardableResult
    func fire(_ a: Automation, trigger: RunTrigger) async -> AutomationRun {
        firing.insert(a.id)
        defer { firing.remove(a.id) }
        var run = AutomationRun(automationId: a.id, trigger: trigger)
        try? model.store.save(run)
        do {
            let sessionId = try await startRun(a, runId: run.id)
            run.status = .created
            run.sessionId = sessionId
        } catch {
            run.status = .failed
            run.error = error.localizedDescription
            if model.notifyAutomationFailed {
                Notifier.shared.post(title: "\(a.name) failed", body: error.localizedDescription, sessionId: "")
            }
        }
        try? model.store.save(run)
        model.reload()
        return run
    }

    private func startRun(_ a: Automation, runId: String) async throws -> String {
        // Continue this automation's own previous session when asked and
        // possible; anything unavailable falls through to a fresh launch.
        if a.continueAgentSession, a.workspaceMode == .pinned,
           let previousId = try model.store.lastRun(automationId: a.id)?.sessionId,
           let previous = model.session(previousId), previous.providerId == a.providerId {
            if model.isAlive(previous.id) {
                try model.sendFollowUp(previous.id, text: a.prompt)
                return previous.id
            }
            if previous.providerSessionId != nil {
                try model.launch(previous, prompt: a.prompt, resume: true)
                return previous.id
            }
        }

        let project = model.project(a.projectId)
        let stamp = Date().formatted(.dateTime.month(.abbreviated).day().hour().minute())
        var session = Session(projectId: a.projectId, name: "\(a.name) · \(stamp)", providerId: a.providerId,
                              status: .provisioning, permissionPolicy: a.permissionPolicy, prompt: a.prompt, automationId: a.id,
                              model: a.model, effort: a.effort)

        if a.workspaceMode == .pinned, let pinned = model.session(a.pinnedSessionId), let path = pinned.worktreePath {
            session.worktreePath = path
            session.branch = pinned.branch
        } else if let project {
            let slug = "auto-\(WorktreeNaming.slugify(a.name))-\(Date().formatted(.iso8601.year().month().day().dateSeparator(.omitted)))"
            let ws = try await Workspace.provision(
                executor: model.executor, project: project, name: slug, baseRef: nil,
                template: project.worktreeTemplate ?? model.worktreeTemplate,
                prefix: project.branchPrefix ?? model.branchPrefix
            )
            session.worktreePath = ws.path
            session.branch = ws.branch
        } else {
            session.worktreePath = try Workspace.scratchDirectory(runId: runId)
        }
        try model.store.save(session)
        model.reload()
        try model.launch(session, prompt: a.prompt, resume: false)
        return session.id
    }
}
