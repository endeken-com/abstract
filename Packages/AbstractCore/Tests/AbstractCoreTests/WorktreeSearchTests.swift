import Foundation
import Synchronization
import Testing
@testable import AbstractCore

/// A repository with tracked, new, ignored and binary files.
private struct SearchRepo {
    let root: String
    let exec = LocalExecutor.shared

    static func make() async throws -> SearchRepo {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("abstract-search-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let repo = SearchRepo(root: dir.path)
        try await repo.git(["init", "-q", "-b", "main"])
        try repo.write(".gitignore", "node_modules/\n")
        try repo.write("Sources/App.swift", "func refreshBranch() {}\n    refreshBranch()\nlet x = RefreshBranch\n")
        try repo.write("Sources/Other.swift", "refreshBranches()\nprefix_refreshBranch\n")
        try await repo.git(["add", "-A"])
        try await repo.git(["-c", "user.email=test@abstract.local", "-c", "user.name=Abstract Test",
                            "-c", "commit.gpgsign=false", "commit", "-qm", "init"])
        // Never added: new, ignored, binary.
        try repo.write("docs/new notes ü.md", "Call refreshBranch here.\n")
        try repo.write("node_modules/lib/index.js", "refreshBranch()\n")
        try Data("refreshBranch\0\u{1}\u{2}binary".utf8).write(to: URL(fileURLWithPath: repo.root + "/blob.bin"))
        return repo
    }

    func remove() { try? FileManager.default.removeItem(atPath: root) }

    func write(_ path: String, _ text: String) throws {
        let url = URL(fileURLWithPath: root + "/" + path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func git(_ args: [String]) async throws {
        let out = try await exec.run("git", args, cwd: root)
        try #require(out.ok, "git \(args) failed: \(out.stderr)")
    }

    func search(_ query: String, _ options: WorktreeSearch.Options = .init(), limit: Int = WorktreeSearch.limit) async throws
        -> WorktreeSearch.Results {
        try await WorktreeSearch.run(exec, root: root, query: query, options: options, limit: limit)
    }
}

private func lines(_ results: WorktreeSearch.Results) -> [String] {
    results.matches.map { "\($0.path):\($0.line)" }.sorted()
}

@Suite("Searching a worktree's files", .serialized)
struct WorktreeSearchTests {
    @Test func findsTrackedAndNewFilesButNotIgnoredOrBinaryOnes() async throws {
        let repo = try await SearchRepo.make()
        defer { repo.remove() }
        let results = try await repo.search("refreshBranch")
        #expect(lines(results) == [
            "Sources/App.swift:1", "Sources/App.swift:2", "Sources/App.swift:3",
            "Sources/Other.swift:1", "Sources/Other.swift:2",
            "docs/new notes ü.md:1",
        ])
        #expect(results.fileCount == 3)
        #expect(!results.truncated && !results.timedOut)
    }

    @Test func matchCaseWholeWordAndRegexChangeTheResults() async throws {
        let repo = try await SearchRepo.make()
        defer { repo.remove() }
        let cased = try await repo.search("refreshBranch", .init(matchCase: true))
        #expect(!lines(cased).contains("Sources/App.swift:3"))
        #expect(lines(cased).count == 5)

        let words = try await repo.search("refreshBranch", .init(wholeWord: true))
        #expect(lines(words) == ["Sources/App.swift:1", "Sources/App.swift:2", "Sources/App.swift:3", "docs/new notes ü.md:1"])

        let regex = try await repo.search("refreshBranch(es)?\\(\\)", .init(matchCase: true, regex: true))
        #expect(lines(regex) == ["Sources/App.swift:1", "Sources/App.swift:2", "Sources/Other.swift:1"])

        // Without Regex the same text is looked for literally.
        let literal = try await repo.search("refreshBranch(es)?", .init())
        #expect(literal.matches.isEmpty)
    }

    @Test func columnsAndHighlightsPointAtTheMatch() async throws {
        let repo = try await SearchRepo.make()
        defer { repo.remove() }
        let results = try await repo.search("refreshbranch")
        let indented = try #require(results.matches.first { $0.path == "Sources/App.swift" && $0.line == 2 })
        #expect(indented.column == 4)
        #expect(indented.length == 13)
        #expect(indented.preview == "refreshBranch()")
        #expect(indented.highlights == [0..<13])

        let note = try #require(results.matches.first { $0.path == "docs/new notes ü.md" })
        #expect(note.column == 5)
        #expect(note.preview == "Call refreshBranch here.")
    }

    @Test func aBadRegexSaysWhy() async throws {
        let repo = try await SearchRepo.make()
        defer { repo.remove() }
        await #expect(throws: AbstractError.self) { try await repo.search("refresh(", .init(regex: true)) }
    }

    @Test func stopsAtTheLimitAndSaysThereWereMore() async throws {
        let repo = try await SearchRepo.make()
        defer { repo.remove() }
        try repo.write("big.txt", String(repeating: "needle\n", count: 5_000))
        let results = try await repo.search("needle")
        #expect(results.matches.count == WorktreeSearch.limit)
        #expect(results.truncated)

        let exact = try await repo.search("needle", limit: 5_000)
        #expect(exact.matches.count == 5_000)
        #expect(!exact.truncated)
    }

    @Test func searchesAFolderThatIsntARepository() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("abstract-search-plain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "one needle\n".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let results = try await WorktreeSearch.run(LocalExecutor.shared, root: dir.path, query: "needle", options: .init(), isGit: false)
        #expect(results.matches.map(\.path) == ["a.txt"])
    }

    // MARK: Parsing

    @Test func argumentsFollowTheOptions() {
        let plain = WorktreeSearch.arguments("a.b", .init())
        #expect(plain.contains("--untracked") && plain.contains("--fixed-strings") && plain.contains("--ignore-case"))
        #expect(plain.suffix(3) == ["-e", "a.b", "--"])
        let all = WorktreeSearch.arguments("-x", .init(matchCase: true, wholeWord: true, regex: true))
        #expect(all.contains("--extended-regexp") && all.contains("--word-regexp") && !all.contains("--ignore-case"))
        // A query starting with a dash stays the pattern.
        #expect(all.suffix(3) == ["-e", "-x", "--"])
        #expect(WorktreeSearch.arguments("x", .init(), isGit: false).contains("--no-index"))
    }

    @Test func parsesPathsWithColonsAndEveryMatchOnALine() {
        let output = "odd:name.txt\u{0}12\u{0}5\u{0}foo bar FOO\nbroken line\n"
        let matches = WorktreeSearch.parse(output, query: "foo", options: .init())
        #expect(matches.count == 1)
        #expect(matches[0].path == "odd:name.txt")
        #expect(matches[0].line == 12)
        #expect(matches[0].highlights == [0..<3, 8..<11])
    }

    @Test func cutsALongLineAroundTheMatch() {
        let line = String(repeating: "x", count: 1_000) + "needle" + String(repeating: "y", count: 1_000)
        let match = try! #require(WorktreeSearch.parse("f\u{0}1\u{0}1001\u{0}\(line)", query: "needle", options: .init()).first)
        #expect(match.column == 1_000)
        #expect(match.preview.hasPrefix("…") && match.preview.hasSuffix("…"))
        #expect(match.preview.count <= WorktreeSearch.previewLength + 2)
        let highlight = try! #require(match.highlights.first)
        let preview = match.preview as NSString
        #expect(preview.substring(with: NSRange(location: highlight.lowerBound, length: highlight.count)) == "needle")
    }

    @Test func aRegexICUCantReadStillPointsAtGitsColumn() {
        // POSIX classes mean something else to ICU; the line still lists, at git's column.
        let match = try! #require(WorktreeSearch.parse("f\u{0}3\u{0}4\u{0}ab cd", query: "[[:alpha:]]d", options: .init(regex: true)).first)
        #expect(match.column == 3)
    }

    // MARK: Stopping

    @Test func cancellingStopsTheRunningSearch() async throws {
        let exec = HangingGit()
        let task = Task { try await WorktreeSearch.run(exec, root: "/tmp", query: "x", options: .init()) }
        try await exec.started()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(exec.terminated)
    }

    @Test func theTimeLimitKeepsWhatWasFound() async throws {
        let exec = HangingGit(lines: ["a.txt\u{0}1\u{0}1\u{0}x"])
        let results = try await WorktreeSearch.run(exec, root: "/tmp", query: "x", options: .init(), timeout: .milliseconds(200))
        #expect(results.timedOut)
        #expect(results.matches.map(\.path) == ["a.txt"])
        #expect(exec.terminated)
    }
}

/// A git grep that prints `lines` and then runs until it is stopped.
private final class HangingGit: Executor {
    let lines: [String]
    private let state = Mutex<(started: Bool, terminated: Bool)>((false, false))

