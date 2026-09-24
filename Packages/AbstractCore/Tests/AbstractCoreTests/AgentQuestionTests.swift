import Foundation
import Testing
import AbstractCore

@Suite struct AgentQuestionTests {
    /// As claude sends it in a `can_use_tool` request for AskUserQuestion.
    static let input = JSONValue.parse(#"""
    {"questions":[
      {"question":"Which approach?","header":"Approach","multiSelect":false,
       "options":[{"label":"Patch","description":"Smallest change"},{"label":"Rewrite","description":""}]},
      {"question":"Which platforms?","header":"","multiSelect":true,
       "options":[{"label":"macOS"},{"label":"iOS"}]},
      {"header":"No text","options":[]}
    ]}
    """#)!

    @Test func parsesQuestionsAndLeavesOutOnesWithoutText() {
        let questions = AgentQuestion.parse(Self.input)
        #expect(questions == [
            AgentQuestion(question: "Which approach?", header: "Approach",
                          options: [.init(label: "Patch", description: "Smallest change"), .init(label: "Rewrite")]),
            AgentQuestion(question: "Which platforms?", options: [.init(label: "macOS"), .init(label: "iOS")], multiSelect: true),
        ])
        #expect(AgentQuestion.parse(.object([:])).isEmpty)
    }

    @Test func joinsChosenLabelsAndTypedTextLikeTheSDK() {
        #expect(AgentQuestion.answer(chosen: ["macOS", "iOS"]) == "macOS, iOS")
        #expect(AgentQuestion.answer(chosen: ["Patch"], other: "  but keep the API  ") == "Patch, but keep the API")
        #expect(AgentQuestion.answer(chosen: [], other: "Neither") == "Neither")
        #expect(AgentQuestion.answer(chosen: [], other: "   ") == nil)
    }

    @Test func answersGoBackAsTheAllowedInputBesideTheQuestions() throws {
        let answered = AgentQuestion.answeredInput(Self.input, answers: ["Which approach?": "Patch"])
        #expect(answered["questions"] == Self.input["questions"])
        #expect(answered["answers"] == .object(["Which approach?": .string("Patch")]))

        let line = try #require(ClaudeProvider().buildPermissionResponse(requestId: "q-1", allow: true, input: answered))
        let response = try #require(JSONValue.parse(line))["response"]?["response"]
        #expect(response?["behavior"]?.string == "allow")
        #expect(response?["updatedInput"]?["answers"]?["Which approach?"]?.string == "Patch")
    }

    @Test func readsAnswersBackFromTheToolResult() {
        let output = #"Your questions have been answered: "Which approach?"="Patch", "Which platforms?"="macOS, iOS". You can now continue with these answers in mind."#
        #expect(AgentQuestion.answers(fromResult: output) == ["Which approach?": "Patch", "Which platforms?": "macOS, iOS"])
        #expect(AgentQuestion.answers(fromResult: "Denied by user").isEmpty)
    }

    @Test func claudeMarksAQuestionAsOneForYou() {
        let events = ClaudeProviderTests.feed([
            #"{"type":"control_request","request_id":"q-1","request":{"subtype":"can_use_tool","tool_name":"AskUserQuestion","input":{"questions":[]}}}"#,
        ])
        #expect(events == [
            .permissionRequest(requestId: "q-1", toolName: "AskUserQuestion", input: .object(["questions": .array([])])),
            .status(.waitingInput, detail: "Question for you"),
        ])
    }
}
