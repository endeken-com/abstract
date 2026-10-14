import Foundation
import Synchronization

/// Where a commit came from: the turns it's tied to, or, when no chat made
/// it, who did.
public struct CommitOrigin: Sendable, Hashable {
    public var sha: String
    public var author: String
    public var subject: String
    /// In the order they ended; empty when no chat made it.
    public var turns: [TurnRecord]
    /// How it was tied to them.
    public var link: CommitLink?
    /// The pull request its message names, for a merge or squash.
    public var pullRequest: Int?
}

/// Where some lines of a file came from.
public struct LineOrigin: Sendable, Hashable {
    public var lines: ClosedRange<Int>
    /// nil for lines not committed yet.
    public var commit: CommitOrigin?
    /// The turns that changed this file in that commit, last last; the
    /// commit's turns when none says it touched the file (an old record).
    public var turns: [TurnRecord]
}

/// Looks up the turns behind commits and lines of code, when asked. Each
/// commit is worked out once and remembered: there is no index of lines.
/// What a merge, squash or rebased copy was traced to is saved too, so the
/// next lookup finds it straight away.
public final class TurnHistory: Sendable {
    public let store: Store
    /// The project whose chats a pull request number or branch is looked up in.
    public let projectId: String?
    private let cache = Mutex<[String: CommitOrigin]>([:])

    public init(store: Store, projectId: String?) { self.store = store; self.projectId = projectId }

    /// Forgets what it worked out, for after new turns were recorded.
    public func forget() { cache.withLock { $0.removeAll() } }

    /// The commits worked out so far.
    public var cachedCommits: Set<String> { cache.withLock { Set($0.keys) } }

    /// Where `sha` came from. `pullRequests`: number → head branch, for a
    /// squash commit whose pull request no turn has recorded.
    public func origin(of sha: String, exec: any Executor, repo: String, pullRequests: [Int: String] = [:]) async -> CommitOrigin? {
        if let known = cache.withLock({ $0[sha] }) { return known }
        guard let facts = await Self.facts(sha, exec: exec, repo: repo) else { return nil }
        var origin = CommitOrigin(sha: facts.sha, author: facts.author, subject: facts.subject, turns: [], link: nil,
                                  pullRequest: nil)
        if let direct = try? store.turns(commit: facts.sha), !direct.isEmpty {
            origin.turns = direct.map(\.turn)
            origin.link = direct.last?.link
            origin.pullRequest = direct.lazy.compactMap(\.turn.pullRequest).last
        } else if let merged = Self.pullRequest(subject: facts.subject, parents: facts.parents.count) {
            origin.pullRequest = merged.number
            var turns = (try? store.turnRecords(projectId: projectId, pullRequest: merged.number)) ?? []
            if turns.isEmpty, let branch = merged.branch ?? pullRequests[merged.number] {
                turns = (try? store.turnRecords(projectId: projectId, branch: branch)) ?? []
            }
            origin.turns = turns
            origin.link = turns.isEmpty ? nil : facts.parents.count > 1 ? .merge : .squash
        }
        if origin.turns.isEmpty, facts.parents.count <= 1,
           let patchId = await TurnGit.patchIds(exec, cwd: repo, ["log", "-1", "--no-merges", facts.sha])[facts.sha],
           let copies = try? store.turns(patchId: patchId), !copies.isEmpty {
            origin.turns = copies.map(\.turn)
            origin.link = .patch
            try? store.link(origin.turns.map { TurnCommit(sha: facts.sha, turnId: $0.id, link: .patch, patchId: patchId) })
        } else if let link = origin.link, link == .merge || link == .squash, (try? store.turns(commit: facts.sha))?.isEmpty ?? true {
            try? store.link(origin.turns.map { TurnCommit(sha: facts.sha, turnId: $0.id, link: link) })
        }
        let found = origin
        cache.withLock { $0[facts.sha] = found }
        if sha != facts.sha { cache.withLock { $0[sha] = found } }
        return origin
    }

