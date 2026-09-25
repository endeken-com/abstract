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

    /// Start a run: its instructions go to its chat, a new one or the one
    /// it runs in. A run counts as created once they have; how the agent's
    /// work went is the chat's own status.
    @discardableResult
    func fire(_ a: Automation, trigger: RunTrigger) async -> AutomationRun {
        firing.insert(a.id)
        defer { firing.remove(a.id) }
        var run = AutomationRun(automationId: a.id, trigger: trigger)
        try? model.store.save(run)
        do {
            let sessionId = try await startRun(a)
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

    private func startRun(_ a: Automation) async throws -> String {
        switch a.workspaceMode {
        case .pinned:
            if let chat = model.session(a.pinnedSessionId) {
                try model.deliverAutomationRun(a.prompt, to: chat.id)
                return chat.id
            }
            // A chat of its own: made on the first run (and again if it was
            // deleted), then every run continues it.
            let id = try await newChat(a, name: a.name)
            // Onto a fresh copy, unless it was pointed at another chat meanwhile.
            if var fresh = try model.store.automation(a.id), fresh.workspaceMode == .pinned, fresh.pinnedSessionId == a.pinnedSessionId {
                fresh.pinnedSessionId = id
                try model.store.save(fresh)
            }
            return id
        case .newWorktree:
            let stamp = Date().formatted(.dateTime.month(.abbreviated).day().hour().minute())
            let slug = "auto-\(WorktreeNaming.slugify(a.name))-\(Date().formatted(.iso8601.year().month().day().dateSeparator(.omitted)))"
            return try await newChat(a, name: "\(a.name) · \(stamp)", slug: slug)
        }
    }

    /// In its project, set up fresh in a worktree of its own; with no
    /// project, a standalone chat.
    private func newChat(_ a: Automation, name: String, slug: String? = nil) async throws -> String {
        try await model.startChat(projectId: a.projectId, providerId: a.providerId, prompt: a.prompt, baseRef: nil,
                                  policy: a.permissionPolicy, model: a.model, effort: a.effort,
                                  name: name, slug: a.projectId == nil ? nil : slug, automationId: a.id, select: false)
    }
}
