import Foundation
import Testing
@testable import AbstractCore

struct RemoteNoticesTests {
    private func snapshot(_ statuses: [(String, SessionStatus)], background: [String]? = nil) -> RemoteSnapshot {
        RemoteSnapshot(projects: [], sessions: statuses.map { Session(id: $0.0, projectId: "p", name: $0.0, providerId: "claude", status: $0.1) },
                       providers: [], alive: statuses.map(\.0), backgroundTasks: background)
    }

    private func next(_ notices: inout RemoteNotices, _ statuses: [(String, SessionStatus)], background: [String]? = nil,
                      fresh: Bool = false, attention: Bool = true, finished: Bool = true, onScreen: String? = nil) -> [RemoteNotices.Notice] {
        notices.next(snapshot(statuses, background: background), fresh: fresh, notifyAttention: attention,
                     notifyFinished: finished, onScreen: onScreen)
    }

    /// Connected, with each chat at `status`.
    private func connected(_ statuses: [(String, SessionStatus)]) -> RemoteNotices {
        var notices = RemoteNotices()
        _ = next(&notices, statuses, fresh: true)
        return notices
    }

    @Test func needsYouDoneAndFailedNotify() {
        var notices = connected([("a", .running), ("b", .running), ("c", .running)])
        #expect(next(&notices, [("a", .waitingInput), ("b", .idle), ("c", .errored)]) == [
            .init(sessionId: "a", status: .waitingInput),
            .init(sessionId: "b", status: .finished),
            .init(sessionId: "c", status: .errored),
        ])
        // Nothing new: nothing again.
        #expect(next(&notices, [("a", .waitingInput), ("b", .idle), ("c", .errored)]).isEmpty)
        // A process that exits after its turn isn't a second "done".
        #expect(next(&notices, [("a", .waitingInput), ("b", .finished), ("c", .errored)]).isEmpty)
    }

    @Test func aWaitNotifiesOnceAndAgainForTheNextOne() {
        var notices = connected([("a", .running)])
        #expect(next(&notices, [("a", .waitingInput)]) == [.init(sessionId: "a", status: .waitingInput)])
        #expect(next(&notices, [("a", .running)]).isEmpty)
        #expect(next(&notices, [("a", .waitingInput)]) == [.init(sessionId: "a", status: .waitingInput)])
    }

    @Test func aNewChatAlreadyWaitingNotifies() {
        var notices = connected([])
        #expect(next(&notices, [("a", .waitingInput), ("b", .idle)]) == [.init(sessionId: "a", status: .waitingInput)])
    }

    @Test func eachSettingOff() {
        var notices = connected([("a", .running), ("b", .running), ("c", .running)])
        #expect(next(&notices, [("a", .waitingInput), ("b", .idle), ("c", .running)], attention: false, finished: false).isEmpty)
        // Failing has no setting, as on this Mac.
        #expect(next(&notices, [("a", .waitingInput), ("b", .idle), ("c", .errored)], attention: false, finished: false)
            == [.init(sessionId: "c", status: .errored)])

        var attentionOnly = connected([("a", .running), ("b", .running)])
        #expect(next(&attentionOnly, [("a", .waitingInput), ("b", .idle)], finished: false) == [.init(sessionId: "a", status: .waitingInput)])
        var finishedOnly = connected([("a", .running), ("b", .running)])
        #expect(next(&finishedOnly, [("a", .waitingInput), ("b", .idle)], attention: false) == [.init(sessionId: "b", status: .finished)])
    }

    @Test func theChatOnScreenStaysQuiet() {
        var notices = connected([("a", .running), ("b", .running)])
        #expect(next(&notices, [("a", .waitingInput), ("b", .idle)], onScreen: "a") == [.init(sessionId: "b", status: .finished)])
        #expect(next(&notices, [("a", .idle), ("b", .running)], onScreen: "a").isEmpty)
        // A wait you saw isn't told again after a reconnect.
        #expect(next(&notices, [("a", .running), ("b", .running)]).isEmpty)
        #expect(next(&notices, [("a", .waitingInput), ("b", .running)], onScreen: "a").isEmpty)
        #expect(next(&notices, [("a", .waitingInput), ("b", .running)], fresh: true).isEmpty)
    }

    @Test func aReconnectTellsOnlyAWaitYouWerentToldAbout() {
        var notices = connected([("a", .running), ("b", .running), ("c", .running), ("d", .running)])
        // The link drops; meanwhile three finish and one starts waiting.
        #expect(next(&notices, [("a", .idle), ("b", .finished), ("c", .errored), ("d", .waitingInput)], fresh: true)
            == [.init(sessionId: "d", status: .waitingInput)])
        // A wait you were told about before the drop stays quiet.
        var told = connected([("a", .running)])
        #expect(next(&told, [("a", .waitingInput)]).count == 1)
        #expect(next(&told, [("a", .waitingInput)], fresh: true).isEmpty)
        // The first snapshot ever tells you of waits too.
        var first = RemoteNotices()
        #expect(next(&first, [("a", .waitingInput), ("b", .idle)], fresh: true) == [.init(sessionId: "a", status: .waitingInput)])
    }

    @Test func aWaitTurnedOffIsToldOnceTurnedOnAfterAReconnect() {
        var notices = connected([("a", .running)])
        #expect(next(&notices, [("a", .waitingInput)], attention: false).isEmpty)
        #expect(next(&notices, [("a", .waitingInput)], fresh: true) == [.init(sessionId: "a", status: .waitingInput)])
    }

    @Test func backgroundTasksHoldBackDone() {
        var notices = connected([("a", .running)])
        #expect(next(&notices, [("a", .idle)], background: ["a"]).isEmpty)
        #expect(next(&notices, [("a", .idle)], background: ["a"]).isEmpty)
        // The tasks end, with no snapshot catching the turn they caused.
        #expect(next(&notices, [("a", .idle)], background: []) == [.init(sessionId: "a", status: .finished)])
        #expect(next(&notices, [("a", .idle)]).isEmpty)

        // Or one that does.
        var caught = connected([("a", .running)])
        #expect(next(&caught, [("a", .idle)], background: ["a"]).isEmpty)
        #expect(next(&caught, [("a", .running)], background: ["a"]).isEmpty)
        #expect(next(&caught, [("a", .idle)]) == [.init(sessionId: "a", status: .finished)])

        // An older Mac doesn't say: done when the turn ends.
        var older = connected([("a", .running)])
        #expect(next(&older, [("a", .idle)], background: nil) == [.init(sessionId: "a", status: .finished)])
    }

    @Test func aChatDoneWithTasksStillRunningAtAReconnectIsDoneWhenTheyEnd() {
        var notices = RemoteNotices()
        #expect(next(&notices, [("a", .idle)], background: ["a"], fresh: true).isEmpty)
        #expect(next(&notices, [("a", .idle)], background: []) == [.init(sessionId: "a", status: .finished)])
    }

    @Test func aTurnYouStoppedHereTellsNothing() {
        var notices = connected([("a", .running), ("b", .idle)])
        notices.stopRequested("a")
        // Stopping a chat between turns is nothing to hold on to.
        notices.stopRequested("b")
        #expect(next(&notices, [("a", .idle), ("b", .running)]).isEmpty)
        #expect(next(&notices, [("a", .running), ("b", .idle)]) == [.init(sessionId: "b", status: .finished)])
        #expect(next(&notices, [("a", .idle), ("b", .idle)]) == [.init(sessionId: "a", status: .finished)])
    }

    @Test func olderSnapshotsDecodeWithoutBackgroundTasks() throws {
        let old = try JSONDecoder().decode(RemoteSnapshot.self, from: Data(#"{"projects":[],"sessions":[],"providers":[],"alive":[]}"#.utf8))
        #expect(old.backgroundTasks == nil)
        let current = RemoteSnapshot(projects: [], sessions: [], providers: [], alive: [], backgroundTasks: ["a"])
        #expect(try JSONDecoder().decode(RemoteSnapshot.self, from: JSONEncoder().encode(current)).backgroundTasks == ["a"])
    }
}