    /// Where lines `lines` of `path` (relative to `repo`) came from, as
    /// `git blame` at `revision` (nil: the file as it is now) sees them,
    /// a range per commit.
    public func blame(_ path: String, lines: ClosedRange<Int>, revision: String? = "HEAD", exec: any Executor, repo: String,
                      pullRequests: [Int: String] = [:]) async throws -> [LineOrigin] {
        let range = ["-L", "\(lines.lowerBound),\(lines.upperBound)"]
        let out = try await Git.gitOK(exec, cwd: repo, ["blame", "--porcelain"] + range + (revision.map { [$0] } ?? []) + ["--", path])
        var origins: [LineOrigin] = []
        for (range, sha) in Self.blameRanges(out) {
            let commit = Self.isUncommitted(sha) ? nil : await origin(of: sha, exec: exec, repo: repo, pullRequests: pullRequests)
            let turns = commit?.turns ?? []
            let touched = turns.filter { $0.files.contains(path) }
            origins.append(LineOrigin(lines: range, commit: commit, turns: touched.isEmpty ? turns : touched))
        }
        return origins
    }

    // MARK: Reading git

    struct Facts { var sha: String; var parents: [String]; var author: String; var subject: String }

    static func facts(_ sha: String, exec: any Executor, repo: String) async -> Facts? {
        guard let out = try? await Git.git(exec, cwd: repo, ["log", "-1", "--no-color", "--format=%H%x00%P%x00%an%x00%s", sha, "--"]),
              out.ok else { return nil }
        let fields = GitText.trimmed(out.stdout).components(separatedBy: "\0")
        guard fields.count == 4, !fields[0].isEmpty else { return nil }
        return Facts(sha: fields[0], parents: fields[1].split(separator: " ").map(String.init), author: fields[2], subject: fields[3])
    }

    private static let mergePattern = try! NSRegularExpression(pattern: #"^Merge pull request #([0-9]+) from [^/\s]+/(\S+)"#)
    private static let squashPattern = try! NSRegularExpression(pattern: #"\(#([0-9]+)\)\s*$"#)

    /// The pull request a commit's subject says it merged: GitHub's merge
    /// commit names it and its branch; a squash ends with "(#43)".
    static func pullRequest(subject: String, parents: Int) -> (number: Int, branch: String?)? {
        let ns = subject as NSString
        let all = NSRange(location: 0, length: ns.length)
        if let m = mergePattern.firstMatch(in: subject, range: all), let n = Int(ns.substring(with: m.range(at: 1))) {
            return (n, ns.substring(with: m.range(at: 2)))
        }
        if parents <= 1, let m = squashPattern.firstMatch(in: subject, range: all), let n = Int(ns.substring(with: m.range(at: 1))) {
            return (n, nil)
        }
        return nil
    }

    static func isUncommitted(_ sha: String) -> Bool { sha.allSatisfy { $0 == "0" } }

    /// `git blame --porcelain`'s lines, grouped into runs from one commit.
    static func blameRanges(_ porcelain: String) -> [(ClosedRange<Int>, String)] {
        var runs: [(ClosedRange<Int>, String)] = []
        for line in GitText.lines(porcelain) where !line.hasPrefix("\t") {
            let parts = line.split(separator: " ")
            guard parts.count >= 3, parts[0].count == 40, parts[0].allSatisfy(\.isHexDigit), let final = Int(parts[2]) else { continue }
            let count = parts.count >= 4 ? Int(parts[3]) ?? 1 : 1
            let sha = String(parts[0])
            // A group's first line gives its length; the rest repeat the header without one.
            let range = final...(final + max(count, 1) - 1)
            if let last = runs.last, last.1 == sha, last.0.upperBound + 1 >= range.lowerBound {
                runs[runs.count - 1].0 = last.0.lowerBound...max(last.0.upperBound, range.upperBound)
            } else {
                runs.append((range, sha))
            }
        }
        return runs
    }
}
