import Foundation

public struct DiffLine: Sendable, Hashable {
    public enum Origin: String, Sendable, Hashable {
        case context = " "
        case added = "+"
        case removed = "-"
        /// `\ No newline at end of file`
        case noNewline = "\\"
    }

    public var origin: Origin
    public var content: String

    public init(origin: Origin, content: String) {
        self.origin = origin
        self.content = content
    }
}

public struct Hunk: Sendable, Hashable {
    public var index: Int
    public var header: String
    public var oldStart: Int
    public var oldLines: Int
    public var newStart: Int
    public var newLines: Int
    public var lines: [DiffLine]
    public var additions: Int
    public var deletions: Int
    /// Verbatim hunk text, reused when building a partial patch.
    public var raw: String

    public init(index: Int, header: String, oldStart: Int, oldLines: Int, newStart: Int, newLines: Int,
                lines: [DiffLine] = [], additions: Int = 0, deletions: Int = 0, raw: String) {
        self.index = index; self.header = header
        self.oldStart = oldStart; self.oldLines = oldLines; self.newStart = newStart; self.newLines = newLines
        self.lines = lines; self.additions = additions; self.deletions = deletions; self.raw = raw
    }
}

public struct FileDiff: Sendable, Hashable, Identifiable {
    public enum FileStatus: String, Sendable, Hashable {
        case added, modified, deleted, renamed
    }

    public var path: String
    public var oldPath: String?
    public var status: FileStatus
    public var isBinary: Bool
    public var additions: Int
    public var deletions: Int
    public var hunks: [Hunk]
    /// Verbatim `diff --git` preamble through the `+++` line.
    public var rawHeader: String

    public var id: String { path }

    public init(path: String, oldPath: String? = nil, status: FileStatus = .modified, isBinary: Bool = false,
                additions: Int = 0, deletions: Int = 0, hunks: [Hunk] = [], rawHeader: String) {
        self.path = path; self.oldPath = oldPath; self.status = status; self.isBinary = isBinary
        self.additions = additions; self.deletions = deletions; self.hunks = hunks; self.rawHeader = rawHeader
    }
}

public enum Diff {
    // MARK: Parsing

    /// Parse `git diff` unified output. Keeps raw text so partial patches stay byte-faithful.
    public static func parse(_ input: String) -> [FileDiff] {
        var files: [FileDiff] = []
        var current: FileDiff?
        var hunk: Hunk?
        var headerDone = false

        func finishHunk() {
            if var file = current, let h = hunk {
                file.additions += h.additions
                file.deletions += h.deletions
                file.hunks.append(h)
                current = file
            }
            hunk = nil
        }
        func finishFile() {
            finishHunk()
            if let file = current { files.append(file) }
            current = nil
        }

        for line in GitText.lines(input) {
            if GitText.hasPrefix(line, "diff --git ") {
                finishFile()
                headerDone = false
                let (oldPath, path) = parseDiffGitPaths(line)
                current = FileDiff(path: path, oldPath: oldPath, rawHeader: line + "\n")
                continue
            }
            guard current != nil else { continue }

            if GitText.hasPrefix(line, "@@") {
                finishHunk()
                headerDone = true
                let (oldStart, oldLines, newStart, newLines) = parseHunkHeader(line)
                hunk = Hunk(index: current?.hunks.count ?? 0, header: line, oldStart: oldStart, oldLines: oldLines,
                            newStart: newStart, newLines: newLines, raw: line + "\n")
                continue
            }

            if !headerDone {
                if GitText.hasPrefix(line, "new file mode") {
                    current?.status = .added
                } else if GitText.hasPrefix(line, "deleted file mode") {
                    current?.status = .deleted
                } else if GitText.hasPrefix(line, "rename from ") {
                    current?.status = .renamed
                    current?.oldPath = GitText.dropPrefix(line, "rename from ")
                } else if GitText.hasPrefix(line, "rename to ") {
                    current?.path = GitText.dropPrefix(line, "rename to ")
                } else if GitText.hasPrefix(line, "Binary files") || GitText.hasPrefix(line, "GIT binary patch") {
                    current?.isBinary = true
                }
                if !line.isEmpty { current?.rawHeader += line + "\n" }
                continue
            }

            guard hunk != nil else { continue }
            // An empty line counts as context (the leniency `git apply` also has).
            let first = line.utf8.first ?? UInt8(ascii: " ")
            let origin: DiffLine.Origin? = switch first {
            case UInt8(ascii: "+"): .added
            case UInt8(ascii: "-"): .removed
            case UInt8(ascii: " "): .context
            case UInt8(ascii: "\\"): .noNewline
            default: nil
            }
            guard let origin else {
                // Anything else ends the hunk.
                finishHunk()
                headerDone = false
                continue
            }
            hunk?.raw += line + "\n"
            if origin == .added { hunk?.additions += 1 } else if origin == .removed { hunk?.deletions += 1 }
            hunk?.lines.append(DiffLine(origin: origin, content: String(decoding: line.utf8.dropFirst(), as: UTF8.self)))
        }
        finishFile()
        return files
    }

