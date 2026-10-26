import Foundation

/// A chat's worktree as a cheap look shows it: each repository's status and
/// HEAD, and when each file in that status last changed. Two equal snapshots
/// mean a full read of the review would show the same, so the review takes
/// one before reading and skips the read while it hasn't changed.
public struct WorktreeSnapshot: Sendable, Hashable {
    public let lines: [String]

    public init(lines: [String]) { self.lines = lines }

    /// Beyond this many changed files the look stops being cheap: nil, and the review reads.
    static let fileLimit = 500

    /// One `git status` per repository with changes: the worktree's own, and
    /// each submodule its parent says changed, inside it too. Nil when git
    /// can't say, so the caller reads in full.
    public static func take(_ exec: any Executor, worktree: String) async -> WorktreeSnapshot? {
        var lines: [String] = []
        var files = 0
        var pending: [(path: String, depth: Int)] = [("", 0)]
        while !pending.isEmpty {
            let (repo, depth) = pending.removeFirst()
            let dir = repo.isEmpty ? worktree : worktree + "/" + repo
            // Polled beside agents running git: never takes the index lock.
            guard let out = try? await Git.git(exec, cwd: dir, ["--no-optional-locks", "status", "--porcelain=v2", "-z",
                                                                "--branch", "--untracked-files=all"]), out.ok
            else { return nil }
            lines.append("@" + repo)
            for entry in parse(out.stdout) {
                if let path = entry.changedSubmodule, depth < 8 {
                    pending.append((repo.isEmpty ? path : repo + "/" + path, depth + 1))
                }
                var line = entry.line
                if let path = entry.file {
                    files += 1
                    guard files <= fileLimit else { return nil }
                    let info = await exec.fileInfo(dir + "/" + path)
                    line += "\u{0}" + (info.map { "\($0.size) \($0.modified?.timeIntervalSince1970 ?? 0)" } ?? "-")
                }
                lines.append(line)
            }
        }
        return WorktreeSnapshot(lines: lines)
    }

    struct Entry: Equatable {
        /// The record as git wrote it, an untracked file's `add -N` undone.
        var line: String
        /// A file in the working tree whose size and age count.
        var file: String?
        /// A submodule with changes of its own, to look into.
        var changedSubmodule: String?
    }

    /// `git status --porcelain=v2 -z` records.
    static func parse(_ output: String) -> [Entry] {
        var fields = Submodules.nulFields(output)[...]
        var entries: [Entry] = []
        while let record = fields.popFirst() {
            let kind = record.prefix(2)
            switch kind {
            case "1 ", "2 ", "u ":
                // "1 XY sub mH mI mW hH hI path", "2 … Xscore path" then the old path, "u … h3 path".
                let count = kind == "1 " ? 8 : kind == "2 " ? 9 : 10
                let parts = record.split(separator: " ", maxSplits: count, omittingEmptySubsequences: false).map(String.init)
                guard parts.count == count + 1 else { entries.append(Entry(line: record)); continue }
                let xy = parts[1], sub = parts[2], path = parts[count]
                var line = record
                if kind == "2 ", let old = fields.popFirst() { line += "\u{0}" + old }
                // The review's own read marks untracked files with `add -N`: still the same untracked file.
                if kind == "1 ", xy == ".A", parts[3] == "000000", parts[4] == "000000" { line = "? " + path }
                let isSubmodule = sub.hasPrefix("S")
                entries.append(Entry(line: line,
                                     file: isSubmodule || xy.hasSuffix("D") ? nil : path,
                                     changedSubmodule: isSubmodule && sub != "S..." ? path : nil))
            case "? ":
                entries.append(Entry(line: record, file: String(record.dropFirst(2))))
            default:
                // "# branch.oid <HEAD>" and the other headers, ignored files.
                entries.append(Entry(line: record))
            }
        }
        return entries
    }
}

/// Runs a reload one at a time, never more often than once per `delay`:
/// a trigger waits `delay`, every trigger that arrives meanwhile (or while
/// another reload runs) joins it, and at most one waits behind the one running.
@MainActor
public final class ReloadQueue {
    private let delay: Duration
    private var action: (@MainActor () async -> Void)?
    private var waiting: Task<Void, Never>?
    private var running: Task<Void, Never>?

    public init(delay: Duration = .seconds(1)) { self.delay = delay }

