import AppKit
import AbstractCore

/// Workflows: profiles taking turns on one chat. Each step hands the chat to
/// its profile (another agent gets a handover, as when you switch agents
/// yourself) and asks it to do its part; when its turn ends the next step
/// starts, or the chat waits for you, as the step says.
extension AppModel {
    // MARK: Saved workflows

    func workflow(_ id: String?) -> Workflow? {
        guard let id else { return nil }
        return workflows.first { $0.id == id }
    }

    func saveWorkflow(_ workflow: Workflow) {
        try? store.save(workflow)
        if let index = workflows.firstIndex(where: { $0.id == workflow.id }) {
            workflows[index] = workflow
        } else {
            workflows.append(workflow)
            workflows.sort { ($0.sortOrder, $0.createdAt) < ($1.sortOrder, $1.createdAt) }
        }
    }

    func deleteWorkflow(_ id: String) {
        try? store.deleteWorkflow(id)
        workflows.removeAll { $0.id == id }
    }

    private var nextWorkflowOrder: Int { (workflows.map(\.sortOrder).max() ?? -1) + 1 }

    @discardableResult
    func addWorkflow() -> Workflow {
        let steps = profiles.prefix(2).map { WorkflowStep(profileId: $0.id) }
        let workflow = Workflow(name: "New workflow", steps: Array(steps), sortOrder: nextWorkflowOrder)
        saveWorkflow(workflow)
        return workflow
    }

    /// A ready-made workflow, with any profile it needs that isn't here yet.
    @discardableResult
    func addWorkflow(from template: WorkflowTemplate) -> Workflow {
        let (workflow, newProfiles) = template.make(existing: profiles, sortOrder: nextWorkflowOrder)
        for profile in newProfiles { saveProfile(profile) }
        saveWorkflow(workflow)
        return workflow
    }

    /// The workflow as a chat starting it now carries it.
    func workflowProgress(_ workflow: Workflow) -> WorkflowProgress {
        WorkflowProgress(workflow: workflow.snapshot(profiles: profiles))
    }

    // MARK: Running one

    /// Start `workflow` in a chat that exists already: its first step takes
    /// the chat over with `task`.
    func startWorkflow(_ workflow: Workflow, in sessionId: String, task: String, chain: Set<String> = []) throws {
        if let problem = workflow.problem(profiles: profiles) { throw AbstractError.message(problem) }
        guard session(sessionId) != nil else { throw AbstractError.notFound("chat") }
        if sessionId.hasPrefix(RemoteService.mirrorPrefix) {
            throw AbstractError.message("Start a workflow in a chat on another Mac from that Mac.")
        }
        let progress = workflowProgress(workflow)
        try takeStep(sessionId, progress: progress,
                     message: WorkflowEngine.firstMessage(progress.workflow, task: task), chain: chain)
    }

    /// On to the next step of a chat waiting for you.
    func continueWorkflow(_ sessionId: String) {
        if let (_, host) = RemoteService.split(sessionId) {
            remoteAction(sessionId, .continueWorkflow(sessionId: host))
            return
        }
        guard let progress = session(sessionId)?.workflow, progress.isActive, progress.next != nil else { return }
        if turnInProgress(sessionId) {
            flash("The current step is still working; it moves on when its turn ends.", isError: true)
            return
        }
        advance(sessionId, to: progress.step + 1)
    }

    /// Stop the chat's workflow where it is; the chat stays with its agent.
    func stopWorkflow(_ sessionId: String) {
        if let (_, host) = RemoteService.split(sessionId) {
            remoteAction(sessionId, .stopWorkflow(sessionId: host))
            return
        }
        updateWorkflow(sessionId) { $0.state = .stopped; $0.note = nil }
    }

    /// A turn ended in a chat: its workflow moves on if the step is done.
    /// Returns whether the chat was handed on, so nothing else reads the
    /// turn's end as the chat waiting for you.
    func workflowTurnEnded(_ sessionId: String, _ status: SessionStatus, stopped: Bool) -> Bool {
        guard let s = session(sessionId), !sessionId.hasPrefix(RemoteService.mirrorPrefix) else { return false }
        let next = WorkflowEngine.afterTurn(s.workflow, status: status, stopped: stopped,
                                            queued: !engine.queued(sessionId: sessionId).isEmpty,
                                            backgroundTasks: runningBackgroundTasks(sessionId))
        switch next {
        case .none:
            return false
        case .advance(let index):
            advance(sessionId, to: index)
            return true
        case .waitForYou(let index):
            updateWorkflow(sessionId) { $0.state = .waiting }
            let upcoming = s.workflow?.workflow.steps[index].profileName ?? "the next step"
            let watching = NSApp.isActive && destination == .session(sessionId)
            if notifyAttention, !watching {
                Notifier.shared.post(title: "\(s.name) is ready for \(upcoming)",
                                     body: "Look over the step that just finished, then continue the workflow.", sessionId: sessionId)
            }
            return false
        case .finished:
            updateWorkflow(sessionId) { $0.state = .finished }
            engine.record(sessionId: sessionId, OutputLine(stream: .note, line: "\(s.workflow?.workflow.name ?? "Workflow") finished."))
            automationEvent(.workflowFinished, in: sessionId)
            return false
        }
    }

