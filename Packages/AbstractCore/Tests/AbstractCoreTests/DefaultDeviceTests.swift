import Foundation
import Testing
@testable import AbstractCore

/// A project's default Mac: stored on the project, pre-selected by the
/// Launcher, and quietly This Mac when that Mac isn't there.
@Suite struct DefaultDeviceTests {
    static let created = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func theDefaultMacRoundTrips() throws {
        let store = try Store.inMemory()
        let project = Project(id: "p1", name: "api", rootPath: "/r/api", createdAt: Self.created, defaultDeviceId: "mac-studio")
        try store.save(project)
        #expect(try store.project("p1") == project)

        var local = project
        local.defaultDeviceId = nil
        try store.save(local)
        #expect(try store.project("p1")?.defaultDeviceId == nil)
    }

    @Test func projectsFromBeforeTheMigrationDefaultToThisMac() throws {
        let store = try Store.inMemory(migratedTo: "v10-turn-records", thenRunning: """
            INSERT INTO projects (id, name, root_path, created_at)
            VALUES ('p1', 'abstract', '/r/abstract', '2026-09-01 12:00:00.000');
            """)
        let p = try #require(try store.project("p1"))
        #expect(p.defaultDeviceId == nil && p.name == "abstract")

        var edited = p
        edited.defaultDeviceId = "mac-mini"
        try store.save(edited)
        #expect(try store.project("p1") == edited)
    }

    @Test func aProjectFromAnOlderMacDecodesWithoutADefaultMac() throws {
        let project = Project(id: "p1", name: "api", rootPath: "/r/api", createdAt: Self.created, defaultDeviceId: "mac-studio")
        let data = try JSONEncoder().encode(project)
        #expect(try JSONDecoder().decode(Project.self, from: data) == project)
        var older = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        older["defaultDeviceId"] = nil
        let decoded = try JSONDecoder().decode(Project.self, from: JSONSerialization.data(withJSONObject: older))
        #expect(decoded.defaultDeviceId == nil && decoded.name == "api")
    }

    // MARK: - What the Launcher pre-selects

    @Test func noDefaultMacMeansThisMacAndNothingMissing() {
        let p = Project(name: "api", rootPath: "/r/api")
        #expect(p.resolvedDefaultDevice(online: ["mac-studio"]) == nil)
        #expect(!p.defaultDeviceMissing(online: []))
    }

    @Test func aConnectedDefaultMacIsPreSelected() {
        let p = Project(name: "api", rootPath: "/r/api", defaultDeviceId: "mac-studio")
        #expect(p.resolvedDefaultDevice(online: ["mac-studio", "mac-mini"]) == "mac-studio")
        #expect(!p.defaultDeviceMissing(online: ["mac-studio"]))
    }

    @Test func aMissingDefaultMacFallsBackToThisMac() {
        let p = Project(name: "api", rootPath: "/r/api", defaultDeviceId: "mac-studio")
        #expect(p.resolvedDefaultDevice(online: ["mac-mini"]) == nil)
        #expect(p.defaultDeviceMissing(online: ["mac-mini"]))
        #expect(p.defaultDeviceMissing(online: []))
    }

    @Test func theSameProjectOnAnotherMacIsFoundByIdThenName() {
        let here = Project(id: "p1", name: "api", rootPath: "/r/api")
        let there = [
            Project(id: "p9", name: "web", rootPath: "/r/web"),
            Project(id: "p2", name: "api", rootPath: "/other/api"),
        ]
        #expect(Project.counterpart(of: here, in: there)?.id == "p2")
        #expect(Project.counterpart(of: here, in: [here])?.id == "p1")
        // An id match wins over a name match.
        #expect(Project.counterpart(of: here, in: there + [here])?.id == "p1")
        #expect(Project.counterpart(of: Project(name: "nope", rootPath: "/r/nope"), in: there) == nil)
        #expect(Project.counterpart(of: here, in: []) == nil)
    }

    // MARK: - Changing it from a paired device

    @Test func settingADefaultMacFromAPairedDeviceRoundTrips() throws {
        for deviceId in ["mac-studio", nil] as [String?] {
            let request = RemoteRequest.setProjectDefaultDevice(projectId: "p1", deviceId: deviceId)
            let decoded = try JSONDecoder().decode(RemoteRequest.self, from: JSONEncoder().encode(request))
            guard case .setProjectDefaultDevice(let projectId, let decodedId) = decoded else {
                Issue.record("decoded as a different request"); return
            }
            #expect(projectId == "p1" && decodedId == deviceId)
        }
    }

    @Test func aSnapshotFromBeforeTheCapabilityDecodesWithoutIt() throws {
        let snapshot = RemoteSnapshot(projects: [Project(id: "p1", name: "api", rootPath: "/r/api", createdAt: Self.created, defaultDeviceId: "mac-studio")],
                                      sessions: [], providers: [], alive: [], automationDevice: true, projectDefaultDevice: true)
        let data = try JSONEncoder().encode(snapshot)
        #expect(try JSONDecoder().decode(RemoteSnapshot.self, from: data) == snapshot)
        var older = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        older["projectDefaultDevice"] = nil
        let decoded = try JSONDecoder().decode(RemoteSnapshot.self, from: JSONSerialization.data(withJSONObject: older))
        #expect(decoded.projectDefaultDevice == nil)
        #expect(decoded.projects.first?.defaultDeviceId == "mac-studio")
    }
}