    init(lines: [String] = []) { self.lines = lines }

    var terminated: Bool { state.withLock { $0.terminated } }

    func started() async throws {
        for _ in 0..<200 where !state.withLock({ $0.started }) { try await Task.sleep(for: .milliseconds(10)) }
    }

    var homeDirectory: String { "/home/test" }
    func run(_ command: String, _ args: [String], cwd: String?, stdin: Data?) async throws -> ExecResult {
        throw AbstractError.message("not here")
    }
    func spawn(_ spec: LaunchSpec, onLine: @escaping @Sendable (OutputLine) -> Void,
               onExit: @escaping @Sendable (Int32?) -> Void) throws -> RunningProcess {
        for line in lines { onLine(OutputLine(stream: .stdout, line: line)) }
        state.withLock { $0.started = true }
        return Process(onTerminate: { [self] in
            state.withLock { $0.terminated = true }
            onExit(nil)
        })
    }
    func fileExists(_ path: String) -> Bool { false }
    func readFile(_ path: String) throws -> String { throw AbstractError.notFound(path) }
    func createDirectory(_ path: String) throws {}
    func removeItem(_ path: String) throws {}
    func which(_ binary: String) async -> String? { binary }

    final class Process: RunningProcess {
        let onTerminate: @Sendable () -> Void
        init(onTerminate: @escaping @Sendable () -> Void) { self.onTerminate = onTerminate }
        var pid: Int32 { 0 }
        func write(_ text: String) throws {}
        func closeStdin() {}
        func terminate() { onTerminate() }
    }
}
