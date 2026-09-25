import Foundation
import Testing
@testable import AbstractCore

@Suite struct AutomationDraftingTests {
    private func claudeEnvelope(_ result: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: ["type": "result", "is_error": false, "result": result])
        return String(decoding: data, as: UTF8.self)
    }

    @Test func thePromptCarriesTheProjectsZoneAndDescription() {
        let prompt = AutomationDrafting.prompt(description: "Triage issues every morning", projects: ["abstract", "payments-api"],
                                               timezone: "Europe/Lisbon")
        #expect(prompt.contains("- abstract\n- payments-api"))
        #expect(prompt.contains("Time zone: Europe/Lisbon"))
        #expect(prompt.contains("<description>\nTriage issues every morning\n</description>"))
        #expect(prompt.contains("abstract session create"))
    }

    @Test func readsClaudesAnswerFromItsCodeFence() throws {
        let answer = """
            Here it is:
            ```json
            {"name": "Morning triage", "instructions": "## Triage\\n1. List new issues.", "schedules": ["RRULE:FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR;BYHOUR=9;BYMINUTE=0"],
             "project": "Payments-API", "chat": "own", "permissions": "ask"}
            ```
            """
        let fields = try #require(AutomationDrafting.parse(try claudeEnvelope(answer)))
        let proposal = AutomationDrafting.proposal(fields, projects: ["abstract", "payments-api"], timezone: "Europe/Lisbon")
        #expect(proposal == AutomationDrafting.Proposal(
            name: "Morning triage", instructions: "## Triage\n1. List new issues.",
            schedules: ["FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR;BYHOUR=9;BYMINUTE=0"], project: "payments-api",
            continuesOwnChat: true, policy: .ask))
    }

    @Test func dropsWhatItCantUse() throws {
        let answer = #"{"name": "Bumps", "instructions": "Bump deps.", "schedules": ["FREQ=DAILY;BYHOUR=9;BYMINUTE=0", "EVERY TUESDAY", 3], "project": "elsewhere", "chat": "sometimes", "permissions": "whatever"}"#
        let fields = try #require(AutomationDrafting.parse(try claudeEnvelope(answer)))
        let proposal = AutomationDrafting.proposal(fields, projects: ["abstract"], timezone: "UTC")
        #expect(proposal.schedules == ["FREQ=DAILY;BYHOUR=9;BYMINUTE=0"])
        #expect(proposal.project == nil)
        #expect(!proposal.continuesOwnChat)
        #expect(proposal.policy == .autoEdits)
    }

    @Test func anErrorOrAnAnswerThatIsntOneIsNothing() throws {
        #expect(AutomationDrafting.parse(#"{"type":"result","is_error":true,"result":"Not logged in"}"#) == nil)
        #expect(AutomationDrafting.parse(try claudeEnvelope(#"{"title": "not an automation"}"#)) == nil)
    }

    @Test func readsCodexsLastAgentMessage() throws {
        let events = [
            #"{"type":"item.completed","item":{"type":"agent_message","text":"Thinking about it."}}"#,
            #"{"type":"item.completed","item":{"type":"agent_message","text":"{\"name\":\"Nightly\",\"instructions\":\"Run the tests.\",\"schedules\":[],\"project\":null,\"chat\":\"new\",\"permissions\":\"full\"}"}}"#,
        ].joined(separator: "\n")
        let fields = try #require(AutomationDrafting.parseCodex(events))
        let proposal = AutomationDrafting.proposal(fields, projects: [], timezone: "UTC")
        #expect(proposal.name == "Nightly")
        #expect(proposal.schedules.isEmpty)
        #expect(proposal.policy == .bypass)
    }

    @Test func onlyClaudeAndCodexCanDraft() async {
        await #expect(throws: AutomationDrafting.Failure.self) {
            _ = try await AutomationDrafting.draft(executor: LocalExecutor.shared, binary: nil, providerId: "opencode",
                                                   description: "x", projects: [], timezone: "UTC")
        }
    }
}
