import Foundation
import Testing
@testable import AbstractCore

/// The one-off run over a real repository's history: how many of its main
/// branch's commits lead back to a turn, and why the rest don't. Skipped
/// unless `ABSTRACT_HISTORY_REPO` names the repository:
///
///     ABSTRACT_HISTORY_REPO=~/Development/Backtick swift test --filter HistoryCoverageRun
///
/// It reads Abstract's data folder (`ABSTRACT_HISTORY_DATA`, else the usual
/// one) without changing it: the database is copied, and every chat log for
/// the repository, including those of deleted chats, is recorded into the
/// copy. `ABSTRACT_HISTORY_SINCE` (default 2026-09-24) and
/// `ABSTRACT_HISTORY_REF` (default origin/main) choose the commits.
@Suite struct HistoryCoverageRun {
    static let env = ProcessInfo.processInfo.environment

    @Test(.enabled(if: env["ABSTRACT_HISTORY_REPO"] != nil))
    func mainsCommitsMapToTurns() async throws {
        let exec = LocalExecutor.shared
        let repo = (Self.env["ABSTRACT_HISTORY_REPO"]! as NSString).expandingTildeInPath
        let since = Self.env["ABSTRACT_HISTORY_SINCE"] ?? "2026-09-24"
        let ref = Self.env["ABSTRACT_HISTORY_REF"] ?? "origin/main"
        let data = URL(fileURLWithPath: Self.env["ABSTRACT_HISTORY_DATA"].map { ($0 as NSString).expandingTildeInPath }
            ?? URL(fileURLWithPath: Store.defaultPath()).deletingLastPathComponent().path)

        // A copy of the database, so the run never touches the real one.
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("history-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: copy) }
        for suffix in ["", "-wal", "-shm"] where FileManager.default.fileExists(atPath: data.path + "/abstract.sqlite" + suffix) {
            try FileManager.default.copyItem(atPath: data.path + "/abstract.sqlite" + suffix, toPath: copy.path + "/abstract.sqlite" + suffix)
        }
        let store = try Store(path: copy.path + "/abstract.sqlite")
        let project = try #require(try store.projects().first { GitText.trimTrailingSlashes($0.rootPath) == GitText.trimTrailingSlashes(repo) },
                                   "No project in Abstract has its root at \(repo)")
        let logs = data.appendingPathComponent("sessions")
        let engine = SessionEngine(executor: exec, logDirectory: logs)

        var chats = try store.sessions().filter { $0.projectId == project.id }
        let known = Set(try store.sessions().map(\.id))
        let repoName = URL(fileURLWithPath: repo).lastPathComponent
        // Deleted chats leave their logs: the ones that worked in this repository's worktrees count too.
        for file in (try? FileManager.default.contentsOfDirectory(atPath: logs.path)) ?? [] where file.hasSuffix(".jsonl") {
            let id = String(file.dropLast(".jsonl".count))
            guard !known.contains(id) else { continue }
            let opening = engine.replayPage(sessionId: id, beforeSeq: 257, limit: 256).lines
            guard let cwd = Self.workingDirectory(opening), cwd.contains(repoName) else { continue }
            let lines = opening.map(\.line)
            chats.append(Session(id: id, projectId: project.id, name: "A deleted chat", providerId: Self.provider(of: lines),
                                 worktreePath: cwd))
        }
        var turns = 0
        let subjects = await HistoryBackfill.subjects(exec, repo: repo)
        for chat in chats {
            turns += await HistoryBackfill.backfill(chat, lines: engine.replay(sessionId: chat.id), store: store, exec: exec, repo: repo,
                                                    subjects: subjects).count
        }
        let pullRequests = Dictionary((try await GitHub.pullRequests(exec, repo: repo, state: "all", limit: 500)).map { ($0.number, $0.head) },
                                      uniquingKeysWith: { first, _ in first })
        let history = TurnHistory(store: store, projectId: project.id)
        let coverage = try await HistoryCoverage.measure(history, exec: exec, repo: repo, ref: ref, since: since, pullRequests: pullRequests)

        var report = ["\(chats.count) chats (\(chats.filter { !known.contains($0.id) }.count) of them deleted), \(turns) turns recorded from their logs.",
                      "\(ref) since \(since): " + coverage.report]
        let line = 1037, file = "Abstract/App/AppModel.swift"
        for origin in try await history.blame(file, lines: line...line, revision: ref, exec: exec, repo: repo, pullRequests: pullRequests) {
            let commit = origin.commit
            if let turn = origin.turns.last {
                report.append("\(file):\(line) ← “\(turn.chatName)”, turn \(turn.number): \(turn.request?.prefix(100) ?? "") "
                              + "(commit \(commit?.sha.prefix(8) ?? "?"), \(commit?.link?.rawValue ?? "?"))")
            } else {
                report.append("\(file):\(line) ← \(commit?.author ?? "not committed") (commit \(commit?.sha.prefix(8) ?? "?"): \(commit?.subject ?? ""))")
            }
        }
        print(report.joined(separator: "\n"))
        if let path = Self.env["ABSTRACT_HISTORY_REPORT"] {
            let misses = coverage.misses.map { "\($0.sha.prefix(8)) \($0.subject) — \($0.reason)" }
            try (report + ["", "Not mapped:"] + misses).joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
        #expect(coverage.commits > 0)
    }

    /// Where the agent said it was working.
    static func workingDirectory(_ lines: [(seq: Int, line: OutputLine)]) -> String? {
        for (_, line) in lines where line.stream == .stdout {
            guard let data = line.line.data(using: .utf8), let json = try? JSONDecoder().decode(JSONValue.self, from: data) else { continue }
            if let cwd = json["cwd"]?.string ?? json["payload"]?["cwd"]?.string { return cwd }
        }
        return nil
    }

    /// The agent whose parser makes the most sense of the log.
    static func provider(of lines: [OutputLine]) -> String {
        ["claude", "codex", "opencode"].max { a, b in understood(lines, a) < understood(lines, b) } ?? "claude"
    }

    private static func understood(_ lines: [OutputLine], _ provider: String) -> Int {
        let stream = ChatStream(providerId: provider)
        return lines.flatMap { stream.feed($0) }.filter { if case .raw = $0 { false } else { true } }.count
    }
}