    static func parseDiffGitPaths(_ line: String) -> (oldPath: String?, path: String) {
        let rest = GitText.dropPrefix(line, "diff --git ")
        guard let (a, b) = GitText.splitOnce(rest, " b/") else { return (nil, rest) }
        let old = GitText.dropPrefix(a, "a/")
        return (old == b ? nil : old, b)
    }

    /// `@@ -old_start,old_lines +new_start,new_lines @@ optional section heading`
    static func parseHunkHeader(_ line: String) -> (Int, Int, Int, Int) {
        var body = Substring(line)
        while body.hasPrefix("@@") { body = body.dropFirst(2) }
        var old = (0, 1)
        var new = (0, 1)
        for token in body.split(whereSeparator: \.isWhitespace) {
            if token.hasPrefix("-") {
                old = parsePair(token.dropFirst())
            } else if token.hasPrefix("+") {
                new = parsePair(token.dropFirst())
            } else if token == "@@" {
                break
            }
        }
        return (old.0, old.1, new.0, new.1)
    }

    private static func parsePair(_ value: Substring) -> (Int, Int) {
        guard let comma = value.firstIndex(of: ",") else { return (Int(value) ?? 0, 1) }
        return (Int(value[..<comma]) ?? 0, Int(value[value.index(after: comma)...]) ?? 1)
    }

    // MARK: Patches

    /// Build a patch containing only the selected hunks of one file; an empty
    /// selection means the whole file. Hunks are copied verbatim; `git apply`
    /// tolerates the line offsets that leaving other hunks out introduces.
    public static func buildPatch(_ file: FileDiff, hunks indexes: [Int]) -> String {
        var out = file.rawHeader
        if !out.hasSuffix("\n") { out += "\n" }
        for hunk in file.hunks where indexes.isEmpty || indexes.contains(hunk.index) {
            out += hunk.raw
        }
        return out
    }

    // MARK: Git

    /// Everything the agent changed in its worktree, including untracked files.
    public static func collect(_ exec: any Executor, worktree: String, exclude: [String] = []) async throws -> [FileDiff] {
        // `add -N` makes untracked files visible to `git diff` as additions.
        // A nested repository makes a whole-tree `add` fail outright ("does not
        // have a commit checked out"), which would silently drop every new file
        // from the review, so excluded paths are skipped here too and anything
        // still unhappy falls back to adding files one at a time.
        let excludes = exclude
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { ":(exclude)" + GitText.trimTrailingSlashes($0) }

        let added = try await Git.git(exec, cwd: worktree, ["add", "-N", "--", "."] + excludes)
        if !added.ok {
            await intentToAddIndividually(exec, worktree: worktree)
        }

        // quotePath=false keeps non-ASCII paths readable instead of octal-escaped and quoted.
        let args = ["-c", "core.quotePath=false", "--no-pager", "diff", "HEAD", "--no-color", "--no-ext-diff", "-M",
                    "--", "."] + excludes
        return parse(try await Git.gitOK(exec, cwd: worktree, args))
    }

    /// Mark untracked files individually, skipping the ones git refuses (an
    /// unregistered nested repository is the usual culprit). One bad directory
    /// must not cost the user the rest of the review.
    private static func intentToAddIndividually(_ exec: any Executor, worktree: String) async {
        guard let status = try? await Git.git(exec, cwd: worktree,
                                              ["-c", "core.quotePath=false", "status", "--porcelain", "-uall"])
        else { return }
        for line in GitText.lines(status.stdout) {
            guard GitText.hasPrefix(line, "?? ") else { continue }
            let path = GitText.dropPrefix(line, "?? ")
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if path.isEmpty || path.hasSuffix("/") { continue }
            _ = try? await Git.git(exec, cwd: worktree, ["add", "-N", "--", path])
        }
    }

    /// Apply a patch. `reverse` undoes it (used to reject a hunk in the worktree).
    public static func apply(_ exec: any Executor, cwd: String, patch: String, reverse: Bool = false,
                             threeWay: Bool = false) async throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("backtick-patch-\(UUID().uuidString).diff")
        do {
            try Data(patch.utf8).write(to: file)
        } catch {
            throw BacktickError.message("write patch file: \(error.localizedDescription)")
        }
        defer { try? FileManager.default.removeItem(at: file) }

