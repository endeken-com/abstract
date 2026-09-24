import Testing
import AbstractCore

@Suite struct OrderingTests {
    let ids = ["a", "b", "c", "d"]

    @Test func movesBeforeOrAfterTheTarget() {
        #expect(Ordering.move("d", in: ids, to: "b", after: false) == ["a", "d", "b", "c"])
        #expect(Ordering.move("a", in: ids, to: "c", after: true) == ["b", "c", "a", "d"])
        #expect(Ordering.move("b", in: ids, to: "d", after: true) == ["a", "c", "d", "b"])
        #expect(Ordering.move("c", in: ids, to: "a", after: false) == ["c", "a", "b", "d"])
    }

    @Test func noOpsLeaveTheOrderAlone() {
        #expect(Ordering.move("b", in: ids, to: "b", after: true) == ids)
        #expect(Ordering.move("x", in: ids, to: "b", after: true) == ids)
        #expect(Ordering.move("b", in: ids, to: "x", after: true) == ids)
        #expect(Ordering.move("a", in: ids, to: "b", after: false) == ids, "already right before it")
    }
}
