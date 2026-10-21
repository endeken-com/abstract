import Foundation
import Synchronization
import Testing
@testable import AbstractCore

/// Records every run instead of starting a process; a run can be held
/// until the test lets it go.
private final class FakeCLI: Executor {
    let installed: Set<String>
    let runs = Mutex<[(command: String, args: [String], cwd: String?)]>([])
    let gate: AsyncStream<Void>?
    let started: AsyncStream<Void>.Continuation?

    init(installed: Set<String> = ["gh"], gate: AsyncStream<Void>? = nil, started: AsyncStream<Void>.Continuation? = nil) {
        self.installed = installed; self.gate = gate; self.started = started
    }

    var homeDirectory: String { "/Users/test" }

    func run(_ command: String, _ args: [String], cwd: String?, stdin: Data?) async throws -> ExecResult {
        runs.withLock { $0.append((command, args, cwd)) }
        started?.yield()
        if let gate { for await _ in gate { break } }
        return ExecResult(code: 0, stdout: "ran " + args.joined(separator: " "), stderr: "")
    }

    func spawn(_ spec: LaunchSpec, onLine: @escaping @Sendable (OutputLine) -> Void,
               onExit: @escaping @Sendable (Int32?) -> Void) throws -> RunningProcess {
        throw AbstractError.message("not here")
    }
    func fileExists(_ path: String) -> Bool { false }
    func readFile(_ path: String) throws -> String { throw AbstractError.notFound(path) }
    func createDirectory(_ path: String) throws {}
    func removeItem(_ path: String) throws {}
    func which(_ binary: String) async -> String? { installed.contains(binary) ? "/opt/homebrew/bin/\(binary)" : nil }

    var all: [(command: String, args: [String], cwd: String?)] { runs.withLock { $0 } }
}

/// The `cli` capability (ABS-139): declared in the manifest, checked at the
/// bridge, run by the host in a readable folder, reads in the git budget,
/// writes asking first.
@Suite struct PluginCLITests {
    static let gh = PluginCLI(binary: "gh", install: "brew install gh", commands: [
        .init(["auth", "status"], .read), .init(["pr", "list"], .read), .init(["pr", "view"], .read),
        .init(["api", "graphql"], .read), .init(["issue", "list"], .read), .init(["repo", "view"], .read),
        .init(["pr", "create"], .write), .init(["pr", "merge"], .write), .init(["pr", "ready"], .write),
        .init(["pr", "close"], .write), .init(["run", "rerun"], .write),
    ])

    static func manifest(cli: PluginCLI? = gh, capabilities: [String] = ["cli", "projects.read"], api: Int = 2) -> PluginManifest {
        PluginManifest(api: api, id: "sh.example.github", name: "GitHub", version: "1.0.0", capabilities: capabilities,
                       background: "background.js", cli: cli)
    }

    func bridge(cli: PluginCLI? = gh, capabilities: Set<PluginCapability> = [.cli, .projectsRead, .chatsRead]) -> PluginBridge {
        var bridge = PluginBridge(capabilities: capabilities)
        bridge.cli = cli
        bridge.isBackground = true
        bridge.knownProjectKeys = ["mac:p1"]
        bridge.knownChatIds = ["c1"]
        return bridge
    }

    let storage = PluginStorage(directory: FileManager.default.temporaryDirectory, pluginId: "sh.example.github")

