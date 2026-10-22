import Foundation
import Testing
@testable import AbstractCore

/// ABS-143: a project links to a Linear team or project, a Jira project, or
/// both. The link is saved by the tracker's own section in Project Settings,
/// scopes the composer's search, and reaches plugins and agents.
@Suite struct ProjectIssueTrackerTests {
    let fm = FileManager.default

    var plugins: URL {
        let here = URL(fileURLWithPath: #filePath)
        let repo = here.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return repo.appendingPathComponent("Abstract/Resources/Plugins")
    }

    func tempRoot() throws -> URL {
        let url = fm.temporaryDirectory.appendingPathComponent("abstract-tracker-links-\(UUID().uuidString)")
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func manager(_ root: URL) throws -> PluginManager {
        PluginManager(store: try Store.inMemory(), pluginsRoot: root.appendingPathComponent("Plugins"),
                      dataRoot: root.appendingPathComponent("PluginData"))
    }

    /// Linear and Jira as bundled, installed and turned on.
    func installTrackers(_ manager: PluginManager) throws {
        for name in ["linear", "jira"] {
            let record = try manager.install(from: plugins.appendingPathComponent("\(name).abstractplugin"), sourceKind: .bundled)
            manager.setEnabled(record.id, true)
        }
    }

    static let linear = "sh.abstract.linear"
    static let jira = "sh.abstract.jira"
    static let core = TrackerProjectLink(team: .init(id: "team:ENG", name: "Engineering", key: "ENG"),
                                         project: .init(id: "project:p-1", name: "Core"))
    static let proj = TrackerProjectLink(project: .init(id: "project:PROJ", name: "Sample project", key: "PROJ"))

    func trackers(_ manager: PluginManager, projectId: String = "p") -> ProjectIssueTrackers {
        ProjectIssueTrackers(projectId: projectId, installed: manager.installed(), storage: manager.storage(for:))
    }

    // MARK: projectSettings

    @Test func bothTrackersOfferAProjectSectionOnlyWhileTheyreOn() throws {
        let root = try tempRoot()
        let manager = try manager(root)
        try installTrackers(manager)
        for id in [Self.linear, Self.jira] {
            let manifest = try #require(manager.installed().first { $0.id == id }?.manifest)
            #expect(manifest.contributes.projectSettings?.id == "project")
            #expect(manifest.appearanceSentences.contains { $0.contains("each project's settings") })
        }
        #expect(Set(PluginContributions.resolve(manager.installed(), place: .projectSettings).map(\.pluginId))
                == [Self.linear, Self.jira])

        manager.setEnabled(Self.jira, false)
        #expect(PluginContributions.resolve(manager.installed(), place: .projectSettings).map(\.pluginId) == [Self.linear])
        manager.setEnabled(Self.jira, true)
        #expect(PluginContributions.resolve(manager.installed(), place: .projectSettings).count == 2)
    }

    @Test func onlyAnIssueTrackerMayHaveAProjectSection() throws {
        let object: [String: Any] = [
            "api": 2, "id": "sh.example.x", "name": "X", "version": "1.0.0", "entry": "index.html",
            "capabilities": [], "background": "background.js",
            "contributes": ["projectSettings": ["id": "project", "title": "X for this project"]],
        ]
        let manifest = try PluginManifest.decode(JSONSerialization.data(withJSONObject: object))
        #expect(throws: PluginValidationError.self) { try manifest.validate() }
    }

    @Test func aSectionReadsAndSavesItsOwnProjectsLinkOnly() throws {
        let root = try tempRoot()
        let storage = PluginStorage(directory: root, pluginId: Self.jira)
        // Not placed in a project: refused, and without needing storage.own.
        var settingsPage = PluginBridge(capabilities: [.cli])
        guard case .refused = settingsPage.handle(#"{"api":2,"type":"projectLink.get","id":"1"}"#, storage: storage) else {
            Issue.record("a page outside a project read a link"); return
        }

        var section = PluginBridge(capabilities: [.cli])
        section.project = (key: "mac:p1", id: "p1")
        guard case .reply(_, let empty) = section.handle(#"{"api":2,"type":"projectLink.get","id":"1"}"#, storage: storage) else {
            Issue.record("the link wasn't read"); return
        }
        #expect(empty["projectKey"] == .string("mac:p1"))
        #expect(empty["link"] == .null)

        let set = #"{"api":2,"type":"projectLink.set","id":"2","payload":{"link":{"project":{"id":"project:PROJ","name":"Sample project","key":"PROJ"}}}}"#
        guard case .projectLinkSaved(_, "mac:p1", let saved) = section.handle(set, storage: storage) else {
            Issue.record("the link wasn't saved"); return
        }
        #expect(TrackerProjectLink(saved["link"]) == Self.proj)
        #expect(TrackerProjectLink.read(storage, projectId: "p1") == Self.proj)
        // Kept per project.
        #expect(TrackerProjectLink.read(storage, projectId: "p2") == nil)
        var other = PluginBridge(capabilities: [.cli])
        other.project = (key: "mac:p2", id: "p2")
        guard case .reply(_, let second) = other.handle(#"{"api":2,"type":"projectLink.get","id":"3"}"#, storage: storage) else {
            Issue.record("the second project's link wasn't read"); return
        }
        #expect(second["link"] == .null)

        // A link that names nothing is refused; null forgets it.
        guard case .refused = section.handle(#"{"api":2,"type":"projectLink.set","id":"4","payload":{"link":{"team":{"name":"x"}}}}"#,
                                             storage: storage) else {
            Issue.record("a malformed link was saved"); return
        }
        guard case .projectLinkSaved = section.handle(#"{"api":2,"type":"projectLink.set","id":"5","payload":{"link":null}}"#,
                                                      storage: storage) else {
            Issue.record("the link wasn't cleared"); return
        }
        #expect(TrackerProjectLink.read(storage, projectId: "p1") == nil)

        // The plugin's own storage calls can't reach a link, even with storage.own.
        TrackerProjectLink.write(Self.proj, to: storage, projectId: "p1")
        var own = PluginBridge(capabilities: [.storageOwn])
        for message in [#"{"api":2,"type":"storage.set","id":"6","payload":{"key":"abstract.projectLink:p1","value":null}}"#,
                        #"{"api":2,"type":"storage.get","id":"7","payload":{"key":"abstract.projectLink:p1"}}"#] {
            guard case .refused = own.handle(message, storage: storage) else {
                Issue.record("storage reached a project link: \(message)"); return
            }
        }
        #expect(TrackerProjectLink.read(storage, projectId: "p1") == Self.proj)
        #expect(TrackerProjectLink.all(in: storage) == ["p1": Self.proj])
    }

    @Test func turningATrackerOffHidesItsLinkAndOnAgainBringsItBack() throws {
        let root = try tempRoot()
        let manager = try manager(root)
        try installTrackers(manager)
        TrackerProjectLink.write(Self.proj, to: manager.storage(for: Self.jira), projectId: "p")
        #expect(trackers(manager).linked.map(\.tracker.pluginId) == [Self.jira])

        manager.setEnabled(Self.jira, false)
        #expect(trackers(manager).linked.isEmpty)
        #expect(trackers(manager).environment.isEmpty)
        manager.setEnabled(Self.jira, true)
        #expect(trackers(manager).linked.first?.link == Self.proj)
    }

    // MARK: What the control shows and searches

    @Test func theControlShowsTheLinkedTrackersOrEveryOneWhenNoneIsLinked() throws {
        let root = try tempRoot()
        let manager = try manager(root)
        try installTrackers(manager)

        // Neither linked: both marks, both searched everywhere.
        let neither = trackers(manager)
        #expect(neither.shown().map(\.pluginId) == [Self.jira, Self.linear])
        #expect(neither.scopes().isEmpty)
        #expect(!neither.canSearchAll)

        // Linear only.
        TrackerProjectLink.write(Self.core, to: manager.storage(for: Self.linear), projectId: "p")
        let linearOnly = trackers(manager)
        #expect(linearOnly.shown().map(\.pluginId) == [Self.linear])
        #expect(linearOnly.scopes() == [Self.linear: "project:p-1"])
        #expect(linearOnly.canSearchAll)
        #expect(linearOnly.shown(searchAll: true).count == 2)
        #expect(linearOnly.scopes(searchAll: true).isEmpty)

        // Both.
        TrackerProjectLink.write(Self.proj, to: manager.storage(for: Self.jira), projectId: "p")
        let both = trackers(manager)
        #expect(both.shown().map(\.pluginId) == [Self.jira, Self.linear])
        #expect(both.scopes() == [Self.linear: "project:p-1", Self.jira: "project:PROJ"])

        // Jira only, in another project.
        TrackerProjectLink.write(Self.proj, to: manager.storage(for: Self.jira), projectId: "q")
        #expect(trackers(manager, projectId: "q").shown().map(\.pluginId) == [Self.jira])
        #expect(trackers(manager, projectId: "q").scopes() == [Self.jira: "project:PROJ"])

        // A Linear team on its own scopes by the team.
        #expect(TrackerProjectLink(team: Self.core.team).scope == "team:ENG")
        #expect(Self.core.title == "Engineering · Core")
    }

    @Test func eachTrackerIsSearchedWithinItsLink() async {
        let linear = ResolvedIssueTracker(pluginId: Self.linear, declaration: .init(title: "Linear", keyExample: "ENG-1",
                                                                                     keyPattern: "[A-Za-z]+-[0-9]+"))
        let jira = ResolvedIssueTracker(pluginId: Self.jira, declaration: .init(title: "Jira", keyExample: "PROJ-1",
                                                                                 keyPattern: "[A-Za-z]+-[0-9]+"))
        let asked = Asked()
        _ = await PluginIssueTrackers.search("login", trackers: [jira, linear],
                                             scopes: [Self.jira: "project:PROJ", Self.linear: "team:ENG"]) { tracker, request in
            if case .searchIssues = request { await asked.add(tracker.pluginId, request) }
            return request == .access ? .access(TrackerAccess(ready: true)) : .issues([])
        }
        #expect(await asked.requests == [Self.jira: .searchIssues(query: "login", project: "project:PROJ"),
                                         Self.linear: .searchIssues(query: "login", project: "team:ENG")])
    }

    actor Asked {
        var requests: [String: TrackerRequest] = [:]
        func add(_ id: String, _ request: TrackerRequest) { requests[id] = request }
    }

    // MARK: Icons

    @Test func jirasIconKeepsItsColoursAndLinearsTakesTheTextColour() throws {
        let jira = try #require(PluginPackage.fileData(in: plugins.appendingPathComponent("jira.abstractplugin"), relativePath: "icon.svg"))
        let linear = try #require(PluginPackage.fileData(in: plugins.appendingPathComponent("linear.abstractplugin"), relativePath: "icon.svg"))
        #expect(!PluginIssueTrackerDeclaration.iconIsTemplate(jira, path: "icon.svg"))
        #expect(String(decoding: jira, as: UTF8.self).contains("linearGradient"))
        #expect(PluginIssueTrackerDeclaration.iconIsTemplate(linear, path: "icon.svg"))
        #expect(PluginIssueTrackerDeclaration.iconIsTemplate(Data(#"<svg><path fill="currentColor" d="M0 0"/></svg>"#.utf8), path: "a.svg"))
        #expect(PluginIssueTrackerDeclaration.iconIsTemplate(Data(#"<svg><path fill="none" stroke="currentColor"/></svg>"#.utf8), path: "a.svg"))
        #expect(!PluginIssueTrackerDeclaration.iconIsTemplate(Data(#"<svg><path style="fill: #f00"/></svg>"#.utf8), path: "a.svg"))
        #expect(PluginIssueTrackerDeclaration.iconIsTemplate(Data([0x89, 0x50]), path: "icon.png"))
    }

    // MARK: Plugins and agents

    @Test func theSnapshotAndTheAgentAreToldTheLinks() throws {
        let root = try tempRoot()
        let manager = try manager(root)
        try installTrackers(manager)
        TrackerProjectLink.write(Self.core, to: manager.storage(for: Self.linear), projectId: "p")
        TrackerProjectLink.write(Self.proj, to: manager.storage(for: Self.jira), projectId: "p")
        let linked = trackers(manager)

        #expect(linked.environment == ["ABSTRACT_LINEAR_TEAM": "ENG", "ABSTRACT_LINEAR_PROJECT": "Core",
                                       "ABSTRACT_JIRA_PROJECT": "PROJ"])

        let row = PluginSnapshot.Project(key: "mac:p", name: "App", macId: "mac", archived: false,
                                         issueTrackers: linked.snapshot)
        let snapshot = PluginSnapshot.build(revision: 1, capabilities: [.projectsRead], macs: [], projects: [row], chats: [])
        #expect(snapshot.jsonValue()["projects"]?.array?.first?["issueTrackers"] == .array([
            .object(["tracker": .string("Jira"), "project": .string("PROJ")]),
            .object(["tracker": .string("Linear"), "project": .string("Core"), "team": .string("ENG")]),
        ]))
        // Without projects.read there is no project row at all.
        #expect(PluginSnapshot.build(revision: 1, capabilities: [.chatsRead], macs: [], projects: [row], chats: []).projects == nil)
        // An unlinked project's row has no key for it.
        let plain = PluginSnapshot.Project(key: "mac:q", name: "Other", macId: "mac", archived: false)
        let unlinked = PluginSnapshot.build(revision: 1, capabilities: [.projectsRead], macs: [], projects: [plain], chats: [])
        #expect(unlinked.jsonValue()["projects"]?.array?.first?["issueTrackers"] == nil)

        var session = Session(projectId: "p", name: "Chat", providerId: "claude")
        var settings = LaunchSettings(providerOverrides: [:], outputStyle: .default, claudeProfile: nil,
                                      attachmentsDirectory: "/tmp/attachments")
        settings.addIssueTrackers(for: session, plugins: manager)
        let spec = AgentLaunch.spec(for: session, provider: ClaudeProvider(), prompt: "hi", resumeId: nil,
                                    settings: settings, home: "/tmp")
        #expect(spec.env["ABSTRACT_JIRA_PROJECT"] == "PROJ")
        #expect(spec.env["ABSTRACT_LINEAR_TEAM"] == "ENG")
        #expect(spec.env["CLAUDE_CODE_BASH_EDIT_DIFF"] == "1")

        // A chat in a project with no links is told nothing.
        session.projectId = "unlinked"
        var bare = LaunchSettings(providerOverrides: [:], outputStyle: .default, claudeProfile: nil,
                                  attachmentsDirectory: "/tmp/attachments")
        bare.addIssueTrackers(for: session, plugins: manager)
        #expect(bare.environment.isEmpty)
    }

    @Test func installedBundledTrackersFollowTheAppsCopy() throws {
        let root = try tempRoot()
        let manager = try manager(root)
        // An older bundled Jira, on.
        let old = root.appendingPathComponent("old-jira")
        try fm.copyItem(at: plugins.appendingPathComponent("jira.abstractplugin"), to: old)
        let manifestURL = old.appendingPathComponent("manifest.json")
        let text = try String(contentsOf: manifestURL, encoding: .utf8)
            .replacingOccurrences(of: #""version": "1.1.0""#, with: #""version": "1.0.0""#)
        try text.write(to: manifestURL, atomically: true, encoding: .utf8)
        try manager.install(from: old, sourceKind: .bundled)
        manager.setEnabled(Self.jira, true)

        #expect(manager.updateBundled(from: [plugins.appendingPathComponent("jira.abstractplugin")]))
        let record = try #require(manager.records().first { $0.id == Self.jira })
        #expect(record.version == "1.1.0")
        #expect(record.enabled)
        // Nothing to do the second time.
        #expect(!manager.updateBundled(from: [plugins.appendingPathComponent("jira.abstractplugin")]))
    }
}