        var args = ["apply"]
        if reverse { args.append("-R") }
        if threeWay { args.append("--3way") }
        args.append(file.path)
        let out = try await Git.git(exec, cwd: cwd, args)
        guard out.ok else {
            throw BacktickError.command(code: out.code, stderr: "git apply: \(GitText.trimmed(out.stderr))")
        }
    }

    public enum AcceptOutcome: Sendable, Equatable {
        /// Applied to the working tree only; nothing staged.
        case applied
        /// Plain apply didn't fit, so git merged three ways. The result is staged.
        case mergedAndStaged
        /// Merged with conflicts; conflict markers are in the working tree.
        case conflicts
    }

    /// Land a patch in the project's main working tree.
    ///
    /// Plain `git apply` first, which leaves the change unstaged and works even
    /// when the developer has their own uncommitted edits elsewhere in the same
    /// file. Only if the context no longer matches does it fall back to
    /// `--3way`, which git always records in the index.
    @discardableResult
    public static func accept(_ exec: any Executor, root: String, patch: String) async throws -> AcceptOutcome {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("backtick-accept-\(UUID().uuidString).diff")
        do { try Data(patch.utf8).write(to: file) } catch {
            throw BacktickError.message("write patch file: \(error.localizedDescription)")
        }
        defer { try? FileManager.default.removeItem(at: file) }

        let check = try await Git.git(exec, cwd: root, ["apply", "--check", file.path])
        if check.ok {
            let out = try await Git.git(exec, cwd: root, ["apply", file.path])
            guard out.ok else { throw BacktickError.command(code: out.code, stderr: "git apply: \(GitText.trimmed(out.stderr))") }
            return .applied
        }
        let merged = try await Git.git(exec, cwd: root, ["apply", "--3way", file.path])
        if merged.ok { return .mergedAndStaged }
        if merged.stderr.contains("with conflicts") { return .conflicts }
        let reason = GitText.trimmed(merged.stderr).isEmpty ? GitText.trimmed(check.stderr) : GitText.trimmed(merged.stderr)
        if reason.contains("does not match index") {
            throw BacktickError.message("This file has uncommitted edits in your working tree that overlap the agent's change. Commit or stash them, then accept again.")
        }
        throw BacktickError.command(code: merged.code, stderr: "git apply: \(reason)")
    }

    /// The file as committed at HEAD; empty when it did not exist there.
    public static func original(_ exec: any Executor, worktree: String, path: String) async -> String {
        guard let out = try? await Git.git(exec, cwd: worktree, ["--no-pager", "show", "HEAD:\(path)"]), out.ok
        else { return "" }
        return out.stdout
    }

    /// The file as it is on disk in the worktree; empty when missing.
    public static func current(_ exec: any Executor, worktree: String, path: String) -> String {
        (try? exec.readFile(GitText.trimTrailingSlashes(worktree) + "/" + path)) ?? ""
    }
}

/// Byte-level string helpers. Diff text is handled per UTF-8 byte so a
/// combining mark or CRLF never shifts a prefix check or a patch.
enum GitText {
    /// Split on `\n` (keeping any `\r`). A trailing newline does not produce a
    /// final empty line.
    static func lines(_ text: String) -> [String] {
        var parts = text.utf8.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
        if text.utf8.last == UInt8(ascii: "\n") { parts.removeLast() }
        return parts.map { String(decoding: $0, as: UTF8.self) }
    }

    static func hasPrefix(_ s: String, _ prefix: String) -> Bool {
        s.utf8.starts(with: prefix.utf8)
    }

    /// `s` without one leading `prefix`, or `s` unchanged.
    static func dropPrefix(_ s: String, _ prefix: String) -> String {
        hasPrefix(s, prefix) ? String(decoding: s.utf8.dropFirst(prefix.utf8.count), as: UTF8.self) : s
    }

    /// Split at the first occurrence of `separator`.
    static func splitOnce(_ s: String, _ separator: String) -> (String, String)? {
        let bytes = Array(s.utf8)
        let sep = Array(separator.utf8)
        guard !sep.isEmpty, bytes.count >= sep.count else { return nil }
        for i in 0...(bytes.count - sep.count) where bytes[i..<(i + sep.count)].elementsEqual(sep) {
            return (String(decoding: bytes[..<i], as: UTF8.self),
                    String(decoding: bytes[(i + sep.count)...], as: UTF8.self))
        }
        return nil
    }

    static func trimTrailingSlashes(_ s: String) -> String {
        var s = Substring(s)
        while s.hasSuffix("/") { s = s.dropLast() }
        return String(s)
    }

    static func trimmed(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
