import AppKit
import Foundation
import Observation
import BacktickCore

// MARK: - Prepared rows

/// One diff line, ready to draw: numbers already formatted, tabs expanded.
nonisolated struct NumberedLine: Sendable, Hashable {
    enum Kind: Sendable, Hashable { case context, added, removed, note }
    let kind: Kind
    /// Old / new line numbers as text, empty when the line has none on that side.
    let old: String
    let new: String
    let text: String
}

/// A row in the diff list. Unified layouts use `.hunk` and `.line`; split
/// layouts use `.hunk` and `.pair`.
nonisolated struct DiffRowItem: Identifiable, Sendable {
    enum Content: Sendable {
        case hunk(Int)
        case line(NumberedLine)
        case pair(NumberedLine?, NumberedLine?)
    }
    let id: Int
    let content: Content
}

nonisolated struct ReviewHunk: Sendable, Hashable {
    /// `Hunk.index`, what `Diff.buildPatch` selects by.
    let index: Int
    /// `@@ -10,5 +10,6 @@`
    let range: String
    /// The function or section git printed after the range, if any.
    let section: String
    /// Identifies this hunk's content across reloads, so an accepted hunk
    /// still reads as accepted after a refresh.
    let fingerprint: String
}

/// A file's diff, parsed once into everything the view draws.
nonisolated struct ReviewFile: Identifiable, Sendable {
    let diff: FileDiff
    let hunks: [ReviewHunk]
    let unified: [DiffRowItem]
    let split: [DiffRowItem]
    /// Widest line in characters, for the horizontal scroll extent.
    let maxColumns: Int
    /// Digits in the largest line number, for the gutter width.
    let numberDigits: Int
    /// Fingerprint for whole-file operations on files without hunks.
    let fileFingerprint: String

    var id: String { diff.path }
    var path: String { diff.path }
    var name: String { (diff.path as NSString).lastPathComponent }
    var directory: String { (diff.path as NSString).deletingLastPathComponent }
    var lineCount: Int { unified.count - hunks.count }
    /// Hunk-level accept/reject only makes sense for in-place modifications;
    /// additions, deletions and renames are handled as a whole.
    var allowsHunkActions: Bool { diff.status == .modified && !diff.isBinary }

    @concurrent
    static func prepare(_ files: [FileDiff]) async -> [ReviewFile] {
        files.map(ReviewFile.init(diff:))
    }

    init(diff: FileDiff) {
        self.diff = diff
        var hunks: [ReviewHunk] = []
        var unified: [DiffRowItem] = []
        var split: [DiffRowItem] = []
        var maxColumns = 0
        var maxNumber = 0

        for (position, hunk) in diff.hunks.enumerated() {
            let (range, section) = Self.splitHeader(hunk.header)
            let body = hunk.raw.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).dropFirst().first ?? ""
            hunks.append(ReviewHunk(index: hunk.index, range: range, section: section,
                                    fingerprint: diff.path + "\u{0}" + body))
            unified.append(DiffRowItem(id: unified.count, content: .hunk(position)))
            split.append(DiffRowItem(id: split.count, content: .hunk(position)))

            var old = hunk.oldStart
            var new = hunk.newStart
            var removedRun: [NumberedLine] = []
            var addedRun: [NumberedLine] = []
            var last: NumberedLine.Kind = .context

            func flushRuns() {
                for i in 0..<max(removedRun.count, addedRun.count) {
                    split.append(DiffRowItem(id: split.count, content: .pair(
                        i < removedRun.count ? removedRun[i] : nil,
                        i < addedRun.count ? addedRun[i] : nil)))
                }
                removedRun.removeAll(keepingCapacity: true)
                addedRun.removeAll(keepingCapacity: true)
            }

            for line in hunk.lines {
                let text = Self.display(line.content)
                maxColumns = max(maxColumns, Self.columns(text))
                switch line.origin {
                case .context:
                    let n = NumberedLine(kind: .context, old: String(old), new: String(new), text: text)
                    maxNumber = max(maxNumber, old, new)
                    old += 1; new += 1
                    unified.append(DiffRowItem(id: unified.count, content: .line(n)))
                    flushRuns()
                    split.append(DiffRowItem(id: split.count, content: .pair(n, n)))
                    last = .context
                case .removed:
                    let n = NumberedLine(kind: .removed, old: String(old), new: "", text: text)
                    maxNumber = max(maxNumber, old)
                    old += 1
                    unified.append(DiffRowItem(id: unified.count, content: .line(n)))
                    if !addedRun.isEmpty { flushRuns() }
                    removedRun.append(n)
                    last = .removed
                case .added:
                    let n = NumberedLine(kind: .added, old: "", new: String(new), text: text)
                    maxNumber = max(maxNumber, new)
                    new += 1
                    unified.append(DiffRowItem(id: unified.count, content: .line(n)))
                    addedRun.append(n)
                    last = .added
                case .noNewline:
                    let n = NumberedLine(kind: .note, old: "", new: "", text: "No newline at end of file")
                    unified.append(DiffRowItem(id: unified.count, content: .line(n)))
                    flushRuns()
                    split.append(DiffRowItem(id: split.count, content: .pair(
                        last == .added ? nil : n, last == .removed ? nil : n)))
                }
            }
            flushRuns()
        }

        self.hunks = hunks
        self.unified = unified
        self.split = split
        self.maxColumns = maxColumns
        self.numberDigits = max(3, String(maxNumber).count)
        self.fileFingerprint = diff.path + "\u{0}" + diff.rawHeader
    }

    /// `@@ -1,2 +1,3 @@ func x()` → ("@@ -1,2 +1,3 @@", "func x()")
    static func splitHeader(_ header: String) -> (String, String) {
        guard header.hasPrefix("@@"),
              let close = header.range(of: "@@", range: header.index(header.startIndex, offsetBy: 2)..<header.endIndex)
        else { return (header, "") }
        return (String(header[..<close.upperBound]), header[close.upperBound...].trimmingCharacters(in: .whitespaces))
    }

    /// Tabs become four spaces and a stray CR disappears, so columns line up.
    static func display(_ content: String) -> String {
        var text = content
        if text.hasSuffix("\r") { text.removeLast() }
        return text.contains("\t") ? text.replacingOccurrences(of: "\t", with: "    ") : text
    }

    /// Approximate monospaced width: East Asian wide characters take two cells.
    static func columns(_ text: String) -> Int {
        var count = 0
        for scalar in text.unicodeScalars {
            let v = scalar.value
            count += (0x1100...0x115F).contains(v) || (0x2E80...0xA4CF).contains(v) || (0xAC00...0xD7A3).contains(v)
                || (0xF900...0xFAFF).contains(v) || (0xFF00...0xFF60).contains(v) || (0x1F300...0x1FAFF).contains(v) ? 2 : 1
        }
        return count
    }
}

