import Foundation
import Testing
@testable import AbstractCore

@Suite struct CommandLineInstallTests {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cli-install-\(UUID().uuidString)")
    var link: String { dir.appendingPathComponent("bin/abstract").path }

    /// A stand-in for the copy inside the app, in a folder with a space and a quote in its name.
    private func makeTool(_ name: String = "Abstract's App.app") throws -> String {
        let helpers = dir.appendingPathComponent("\(name)/Contents/Helpers")
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        let tool = helpers.appendingPathComponent("abstract").path
        FileManager.default.createFile(atPath: tool, contents: Data("#!/bin/sh\n".utf8))
        return tool
    }

    @Test func installsALinkToThisAppsCopy() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let tool = try makeTool()
        #expect(CommandLineInstall.status(link: link, tool: tool) == .notInstalled)
        #expect(CommandLineInstall.install(link: link, tool: tool))
        #expect(CommandLineInstall.status(link: link, tool: tool) == .installed)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link) == tool)

        #expect(CommandLineInstall.uninstall(link: link))
        #expect(CommandLineInstall.status(link: link, tool: tool) == .notInstalled)
    }

    @Test func aLinkToAnotherCopyIsRelinked() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let old = try makeTool("Old Abstract.app")
        let tool = try makeTool()
        #expect(CommandLineInstall.install(link: link, tool: old))
        #expect(CommandLineInstall.status(link: link, tool: tool) == .linkedElsewhere(old))
        #expect(CommandLineInstall.install(link: link, tool: tool))
        #expect(CommandLineInstall.status(link: link, tool: tool) == .installed)
    }

    @Test func somethingThatIsntALinkIsLeftAlone() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let tool = try makeTool()
        try FileManager.default.createDirectory(atPath: (link as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: link, contents: Data("someone else's".utf8))
        #expect(CommandLineInstall.status(link: link, tool: tool) == .blocked)
        #expect(!CommandLineInstall.install(link: link, tool: tool))
        #expect(!CommandLineInstall.uninstall(link: link))
        #expect(try String(contentsOfFile: link, encoding: .utf8) == "someone else's")
    }

    @Test func theAdministratorCommandQuotesItsPaths() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let tool = try makeTool()
        let install = try await LocalExecutor.shared.run("/bin/sh", ["-c", CommandLineInstall.installCommand(link: link, tool: tool)], cwd: nil)
        #expect(install.ok, "\(install.stderr)")
        #expect(CommandLineInstall.status(link: link, tool: tool) == .installed)
        let remove = try await LocalExecutor.shared.run("/bin/sh", ["-c", CommandLineInstall.uninstallCommand(link: link)], cwd: nil)
        #expect(remove.ok)
        #expect(CommandLineInstall.status(link: link, tool: tool) == .notInstalled)
    }
}
