import AppKit
import Foundation
import Observation
import AbstractCore

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
    /// The ref the chat's branch was made from.
    let baseRef: String?
}

enum DiffAvailability {
    case ready(DiffContext)
    case noProject
    case noWorktree
    /// The chat had a worktree, but its folder is no longer on disk.
    case worktreeMissing(String)
    /// A newer chat started in this chat's worktree and took it over.
    case handedOver
}

extension AppModel {
    func diffAvailability(_ sessionId: String) -> DiffAvailability {
        guard let session = session(sessionId), let project = project(session.projectId) else { return .noProject }
        guard let worktree = session.worktreePath, !worktree.isEmpty else {
            return session.branch == nil ? .noWorktree : .handedOver
        }
        // A chat on another Mac: its worktree is there; the link says if it's gone.
        let remote = sessionId.hasPrefix(RemoteService.mirrorPrefix)
        guard remote || FileManager.default.fileExists(atPath: worktree) else { return .worktreeMissing(worktree) }
        return .ready(DiffContext(executor: executor(for: sessionId), sessionId: sessionId, worktree: worktree, root: project.rootPath,
                                  projectName: project.name, exclude: project.nestedRepos, baseRef: session.baseRef))
    }
}

/// Which hunks have been accepted into the main working tree, per chat.
/// Kept for the app's lifetime so switching tabs doesn't forget it.
enum AcceptedLedger {
    static var bySession: [String: Set<String>] = [:]
}

// MARK: - Review model

/// Which changes a review shows, after Paseo's comparison modes (Apache-2.0,
/// Copyright (c) 2025-present Mohamed Boudra).
enum ReviewMode: Hashable {
    /// What isn't committed yet, new files included.
    case uncommitted
    /// The branch's commits since it left its base.
    case committed
    /// One of those commits.
    case commit(CommitSummary)

    var label: String {
        switch self {
        case .uncommitted: "Uncommitted"
        case .committed: "Committed"
        case .commit(let c): c.shortSha
        }
    }
}

@Observable
final class DiffReview {
    enum Phase: Equatable { case loading, loaded, failed(String) }

    private(set) var mode: ReviewMode = .uncommitted
    /// The ref committed changes are measured from.
    private(set) var base: String?
    private(set) var commits: [CommitSummary] = []
    /// Whether the worktree has uncommitted changes.
    private(set) var dirty = false
    /// With nothing to show, whether the other mode has something.
    private(set) var otherModeHasChanges = false
    /// A mode picked by hand holds while the worktree stays as dirty (or as
    /// clean) as it was when picked; then the review picks again.
    @ObservationIgnored private var pickedWhileDirty: Bool?

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
    /// Files opened or closed by hand; the rest open unless they're long.
    var expansion: [String: Bool] = [:]

    /// Files in the order they're listed: top-level first, then by folder.
    var orderedFiles: [ReviewFile] { groups.flatMap(\.files) }

    func isExpanded(_ file: ReviewFile) -> Bool {
        expansion[file.path] ?? (!file.diff.isBinary && file.lineCount <= 400)
    }

    func toggle(_ file: ReviewFile) { expansion[file.path] = !isExpanded(file) }

    /// A file another pane asked to show; the token repeats a request for the same file.
    private(set) var focusPath: String?
    private(set) var focusToken = 0

    func focus(_ path: String) {
        focusPath = path
        focusToken += 1
        if let file = files.first(where: { $0.path == path }), !isExpanded(file) { toggle(file) }
    }

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

    /// `git diff -w`: changes that only move whitespace don't show.
    var ignoreWhitespace = false

    func load(_ context: DiffContext) async {
        generation += 1
        let current = generation
        accepted = AcceptedLedger.bySession[context.sessionId] ?? []
        if phase == .loaded { isRefreshing = true } else { phase = .loading }
        defer { if current == generation { isRefreshing = false } }
        let exec = context.executor
        let dirty = await Diff.isDirty(exec, worktree: context.worktree)
        let base = await Diff.resolveBase(exec, worktree: context.worktree, preferred: context.baseRef)
        let commits = base == nil ? [] : await Diff.commits(exec, worktree: context.worktree, base: base!)
        guard current == generation else { return }
        self.dirty = dirty
        self.base = base
        self.commits = commits
        // Uncommitted work while there is some, the branch's commits once it's all committed.
        if case .commit = mode {} else if pickedWhileDirty != dirty {
            pickedWhileDirty = nil
            mode = dirty || base == nil ? .uncommitted : .committed
        }
        let compare: DiffCompare = switch mode {
        case .uncommitted: .uncommitted
        case .committed: base.map { .committed(base: $0) } ?? .uncommitted
        case .commit(let c): .commit(sha: c.sha)
        }
        do {
            let raw = try await Diff.collect(exec, worktree: context.worktree, exclude: context.exclude,
                                             compare: compare, ignoreWhitespace: ignoreWhitespace)
            let prepared = await ReviewFile.prepare(raw)
            guard current == generation else { return }
            apply(prepared)
            otherModeHasChanges = switch mode {
            case .uncommitted: prepared.isEmpty && !commits.isEmpty
            case .committed: prepared.isEmpty && dirty
            case .commit: false
            }
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

    /// Show `mode`; it holds until the worktree's dirty state changes.
    func show(_ mode: ReviewMode, _ context: DiffContext) async {
        self.mode = mode
        pickedWhileDirty = dirty
        expansion = [:]
        await load(context)
    }

    /// Open or close every file at once.
    func setAllExpanded(_ open: Bool) {
        for file in files { expansion[file.path] = open }
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
            return "Applied \(file.name) to \(context.projectName)" + Self.note(outcome)
        }
    }

    /// Throw away the uncommitted changes to `files` in the worktree.
    func discard(_ files: [ReviewFile], _ context: DiffContext, model: AppModel) async {
        guard let first = files.first else { return }
        await perform(files.count == 1 ? "file:\(first.path)" : "all", context, model: model) {
            let paths = files.flatMap { [$0.path] + ($0.diff.oldPath.map { [$0] } ?? []) }
            try await Diff.discard(context.executor, worktree: context.worktree, paths: paths)
            for file in files {
                self.unmarkAccepted(file.hunks.map(\.fingerprint) + [file.fileFingerprint], session: context.sessionId)
            }
            return files.count == 1 ? "Discarded changes to \(first.name)" : "Discarded changes to \(files.count) files"
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
            throw AbstractError.message("Couldn't copy \(file.path): \(error.localizedDescription)")
        }
    }

    private static func git(_ exec: any Executor, _ cwd: String, _ args: [String]) async throws {
        let out = try await exec.run("git", args, cwd: cwd)
        guard out.ok else {
            let detail = out.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw AbstractError.command(code: out.code, stderr: "git \(args.first ?? ""): \(detail)")
        }
    }

    static func join(_ base: String, _ path: String) -> String {
        var base = base
        while base.hasSuffix("/") { base.removeLast() }
        return base + "/" + path
    }
}
