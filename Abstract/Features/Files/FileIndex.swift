import Foundation
import AbstractCore

/// A file or folder in the worktree, by path relative to its root.
nonisolated struct FileEntry: Sendable, Hashable, Identifiable {
    let path: String
    let name: String
    let isDirectory: Bool

    var id: String { path }
    /// The containing folder's path; "" at the top level.
    var directory: String { FileIndex.parent(of: path) }
}

/// Filter results: the best matches, and how many matched in all.
nonisolated struct FileMatches: Sendable {
    let paths: [String]
    let total: Int
    static let none = FileMatches(paths: [], total: 0)
}

/// Everything the tree draws, read once per refresh off the main actor.
nonisolated struct FileIndex: Sendable {
    /// Listed by git (tracked + untracked, .gitignore respected), or walked.
    let isGit: Bool
    /// Folder path ("" for the root) → its entries, folders first.
    let children: [String: [FileEntry]]
    /// Every file path, sorted, with lowercased copies for filtering.
    let files: [String]
    let lowercasedFiles: [String]
    /// What the agent changed, by path.
    let changes: [String: FileDiff.FileStatus]
    /// Folders with a change somewhere below them.
    let changedDirectories: Set<String>
    /// The walk stopped at `walkLimit` files.
    let truncated: Bool

    func entries(in directory: String) -> [FileEntry] { children[directory] ?? [] }
    func isDirectory(_ path: String) -> Bool { children[path] != nil }
    func contains(_ path: String) -> Bool { children[path] != nil || filePaths.contains(path) }

    private let filePaths: Set<String>

    init(isGit: Bool, children: [String: [FileEntry]], files: [String], changes: [String: FileDiff.FileStatus],
         truncated: Bool) {
        self.isGit = isGit
        self.children = children
        self.files = files
        self.lowercasedFiles = files.map { $0.lowercased() }
        self.filePaths = Set(files)
        self.changes = changes
        self.truncated = truncated
        var dirs: Set<String> = []
        for path in changes.keys {
            var dir = Self.parent(of: path)
            while !dir.isEmpty, dirs.insert(dir).inserted { dir = Self.parent(of: dir) }
        }
        self.changedDirectories = dirs
    }

    static func parent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    /// Every folder above `path`, nearest last: "a/b/c.txt" → ["a", "a/b"].
    static func ancestors(of path: String) -> [String] {
        var result: [String] = []
        var dir = parent(of: path)
        while !dir.isEmpty {
            result.append(dir)
            dir = parent(of: dir)
        }
        return result.reversed()
    }

    static func join(_ root: String, _ path: String) -> String {
        var base = root
        while base.hasSuffix("/") { base.removeLast() }
        return path.isEmpty ? base : base + "/" + path
    }
}

// MARK: - Loading

