import Foundation
import Testing
@testable import AbstractCore

/// How many sub-tasks a chat may start (ABS-214): the setting decides,
/// and lowering it never touches sub-tasks that already exist.
struct SubtaskLimitTests {
    func chats(parent: String, children: Int) -> [Session] {
        let parentChat = Session(id: parent, projectId: "p", name: "Parent", providerId: "claude", status: .idle)
        let kids = (0..<children).map { index in
            var child = Session(id: "\(parent)-child-\(index)", projectId: "p", name: "Child \(index)",
                                providerId: "claude", status: .running)
            child.parentSessionId = parent
            return child
        }
        // Another chat's sub-tasks never count against this one.
        var stranger = Session(id: "other-child", projectId: "p", name: "Other", providerId: "claude", status: .idle)
        stranger.parentSessionId = "other"
        return [parentChat, stranger] + kids
    }

    @Test func theSettingDecidesHowManySubtasksStart() {
        let limit = 8
        for count in 0..<limit {
            #expect(SubtaskLimit.refusal(parentId: "a", sessions: chats(parent: "a", children: count), limit: limit) == nil)
        }
        #expect(SubtaskLimit.refusal(parentId: "a", sessions: chats(parent: "a", children: 8), limit: limit)
                == "A chat can have at most 8 sub-tasks (Settings › Agents).")
    }

    @Test func loweringTheSettingKeepsSubtasksButRefusesNewOnes() {
        // Three already running, the setting then lowered to two.
        let sessions = chats(parent: "a", children: 3)
        #expect(sessions.filter { $0.parentSessionId == "a" }.count == 3)
        #expect(SubtaskLimit.refusal(parentId: "a", sessions: sessions, limit: 2)
                == "A chat can have at most 2 sub-tasks (Settings › Agents).")
        #expect(SubtaskLimit.refusal(parentId: "a", sessions: chats(parent: "a", children: 1), limit: 2) == nil)
    }

    @Test func oneReadsAsOneSubtask() {
        #expect(SubtaskLimit.refusal(parentId: "a", sessions: chats(parent: "a", children: 1), limit: 1)
                == "A chat can have at most 1 sub-task (Settings › Agents).")
    }

    @Test func theSettingStaysBetweenOneAndTwenty() {
        #expect(SubtaskLimit.defaultPerChat == 5)
        #expect(SubtaskLimit.range == 1...20)
        #expect(SubtaskLimit.clamped(0) == 1)
        #expect(SubtaskLimit.clamped(-3) == 1)
        #expect(SubtaskLimit.clamped(12) == 12)
        #expect(SubtaskLimit.clamped(99) == 20)
        // A stored value out of range is read as its nearest end.
        #expect(SubtaskLimit.refusal(parentId: "a", sessions: chats(parent: "a", children: 20), limit: 50) != nil)
        #expect(SubtaskLimit.refusal(parentId: "a", sessions: chats(parent: "a", children: 0), limit: 0) == nil)
    }

    @Test func depthStaysAtTwo() {
        #expect(SubtaskLimit.maxDepth == 2)
    }
}
