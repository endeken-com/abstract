import Foundation
import Synchronization
import Testing
@testable import AbstractCore

extension GitHeavy {
    @Suite("Accepting changes into the main tree", .serialized)
    struct DiffAcceptTests {
        private let exec = LocalExecutor.shared

        private func git(_ cwd: String, _ args: String...) async throws -> ExecResult {
            try await exec.run("git", args, cwd: cwd)
        }

        private func makeRepoWithWorktree(binaries: [String: Data] = [:]) async throws -> (root: String, worktree: String) {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("accept-\(UUID().uuidString)").path
            try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
            _ = try await git(root, "init", "-q", "-b", "main")
            _ = try await git(root, "config", "user.email", "t@t")
            _ = try await git(root, "config", "user.name", "t")
            let body = (1...30).map { "line \($0)" }.joined(separator: "\n") + "\n"
            try body.write(toFile: root + "/app.txt", atomically: true, encoding: .utf8)
            for (name, data) in binaries { try data.write(to: URL(fileURLWithPath: root + "/" + name)) }
            _ = try await git(root, "add", "-A")
            _ = try await git(root, "commit", "-qm", "init")
            let wt = root + "-wt"
            try await Git.addWorktree(exec, root: root, path: wt, branch: "abstract/t", baseRef: "HEAD")
            return (root, wt)
        }

        @Test func acceptedChangeLandsUnstaged() async throws {
            let (root, wt) = try await makeRepoWithWorktree()
            defer { try? FileManager.default.removeItem(atPath: root); try? FileManager.default.removeItem(atPath: wt) }
            var lines = try String(contentsOfFile: wt + "/app.txt", encoding: .utf8).components(separatedBy: "\n")
            lines[0] = "FIRST"
            try lines.joined(separator: "\n").write(toFile: wt + "/app.txt", atomically: true, encoding: .utf8)

            let file = try #require(try await Diff.collect(exec, worktree: wt, exclude: []).first)
            let outcome = try await Diff.accept(exec, root: root, patch: Diff.buildPatch(file, hunks: []))
            #expect(outcome == .applied)
            #expect(try await git(root, "diff", "--cached", "--name-only").stdout.isEmpty, "nothing is staged")
            #expect(try String(contentsOfFile: root + "/app.txt", encoding: .utf8).hasPrefix("FIRST\n"))
        }

        @Test func acceptWorksAlongsideTheDevelopersOwnUncommittedEdits() async throws {
            let (root, wt) = try await makeRepoWithWorktree()
            defer { try? FileManager.default.removeItem(atPath: root); try? FileManager.default.removeItem(atPath: wt) }
            // The developer edits the bottom of the file in the main tree…
            var mine = try String(contentsOfFile: root + "/app.txt", encoding: .utf8).components(separatedBy: "\n")
            mine[29] = "MINE"
            try mine.joined(separator: "\n").write(toFile: root + "/app.txt", atomically: true, encoding: .utf8)
            // …while the agent edits the top in its worktree.
            var theirs = try String(contentsOfFile: wt + "/app.txt", encoding: .utf8).components(separatedBy: "\n")
            theirs[0] = "AGENT"
            try theirs.joined(separator: "\n").write(toFile: wt + "/app.txt", atomically: true, encoding: .utf8)

            let file = try #require(try await Diff.collect(exec, worktree: wt, exclude: []).first)
            let outcome = try await Diff.accept(exec, root: root, patch: Diff.buildPatch(file, hunks: []))
            #expect(outcome == .applied)
            let result = try String(contentsOfFile: root + "/app.txt", encoding: .utf8)
            #expect(result.hasPrefix("AGENT\n"), "the agent's change landed")
            #expect(result.contains("MINE"), "the developer's edit survived")
        }

        private func edit(_ path: String, line: Int, to text: String) throws {
            var lines = try String(contentsOfFile: path, encoding: .utf8).components(separatedBy: "\n")
            lines[line] = text
            try lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }

        @Test func aPatchThatNoLongerFitsMergesThreeWaysAndIsStaged() async throws {
            let (root, wt) = try await makeRepoWithWorktree()
            defer { try? FileManager.default.removeItem(atPath: root); try? FileManager.default.removeItem(atPath: wt) }
            // The project moved on inside the agent's context, so the patch no longer fits.
            try edit(root + "/app.txt", line: 2, to: "PROJECT")
            _ = try await git(root, "commit", "-qam", "project")
            try edit(wt + "/app.txt", line: 0, to: "AGENT")

            let file = try #require(try await Diff.collect(exec, worktree: wt, exclude: []).first)
            let outcome = try await Diff.accept(exec, root: root, patch: Diff.buildPatch(file, hunks: []))
            #expect(outcome == .mergedAndStaged)
            #expect(try String(contentsOfFile: root + "/app.txt", encoding: .utf8).hasPrefix("AGENT\nline 2\nPROJECT\n"))
        }

        @Test func overlappingEditsLandAsConflicts() async throws {
            let (root, wt) = try await makeRepoWithWorktree()
            defer { try? FileManager.default.removeItem(atPath: root); try? FileManager.default.removeItem(atPath: wt) }
            try edit(root + "/app.txt", line: 0, to: "PROJECT")
            _ = try await git(root, "commit", "-qam", "project")
            try edit(wt + "/app.txt", line: 0, to: "AGENT")

            let file = try #require(try await Diff.collect(exec, worktree: wt, exclude: []).first)
            let outcome = try await Diff.accept(exec, root: root, patch: Diff.buildPatch(file, hunks: []))
            #expect(outcome == .conflicts)
            #expect(try String(contentsOfFile: root + "/app.txt", encoding: .utf8).contains("<<<<<<<"))
        }

        /// Bytes no text diff would show.
        private func binary(_ seed: UInt8) -> Data { Data([0, 1, 2, seed, 0, 255] + Array(repeating: seed, count: 64)) }

        /// A worktree whose agent changed, deleted, renamed and added binary files.
        private func makeBinaryChanges() async throws -> (root: String, worktree: String) {
            let (root, wt) = try await makeRepoWithWorktree(binaries: ["changed.bin": binary(1), "deleted.bin": binary(2), "old.bin": binary(3)])
            try binary(9).write(to: URL(fileURLWithPath: wt + "/changed.bin"))
            try FileManager.default.removeItem(atPath: wt + "/deleted.bin")
            try FileManager.default.moveItem(atPath: wt + "/old.bin", toPath: wt + "/new.bin")
            try FileManager.default.createDirectory(atPath: wt + "/assets", withIntermediateDirectories: true)
            try binary(7).write(to: URL(fileURLWithPath: wt + "/assets/added.bin"))
            return (root, wt)
        }

        @Test func binaryFilesLandAsBinaryPatches() async throws {
            let (root, wt) = try await makeBinaryChanges()
            defer { try? FileManager.default.removeItem(atPath: root); try? FileManager.default.removeItem(atPath: wt) }
            let files = try await Diff.collect(exec, worktree: wt, exclude: [])
            #expect(Set(files.map(\.status)) == [.added, .modified, .deleted, .renamed])
            // A rename with nothing changed is only its header.
            #expect(files.allSatisfy { $0.isBinary || $0.status == .renamed })

            // While the developer's own copy differs from what the agent started from, it's left alone.
            try binary(5).write(to: URL(fileURLWithPath: root + "/deleted.bin"))
            let deleted = try #require(files.first { $0.status == .deleted })
            await #expect(throws: (any Error).self) {
                try await Diff.accept(exec, file: deleted, worktree: wt, root: root, compare: .uncommitted)
            }
            #expect(FileManager.default.contents(atPath: root + "/deleted.bin") == binary(5), "the developer's file is kept")
            try binary(2).write(to: URL(fileURLWithPath: root + "/deleted.bin"))

            for file in files {
                #expect(try await Diff.accept(exec, file: file, worktree: wt, root: root, compare: .uncommitted) == .applied, "\(file.path)")
            }
            let fm = FileManager.default
            #expect(fm.contents(atPath: root + "/changed.bin") == binary(9))
            #expect(!fm.fileExists(atPath: root + "/deleted.bin"))
            #expect(!fm.fileExists(atPath: root + "/old.bin"))
            #expect(fm.contents(atPath: root + "/new.bin") == binary(3))
            #expect(fm.contents(atPath: root + "/assets/added.bin") == binary(7))
            #expect(try await git(root, "diff", "--cached", "--name-only").stdout.isEmpty, "nothing is staged")
        }