/// Files grouped under their directory, in display order.
struct ReviewGroup: Identifiable {
    let directory: String
    let files: [ReviewFile]
    var id: String { directory }
}

// MARK: - Where a review happens

/// Everything a review needs from the app, resolved once per action.
struct DiffContext: Sendable {
    let executor: any Executor
    let sessionId: String
    let worktree: String
    let root: String
    let projectName: String
    let exclude: [String]
}

enum DiffAvailability {
    case ready(DiffContext)
    case noProject
    case noWorktree
}

extension AppModel {
    func diffAvailability(_ sessionId: String) -> DiffAvailability {
        guard let session = session(sessionId), let project = project(session.projectId) else { return .noProject }
        guard let worktree = session.worktreePath, !worktree.isEmpty else { return .noWorktree }
        return .ready(DiffContext(executor: executor, sessionId: sessionId, worktree: worktree, root: project.rootPath,
                                  projectName: project.name, exclude: project.nestedRepos))
    }
}

/// Which hunks have been accepted into the main working tree, per chat.
/// Kept for the app's lifetime so switching tabs doesn't forget it.
enum AcceptedLedger {
    static var bySession: [String: Set<String>] = [:]
}

// MARK: - Review model

@Observable
final class DiffReview {
    enum Phase: Equatable { case loading, loaded, failed(String) }

