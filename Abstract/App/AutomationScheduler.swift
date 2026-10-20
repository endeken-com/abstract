import Foundation
import AbstractCore

/// Fires automations on schedule while Abstract runs. Closing the window
/// keeps the app (and this loop) alive; quitting stops it, and what a fire
/// missed while closed does on launch is the automation's own choice.
@MainActor
final class AutomationScheduler {
    private unowned let model: AppModel
    private var loop: Task<Void, Never>?
    /// Automations mid-fire, so a re-evaluation cannot launch one twice.
    private var firing: Set<String> = []
    /// Automations owed one run when the run still going finishes.
    private var waiting: Set<String> = []

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
        func soon(_ date: Date) { earliest = min(earliest ?? date, date) }
        // Pausing or deleting an automation drops the run it was owed.
        waiting = waiting.filter { id in model.automations.contains { $0.id == id && $0.enabled } }

        // Runs owed to automations whose last run was still going: each
        // starts as soon as that run's chat is quiet again. Checked on a
        // short leash below, since nothing says when a turn ends.
        var firedWaiting: Set<String> = []
        for a in model.automations where a.enabled && waiting.contains(a.id) {
            guard !firing.contains(a.id), !lastRunActive(a) else { continue }
            waiting.remove(a.id)
            firedWaiting.insert(a.id)
            await fire(a, trigger: .schedule)
        }

        for a in model.automations where a.enabled {
            guard !firedWaiting.contains(a.id) else {
                if let next = a.nextRunAt { soon(next) }
                continue
            }
            guard let due = a.nextRunAt ?? a.nextOccurrence(after: now) else { continue }
            var nextRun = due
            if due <= now {
                guard !firing.contains(a.id) else { soon(now.addingTimeInterval(15)); continue }
                let occurrences = a.dueOccurrences(from: due, through: now)
                let decision = AutomationScheduling.decision(
                    for: a, dueCount: occurrences.count, missed: now.timeIntervalSince(due) > 300,
                    lastRunActive: lastRunActive(a), alreadyWaiting: waiting.contains(a.id),
                    baseMoved: await baseMoved(a))
                var skippedAt = 0
                for skip in decision.skips {
                    for _ in 0..<skip.count {
                        let at = occurrences[min(skippedAt, occurrences.count - 1)]
                        try? model.store.save(AutomationRun.skipped(automationId: a.id, reason: skip.reason, at: at))
                        skippedAt += 1
                    }
                }
                if decision.runAfterCurrentFinishes { waiting.insert(a.id) }
                for _ in 0..<decision.fires { await fire(a, trigger: .schedule) }
                guard let after = a.nextOccurrence(after: now) else { recordNextRun(nil, for: a); continue }
                nextRun = after
            }
            recordNextRun(nextRun, for: a)
            soon(nextRun)
        }
        if !waiting.isEmpty { soon(now.addingTimeInterval(15)) }
        model.automations = (try? model.store.automations()) ?? model.automations
        guard let earliest else { return 300 }
        return min(max(earliest.timeIntervalSinceNow, 1), 300)
    }

    /// The last run that started is still going: it is being set up, or
    /// its chat's agent is mid-turn (a chat it continues counts too —
    /// that chat busy is the run busy). A chat waiting on a permission
    /// is still going; one idle for a follow-up is not.
    private func lastRunActive(_ a: Automation) -> Bool {
        let runs = (try? model.store.runs(automationId: a.id, limit: 10)) ?? []
        guard let last = runs.first(where: { $0.status != .skipped }) else { return false }
        if last.status == .creating { return true }
        let chats = [last.sessionId, a.workspaceMode == .pinned ? a.pinnedSessionId : nil].compactMap { $0 }
        return chats.contains { id in
            guard let status = model.session(id)?.status else { return false }
            return status == .provisioning || status == .running || status == .waitingInput
        }
    }

    /// The project its runs branch from, through its chat when it
    /// continues one someone else started. This Mac's record only: a
    /// paired Mac's project names a folder over there.
    private func baseProject(_ a: Automation) -> Project? {
        let id = a.projectId ?? a.pinnedSessionId.flatMap { model.session($0)?.projectId }
        return id.flatMap { id in model.projects.first { $0.id == id } }
    }

    /// The base's commit now, on this Mac. A run that starts on a paired
    /// Mac branches from that Mac's copy, which this one can't read.
    private func currentBaseCommit(_ a: Automation) async -> String? {
        guard a.deviceId == nil, let project = baseProject(a) else { return nil }
        return await Git.commit(model.executor, root: project.rootPath, ref: project.defaultBaseRef)
    }

    /// Whether the base moved since the last run, for an automation that
    /// only runs when it has; nil for any other, and when it can't tell.
    private func baseMoved(_ a: Automation) async -> Bool? {
        guard a.onlyWhenChanged else { return nil }
        let runs = (try? model.store.runs(automationId: a.id, limit: 50)) ?? []
        return AutomationScheduling.baseMoved(lastRunCommit: runs.first { $0.baseCommit != nil }?.baseCommit,
                                              currentCommit: await currentBaseCommit(a))
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
        run.baseCommit = await currentBaseCommit(a)
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
                try await model.deliverAutomationRun(a.prompt, to: chat.id)
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
            let now = Date()
            // A placeholder: the agent's first reply or its pull request names it.
            return try await newChat(a, name: AutomationRunNaming.provisional(a.name, at: now), nameSource: .fallback,
                                     slug: WorktreeNaming.runBranch(automationName: a.name, at: now))
        }
    }

    /// In its project, set up fresh in a worktree of its own; with no
    /// project, a standalone chat. On a paired Mac when the automation
    /// runs on one: the chat starts through the remote channel, and a Mac
    /// that can't start it fails the run with that reason.
    private func newChat(_ a: Automation, name: String, nameSource: ChatNameSource = .manual, slug: String? = nil) async throws -> String {
        // A run starts from its profile as it is now (ABS-101); a profile
        // that was deleted leaves the automation on its own settings.
        let profile = model.profile(a.profileId)
        let run = a.resolved(with: profile)
        if let deviceId = a.deviceId {
            let link = model.remote.links[deviceId]
            let deviceName = link?.device.peer.name
                ?? model.remote.paired.first { $0.id == deviceId }?.peer.name ?? "That Mac"
            let start = try AutomationDeviceRun.plan(
                a, deviceName: deviceName, snapshot: link?.state == .online ? link?.snapshot : nil,
                localProject: a.projectId.flatMap { id in model.projects.first { $0.id == id } },
                name: name, nameSource: nameSource, slug: slug, profile: profile)
            return try await model.remote.startAutomationRun(on: deviceId, start)
        }
        return try await model.startChat(projectId: run.projectId, providerId: run.providerId, prompt: run.prompt, baseRef: nil,
                                         policy: run.permissionPolicy, model: run.model, effort: run.effort,
                                         name: name, nameSource: nameSource, slug: run.projectId == nil ? nil : slug,
                                         automationId: run.id, profile: profile?.snapshot, select: false)
    }
}
