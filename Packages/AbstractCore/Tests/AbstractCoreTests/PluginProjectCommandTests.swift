import Foundation
import Testing
@testable import AbstractCore

@Suite struct PluginProjectCommandTests {
    func setup() throws -> (root: URL, project: Project, manager: PluginManager, commands: Commands) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("abstract-plugin-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let storePath = root.appendingPathComponent("abstract.sqlite").path
        let store = try Store(path: storePath)
        let project = Project(name: "App", rootPath: root.appendingPathComponent("repo").path)
        try FileManager.default.createDirectory(atPath: project.rootPath, withIntermediateDirectories: true)
        try store.save(project)
        let manager = PluginManager(store: store, pluginsRoot: root.appendingPathComponent("Plugins"),
                                    dataRoot: root.appendingPathComponent("PluginData"))
        let fixtures = try #require(Bundle.module.url(forResource: "Fixtures/trackers", withExtension: nil))
        for name in ["linear", "jira"] {
            let record = try manager.install(from: fixtures.appendingPathComponent("\(name).abstractplugin"), sourceKind: .bundled)
            manager.setEnabled(record.id, true)
        }
        let commands = Commands(store: store, storePath: storePath, locks: root.appendingPathComponent("locks"),
                                executable: "/tmp/abstract")
        return (root, project, manager, commands)
    }

    @Test func enabledTrackersContributeCommandsAndUseTheirOwnStorage() throws {
        let (root, project, manager, commands) = try setup()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(commands.pluginCommands().map(\.command).contains("abstract plugin linear link-project"))
        #expect(commands.pluginCommands().map(\.command).contains("abstract plugin jira project-link"))

        let linear = Data(#"{"workspace":"example","team":{"id":"team:ENG","name":"Engineering","key":"ENG"}}"#.utf8)
        let saved = try commands.setPluginProjectLink(plugin: "linear", project: project.id,
                                                      linkFile: "-", stdin: { linear })
        #expect(saved.link?.workspace == "example")
        #expect(saved.link?.team?.key == "ENG")
        #expect(try commands.pluginProjectLink(plugin: "sh.abstract.linear", project: project.rootPath).link == saved.link)
        #expect(TrackerProjectLink.read(manager.storage(for: "sh.abstract.linear"), projectId: project.id) == saved.link)
        #expect(TrackerProjectLink.read(manager.storage(for: "sh.abstract.jira"), projectId: project.id) == nil)

        let jira = Data(#"{"project":{"id":"project:PROJ","name":"Project","key":"PROJ"}}"#.utf8)
        let jiraFile = root.appendingPathComponent("jira.json")
        try jira.write(to: jiraFile)
        let jiraSaved = try commands.setPluginProjectLink(plugin: "Jira", project: "App",
                                                          linkFile: jiraFile.path, stdin: { Data() })
        #expect(jiraSaved.link?.project?.key == "PROJ")
        #expect(try commands.clearPluginProjectLink(plugin: "linear", project: project.id).link == nil)
        #expect(try commands.pluginProjectLink(plugin: "linear", project: project.id).link == nil)
        #expect(try commands.pluginProjectLink(plugin: "jira", project: project.id).link == jiraSaved.link)
    }

    @Test func badInputDoesNotReplaceALinkAndDisabledPluginsOfferNoCommands() throws {
        let (root, project, manager, commands) = try setup()
        defer { try? FileManager.default.removeItem(at: root) }
        let valid = Data(#"{"workspace":"example"}"#.utf8)
        _ = try commands.setPluginProjectLink(plugin: "linear", project: project.id, linkFile: "-", stdin: { valid })
        for input in [Data("not JSON".utf8), Data(#"{"team":{"id":"team:ENG"}}"#.utf8)] {
            #expect(throws: CLIError.self) {
                try commands.setPluginProjectLink(plugin: "linear", project: project.id, linkFile: "-", stdin: { input })
            }
        }
        #expect(try commands.pluginProjectLink(plugin: "linear", project: project.id).link?.workspace == "example")

        manager.setEnabled("sh.abstract.linear", false)
        #expect(!commands.pluginCommands().map(\.command).contains("abstract plugin linear link-project"))
        #expect(throws: CLIError.self) { try commands.pluginProjectLink(plugin: "linear", project: project.id) }
        #expect(TrackerProjectLink.read(manager.storage(for: "sh.abstract.linear"), projectId: project.id)?.workspace == "example")
    }

    @Test func terminalRoutesAPluginCommandAndPrintsJSON() throws {
        let (root, project, _, _) = try setup()
        defer { try? FileManager.default.removeItem(at: root) }
        let linkFile = root.appendingPathComponent("linear.json")
        try Data(#"{"workspace":"example"}"#.utf8).write(to: linkFile)
        let process = Process()
        process.executableURL = Bundle.module.bundleURL.deletingLastPathComponent().appendingPathComponent("abstract")
        process.arguments = ["plugin", "linear", "link-project", "--link-file", linkFile.path]
        let nested = URL(fileURLWithPath: project.rootPath).appendingPathComponent("Sources")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        process.currentDirectoryURL = nested
        var environment = ProcessInfo.processInfo.environment
        environment["ABSTRACT_DATA_DIR"] = root.path
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let result = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(result["plugin"]?.string == "sh.abstract.linear")
        #expect(result["projectId"]?.string == project.id)
        #expect(result["link"]?["workspace"]?.string == "example")
    }

    @Test func currentWorktreeSelectsItsProjectAndUnrelatedFoldersNeedAProject() throws {
        let (root, project, _, commands) = try setup()
        defer { try? FileManager.default.removeItem(at: root) }
        let worktree = root.appendingPathComponent("chat-worktree")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try commands.store.save(Session(projectId: project.id, name: "Chat", providerId: "claude",
                                        worktreePath: worktree.path))
        #expect(try commands.pluginProjectLink(plugin: "linear", cwd: worktree.path).projectId == project.id)
        #expect(throws: CLIError.self) { try commands.pluginProjectLink(plugin: "linear", cwd: root.path) }
        #expect(try commands.pluginProjectLink(plugin: "linear", project: "App", cwd: root.path).projectId == project.id)
    }
}