        @Test func committedBinariesLandFromTheBranch() async throws {
            let (root, wt) = try await makeBinaryChanges()
            defer { try? FileManager.default.removeItem(atPath: root); try? FileManager.default.removeItem(atPath: wt) }
            _ = try await git(wt, "add", "-A")
            _ = try await git(wt, "commit", "-qm", "agent")
            let files = try await Diff.collect(exec, worktree: wt, compare: .committed(base: "main"))
            #expect(files.count == 4)
            for file in files { try await Diff.accept(exec, file: file, worktree: wt, root: root, compare: .committed(base: "main")) }
            #expect(FileManager.default.contents(atPath: root + "/changed.bin") == binary(9))
            #expect(FileManager.default.contents(atPath: root + "/new.bin") == binary(3))
        }

        /// For a chat on another Mac, accepting must go through its executor only:
        /// this Mac's files, temporary ones included, are never touched.
        @Test func acceptRunsOnlyThroughTheExecutor() async throws {
            let (root, wt) = try await makeBinaryChanges()
            defer { try? FileManager.default.removeItem(atPath: root); try? FileManager.default.removeItem(atPath: wt) }
            try edit(wt + "/app.txt", line: 0, to: "AGENT")
            let files = try await Diff.collect(exec, worktree: wt, exclude: [])
            #expect(files.count == 5)

            let remote = ElsewhereExecutor()
            for file in files { try await Diff.accept(remote, file: file, worktree: wt, root: root, compare: .uncommitted) }
            #expect(remote.fileCalls.isEmpty, "touched files directly: \(remote.fileCalls)")
            let temporary = FileManager.default.temporaryDirectory.path
            for call in remote.runs {
                #expect(call.command == "git")
                #expect(!call.args.contains { $0.hasPrefix(temporary) || $0.hasPrefix("/var/folders") }, "\(call.args)")
                if call.args.first == "apply" { #expect(call.args.last == "-" && call.stdin?.isEmpty == false) }
            }
            #expect(try String(contentsOfFile: root + "/app.txt", encoding: .utf8).hasPrefix("AGENT\n"))
            #expect(FileManager.default.contents(atPath: root + "/new.bin") == binary(3))
        }
    }
}

/// Stands in for another Mac's executor: commands run (here, for the test),
/// and any direct file call is noted as one this Mac must not make.
private final class ElsewhereExecutor: Executor {
    let base = LocalExecutor.shared
    private let log = Mutex<(runs: [(command: String, args: [String], stdin: Data?)], files: [String])>(([], []))

    var runs: [(command: String, args: [String], stdin: Data?)] { log.withLock { $0.runs } }
    var fileCalls: [String] { log.withLock { $0.files } }
    private func touched(_ what: String) { log.withLock { $0.files.append(what) } }

    var homeDirectory: String { "/elsewhere" }
    func run(_ command: String, _ args: [String], cwd: String?, stdin: Data?) async throws -> ExecResult {
        log.withLock { $0.runs.append((command, args, stdin)) }
        return try await base.run(command, args, cwd: cwd, stdin: stdin)
    }
    func spawn(_ spec: LaunchSpec, onLine: @escaping @Sendable (OutputLine) -> Void,
               onExit: @escaping @Sendable (Int32?) -> Void) throws -> RunningProcess {
        touched("spawn \(spec.command)")
        return try base.spawn(spec, onLine: onLine, onExit: onExit)
    }
    func fileExists(_ path: String) -> Bool { touched("fileExists \(path)"); return false }
    func readFile(_ path: String) throws -> String { touched("readFile \(path)"); throw AbstractError.notFound(path) }
    func createDirectory(_ path: String) throws { touched("createDirectory \(path)") }
    func removeItem(_ path: String) throws { touched("removeItem \(path)") }
    func which(_ binary: String) async -> String? { "git" }
    func readData(_ path: String) async throws -> Data { touched("readData \(path)"); throw AbstractError.notFound(path) }
    func writeData(_ data: Data, to path: String) async throws { touched("writeData \(path)") }
    func fileInfo(_ path: String) async -> FileInfo? { touched("fileInfo \(path)"); return nil }
}
