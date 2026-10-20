import Foundation
import Testing
@testable import AbstractCore

/// A working chat that goes quiet: flagged at the quiet threshold, stalled
/// (once, with one notification) at the stalled threshold, and never while
/// it waits on you or on a background task. All times are a fake clock.
@Suite("Stall watch")
struct StallWatchTests {
    static let start = Date(timeIntervalSince1970: 1_790_000_000)
    static let thresholds = StallThresholds(quietMinutes: 5, stalledMinutes: 15)

    private func at(_ minutes: Double) -> Date { Self.start.addingTimeInterval(minutes * 60) }

    @Test func quietThenStalledAsSilenceGrows() {
        var watch = StallWatch()
        watch.beginTurn(at: at(0))
        #expect(watch.state(at: at(4.99), thresholds: Self.thresholds) == .working)
        #expect(watch.state(at: at(5), thresholds: Self.thresholds) == .quiet(since: at(0)))
        #expect(watch.state(at: at(14.99), thresholds: Self.thresholds) == .quiet(since: at(0)))
        #expect(watch.state(at: at(15), thresholds: Self.thresholds) == .stalled(since: at(0)))
        // The Done-when case: 16 silent minutes is stalled.
        #expect(watch.state(at: at(16), thresholds: Self.thresholds).isStalled)
    }

    @Test func outputRestartsTheClockAndClearsTheFlag() {
        var watch = StallWatch()
        watch.beginTurn(at: at(0))
        #expect(watch.state(at: at(16), thresholds: Self.thresholds).isStalled)
        watch.noteOutput(at: at(16))
        #expect(watch.state(at: at(16), thresholds: Self.thresholds) == .working)
        #expect(watch.state(at: at(20.99), thresholds: Self.thresholds) == .working)
        #expect(watch.state(at: at(21), thresholds: Self.thresholds) == .quiet(since: at(16)))
    }

    @Test func oneNotificationPerStallAndAnotherForTheNextStall() {
        var watch = StallWatch()
        watch.beginTurn(at: at(0))
        let fired1 = watch.consumeStallNotification(at: at(14), thresholds: Self.thresholds); #expect(!fired1)
        let fired2 = watch.consumeStallNotification(at: at(15), thresholds: Self.thresholds); #expect(fired2)
        let fired3 = watch.consumeStallNotification(at: at(20), thresholds: Self.thresholds); #expect(!fired3)
        let fired4 = watch.consumeStallNotification(at: at(60), thresholds: Self.thresholds); #expect(!fired4)
        watch.noteOutput(at: at(61))
        let fired5 = watch.consumeStallNotification(at: at(75), thresholds: Self.thresholds); #expect(!fired5)
        let fired6 = watch.consumeStallNotification(at: at(76), thresholds: Self.thresholds); #expect(fired6)
    }

    @Test func waitingOnAPermissionPausesTheClock() {
        var watch = StallWatch()
        watch.beginTurn(at: at(0))
        watch.setPaused(true, at: at(4))
        // An hour waiting for you is never flagged, and never notifies.
        #expect(watch.state(at: at(64), thresholds: Self.thresholds) == .working)
        let fired7 = watch.consumeStallNotification(at: at(64), thresholds: Self.thresholds); #expect(!fired7)
        watch.setPaused(false, at: at(64))
        #expect(watch.state(at: at(64.99), thresholds: Self.thresholds) == .working)
        #expect(watch.state(at: at(65), thresholds: Self.thresholds) == .quiet(since: at(60)))
        #expect(watch.state(at: at(75), thresholds: Self.thresholds).isStalled)
    }

    @Test func aRunningBackgroundTaskPausesTheClockTheSameWay() {
        var watch = StallWatch()
        watch.beginTurn(at: at(0))
        watch.noteOutput(at: at(2))
        watch.setPaused(true, at: at(3))
        #expect(watch.state(at: at(120), thresholds: Self.thresholds) == .working)
        watch.setPaused(false, at: at(120))
        // One minute of silence had passed before the pause; four more to quiet.
        #expect(watch.state(at: at(123.99), thresholds: Self.thresholds) == .working)
        #expect(watch.state(at: at(124), thresholds: Self.thresholds) == .quiet(since: at(119)))
    }

    @Test func keepWaitingClearsTheStallAndRestartsTheClock() {
        var watch = StallWatch()
        watch.beginTurn(at: at(0))
        let fired8 = watch.consumeStallNotification(at: at(15), thresholds: Self.thresholds); #expect(fired8)
        watch.keepWaiting(at: at(16))
        #expect(watch.state(at: at(16), thresholds: Self.thresholds) == .working)
        let fired9 = watch.consumeStallNotification(at: at(30), thresholds: Self.thresholds); #expect(!fired9)
        let fired10 = watch.consumeStallNotification(at: at(31), thresholds: Self.thresholds); #expect(fired10)
    }

    @Test func noTurnNoFlag() {
        var watch = StallWatch()
        #expect(watch.state(at: at(100), thresholds: Self.thresholds) == .working)
        let fired11 = watch.consumeStallNotification(at: at(100), thresholds: Self.thresholds); #expect(!fired11)
        watch.beginTurn(at: at(0))
        watch.endTurn()
        #expect(watch.state(at: at(100), thresholds: Self.thresholds) == .working)
        let fired12 = watch.consumeStallNotification(at: at(100), thresholds: Self.thresholds); #expect(!fired12)
    }

    @Test func customThresholdsAreHonouredAndClamped() {
        let fast = StallThresholds(quietMinutes: 1, stalledMinutes: 2)
        var watch = StallWatch()
        watch.beginTurn(at: at(0))
        #expect(watch.state(at: at(1), thresholds: fast) == .quiet(since: at(0)))
        #expect(watch.state(at: at(2), thresholds: fast).isStalled)
        // Stalled never comes at or before quiet, and neither is under a minute.
        let clamped = StallThresholds(quietMinutes: 0, stalledMinutes: 0)
        #expect(clamped.quietMinutes >= 1)
        #expect(clamped.stalledMinutes > clamped.quietMinutes)
        #expect(StallThresholds.default.quietMinutes == 5)
        #expect(StallThresholds.default.stalledMinutes == 15)
    }

    @Test func quietMinutesReadOffTheState() {
        #expect(StallState.working.quietMinutes(at: at(10)) == nil)
        #expect(StallState.quiet(since: at(0)).quietMinutes(at: at(7.5)) == 7)
        #expect(StallState.stalled(since: at(0)).quietMinutes(at: at(16)) == 16)
    }

    @Test func theTimelineKnowsItsLastOutputAndYourLastMessage() {
        var t = Timeline()
        t.append(.text(role: .user, text: "first ask", blockId: nil, partial: false), at: at(0))
        t.append(.text(role: .assistant, text: "On it.", blockId: "m", partial: false), at: at(1))
        t.append(.text(role: .user, text: "second ask", blockId: nil, partial: false), at: at(2))
        t.append(.toolUse(id: "a", name: "Bash", input: .null, edit: nil), at: at(3))
        #expect(t.lastOutputAt == at(3))
        #expect(t.lastUserMessage == "second ask")
        #expect(Timeline().lastOutputAt == nil)
        #expect(Timeline().lastUserMessage == nil)
    }
}