    /// After `delay`, together with whatever else asks before it starts.
    public func soon(_ action: @escaping @MainActor () async -> Void) {
        self.action = action
        if waiting == nil { waiting = queue(after: delay) }
    }

    /// As soon as the reload running, if any, ends; one already waiting
    /// stops waiting and is this one. Returns once it has run.
    public func now(_ action: @escaping @MainActor () async -> Void) async {
        self.action = action
        let next = waiting ?? queue(after: .zero)
        waiting = next
        next.cancel()
        await next.value
    }

    private func queue(after delay: Duration) -> Task<Void, Never> {
        Task { [weak self] in
            // Cancelled by `now`: stop waiting, but still run.
            try? await Task.sleep(for: delay)
            await self?.run()
        }
    }

    private func run() async {
        while let current = running {
            await current.value
            if running == current { running = nil }
        }
        // From here, a new trigger queues behind this one rather than joining it.
        waiting = nil
        guard let action else { return }
        // Its own task: the waiting one may have been cancelled.
        let task = Task { await action() }
        running = task
        await task.value
        if running == task { running = nil }
    }
}

/// Which file events can change what the review shows: the worktree's
/// files, and in a git folder only where HEAD points and the refs. The
/// index, FETCH_HEAD and logs move every time Abstract itself reads git.
public enum ReviewWatch {
    static let heads: Set<String> = ["HEAD", "MERGE_HEAD", "REBASE_HEAD"]

    /// `gitDir` is the worktree's own git folder, `refs` the shared refs folder.
    public static func matters(_ path: String, gitDir: String?, refs: String?) -> Bool {
        if path.hasSuffix(".lock") { return false }
        if let refs, path == refs || path.hasPrefix(refs + "/") { return true }
        let inGit: String?
        if let gitDir, path == gitDir || path.hasPrefix(gitDir + "/") {
            inGit = path == gitDir ? "" : String(path.dropFirst(gitDir.count + 1))
        } else if let marker = path.range(of: "/.git/", options: .backwards) {
            inGit = String(path[marker.upperBound...])
        } else {
            inGit = nil
        }
        guard let inGit else { return true }
        // The folder itself: something in it changed, a look will tell.
        if inGit.isEmpty { return true }
        if inGit.hasPrefix("logs/") || inGit.contains("/logs/") { return false }
        return heads.contains((inGit as NSString).lastPathComponent) || inGit.hasPrefix("refs/") || inGit.contains("/refs/")
    }
}

public extension RepoReview {
    /// Whether the review, left to itself, shows the branch's commits rather
    /// than the uncommitted work. It starts on the uncommitted work while
    /// there is some, and only leaves the list it shows once that one is
    /// empty, never while you might be reading a file in it.
    /// `showingCommitted` is nil before the first load.
    static func followsCommitted(showingCommitted: Bool?, dirty: Bool, hasBase: Bool, hasCommits: Bool) -> Bool {
        guard hasBase else { return false }
        switch showingCommitted {
        case nil, false?: return !dirty
        case true?: return hasCommits || !dirty
        }
    }

    /// Of `files`, the ones whose diff is the same as one in `previous`,
    /// which the review keeps as it prepared them.
    static func unchanged<Prepared>(_ files: [FileDiff], previous: [Prepared],
                                    diff: (Prepared) -> FileDiff) -> [String: Prepared] {
        var byPath: [String: Prepared] = [:]
        for prepared in previous { byPath[diff(prepared).path] = prepared }
        var kept: [String: Prepared] = [:]
        for file in files {
            if let prepared = byPath[file.path], diff(prepared) == file { kept[file.path] = prepared }
        }
        return kept
    }

    /// The file selected once the list is `after`: the same one while it's
    /// still listed, else the one now where it was, else the first.
    static func selection(_ selected: String?, before: [String], after: [String]) -> String? {
        if let selected, after.contains(selected) { return selected }
        if let selected, let index = before.firstIndex(of: selected), !after.isEmpty {
            return after[min(index, after.count - 1)]
        }
        return after.first
    }
}

public extension SessionStatus {
    /// A turn ended: the agent stopped working, for now or for good.
    static func endsTurn(from old: SessionStatus?, to new: SessionStatus?) -> Bool {
        guard let new, new != old else { return false }
        return new == .idle || new == .finished || new == .errored
    }
}
