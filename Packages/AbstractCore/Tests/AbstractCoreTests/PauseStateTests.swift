import Foundation
import Testing
import AbstractCore

@Suite struct PauseStateTests {
    let triage = Session(id: "triage", projectId: "web", name: "Weekly triage", providerId: "claude")
    let build = Session(id: "build", projectId: "api", name: "Build", providerId: "codex")
    let loose = Session(id: "loose", projectId: nil, name: "Loose", providerId: "claude")
    var sessions: [Session] { [triage, build, loose] }

    func automation(_ name: String, project: String?, enabled: Bool = true, pinned: String? = nil) -> Automation {
        Automation(id: name, name: name, prompt: "", providerId: "claude", projectId: project,
                   triggers: [AutomationTrigger(rrule: "FREQ=DAILY", timezone: "UTC")],
                   workspaceMode: pinned == nil ? .newWorktree : .pinned, pinnedSessionId: pinned, enabled: enabled)
    }

    /// The three active automations of the ticket, plus one paused by hand.
    var automations: [Automation] {
        [automation("a", project: "api"), automation("b", project: "web"), automation("c", project: nil),
         automation("mine", project: "api", enabled: false)]
    }

    @Test func pauseEverythingDisablesEveryActiveAutomationAndRemembersThem() {
        var state = PauseState()
        #expect(state.pause(.all, automations: automations, sessions: sessions).sorted() == ["a", "b", "c"])
        #expect(state.everythingPaused)
        #expect(state.automationIds == ["a", "b", "c"])
    }

    @Test func resumeEverythingRestoresExactlyThoseAndNotOnePausedByHand() {
        var state = PauseState()
        _ = state.pause(.all, automations: automations, sessions: sessions)
        let paused = automations.map { a in var a = a; a.enabled = false; return a }
        #expect(state.resume(.all, automations: paused, sessions: sessions).sorted() == ["a", "b", "c"])
        #expect(!state.everythingPaused)
        #expect(state.automationIds.isEmpty)
    }

    @Test func pausingTwiceAddsNothing() {
        var state = PauseState()
        _ = state.pause(.all, automations: automations, sessions: sessions)
        let paused = automations.map { a in var a = a; a.enabled = false; return a }
        #expect(state.pause(.all, automations: paused, sessions: sessions).isEmpty)
        #expect(state.resume(.all, automations: paused, sessions: sessions).sorted() == ["a", "b", "c"])
    }

    @Test func anAutomationRemovedWhilePausedIsNotRestored() {
        var state = PauseState()
        _ = state.pause(.all, automations: automations, sessions: sessions)
        #expect(state.resume(.all, automations: automations.filter { $0.id != "b" }, sessions: sessions).sorted() == ["a", "c"])
        #expect(state.automationIds.isEmpty)
    }

    @Test func takingAnAutomationBackInHandKeepsItOutOfResume() {
        var state = PauseState()
        _ = state.pause(.all, automations: automations, sessions: sessions)
        state.forget(automationId: "b")
        #expect(state.resume(.all, automations: automations, sessions: sessions).sorted() == ["a", "c"])
    }

    @Test func pausingAProjectTouchesOnlyItsAutomationsIncludingPinnedOnes() {
        var state = PauseState()
        let pinned = automation("p", project: "api", pinned: "triage") // its chat is in web
        let list = automations + [pinned]
        #expect(state.pause(.project("web"), automations: list, sessions: sessions).sorted() == ["b", "p"])
        #expect(!state.everythingPaused)
        #expect(state.isPaused(.project("web")))
        #expect(!state.isPaused(.project("api")))
        #expect(state.resume(.project("web"), automations: list, sessions: sessions).sorted() == ["b", "p"])
        #expect(!state.isPaused(.project("web")))
        #expect(state.automationIds.isEmpty)
    }

    @Test func aProjectResumeWhileEverythingIsPausedRestoresNothingYet() {
        var state = PauseState()
        _ = state.pause(.project("api"), automations: automations, sessions: sessions)
        let partly = automations.map { a in var a = a; if a.id == "a" { a.enabled = false }; return a }
        _ = state.pause(.all, automations: partly, sessions: sessions)
        #expect(state.resume(.project("api"), automations: partly, sessions: sessions).isEmpty)
        #expect(state.resume(.all, automations: partly, sessions: sessions).sorted() == ["a", "b", "c"])
        #expect(!state.isPaused(.project("api")))
    }

    @Test func resumeEverythingAlsoClearsProjectPauses() {
        var state = PauseState()
        _ = state.pause(.project("api"), automations: automations, sessions: sessions)
        _ = state.resume(.all, automations: automations, sessions: sessions)
        #expect(!state.isPaused(.project("api")))
        #expect(state.automationIds.isEmpty)
    }

    @Test func scopePicksChatsByProject() {
        #expect(PauseState.sessions(in: .all, from: sessions).map(\.id) == ["triage", "build", "loose"])
        #expect(PauseState.sessions(in: .project("api"), from: sessions).map(\.id) == ["build"])
        #expect(PauseState.sessions(in: .project("web"), from: sessions).map(\.id) == ["triage"])
    }

    @Test func stateSurvivesCoding() throws {
        var state = PauseState()
        _ = state.pause(.all, automations: automations, sessions: sessions)
        _ = state.pause(.project("api"), automations: automations, sessions: sessions)
        let decoded = try JSONDecoder().decode(PauseState.self, from: JSONEncoder().encode(state))
        #expect(decoded == state)
    }
}