    func message(_ payload: [String: Any], api: Int = 2) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: ["api": api, "type": "cli.run", "id": "1", "payload": payload])
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Manifest

    @Test func aManifestDeclaresTheBinaryAndItsCommands() throws {
        let json = """
        {"api": 2, "id": "sh.example.github", "name": "GitHub", "version": "1.0.0", "entry": "index.html",
         "capabilities": ["cli"], "background": "background.js",
         "cli": {"binary": "gh", "install": "brew install gh",
                 "commands": [{"args": ["pr", "list"], "access": "read"}, {"args": ["pr", "merge"], "access": "write"}]}}
        """
        let manifest = try PluginManifest.decode(Data(json.utf8))
        try manifest.validate()
        #expect(manifest.cli?.binary == "gh")
        #expect(manifest.cli?.reads.map(\.words) == ["pr list"])
        #expect(manifest.cli?.writes.map(\.words) == ["pr merge"])
        #expect(manifest.cli?.sentences.contains("To change things, asking you first: gh pr merge.") == true)
        #expect(manifest.cli?.sentences.contains("It needs gh installed (brew install gh).") == true)
    }

    @Test func aCLIAndItsCapabilityComeTogether() {
        #expect(throws: PluginValidationError.self) { try Self.manifest(cli: nil).validate() }
        #expect(throws: PluginValidationError.self) { try Self.manifest(capabilities: ["projects.read"]).validate() }
        #expect(throws: PluginValidationError.self) { try Self.manifest(api: 1).validate() }
        #expect(throws: Never.self) { try Self.manifest().validate() }
    }

    @Test func shellsPathsAndGitAreRefusedAsBinaries() {
        for binary in ["sh", "bash", "zsh", "env", "git", "/usr/bin/gh", "../gh", "-gh", "python3", "osascript", "G H"] {
            let cli = PluginCLI(binary: binary, commands: [.init(["pr", "list"], .read)])
            #expect(throws: PluginValidationError.self, "\(binary)") { try Self.manifest(cli: cli).validate() }
        }
    }

    @Test func commandsAreWordsWithoutFlags() {
        for args in [[String](), ["pr", "--web"], ["-R"], ["pr", "list", "a", "b", "c"], ["PR"], ["pr list"]] {
            let cli = PluginCLI(binary: "gh", commands: [.init(args, .read)])
            #expect(throws: PluginValidationError.self, "\(args)") { try Self.manifest(cli: cli).validate() }
        }
        let twice = PluginCLI(binary: "gh", commands: [.init(["pr", "list"], .read), .init(["pr", "list"], .write)])
        #expect(throws: PluginValidationError.self) { try Self.manifest(cli: twice).validate() }
    }

    @Test func aRunMatchesTheLongestDeclaredCommand() {
        let cli = PluginCLI(binary: "x", commands: [.init(["pr"], .read), .init(["pr", "merge"], .write)])
        #expect(cli.command(for: ["pr", "merge", "12"])?.access == .write)
        #expect(cli.command(for: ["pr", "list"])?.access == .read)
        #expect(cli.command(for: ["issue", "list"]) == nil)
    }

    @Test func anUpdateIsCoveredOnlyWithinWhatWasGranted() {
        let granted = Self.gh
        #expect(granted.covers(PluginCLI(binary: "gh", commands: [.init(["pr", "list"], .read)])))
        #expect(granted.covers(PluginCLI(binary: "gh", commands: [.init(["pr", "merge"], .read)])))
        #expect(!granted.covers(PluginCLI(binary: "gh", commands: [.init(["pr", "list"], .write)])))
        #expect(!granted.covers(PluginCLI(binary: "gh", commands: [.init(["release", "create"], .write)])))
        #expect(!granted.covers(PluginCLI(binary: "glab", commands: [.init(["pr", "list"], .read)])))
    }

    @Test func anUpdateAddingACommandIsReviewedAgain() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("cli-update-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let store = try Store.inMemory()
        let manager = PluginManager(store: store, pluginsRoot: root.appendingPathComponent("Plugins"),
                                    dataRoot: root.appendingPathComponent("Data"))
        func package(_ version: String, _ cli: PluginCLI) throws -> URL {
            let folder = root.appendingPathComponent("src-\(version)")
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            var manifest = Self.manifest(cli: cli)
            manifest.version = version
            try JSONEncoder().encode(manifest).write(to: folder.appendingPathComponent("manifest.json"))
            try Data("<p>hi</p>".utf8).write(to: folder.appendingPathComponent("index.html"))
            try Data("".utf8).write(to: folder.appendingPathComponent("background.js"))
            return folder
        }
        let small = PluginCLI(binary: "gh", commands: [.init(["pr", "list"], .read)])
        try manager.install(from: package("1.0.0", small), sourceKind: .user)
        manager.setEnabled("sh.example.github", true)
        #expect(manager.records().first?.grantedCLI == small)
        try manager.install(from: package("1.0.1", small), sourceKind: .user)
        #expect(manager.records().first?.enabled == true)
        try manager.install(from: package("1.0.2", Self.gh), sourceKind: .user)
        #expect(manager.records().first?.enabled == false)
        #expect(manager.records().first?.grantedCLI == nil)
        manager.setEnabled("sh.example.github", true)
        manager.revokeCapability("sh.example.github", .cli)
        #expect(manager.records().first?.grantedCLI == nil)
    }

    // MARK: Bridge

    @Test func anAllowedSubcommandIsPassedOn() throws {
        var bridge = bridge()
        let outcome = bridge.handle(try message(["args": ["pr", "list", "--json", "number"], "projectKey": "mac:p1"]), storage: storage)
        guard case .runCLI(_, let request) = outcome else { Issue.record("\(outcome)"); return }
        #expect(request.args == ["pr", "list", "--json", "number"])
        #expect(request.command == .init(["pr", "list"], .read))
        #expect(request.projectKey == "mac:p1")
        #expect(!request.isWrite)
    }

    @Test func anUndeclaredSubcommandIsRefused() throws {
        var bridge = bridge()
        for args in [["pr", "checkout", "1"], ["extension", "install", "x"], ["alias", "set"], ["--repo", "x", "pr", "list"]] {
            let outcome = bridge.handle(try message(["args": args]), storage: storage)
            guard case .refused(_, let reason) = outcome else { Issue.record("\(args): \(outcome)"); continue }
            #expect(reason.contains("hasn't been granted running gh"))
        }
    }

    @Test func withoutTheGrantNothingRuns() throws {
        var bridge = bridge(capabilities: [.projectsRead])
        guard case .refused = bridge.handle(try message(["args": ["pr", "list"]]), storage: storage) else {
            Issue.record("expected a refusal"); return
        }
        var noCLI = self.bridge(cli: nil)
        guard case .refused = noCLI.handle(try message(["args": ["pr", "list"]]), storage: storage) else {
            Issue.record("expected a refusal"); return
        }
        var old = self.bridge()
        guard case .refused = old.handle(try message(["args": ["pr", "list"]], api: 1), storage: storage) else {
            Issue.record("expected a refusal"); return
        }
    }

    @Test func aFolderOutsideWhatItCanReadIsRefused() throws {
        var bridge = bridge()
        for payload: [String: Any] in [["args": ["pr", "list"], "projectKey": "mac:other"],
                                       ["args": ["pr", "list"], "chatId": "c9"],
                                       ["args": ["pr", "list"], "cwd": "/etc"]] {
            guard case .refused = bridge.handle(try message(payload), storage: storage) else {
                Issue.record("expected a refusal for \(payload)"); continue
            }
        }
        // A project core handed it with a code host call becomes readable.
        bridge.know(projectKey: "mac:other")
        guard case .runCLI = bridge.handle(try message(["args": ["pr", "list"], "projectKey": "mac:other"]), storage: storage) else {
            Issue.record("expected a run"); return
        }
    }

    @Test func badArgumentsAreRefused() throws {
        var bridge = bridge()
        for payload: [String: Any] in [["args": []], ["args": ["pr", 1]], ["args": "pr list"],
                                       ["args": ["pr", "list", "a\u{0}b"]],
                                       ["args": ["pr", "list"] + Array(repeating: "x", count: PluginCLI.argumentLimit)]] {
            guard case .refused = bridge.handle(try message(payload), storage: storage) else {
                Issue.record("expected a refusal for \(payload)"); continue
            }
        }
    }

    @Test func aWriteSubcommandAsksFirst() throws {
        var bridge = bridge()
        guard case .runCLI(_, let request) = bridge.handle(try message(["args": ["pr", "merge", "12", "--squash"],
                                                                        "projectKey": "mac:p1"]), storage: storage) else {
            Issue.record("expected a run"); return
        }
        #expect(request.isWrite)
        #expect(PluginCLIRoute.of(request, alwaysAllowed: false, personStarted: false) == .ask)
        #expect(PluginCLIRoute.of(request, alwaysAllowed: true, personStarted: false) == .write)
        #expect(PluginCLIRoute.of(request, alwaysAllowed: false, personStarted: true) == .write)
        let read = PluginCLIRequest(args: ["pr", "list"], command: .init(["pr", "list"], .read))
        #expect(PluginCLIRoute.of(read, alwaysAllowed: false, personStarted: false) == .read)
    }

    @Test func writesCountTowardTheActionLimit() throws {
        var bridge = bridge()
        let now = Date()
        for _ in 0..<PluginBridge.actionLimit {
            guard case .runCLI = bridge.handle(try message(["args": ["pr", "close", "1"]]), storage: storage, now: now) else {
                Issue.record("expected a run"); return
            }
        }
        guard case .actionRateLimited = bridge.handle(try message(["args": ["pr", "close", "1"]]), storage: storage, now: now) else {
            Issue.record("expected the limit"); return
        }
        // Reads don't count.
        guard case .runCLI = bridge.handle(try message(["args": ["pr", "list"]]), storage: storage, now: now) else {
            Issue.record("expected a read"); return
        }
    }

    @Test func cliIsAKindThePersonCanAlwaysAllow() {
        #expect(PluginCapability.cli.asksFirst)
        #expect(!PluginCapability.cli.isAction)
        #expect(PluginCapability.askingCases.contains(.cli))
    }

    // MARK: Running

    @Test func theRunnerRunsTheBinaryWithNoShellInTheFolder() async throws {
        let exec = FakeCLI()
        let request = PluginCLIRequest(args: ["pr", "list", "--json", "number; rm -rf ~"], command: .init(["pr", "list"], .read))
        let result = try await PluginCLIRunner(budget: GitBudget()).run(request, cli: Self.gh, executor: exec,
                                                                        cwd: "/tmp/shop", readable: ["/tmp/shop"])
        #expect(result.code == 0)
        #expect(exec.all.map(\.command) == ["gh"])
        #expect(exec.all.first?.args == ["pr", "list", "--json", "number; rm -rf ~"])
        #expect(exec.all.first?.cwd == "/tmp/shop")
        #expect(result.jsonValue()["ok"]?.bool == true)
    }

    @Test func theRunnerRefusesAFolderItCantRead() async throws {
        let exec = FakeCLI()
        let request = PluginCLIRequest(args: ["pr", "list"], command: .init(["pr", "list"], .read))
        for cwd in ["/etc", "/tmp/shop-other", "/tmp/shop/../elsewhere"] {
            await #expect(throws: PluginCLIError.self, "\(cwd)") {
                try await PluginCLIRunner(budget: GitBudget()).run(request, cli: Self.gh, executor: exec,
                                                                   cwd: cwd, readable: ["/tmp/shop"])
            }
        }
        #expect(exec.all.isEmpty)
        // Inside a worktree's subfolder is inside it.
        _ = try await PluginCLIRunner(budget: GitBudget()).run(request, cli: Self.gh, executor: exec,
                                                               cwd: "/tmp/shop/sub", readable: ["/tmp/shop"])
        #expect(exec.all.count == 1)
    }

    @Test func theRunnerRefusesACommandThatIsntDeclared() async {
        let exec = FakeCLI()
        let request = PluginCLIRequest(args: ["pr", "checkout"], command: .init(["pr", "checkout"], .read))
        await #expect(throws: PluginCLIError.self) {
            try await PluginCLIRunner(budget: GitBudget()).run(request, cli: Self.gh, executor: exec, cwd: nil, readable: [])
        }
        #expect(exec.all.isEmpty)
    }

    @Test func aMissingToolSaysHowToInstallIt() async {
        let exec = FakeCLI(installed: [])
        let request = PluginCLIRequest(args: ["auth", "status"], command: .init(["auth", "status"], .read))
        do {
            _ = try await PluginCLIRunner(budget: GitBudget()).run(request, cli: Self.gh, executor: exec, cwd: nil, readable: [])
            Issue.record("expected it to be missing")
        } catch let error as PluginCLIError {
            #expect(error == .missing(binary: "gh", install: "brew install gh"))
            #expect(error.errorDescription == "gh isn't installed. Install it with `brew install gh`.")
            #expect(error.jsonValue()["install"]?.string == "brew install gh")
        } catch {
            Issue.record("\(error)")
        }
    }

    @Test func aReadGoesThroughTheGitBudgetAndAWriteDoesnt() async throws {
        let (gate, open) = AsyncStream<Void>.makeStream()
        let (started, didStart) = AsyncStream<Void>.makeStream()
        let exec = FakeCLI(gate: gate, started: didStart)
        let budget = GitBudget(census: { 0 })
        let read = PluginCLIRequest(args: ["pr", "list"], command: .init(["pr", "list"], .read))
        let task = Task { try await PluginCLIRunner(budget: budget).run(read, cli: Self.gh, executor: exec, cwd: nil, readable: []) }
        for await _ in started { break }
        #expect(budget.running == 1)
        open.yield()
        _ = try await task.value
        #expect(budget.running == 0)

        let write = PluginCLIRequest(args: ["pr", "ready", "3"], command: .init(["pr", "ready"], .write))
        let quick = FakeCLI()
        _ = try await PluginCLIRunner(budget: budget).run(write, cli: Self.gh, executor: quick, cwd: nil, readable: [])
        #expect(quick.all.count == 1)
        #expect(budget.running == 0 && budget.queued == 0)
    }

    // MARK: Paired Macs

    @Test func aPairedMacRunsOnlyItsPluginsDeclaredCommands() {
        let linear = PluginCLI(binary: "linear", commands: [.init(["issue", "list"], .read), .init(["issue", "create"], .write)])
        let inside: (String?) -> Bool = { $0 == "/Users/test/shop" }
        #expect(RemoteAccess.refusal("linear", ["issue", "list"], cwd: "/Users/test/shop", plugins: [linear], allowed: inside) == nil)
        #expect(RemoteAccess.refusal("linear", ["issue", "list"], cwd: nil, plugins: [linear], allowed: inside) == nil)
        #expect(RemoteAccess.refusal("linear", ["issue", "create"], cwd: nil, plugins: [linear], allowed: inside) != nil)
        #expect(RemoteAccess.refusal("linear", ["issue", "delete"], cwd: "/Users/test/shop", plugins: [linear], allowed: inside) != nil)
        #expect(RemoteAccess.refusal("linear", ["issue", "list"], cwd: "/etc", plugins: [linear], allowed: inside) != nil)
        #expect(RemoteAccess.refusal("linear", ["issue", "list"], cwd: "/Users/test/shop", plugins: [], allowed: inside) != nil)
        #expect(RemoteAccess.refusal("linear", ["issue", "list"], cwd: "/Users/test/shop", input: true, plugins: [linear],
                                     allowed: inside) != nil)
        // A plugin can't widen git.
        let git = PluginCLI(binary: "git", commands: [.init(["fetch"], .write)])
        #expect(RemoteAccess.refusal("git", ["-c", "core.sshCommand=x", "fetch"], cwd: "/Users/test/shop", plugins: [git],
                                     allowed: inside) != nil)
        // gh runs only as a plugin declares it.
        #expect(RemoteAccess.refusal("gh", ["run", "rerun", "1"], cwd: "/Users/test/shop", allowed: inside) != nil)
        #expect(RemoteAccess.refusal("gh", ["run", "rerun", "1"], cwd: "/Users/test/shop", plugins: [Self.gh], allowed: inside) == nil)
    }
}
