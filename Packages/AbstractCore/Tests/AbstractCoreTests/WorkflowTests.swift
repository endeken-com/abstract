import Foundation
import Testing
@testable import AbstractCore

@Suite struct WorkflowTests {
    let researcher = AgentProfile(id: "researcher", name: "UI Researcher", providerId: "claude", permissionPolicy: .ask,
                                  instructions: "Research the interface.")
    let developer = AgentProfile(id: "developer", name: "Developer", providerId: "claude", model: "opus",
                                 permissionPolicy: .autoEdits, instructions: "Build it.")
    let reviewer = AgentProfile(id: "reviewer", name: "Reviewer", providerId: "codex", effort: "high",
                                permissionPolicy: .ask, instructions: "Review it.")

    private var workflow: Workflow {
        Workflow(id: "ship", name: "Ship a screen", steps: [
            WorkflowStep(id: "1", profileId: "researcher", prompt: "Find three references first.", advance: .wait),
            WorkflowStep(id: "2", profileId: "developer"),
            WorkflowStep(id: "3", profileId: "reviewer", prompt: "Review the diff."),
        ], createdAt: Date(timeIntervalSinceReferenceDate: 800_000_000))
    }

    private func progress(step: Int, state: WorkflowProgress.State = .working) -> WorkflowProgress {
        WorkflowProgress(workflow: workflow.snapshot(profiles: [researcher, developer, reviewer]), step: step, state: state)
    }

    // MARK: Moving on

