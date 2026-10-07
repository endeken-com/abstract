import Foundation
import Testing
@testable import AbstractCore

@Suite struct AutomationRunNamingTests {
    @Test func aRunStartsNamedForItsAutomationAndIsRecognisedUntilRenamed() {
        let name = AutomationRunNaming.provisional("Roadmap: build the next ticket", at: Date(timeIntervalSince1970: 0))
        #expect(name.hasPrefix("Roadmap: build the next ticket · "))
        #expect(AutomationRunNaming.isProvisional(name, automationName: "Roadmap: build the next ticket"))
        #expect(!AutomationRunNaming.isProvisional("Show each worktree's diff stat", automationName: "Roadmap: build the next ticket"))
        #expect(!AutomationRunNaming.isProvisional(name, automationName: "Roadmap"))
    }

    @Test func theNamingCallReadsTheAgentsReport() {
        let task = AutomationRunNaming.task(fromReport: "Opened #42: Shows each worktree's diff stat (ABS-7).")
        #expect(task.hasSuffix("Opened #42: Shows each worktree's diff stat (ABS-7)."))
    }

    @Test func theReportIsTheAgentsLatestReply() {
        var t = Timeline()
        #expect(t.lastReply == nil)
        t.append(.text(role: .user, text: "Build the next ticket", blockId: nil, partial: false))
        #expect(t.lastReply == nil)
        t.append(.text(role: .assistant, text: "Taking ABS-7.", blockId: "m:0", partial: false))
        t.append(.toolUse(id: "a", name: "Bash", input: .object([:]), edit: nil))
        t.append(.text(role: .assistant, text: "Opened #42 for ABS-7.", blockId: "m:1", partial: false))
        t.append(.text(role: .assistant, text: "  ", blockId: "m:2", partial: false))
        #expect(t.lastReply == "Opened #42 for ABS-7.")
    }
}