    private(set) var phase: Phase = .loading
    private(set) var files: [ReviewFile] = []
    private(set) var groups: [ReviewGroup] = []
    var selectedPath: String?
    private(set) var isRefreshing = false
    /// The key of the accept/reject in flight; actions are serialized so git
    /// never races itself on the index.
    private(set) var workingOn: String?
    var actionError: String?
    private(set) var accepted: Set<String> = []
    /// Very large files render only when asked.
    var revealedLargeFiles: Set<String> = []

    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var orderedPaths: [String] = []

    var selectedFile: ReviewFile? {
        guard let selectedPath else { return nil }
        return files.first { $0.path == selectedPath }
    }

    var totalAdditions: Int { files.reduce(0) { $0 + $1.diff.additions } }
    var totalDeletions: Int { files.reduce(0) { $0 + $1.diff.deletions } }
    var isWorking: Bool { workingOn != nil }

    // MARK: Loading

    func load(_ context: DiffContext) async {
        generation += 1
        let current = generation
        accepted = AcceptedLedger.bySession[context.sessionId] ?? []
        if phase == .loaded { isRefreshing = true } else { phase = .loading }
        defer { if current == generation { isRefreshing = false } }
        do {
            let raw = try await Diff.collect(context.executor, worktree: context.worktree, exclude: context.exclude)
            let prepared = await ReviewFile.prepare(raw)
            guard current == generation else { return }
            apply(prepared)
            phase = .loaded
        } catch {
            guard current == generation else { return }
            if phase == .loaded {
                actionError = "Couldn't refresh: \(error.localizedDescription)"
            } else {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func apply(_ prepared: [ReviewFile]) {
        let previousIndex = selectedPath.flatMap { orderedPaths.firstIndex(of: $0) }
        let grouped = Dictionary(grouping: prepared, by: \.directory)
        groups = grouped.keys.sorted { a, b in
            // Top-level files first, then directories alphabetically.
            a.isEmpty != b.isEmpty ? a.isEmpty : a.localizedStandardCompare(b) == .orderedAscending
        }.map { dir in
            ReviewGroup(directory: dir, files: grouped[dir]!.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
        }
        files = prepared
        orderedPaths = groups.flatMap { $0.files.map(\.path) }
        if let selectedPath, orderedPaths.contains(selectedPath) { return }
        if let previousIndex, !orderedPaths.isEmpty {
            selectedPath = orderedPaths[min(previousIndex, orderedPaths.count - 1)]
        } else {
            selectedPath = orderedPaths.first
        }
    }

    func moveSelection(_ delta: Int) {
        guard !orderedPaths.isEmpty else { return }
        let index = selectedPath.flatMap { orderedPaths.firstIndex(of: $0) } ?? -delta
        selectedPath = orderedPaths[min(max(index + delta, 0), orderedPaths.count - 1)]
    }

    // MARK: Accepted state

    func isAccepted(_ hunk: ReviewHunk) -> Bool { accepted.contains(hunk.fingerprint) }

    func isAccepted(_ file: ReviewFile) -> Bool {
        if file.hunks.isEmpty { return accepted.contains(file.fileFingerprint) }
        return file.hunks.allSatisfy { accepted.contains($0.fingerprint) }
    }

    func isPartlyAccepted(_ file: ReviewFile) -> Bool {
        !isAccepted(file) && file.hunks.contains { accepted.contains($0.fingerprint) }
    }

    private func markAccepted(_ keys: [String], session: String) {
        accepted.formUnion(keys)
        AcceptedLedger.bySession[session, default: []].formUnion(keys)
    }

    private func unmarkAccepted(_ keys: [String], session: String) {
        accepted.subtract(keys)
        AcceptedLedger.bySession[session]?.subtract(keys)
    }

    // MARK: Actions

    /// Apply a whole file onto the project's main working tree.
    func acceptFile(_ file: ReviewFile, _ context: DiffContext, model: AppModel) async {
        await perform("file:\(file.path)", context, model: model) {
            let outcome = try await Self.accept(file, context)
            self.markAccepted(file.hunks.map(\.fingerprint) + [file.fileFingerprint], session: context.sessionId)
            return "Accepted \(file.name) into \(context.projectName)" + Self.note(outcome)
        }
    }

    func acceptHunk(_ hunk: ReviewHunk, in file: ReviewFile, _ context: DiffContext, model: AppModel) async {
        await perform("hunk:\(hunk.fingerprint)", context, model: model) {
            let patch = Diff.buildPatch(file.diff, hunks: [hunk.index])
            let outcome = try await Diff.accept(context.executor, root: context.root, patch: patch)
            self.markAccepted([hunk.fingerprint], session: context.sessionId)
            return "Accepted a change in \(file.name)" + Self.note(outcome)
        }
    }

    /// Undo the agent's change to a whole file inside its worktree.
    func rejectFile(_ file: ReviewFile, _ context: DiffContext, model: AppModel) async {
        await perform("file:\(file.path)", context, model: model) {
            try await Self.reject(file, context)
            self.unmarkAccepted(file.hunks.map(\.fingerprint) + [file.fileFingerprint], session: context.sessionId)
            return "Rejected \(file.name)"
        }
    }

    func rejectHunk(_ hunk: ReviewHunk, in file: ReviewFile, _ context: DiffContext, model: AppModel) async {
        await perform("hunk:\(hunk.fingerprint)", context, model: model) {
            let patch = Diff.buildPatch(file.diff, hunks: [hunk.index])
            try await Diff.apply(context.executor, cwd: context.worktree, patch: patch, reverse: true, threeWay: false)
            self.unmarkAccepted([hunk.fingerprint], session: context.sessionId)
            return "Rejected a change in \(file.name)"
        }
    }

    /// Accept every file not already accepted, one file at a time so one
    /// conflict doesn't hold back the rest.
    func acceptAll(_ context: DiffContext, model: AppModel) async {
        let pending = files.filter { !isAccepted($0) }
        guard !pending.isEmpty else { return }
        workingOn = "all"
        actionError = nil
        var failures: [String] = []
        for file in pending {
            do {
                try await Self.accept(file, context)
                markAccepted(file.hunks.map(\.fingerprint) + [file.fileFingerprint], session: context.sessionId)
            } catch {
                failures.append("\(file.path): \(Self.explain(error).0)")
            }
        }
        workingOn = nil
        let done = pending.count - failures.count
        if failures.isEmpty {
            model.flash("Accepted \(done) file\(done == 1 ? "" : "s") into \(context.projectName)")
        } else {
            actionError = "Accepted \(done) of \(pending.count) files. These didn't apply:\n" + failures.joined(separator: "\n")
            model.flash("\(failures.count) file\(failures.count == 1 ? "" : "s") couldn't be accepted", isError: true)
        }
        await load(context)
    }

    func isWorking(on key: String) -> Bool { workingOn == key || workingOn == "all" }

    private func perform(_ key: String, _ context: DiffContext, model: AppModel,
                         _ action: () async throws -> String) async {
        guard workingOn == nil else { return }
        workingOn = key
        actionError = nil
        do {
            let message = try await action()
            model.flash(message)
        } catch {
            let (headline, detail) = Self.explain(error)
            actionError = detail.map { headline + "\n" + $0 } ?? headline
            model.flash(headline, isError: true)
        }
        workingOn = nil
        await load(context)
    }

    /// Git's refusals, in words that say what to do next.
    static func explain(_ error: Error) -> (String, String?) {
        let raw = error.localizedDescription
        if raw.contains("does not match index") {
            return ("That file has uncommitted edits in your main working tree. Commit or stash them, then accept again.", raw)
        }
        if raw.contains("patch does not apply") || raw.contains("patch failed") {
            return ("The change no longer applies cleanly. Refresh and try again.", raw)
        }
        return (raw, nil)
    }

    // MARK: Git

    @discardableResult
    private static func accept(_ file: ReviewFile, _ context: DiffContext) async throws -> Diff.AcceptOutcome {
        if file.diff.isBinary {
            try copyBinary(file, from: context.worktree, to: context.root)
            return .applied
        }
        let patch = Diff.buildPatch(file.diff, hunks: [])
        return try await Diff.accept(context.executor, root: context.root, patch: patch)
    }

    /// Plain words for the rare cases where git had to merge.
    private static func note(_ outcome: Diff.AcceptOutcome) -> String {
        switch outcome {
        case .applied: ""
        case .mergedAndStaged: " (merged three ways and staged)"
        case .conflicts: " with conflicts; resolve the markers in your editor"
        }
    }

    private static func reject(_ file: ReviewFile, _ context: DiffContext) async throws {
        let exec = context.executor
        let absolute = join(context.worktree, file.path)
        if file.diff.status == .added {
            // `collect` marked it intent-to-add; drop that entry, then the file.
            try await git(exec, context.worktree, ["rm", "--cached", "--force", "--quiet", "--ignore-unmatch", "--", file.path])
            if exec.fileExists(absolute) { try exec.removeItem(absolute) }
            return
        }
        if file.diff.isBinary {
            // No patch text for binaries: restore the committed copy instead.
            let source = file.diff.oldPath ?? file.path
            try await git(exec, context.worktree, ["checkout", "HEAD", "--", source])
            if file.diff.status == .renamed {
                try await git(exec, context.worktree, ["rm", "--cached", "--force", "--quiet", "--ignore-unmatch", "--", file.path])
                if exec.fileExists(absolute) { try exec.removeItem(absolute) }
            }
            return
        }
        let patch = Diff.buildPatch(file.diff, hunks: [])
        try await Diff.apply(exec, cwd: context.worktree, patch: patch, reverse: true, threeWay: false)
        // A reverted rename leaves the new path's intent-to-add entry behind.
        if file.diff.status == .renamed, !exec.fileExists(absolute) {
            try await git(exec, context.worktree, ["rm", "--cached", "--force", "--quiet", "--ignore-unmatch", "--", file.path])
        }
    }

    private static func copyBinary(_ file: ReviewFile, from worktree: String, to root: String) throws {
        let fm = FileManager.default
        let target = URL(fileURLWithPath: join(root, file.path))
        do {
            if file.diff.status == .renamed, let old = file.diff.oldPath {
                let oldURL = URL(fileURLWithPath: join(root, old))
                if fm.fileExists(atPath: oldURL.path) { try fm.removeItem(at: oldURL) }
            }
            if file.diff.status == .deleted {
                if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
                return
            }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try fm.copyItem(at: URL(fileURLWithPath: join(worktree, file.path)), to: target)
        } catch {
            throw BacktickError.message("Couldn't copy \(file.path): \(error.localizedDescription)")
        }
    }

    private static func git(_ exec: any Executor, _ cwd: String, _ args: [String]) async throws {
        let out = try await exec.run("git", args, cwd: cwd)
        guard out.ok else {
            let detail = out.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw BacktickError.command(code: out.code, stderr: "git \(args.first ?? ""): \(detail)")
        }
    }

    static func join(_ base: String, _ path: String) -> String {
        var base = base
        while base.hasSuffix("/") { base.removeLast() }
        return base + "/" + path
    }
}
