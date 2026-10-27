import Foundation
import Testing
@testable import AbstractCore

@Suite struct PluginTests {
    let fm = FileManager.default

    func tempRoot() throws -> URL {
        let url = fm.temporaryDirectory.appendingPathComponent("abstract-plugin-tests-\(UUID().uuidString)")
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func manager(root: URL, store: Store? = nil) throws -> PluginManager {
        PluginManager(store: try store ?? Store.inMemory(),
                      pluginsRoot: root.appendingPathComponent("Plugins"),
                      dataRoot: root.appendingPathComponent("PluginData"))
    }

    /// A minimal valid package folder.
    @discardableResult
    func package(in root: URL, id: String = "sh.abstract.chat-count", name: String = "Chat count",
                 version: String = "1.0.0", api: Int = 1, entry: String = "index.html",
                 capabilities: [String] = ["chats.read", "chats.open", "storage.own"],
                 writeEntry: Bool = true) throws -> URL {
        let folder = root.appendingPathComponent("pkg-\(UUID().uuidString)")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let manifest: [String: Any] = [
            "api": api, "id": id, "name": name, "version": version,
            "description": "Counts chats.", "entry": entry, "capabilities": capabilities,
            "contributes": ["views": [["id": "main", "title": name, "symbol": "number", "location": "main"]]],
        ]
        try JSONSerialization.data(withJSONObject: manifest)
            .write(to: folder.appendingPathComponent("manifest.json"))
        if writeEntry, !entry.isEmpty, !entry.contains("..") {
            try "<html><body>hi</body></html>".write(to: folder.appendingPathComponent(entry), atomically: true, encoding: .utf8)
        }
        return folder
    }

    func expectRefusal(_ body: () throws -> Void, _ check: (PluginValidationError) -> Bool) {
        do {
            try body()
            Issue.record("expected a refusal")
        } catch let error as PluginValidationError {
            #expect(check(error), "unexpected refusal: \(error.detail)")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    // MARK: Manifest and package validation

    @Test func aValidPackageInspects() throws {
        let root = try tempRoot()
        let folder = try package(in: root)
        let inspection = try PluginPackage.inspect(folder: folder)
        #expect(inspection.manifest.id == "sh.abstract.chat-count")
        #expect(inspection.manifest.grantedCapabilities == [.chatsRead, .chatsOpen, .storageOwn])
        #expect(!inspection.hash.isEmpty)
    }

    @Test func unsupportedAPIMissingEntryAndUnknownCapabilityAreRefused() throws {
        let root = try tempRoot()
        expectRefusal({ _ = try PluginPackage.inspect(folder: package(in: root, api: 99)) }) {
            if case .unsupportedAPI(99, _) = $0 { return true }; return false
        }
        expectRefusal({ _ = try PluginPackage.inspect(folder: package(in: root, capabilities: ["network.all"])) }) {
            if case .unknownCapability("network.all") = $0 { return true }; return false
        }
        expectRefusal({ _ = try PluginPackage.inspect(folder: package(in: root, writeEntry: false)) }) {
            if case .missingEntry = $0 { return true }; return false
        }
        expectRefusal({ _ = try PluginPackage.inspect(folder: package(in: root, entry: "../secret.html")) }) {
            if case .escapingPath = $0 { return true }; return false
        }
        expectRefusal({ _ = try PluginPackage.inspect(folder: package(in: root, id: "not-reverse-dns")) }) {
            if case .invalidManifest = $0 { return true }; return false
        }
        expectRefusal({ _ = try PluginPackage.inspect(folder: package(in: root, version: "v1")) }) {
            if case .invalidManifest = $0 { return true }; return false
        }
    }

    @Test func badJSONSymlinksExecutablesAndOversizeAreRefused() throws {
        let root = try tempRoot()

        let bad = try package(in: root)
        try "{nope".write(to: bad.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        expectRefusal({ _ = try PluginPackage.inspect(folder: bad) }) {
            if case .invalidManifest = $0 { return true }; return false
        }

        let linked = try package(in: root)
        try fm.createSymbolicLink(at: linked.appendingPathComponent("link.html"),
                                  withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        expectRefusal({ _ = try PluginPackage.inspect(folder: linked) }) {
            if case .symlink = $0 { return true }; return false
        }

        let executable = try package(in: root)
        let script = executable.appendingPathComponent("run.sh")
        try "#!/bin/sh\n".write(to: script, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        expectRefusal({ _ = try PluginPackage.inspect(folder: executable) }) {
            if case .executableFile = $0 { return true }; return false
        }

        let big = try package(in: root)
        expectRefusal({ _ = try PluginPackage.inspect(folder: big, sizeLimit: 10) }) {
            if case .tooLarge = $0 { return true }; return false
        }
    }

    @Test func packageFilesAreServedOnlyFromInside() throws {
        let root = try tempRoot()
        let folder = try package(in: root)
        #expect(PluginPackage.fileData(in: folder, relativePath: "index.html") != nil)
        #expect(PluginPackage.fileData(in: folder, relativePath: "../manifest.json") == nil)
        #expect(PluginPackage.fileData(in: folder, relativePath: "/etc/hosts") == nil)
        #expect(PluginPackage.fileData(in: folder, relativePath: "nope.css") == nil)
    }

    // MARK: Install, enable, disable, remove

    @Test func installEnableDisableRemoveSurviveRelaunch() throws {
        let root = try tempRoot()
        let first = try manager(root: root)
        let folder = try package(in: root)
        let record = try first.install(from: folder, sourceKind: .bundled)
        #expect(record.enabled == false)
        #expect(record.grantedCapabilities.isEmpty)

        // Its own storage, through the bridge's store.
        try first.storage(for: record.id).set(.bool(true), forKey: "showDone")
        first.setEnabled(record.id, true)

        // Relaunch: a new manager over the same store and folders.
        let second = PluginManager(store: first.store, pluginsRoot: first.pluginsRoot, dataRoot: first.dataRoot)
        let installed = second.installed()
        #expect(installed.count == 1)
        #expect(installed.first?.isUsable == true)
        #expect(installed.first?.record.grantedCapabilities == [.chatsRead, .chatsOpen, .storageOwn])
        #expect(try second.storage(for: record.id).value(forKey: "showDone") == .bool(true))

        second.setEnabled(record.id, false)
        #expect(second.installed().first?.isUsable == false)
        // Disable keeps storage.
        #expect(try second.storage(for: record.id).value(forKey: "showDone") == .bool(true))

        second.remove(record.id)
        #expect(second.installed().isEmpty)
        #expect(second.records().isEmpty)
        #expect(!fm.fileExists(atPath: first.packageURL(for: record).path))
        #expect(!fm.fileExists(atPath: second.storage(for: record.id).fileURL.path))
    }

    @Test func changedFilesTurnAPluginOffUntilReviewedAgain() throws {
        let root = try tempRoot()
        let host = try manager(root: root)
        let record = try host.install(from: package(in: root), sourceKind: .user)
        host.setEnabled(record.id, true)
        try "<html>tampered</html>".write(
            to: host.packageURL(for: record).appendingPathComponent("index.html"), atomically: true, encoding: .utf8)

        let found = try #require(host.installed().first)
        #expect(found.isUsable == false)
        #expect(found.record.enabled == false)
        #expect(found.problem?.contains("changed since you installed it") == true)

        host.reviewChangedPackage(record.id)
        let reviewed = try #require(host.installed().first)
        #expect(reviewed.problem == nil)
        #expect(reviewed.record.enabled == false)
        host.setEnabled(record.id, true)
        #expect(host.installed().first?.isUsable == true)
    }

    @Test func aMissingOrCorruptPackageIsListedNotFatal() throws {
        let root = try tempRoot()
        let host = try manager(root: root)
        let record = try host.install(from: package(in: root), sourceKind: .user)
        host.setEnabled(record.id, true)
        try fm.removeItem(at: host.packageURL(for: record))

        let found = try #require(host.installed().first)
        #expect(found.isUsable == false)
        #expect(found.problem != nil)

        // A broken folder nobody installed is reported, not run.
        let orphan = host.pluginsRoot.appendingPathComponent("sh.example.broken/9.9.9")
        try fm.createDirectory(at: orphan, withIntermediateDirectories: true)
        try "{".write(to: orphan.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        #expect(host.orphanedProblems().contains { $0.name == "sh.example.broken" })
    }

    @Test func anUpdateThatAsksForMoreLandsDisabled() throws {
        let root = try tempRoot()
        let host = try manager(root: root)
        let record = try host.install(from: package(in: root, capabilities: ["chats.read"]), sourceKind: .user)
        host.setEnabled(record.id, true)

        let updated = try host.install(
            from: package(in: root, version: "1.1.0", capabilities: ["chats.read", "projects.read"]), sourceKind: .user)
        #expect(updated.enabled == false)
        #expect(updated.grantedCapabilities.isEmpty)
        // One installed version per plugin.
        #expect(!fm.fileExists(atPath: host.packageURL(for: record).path))

        // An update that asks for no more keeps its grant.
        host.setEnabled(record.id, true)
        let sameCaps = try host.install(
            from: package(in: root, version: "1.2.0", capabilities: ["chats.read", "projects.read"]), sourceKind: .user)
        #expect(sameCaps.enabled == true)
        #expect(sameCaps.grantedCapabilities == [.chatsRead, .projectsRead])
    }

    @Test func transcriptProjectsArePickedAtReviewAndSurviveRelaunch() throws {
        let root = try tempRoot()
        let host = try manager(root: root)
        let record = try host.install(
            from: package(in: root, capabilities: ["chats.read", "transcripts.read"]), sourceKind: .user)
        host.setEnabled(record.id, true, transcriptProjectKeys: ["mac-1:p1"])

        let second = PluginManager(store: host.store, pluginsRoot: host.pluginsRoot, dataRoot: host.dataRoot)
        #expect(second.records().first?.transcriptProjectKeys == ["mac-1:p1"])
        #expect(second.records().first?.grantedCapabilities.contains(.transcriptsRead) == true)

        second.setTranscriptProjectKeys(record.id, ["mac-1:p2"])
        #expect(second.records().first?.transcriptProjectKeys == ["mac-1:p2"])

        // An update asking for more loses the pick along with the grant.
        let updated = try second.install(
            from: package(in: root, version: "1.1.0", capabilities: ["chats.read", "transcripts.read", "usage.read"]),
            sourceKind: .user)
        #expect(updated.transcriptProjectKeys.isEmpty)
    }

    @Test func aZipOfAPackageInstalls() throws {
        let root = try tempRoot()
        let folder = try package(in: root)
        let zip = root.appendingPathComponent("chat-count.zip")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", folder.path, zip.path]
        try ditto.run()
        ditto.waitUntilExit()
        #expect(ditto.terminationStatus == 0)

        let host = try manager(root: root)
        let picked = try host.inspectPicked(zip)
        defer { picked.cleanup.map { try? fm.removeItem(at: $0) } }
        #expect(picked.inspection.manifest.name == "Chat count")
        let record = try host.install(from: picked.folder, sourceKind: .user)
        host.setEnabled(record.id, true)
        #expect(host.installed().first?.isUsable == true)
    }

    // MARK: Snapshot allowlist

    func snapshotInput() -> (macs: [PluginSnapshot.Mac], projects: [PluginSnapshot.Project], chats: [PluginSnapshot.ChatInput]) {
        var session = Session(id: "chat-1", projectId: "project-1", name: "Fix the thing", providerId: "claude",
                              providerSessionId: "provider-secret", worktreePath: "/Users/someone/secret",
                              branch: "fix/thing", status: .waitingInput, prompt: "a private prompt",
                              createdAt: Date(timeIntervalSince1970: 1_000), lastEventAt: Date(timeIntervalSince1970: 2_000))
        session.pinnedAt = Date(timeIntervalSince1970: 1_500)
        let chat = SidebarChats.Chat(session: session,
                                     pullRequest: .init(number: 7, state: .open, checks: .failing, changesRequested: true),
                                     hasChanges: true, backgroundTasks: 2, projectName: "abstract", mac: "Studio")
        return ([.init(id: "mac-1", name: "Studio", isThisMac: true, reachable: true),
                 .init(id: "mac-2", name: "Laptop", isThisMac: false, reachable: false)],
                [.init(key: PluginSnapshot.projectKey(macId: "mac-1", projectId: "project-1"),
                       name: "abstract", macId: "mac-1", archived: false)],
                [.init(chat: chat, projectKey: PluginSnapshot.projectKey(macId: "mac-1", projectId: "project-1"), macId: "mac-1")])
    }

    @Test func theSnapshotCarriesOnlyAllowlistedFields() throws {
        let input = snapshotInput()
        let snapshot = PluginSnapshot.build(revision: 3, now: Date(timeIntervalSince1970: 3_000),
                                            capabilities: Set(PluginCapability.allCases),
                                            macs: input.macs, projects: input.projects, chats: input.chats)
        let json = snapshot.jsonValue()
        let text = json.compact()
        // Deliberately excluded (ABS-84 §4): paths, prompts, provider ids…
        #expect(!text.contains("secret"))
        #expect(!text.contains("private prompt"))
        #expect(!text.contains("/Users/"))

        #expect(Set((json.object ?? [:]).keys) == ["revision", "generatedAt", "macs", "projects", "chats"])
        let chat = try #require(json["chats"]?.array?.first?.object)
        #expect(Set(chat.keys) == ["id", "title", "projectKey", "agentId", "branch", "status", "progress",
                                   "pinned", "archived", "createdAt", "lastActivityAt", "hasChanges",
                                   "backgroundTasks", "pullRequest", "macId", "stalled"])
        #expect(chat["progress"] == .string("needsYou"))
        #expect(chat["pinned"] == .bool(true))
        let project = try #require(json["projects"]?.array?.first?.object)
        #expect(Set(project.keys) == ["key", "name", "macId", "archived"])
        let mac = try #require(json["macs"]?.array?.first?.object)
        #expect(Set(mac.keys) == ["id", "name", "isThisMac", "reachable"])
        let pr = try #require(chat["pullRequest"]?.object)
        #expect(Set(pr.keys) == ["number", "state", "isDraft", "checks", "changesRequested", "comments", "failedChecks"])
        #expect(pr["checks"] == .string("failing"))
    }

    @Test func capabilitiesGateTheSnapshotSections() {
        let input = snapshotInput()
        let chatsOnly = PluginSnapshot.build(revision: 1, capabilities: [.chatsRead],
                                             macs: input.macs, projects: input.projects, chats: input.chats)
        #expect(chatsOnly.projects == nil)
        #expect(chatsOnly.chats?.count == 1)
        #expect(chatsOnly.jsonValue()["projects"] == nil)

        let projectsOnly = PluginSnapshot.build(revision: 1, capabilities: [.projectsRead],
                                                macs: input.macs, projects: input.projects, chats: input.chats)
        #expect(projectsOnly.chats == nil)
        #expect(projectsOnly.projects?.count == 1)

        let none = PluginSnapshot.build(revision: 1, capabilities: [], macs: input.macs,
                                        projects: input.projects, chats: input.chats)
        #expect(none.chats == nil && none.projects == nil)
        #expect(none.macs.count == 2)
    }

    // MARK: Bridge

    func storage(root: URL) throws -> PluginStorage {
        let dir = root.appendingPathComponent("PluginData")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return PluginStorage(directory: dir, pluginId: "sh.abstract.chat-count")
    }

    @Test func openChatNeedsTheGrantAndAKnownChat() throws {
        let root = try tempRoot()
        let store = try storage(root: root)
        var bridge = PluginBridge(capabilities: [.chatsRead])
        bridge.knownChatIds = ["chat-1"]
        let denied = bridge.handle(#"{"api":1,"type":"openChat","id":"1","payload":{"chatId":"chat-1"}}"#, storage: store)
        #expect(denied == .refused(id: "1", reason: "This plugin hasn't been granted opening chats."))
        #expect(bridge.refusalCount == 1)

        bridge.capabilities.insert(.chatsOpen)
        let unknown = bridge.handle(#"{"api":1,"type":"openChat","id":"2","payload":{"chatId":"made-up"}}"#, storage: store)
        if case .refused = unknown {} else { Issue.record("made-up chat wasn't refused: \(unknown)") }

        let ok = bridge.handle(#"{"api":1,"type":"openChat","id":"3","payload":{"chatId":"chat-1"}}"#, storage: store)
        #expect(ok == .openChat(id: "3", chatId: "chat-1"))
    }

    @Test func storageNeedsItsGrantAndKeepsItsLimit() throws {
        let root = try tempRoot()
        let store = try storage(root: root)
        var bridge = PluginBridge(capabilities: [.chatsRead])
        let denied = bridge.handle(#"{"api":1,"type":"storage.set","id":"1","payload":{"key":"k","value":true}}"#, storage: store)
        if case .refused = denied {} else { Issue.record("storage without grant wasn't refused") }
        #expect(try store.value(forKey: "k") == nil)

        bridge.capabilities.insert(.storageOwn)
        let saved = bridge.handle(#"{"api":1,"type":"storage.set","id":"2","payload":{"key":"showDone","value":true}}"#, storage: store)
        if case .reply = saved {} else { Issue.record("storage.set didn't reply: \(saved)") }
        let read = bridge.handle(#"{"api":1,"type":"storage.get","id":"3","payload":{"key":"showDone"}}"#, storage: store)
        #expect(read == .reply(id: "3", .object(["key": .string("showDone"), "value": .bool(true)])))

        // A value that would pass 512 KB is refused and nothing is written.
        let big = String(repeating: "x", count: PluginStorage.byteLimit)
        let payload = JSONValue.object(["api": .number(1), "type": .string("storage.set"), "id": .string("4"),
                                        "payload": .object(["key": .string("big"), "value": .string(big)])]).compact()
        // (Over the per-message cap too, so this one is refused unread.)
        if case .refused = bridge.handle(payload, storage: store) {} else { Issue.record("oversize wasn't refused") }
        #expect(try store.set(.string(big), forKey: "big") == false)
        #expect(try store.value(forKey: "big") == nil)
    }

    @Test func unknownAndOversizeMessagesAreRefusedNotFatal() throws {
        let root = try tempRoot()
        let store = try storage(root: root)
        var bridge = PluginBridge(capabilities: Set(PluginCapability.allCases))
        if case .refused = bridge.handle(#"{"api":1,"type":"runCommand","payload":{"cmd":"rm"}}"#, storage: store) {} else {
            Issue.record("unknown type wasn't refused")
        }
        if case .refused = bridge.handle("not json", storage: store) {} else { Issue.record("garbage wasn't refused") }
        if case .refused = bridge.handle(#"{"api":99,"type":"getSnapshot"}"#, storage: store) {} else {
            Issue.record("newer api wasn't refused")
        }
        #expect(bridge.refusalCount == 3)
        // API 1 and API 2 plugins both speak to this host (ABS-92).
        let snapshot = bridge.handle(#"{"api":1,"type":"getSnapshot","id":"9"}"#, storage: store)
        #expect(snapshot == .getSnapshot(id: "9"))
        #expect(bridge.handle(#"{"api":2,"type":"getSnapshot","id":"10"}"#, storage: store) == .getSnapshot(id: "10"))
    }

    @Test func floodingTheBridgeIsDetected() throws {
        let root = try tempRoot()
        let store = try storage(root: root)
        var bridge = PluginBridge(capabilities: [.chatsRead])
        let now = Date()
        var flooded = false
        for _ in 0...PluginBridge.floodCount {
            if bridge.handle(#"{"api":1,"type":"getSnapshot"}"#, storage: store, now: now) == .flooded { flooded = true }
        }
        #expect(flooded)
    }

    @Test func corruptPluginStorageReadsAsAProblem() throws {
        let root = try tempRoot()
        let store = try storage(root: root)
        try "{broken".write(to: store.fileURL, atomically: true, encoding: .utf8)
        #expect(throws: PluginValidationError.self) { _ = try store.values() }
    }

    @Test func theBundledSampleManifestIsValid() throws {
        // The sample ships in the app bundle; its source lives beside the app.
        let here = URL(fileURLWithPath: #filePath)
        let repo = here.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sample = repo.appendingPathComponent("Abstract/Resources/Plugins/chat-count.abstractplugin")
        guard fm.fileExists(atPath: sample.path) else { return }
        let inspection = try PluginPackage.inspect(folder: sample)
        #expect(inspection.manifest.id == "sh.abstract.chat-count")
        #expect(inspection.manifest.grantedCapabilities == [.chatsRead, .chatsOpen, .storageOwn])
    }

    @Test func contextCarriesEveryTheme() {
        for theme in Theme.allCases {
            let context = PluginContext.jsonValue(theme: theme, locale: "en_US", pluginId: "sh.abstract.chat-count",
                                                  pluginVersion: "1.0.0", capabilities: [.chatsRead])
            #expect(context["theme"] == .string(theme.rawValue))
            #expect(context["tokens"]?["canvas"]?.string?.hasPrefix("#") == true)
            #expect(context["tokens"]?["text"]?.string?.hasPrefix("#") == true)
        }
    }
}
