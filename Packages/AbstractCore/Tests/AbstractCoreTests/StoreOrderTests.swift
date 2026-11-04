import Foundation
import Testing
@testable import AbstractCore

/// Saving one record updates exactly its entry in the app's lists, as the
/// store would list them (ABS-184).
@Suite struct StoreOrderTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func chat(_ id: String, active minutesAgo: Double?, created daysAgo: Double = 1) -> Session {
        Session(id: id, projectId: nil, name: id, providerId: "claude", createdAt: now.addingTimeInterval(-daysAgo * 86_400),
                lastEventAt: minutesAgo.map { now.addingTimeInterval(-$0 * 60) })
    }

    @Test func aSavedChatReplacesOnlyItsEntry() {
        let list = [chat("a", active: 1), chat("b", active: 5), chat("c", active: 9)]
        var renamed = list[1]
        renamed.name = "Renamed"
        let saved = StoreOrder.saving(renamed, in: list, precedes: StoreOrder.sessionPrecedes)
        #expect(saved.map(\.id) == ["a", "b", "c"])
        #expect(saved[1].name == "Renamed")
        #expect(saved[0] == list[0] && saved[2] == list[2])
    }

    @Test func aNewChatGoesWhereTheStoreListsIt() throws {
        let store = try Store.inMemory()
        var list = [chat("a", active: 1), chat("b", active: 5), chat("c", active: 9)]
        for s in list { try store.save(s) }
        for new in [chat("new", active: nil, created: 0), chat("mid", active: 3), chat("old", active: nil, created: 30)] {
            try store.save(new)
            list = StoreOrder.saving(new, in: list, precedes: StoreOrder.sessionPrecedes)
            #expect(list.map(\.id) == (try store.sessions()).map(\.id))
        }
    }

    @Test func aDeletedChatLeavesItsSubtasksStandingAlone() throws {
        let store = try Store.inMemory()
        let parent = chat("parent", active: 1)
        var child = chat("child", active: 2)
        child.parentSessionId = parent.id
        let other = chat("other", active: 3)
        for s in [parent, child, other] { try store.save(s) }
        try store.deleteSession(parent.id)
        let left = StoreOrder.deleting(parent.id, from: [parent, child, other])
        #expect(left == (try store.sessions()))
        #expect(left.map(\.id) == ["child", "other"])
        #expect(left[0].parentSessionId == nil)
    }

    @Test func movingProjectsReordersOnlyThem() throws {
        let store = try Store.inMemory()
        let projects = (0..<4).map { Project(name: "p\($0)", rootPath: "/tmp/p\($0)", sortOrder: $0, createdAt: now) }
        for p in projects { try store.save(p) }
        var first = projects[0], last = projects[3]
        (first.sortOrder, last.sortOrder) = (3, 0)
        try store.save(first)
        try store.save(last)
        let list = StoreOrder.reordering([first, last], in: projects, precedes: StoreOrder.projectPrecedes)
        #expect(list == (try store.projects()))
        #expect(list.map(\.name) == ["p3", "p1", "p2", "p0"])
    }

    @Test func aNewProjectAndAutomationLandWhereTheStoreListsThem() throws {
        let store = try Store.inMemory()
        var projects: [Project] = []
        for (i, order) in [2, 0, 1].enumerated() {
            let p = Project(name: "p\(i)", rootPath: "/tmp/p\(i)", sortOrder: order, createdAt: now.addingTimeInterval(Double(i)))
            try store.save(p)
            projects = StoreOrder.saving(p, in: projects, precedes: StoreOrder.projectPrecedes)
            #expect(projects == (try store.projects()))
        }
        var automations: [Automation] = []
        for i in [2, 0, 1] {
            let a = Automation(name: "a\(i)", prompt: "x", providerId: "claude", projectId: nil, triggers: [],
                               createdAt: now.addingTimeInterval(Double(i)), updatedAt: now)
            try store.save(a)
            automations = StoreOrder.saving(a, in: automations, precedes: StoreOrder.automationPrecedes)
            #expect(automations.map(\.id) == (try store.automations()).map(\.id))
        }
    }
}