nonisolated extension FileIndex {
    /// Folders a directory walk never enters.
    static let skippedDirectories: Set<String> = [".git", "node_modules", ".build", "build", "DerivedData"]
    static let walkLimit = 100_000

    /// Read the worktree: git's view when it is a repository, otherwise a
    /// walk of the directory (automation scratch folders).
    @concurrent
    static func load(_ exec: any Executor, root: String) async throws -> FileIndex {
        guard await exec.fileInfo(root)?.isDirectory == true else {
            throw AbstractError.message("The folder \(root) no longer exists.")
        }
        if let prefix = try? await exec.run("git", ["rev-parse", "--show-prefix"], cwd: root), prefix.ok {
            async let listing = exec.run("git", ["ls-files", "-z", "--cached", "--others", "--exclude-standard"], cwd: root)
            async let status = exec.run("git", ["status", "--porcelain=v1", "-z", "--untracked-files=all"], cwd: root)
            let listed = try? await listing
            let changed = try? await status
            if let listed, listed.ok {
                let changes = changed.flatMap { $0.ok ? parseStatus($0.stdout, prefix: prefix.stdout) : nil } ?? [:]
                var paths = splitNUL(listed.stdout)
                // A removal the agent staged is gone from the listing; keep it visible.
                paths += changes.compactMap { $0.value == .deleted ? $0.key : nil }
                // A folder git ignores entirely lists nothing; show what is on disk instead.
                if !paths.isEmpty {
                    return build(paths, changes: changes, isGit: true, truncated: false)
                }
            }
        }
        // A folder on another Mac is walked there.
        let (paths, truncated) = if let remote = exec as? RemoteExecutor { try await remote.listFiles(root) } else { walk(root) }
        return build(paths, changes: [:], isGit: false, truncated: truncated)
    }

    /// `git status --porcelain=v1 -z`: "XY path\0", renames "XY new\0old\0".
    /// Paths are relative to the repository root, so drop the worktree's prefix.
    static func parseStatus(_ output: String, prefix rawPrefix: String) -> [String: FileDiff.FileStatus] {
        let prefix = rawPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        var result: [String: FileDiff.FileStatus] = [:]
        let records = splitNUL(output)
        var i = 0
        while i < records.count {
            let record = records[i]
            i += 1
            guard record.count > 3 else { continue }
            let x = record[record.startIndex]
            let y = record[record.index(after: record.startIndex)]
            if "RC".contains(x) || "RC".contains(y) { i += 1 }
            var path = String(record.dropFirst(3))
            while path.hasSuffix("/") { path.removeLast() }
            if !prefix.isEmpty {
                guard path.hasPrefix(prefix) else { continue }
                path.removeFirst(prefix.count)
            }
            guard !path.isEmpty else { continue }
            switch (x, y) {
            case ("!", _): continue
            case ("?", _): result[path] = .added
            case _ where x == "D" || y == "D": result[path] = .deleted
            case _ where x == "R" || y == "R": result[path] = .renamed
            case _ where x == "A" || y == "A" || x == "C": result[path] = .added
            default: result[path] = .modified
            }
        }
        return result
    }

    /// NUL-separated fields, split on bytes: fast on huge listings, and a
    /// path that starts with a combining mark can't fuse with the separator.
    static func splitNUL(_ output: String) -> [String] {
        output.utf8.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Every file under `root`, relative, skipping build output and VCS folders.
    static func walk(_ root: String) -> ([String], Bool) {
        guard let enumerator = FileManager.default.enumerator(atPath: root) else { return ([], false) }
        var paths: [String] = []
        while let relative = enumerator.nextObject() as? String {
            let name = (relative as NSString).lastPathComponent
            if enumerator.fileAttributes?[.type] as? FileAttributeType == .typeDirectory {
                if skippedDirectories.contains(name) { enumerator.skipDescendants() }
                continue
            }
            if name == ".DS_Store" { continue }
            paths.append(relative)
            if paths.count >= walkLimit { return (paths, true) }
        }
        return (paths, false)
    }

    /// Folders come from the file paths themselves; a path ending in "/" is a
    /// folder git won't look inside (a nested repository).
    static func build(_ raw: [String], changes: [String: FileDiff.FileStatus], isGit: Bool, truncated: Bool) -> FileIndex {
        var children: [String: [FileEntry]] = ["": []]
        var files: [String] = []
        var seenFiles: Set<String> = []

        for item in raw {
            var path = item
            var isFolder = false
            while path.hasSuffix("/") { path.removeLast(); isFolder = true }
            if path.hasPrefix("./") { path.removeFirst(2) }
            guard !path.isEmpty else { continue }

            var parent = ""
            var start = path.startIndex
            while let slash = path[start...].firstIndex(of: "/") {
                let dir = String(path[..<slash])
                if children[dir] == nil {
                    children[dir] = []
                    children[parent, default: []].append(FileEntry(path: dir, name: String(path[start..<slash]), isDirectory: true))
                }
                parent = dir
                start = path.index(after: slash)
            }
            let name = String(path[start...])
            if isFolder {
                if children[path] == nil {
                    children[path] = []
                    children[parent, default: []].append(FileEntry(path: path, name: name, isDirectory: true))
                }
            } else if children[path] == nil, seenFiles.insert(path).inserted {
                children[parent, default: []].append(FileEntry(path: path, name: name, isDirectory: false))
                files.append(path)
            }
        }

        for key in Array(children.keys) where (children[key]?.count ?? 0) > 1 {
            children[key]?.sort { a, b in
                a.isDirectory != b.isDirectory ? a.isDirectory : a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }
        files.sort()
        return FileIndex(isGit: isGit, children: children, files: files, changes: changes, truncated: truncated)
    }
}

// MARK: - Filtering

nonisolated extension FileIndex {
    /// Every whitespace-separated word must appear in the path; matches in
    /// the file name rank first, then shorter paths. With no such match, the
    /// query's letters in order anywhere in the path.
    @concurrent
    static func match(_ query: String, in index: FileIndex, limit: Int = 500) async -> FileMatches {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return .none }
        var scored: [(score: Int, index: Int)] = []
        for (i, lower) in index.lowercasedFiles.enumerated() {
            if i & 4095 == 0, Task.isCancelled { return .none }
            guard words.allSatisfy({ lower.contains($0) }) else { continue }
            scored.append((score(lower, words), i))
        }
        if scored.isEmpty {
            let letters = Array(words.joined().utf8)
            for (i, lower) in index.lowercasedFiles.enumerated() {
                if i & 4095 == 0, Task.isCancelled { return .none }
                if let s = subsequenceScore(Array(lower.utf8), letters) { scored.append((s, i)) }
            }
        }
        let files = index.files
        scored.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            let pa = files[a.index], pb = files[b.index]
            return pa.utf8.count != pb.utf8.count ? pa.utf8.count < pb.utf8.count : pa < pb
        }
        return FileMatches(paths: scored.prefix(limit).map { files[$0.index] }, total: scored.count)
    }

    private static func score(_ lower: String, _ words: [String]) -> Int {
        let name = lower.lastIndex(of: "/").map { String(lower[lower.index(after: $0)...]) } ?? lower
        var score = 0
        for word in words {
            if name == word { score += 100 }
            else if name.hasPrefix(word) { score += 60 }
            else if name.contains(word) { score += 30 }
        }
        return score
    }

    /// Letters in order; contiguous runs and hits in the file name score higher.
    private static func subsequenceScore(_ text: [UInt8], _ letters: [UInt8]) -> Int? {
        let nameStart = (text.lastIndex(of: UInt8(ascii: "/")) ?? -1) + 1
        var score = 0, run = 0, t = 0
        for letter in letters {
            guard let found = text[t...].firstIndex(of: letter) else { return nil }
            run = found == t ? run + 1 : 1
            score += run + (found >= nameStart ? 1 : 0)
            t = found + 1
        }
        return score
    }
}