    @Test func aStepThatWaitsStopsForYou() {
        #expect(WorkflowEngine.afterTurn(progress(step: 0), status: .idle, stopped: false, queued: false, backgroundTasks: 0)
            == .waitForYou(next: 1))
    }

    @Test func anAutomaticStepHandsTheChatOn() {
        #expect(WorkflowEngine.afterTurn(progress(step: 1), status: .idle, stopped: false, queued: false, backgroundTasks: 0)
            == .advance(to: 2))
        // An agent that exits after each turn (Codex) ends it as finished.
        #expect(WorkflowEngine.afterTurn(progress(step: 1), status: .finished, stopped: false, queued: false, backgroundTasks: 0)
            == .advance(to: 2))
    }

    @Test func theLastStepFinishesTheWorkflow() {
        #expect(WorkflowEngine.afterTurn(progress(step: 2), status: .idle, stopped: false, queued: false, backgroundTasks: 0)
            == .finished)
    }

    @Test func aTurnThatDidNotEndCleanlyNeverMovesOn() {
        let p = progress(step: 1)
        #expect(WorkflowEngine.afterTurn(p, status: .idle, stopped: true, queued: false, backgroundTasks: 0) == .none)
        #expect(WorkflowEngine.afterTurn(p, status: .errored, stopped: false, queued: false, backgroundTasks: 0) == .none)
        #expect(WorkflowEngine.afterTurn(p, status: .waitingInput, stopped: false, queued: false, backgroundTasks: 0) == .none)
        // Your queued messages go first; the step ends after them.
        #expect(WorkflowEngine.afterTurn(p, status: .idle, stopped: false, queued: true, backgroundTasks: 0) == .none)
        #expect(WorkflowEngine.afterTurn(p, status: .idle, stopped: false, queued: false, backgroundTasks: 1) == .none)
    }

    @Test func onlyAWorkingWorkflowMovesOn() {
        for state in [WorkflowProgress.State.waiting, .finished, .stopped] {
            #expect(WorkflowEngine.afterTurn(progress(step: 1, state: state), status: .idle, stopped: false,
                                             queued: false, backgroundTasks: 0) == .none)
        }
        #expect(WorkflowEngine.afterTurn(nil, status: .idle, stopped: false, queued: false, backgroundTasks: 0) == .none)
    }

    // MARK: Messages

    @Test func theFirstStepsPromptGoesAheadOfTheTask() {
        let snapshot = workflow.snapshot(profiles: [researcher, developer, reviewer])
        #expect(WorkflowEngine.firstMessage(snapshot, task: "A settings screen") == "Find three references first.\n\nA settings screen")
        var plain = workflow
        plain.steps[0].prompt = "  "
        #expect(WorkflowEngine.firstMessage(plain.snapshot(profiles: [researcher]), task: "A settings screen") == "A settings screen")
    }

    @Test func aLaterStepIsToldWhereItStandsAndWhatToDo() {
        let snapshot = workflow.snapshot(profiles: [researcher, developer, reviewer])
        let middle = WorkflowEngine.message(snapshot, step: 1, profileName: "Developer")
        #expect(middle.contains("step 2 of 3"))
        #expect(middle.contains("“Ship a screen”"))
        #expect(middle.contains("Reviewer takes over after you."))
        #expect(middle.contains("do your part as Developer"))
        let last = WorkflowEngine.message(snapshot, step: 2, profileName: "Reviewer")
        #expect(last.hasSuffix("Review the diff."))
        #expect(!last.contains("takes over after you"))
    }

    // MARK: Snapshots and problems

    @Test func aSnapshotKeepsEachStepsProfileName() {
        let snapshot = workflow.snapshot(profiles: [researcher, developer])
        #expect(snapshot.steps.map(\.profileName) == ["UI Researcher", "Developer", "Deleted profile"])
        #expect(workflow.problem(profiles: [researcher, developer]) == "Step 3's profile was deleted.")
        #expect(workflow.problem(profiles: [researcher, developer, reviewer]) == nil)
        #expect(Workflow(name: "Empty").problem(profiles: []) == "It has no steps yet.")
    }

    @Test func takingAStepHandsTheChatToItsProfile() {
        var session = Session(projectId: nil, name: "Chat", providerId: "claude")
        session.apply(developer)
        let next = progress(step: 2)
        session.takeStep(reviewer, in: next)
        #expect(session.providerId == "codex")
        #expect(session.effort == "high")
        #expect(session.model == nil)
        #expect(session.permissionPolicy == .ask)
        #expect(session.profileName == "Reviewer")
        #expect(session.profileInstructions == "Review it.")
        #expect(session.workflow?.step == 2)
    }

    @Test func aChatCarriesItsWorkflowToAnotherMac() throws {
        var session = Session(projectId: nil, name: "Chat", providerId: "claude")
        session.workflow = progress(step: 1, state: .waiting)
        let decoded = try JSONDecoder().decode(Session.self, from: JSONEncoder().encode(session))
        #expect(decoded.workflow == session.workflow)
        // A chat from a Mac that knows no workflows reads without one.
        let older = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Session(projectId: nil, name: "Chat", providerId: "claude")))
        #expect(try JSONDecoder().decode(Session.self, from: JSONSerialization.data(withJSONObject: older)).workflow == nil)
    }

    // MARK: Templates

    @Test func aTemplateReusesProfilesByNameAndMakesTheRest() {
        let template = WorkflowTemplate.all[0]
        var implementer = AgentProfile.starters[0]
        implementer.id = "mine"
        let (made, newProfiles) = template.make(existing: [implementer], sortOrder: 3)
        #expect(made.steps.count == 4)
        #expect(made.steps[1].profileId == "mine")
        #expect(newProfiles.map(\.name) == ["UI Researcher", "Reviewer", "QA"])
        #expect(Set(newProfiles.map(\.id)).count == 3)
        #expect(newProfiles.allSatisfy { $0.id != WorkflowTemplate.uiResearcher.id })
        #expect(made.steps[0].advance == .wait)
        #expect(made.sortOrder == 3)
    }

    // MARK: Store

    @Test func workflowsAreSavedInOrder() throws {
        let store = try Store.inMemory()
        var second = workflow
        second.id = "second"
        second.sortOrder = 1
        try store.save(second)
        try store.save(workflow)
        #expect(try store.workflows().map(\.id) == ["ship", "second"])
        #expect(try store.workflow("ship") == workflow)
        try store.deleteWorkflow("ship")
        #expect(try store.workflows().map(\.id) == ["second"])
    }

    @Test func aChatsWorkflowIsSaved() throws {
        let store = try Store.inMemory()
        var session = Session(projectId: nil, name: "Chat", providerId: "claude")
        session.workflow = progress(step: 1, state: .waiting)
        try store.save(session)
        #expect(try store.session(session.id)?.workflow == session.workflow)
    }

    // MARK: Events

    private func automation(_ id: String, events: [AutomationEvent], projectId: String? = nil, enabled: Bool = true) -> Automation {
        var a = Automation(id: id, name: id, prompt: "Do it", providerId: "claude", projectId: projectId, triggers: [], enabled: enabled)
        a.events = events
        return a
    }

    @Test func anEventStartsTheAutomationsListeningInItsProject() {
        let all = [
            automation("any", events: [.chatArchived]),
            automation("mine", events: [.chatArchived, .turnFinished], projectId: "p1"),
            automation("other", events: [.chatArchived], projectId: "p2"),
            automation("paused", events: [.chatArchived], enabled: false),
            automation("deaf", events: [.pullRequestMerged]),
        ]
        let archived = AutomationEventOccurrence(event: .chatArchived, sessionId: "s", projectId: "p1")
        #expect(AutomationEvents.automations(for: archived, in: all).map(\.id) == ["any", "mine"])
        let standalone = AutomationEventOccurrence(event: .chatArchived, sessionId: "s", projectId: nil)
        #expect(AutomationEvents.automations(for: standalone, in: all).map(\.id) == ["any"])
    }

    @Test func anAutomationIsNeverStartedByWhatItLedTo() {
        let all = [automation("a", events: [.turnFinished]), automation("b", events: [.turnFinished])]
        let occurrence = AutomationEventOccurrence(event: .turnFinished, sessionId: "s", projectId: nil, chain: ["a"])
        #expect(AutomationEvents.automations(for: occurrence, in: all).map(\.id) == ["b"])
    }

    @Test func pullRequestsAlreadyThereAreNotNews() {
        let since = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let before = since.addingTimeInterval(-60), after = since.addingTimeInterval(60)
        typealias Mark = AutomationEvents.PullRequestMark
        let first = AutomationEvents.pullRequestChanges(seen: [:], now: [
            "old": Mark(number: 4, state: .open, createdAt: before, updatedAt: before),
            "oldMerged": Mark(number: 5, state: .merged, createdAt: before, updatedAt: before),
            "new": Mark(number: 6, state: .open, createdAt: after),
            "newMerged": Mark(number: 7, state: .merged, createdAt: before, updatedAt: after),
        ], since: since)
        #expect(first.events.map(\.sessionId) == ["new", "newMerged"])
        #expect(first.events.map(\.event) == [.pullRequestOpened, .pullRequestMerged])
        #expect(first.seen == ["new": "6:OPEN", "newMerged": "7:MERGED", "old": "4:OPEN", "oldMerged": "5:MERGED"])

        // Seen before: a change is news whenever it happened.
        let later = AutomationEvents.pullRequestChanges(seen: first.seen, now: [
            "old": Mark(number: 4, state: .merged, updatedAt: before),
            "new": Mark(number: 6, state: .open),
        ], since: since)
        #expect(later.events.map(\.sessionId) == ["old"])
        #expect(later.events.map(\.event) == [.pullRequestMerged])
        // A chat not listed this time keeps what was seen of it.
        #expect(later.seen == ["old": "4:MERGED", "new": "6:OPEN", "oldMerged": "5:MERGED", "newMerged": "7:MERGED"])

        // A newer pull request replacing a closed one is news; a closed one isn't.
        let reopened = AutomationEvents.pullRequestChanges(seen: ["s": "4:CLOSED", "t": "8:OPEN"],
                                                           now: ["s": Mark(number: 9, state: .open), "t": Mark(number: 8, state: .closed)],
                                                           since: since)
        #expect(reopened.events.map(\.sessionId) == ["s"])
    }

    @Test func eventsReadAsOneSentence() {
        #expect(AutomationEvents.summary([]) == nil)
        #expect(AutomationEvents.summary([.chatArchived]) == "When a chat is archived")
        #expect(AutomationEvents.summary([.turnFinished, .chatArchived, .pullRequestMerged])
            == "When a chat finishes its turn, is archived or has its pull request merged")
    }

    @Test func anAutomationsEventsAndWorkflowAreSaved() throws {
        let store = try Store.inMemory()
        var a = automation("events", events: [.workflowFinished, .pullRequestOpened])
        a.workflowId = "ship"
        a.eventTarget = .ownChat
        try store.save(a)
        let saved = try #require(try store.automation("events"))
        #expect(saved.events == [.workflowFinished, .pullRequestOpened])
        #expect(saved.workflowId == "ship")
        #expect(saved.eventTarget == .ownChat)
        // And between Macs.
        let decoded = try JSONDecoder().decode(Automation.self, from: JSONEncoder().encode(a))
        #expect(decoded.events == a.events && decoded.workflowId == "ship" && decoded.eventTarget == .ownChat)
    }

    @Test func aRunAnEventStartedIsSavedAsOneOlderBuildsCanRead() throws {
        let store = try Store.inMemory()
        try store.save(automation("a", events: [.chatArchived]))
        let run = AutomationRun(automationId: "a", trigger: .event, status: .created, event: .chatArchived, sourceSessionId: "s")
        try store.save(run)
        let saved = try #require(try store.lastRun(automationId: "a"))
        #expect(saved.trigger == .event)
        #expect(saved.event == .chatArchived)
        #expect(saved.sourceSessionId == "s")
        #expect(try store.rawTrigger(runId: run.id) == "manual")
        // And between Macs: an older one reads it as manual.
        let wire = try JSONEncoder().encode(run)
        let json = try #require(try JSONSerialization.jsonObject(with: wire) as? [String: Any])
        #expect(json["trigger"] as? String == "manual")
        let back = try JSONDecoder().decode(AutomationRun.self, from: wire)
        #expect(back.trigger == .event && back.event == .chatArchived && back.sourceSessionId == "s")
    }
}