    /// Hand the chat to step `index`.
    private func advance(_ sessionId: String, to index: Int) {
        guard var progress = session(sessionId)?.workflow, progress.workflow.steps.indices.contains(index) else { return }
        progress.step = index
        progress.state = .working
        progress.note = nil
        let message = WorkflowEngine.message(progress.workflow, step: index,
                                             profileName: progress.current?.resolve(in: profiles)?.name ?? progress.current?.profileName ?? "")
        do {
            try takeStep(sessionId, progress: progress, message: message, chain: eventChains[sessionId] ?? [])
        } catch {
            updateWorkflow(sessionId) { $0.state = .stopped; $0.note = error.localizedDescription }
            flash(error.localizedDescription, isError: true)
        }
    }

    /// The chat goes to `progress`'s current step: its profile's agent,
    /// model, effort, permissions and instructions, then `message`.
    private func takeStep(_ sessionId: String, progress: WorkflowProgress, message: String, chain: Set<String>) throws {
        guard let profile = progress.current?.resolve(in: profiles) else {
            throw AbstractError.message("Step \(progress.step + 1)'s profile was deleted, so the workflow stopped.")
        }
        // Agent, model and effort the way a switch you make goes: another
        // agent gets a handover with the message.
        setAgent(sessionId, providerId: profile.providerId, model: profile.model, effort: profile.effort)
        guard var s = session(sessionId) else { return }
        let instructionsChanged = s.profileInstructions != profile.snapshot.nonBlankInstructions
            || s.permissionPolicy != profile.permissionPolicy
        s.permissionPolicy = profile.permissionPolicy
        s.apply(profile.snapshot)
        s.workflow = progress
        try? store.save(s)
        reload()
        // New instructions and permissions take effect when the agent starts again.
        if instructionsChanged, isAlive(sessionId) { needsRelaunch.insert(sessionId) }
        engine.record(sessionId: sessionId, OutputLine(stream: .note, line: WorkflowEngine.stepNote(
            progress.workflow, step: progress.step, profileName: profile.name)))
        try sendFollowUp(sessionId, text: message, chain: chain)
    }

    private func updateWorkflow(_ sessionId: String, _ change: (inout WorkflowProgress) -> Void) {
        guard var s = session(sessionId), var progress = s.workflow else { return }
        change(&progress)
        guard progress != s.workflow else { return }
        s.workflow = progress
        try? store.save(s)
        reload()
    }

    // MARK: Events

    /// Something happened to a chat: start the automations listening for it.
    func automationEvent(_ event: AutomationEvent, in sessionId: String) {
        guard !sessionId.hasPrefix(RemoteService.mirrorPrefix), let s = session(sessionId), let scheduler else { return }
        let occurrence = AutomationEventOccurrence(event: event, sessionId: sessionId, projectId: s.projectId,
                                                   chain: eventChains[sessionId] ?? [])
        for a in AutomationEvents.automations(for: occurrence, in: automations) {
            Task { await scheduler.fire(a, trigger: .event, occurrence: occurrence) }
        }
    }

    /// Pull requests that opened or merged since they were last seen,
    /// remembered across launches so each is told once.
    func notePullRequestEvents() {
        let now = pullRequests.filter { !$0.key.hasPrefix(RemoteService.mirrorPrefix) && session($0.key) != nil }
            .mapValues { AutomationEvents.PullRequestMark(number: $0.number, state: $0.state,
                                                          createdAt: $0.createdAt, updatedAt: $0.updatedAt) }
        let since = store.setting("automationPullRequestsSince", as: Date.self) ?? {
            let date = Date()
            try? store.setSetting("automationPullRequestsSince", date)
            return date
        }()
        let seen = store.setting("automationPullRequestsSeen", as: [String: String].self) ?? [:]
        var (events, updated) = AutomationEvents.pullRequestChanges(seen: seen, now: now, since: since)
        updated = updated.filter { session($0.key) != nil }
        if updated != seen { try? store.setSetting("automationPullRequestsSeen", updated) }
        for (sessionId, event) in events { automationEvent(event, in: sessionId) }
    }
}
