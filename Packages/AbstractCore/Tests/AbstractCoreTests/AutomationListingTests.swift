import Foundation
import Testing
import AbstractCore

@Suite struct AutomationListingTests {
    let api = Project(id: "api", name: "payments-api", rootPath: "/tmp/api")
    let web = Project(id: "web", name: "web", rootPath: "/tmp/web")
    var projects: [Project] { [api, web] }
    let triage = Session(id: "triage", projectId: "web", name: "Weekly triage", providerId: "claude")

    func automation(_ name: String, project: String?, agent: String = "claude", enabled: Bool = true,
                    manual: Bool = false, next: TimeInterval? = nil, pinned: String? = nil) -> Automation {
        Automation(id: name, name: name, prompt: "", providerId: agent, projectId: project,
                   triggers: manual ? [] : [AutomationTrigger(rrule: "FREQ=DAILY", timezone: "UTC")],
                   workspaceMode: pinned == nil ? .newWorktree : .pinned, pinnedSessionId: pinned,
                   enabled: enabled, nextRunAt: next.map { Date(timeIntervalSince1970: $0) })
    }

    func sections(_ automations: [Automation], _ filter: AutomationFilter = AutomationFilter()) -> [[String]] {
        AutomationListing.sections(automations, projects: projects, sessions: [triage], filter: filter)
            .map { [$0.project?.name ?? "No project"] + $0.automations.map(\.name) }
    }

    @Test func groupsByProjectInSidebarOrderWithNoProjectLast() {
        let list = [automation("loose", project: nil), automation("deploy", project: "web"), automation("bump", project: "api")]
        #expect(sections(list) == [["payments-api", "bump"], ["web", "deploy"], ["No project", "loose"]])
    }

    @Test func aPinnedAutomationSitsUnderItsChatsProject() {
        let pinned = automation("triage", project: "api", pinned: "triage")
        #expect(sections([pinned]) == [["web", "triage"]])
        #expect(AutomationListing.projectId(of: pinned, sessions: [triage]) == "web")
        // Before its first run there is no chat yet: it goes where it will start one.
        #expect(sections([automation("fresh", project: "api", pinned: nil)]) == [["payments-api", "fresh"]])
    }

    @Test func anUnknownProjectCountsAsNoProject() {
        #expect(sections([automation("orphan", project: "gone")]) == [["No project", "orphan"]])
    }

    @Test func activeComeFirstBySoonestRunThenTheRestByName() {
        let list = [
            automation("zeta", project: "api", enabled: false),
            automation("later", project: "api", next: 200),
            automation("alpha", project: "api", manual: true),
            automation("never", project: "api"),
            automation("soon", project: "api", next: 100),
            automation("beta", project: "api", enabled: false, manual: true),
        ]
        #expect(sections(list) == [["payments-api", "soon", "later", "never", "alpha", "beta", "zeta"]])
    }

    @Test func filtersByProject() {
        let list = [automation("a", project: "api"), automation("b", project: "web"), automation("c", project: nil),
                    automation("d", project: "api", pinned: "triage")]
        #expect(sections(list, AutomationFilter(project: .only("api"))) == [["payments-api", "a"]])
        #expect(sections(list, AutomationFilter(project: .only("web"))) == [["web", "b", "d"]])
        #expect(sections(list, AutomationFilter(project: .noProject)) == [["No project", "c"]])
    }

    @Test func filtersByAgent() {
        let list = [automation("a", project: "api", agent: "codex"), automation("b", project: "api")]
        #expect(sections(list, AutomationFilter(providerId: "codex")) == [["payments-api", "a"]])
    }

    @Test func filtersByState() {
        let list = [automation("on", project: "api", next: 1), automation("off", project: "api", enabled: false),
                    automation("hand", project: "api", manual: true),
                    automation("off by hand", project: "api", enabled: false, manual: true)]
        #expect(sections(list, AutomationFilter(state: .active)) == [["payments-api", "on"]])
        #expect(sections(list, AutomationFilter(state: .paused)) == [["payments-api", "off", "off by hand"]])
        #expect(sections(list, AutomationFilter(state: .manual)) == [["payments-api", "hand"]])
    }

    @Test func filtersCombineAndCanHideEverything() {
        let list = [automation("a", project: "api", agent: "codex", enabled: false), automation("b", project: "web")]
        #expect(sections(list, AutomationFilter(project: .only("api"), providerId: "codex", state: .paused)) == [["payments-api", "a"]])
        #expect(sections(list, AutomationFilter(project: .only("web"), state: .paused)).isEmpty)
        #expect(!AutomationFilter().isOn)
        #expect(AutomationFilter(state: .paused).isOn)
    }

    @Test func projectChoiceRoundTripsThroughItsStoredString() {
        for choice in [AutomationFilter.ProjectChoice.all, .noProject, .only("api")] {
            #expect(AutomationFilter.ProjectChoice(stored: choice.stored) == choice)
        }
        #expect(AutomationFilter.ProjectChoice(stored: "") == .all)
    }
}
