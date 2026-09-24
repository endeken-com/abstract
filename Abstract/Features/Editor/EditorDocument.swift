import AppKit
import Foundation
import AbstractCore

/// A file open in a tab, after Paseo's editor model (Apache-2.0, Copyright
/// (c) 2025-present Mohamed Boudra): your edits save themselves 800 ms after
/// you stop typing (or at once with ⌘S); a change on disk replaces a clean
/// copy quietly and stops an edited one with the choice to keep yours or
/// take theirs.
@MainActor
@Observable
final class EditorDocument {
    enum Content: Equatable {
        case loading
        case text(editable: Bool)
        case image(NSImage)
        case binary
        case tooLarge
        case missing
        case unreadable(String)
    }

    enum Status: Equatable {
        case clean, dirty, saving
        /// Edited here and changed on disk too.
        case conflict
        /// Gone from disk; the open copy is kept.
        case deleted
        case failed(String)
    }

    let root: String
    let path: String
    var absolute: String { FileIndex.join(root, path) }

    private(set) var content: Content = .loading
    private(set) var status: Status = .clean
    /// Bytes on disk.
    private(set) var size: Int64 = 0
    private(set) var lineCount = 0
    /// The caret, 1-based.
    var line = 1
    var column = 1
    /// A line to show and put the caret on, once the editor has the text.
    var goToLine: Int?
    /// Bumped when the text changes from outside the editor (reading or
    /// reloading the file), so the editor replaces what it shows.
    private(set) var revision = 0

    @ObservationIgnored private(set) var text = ""
    @ObservationIgnored private var saved = ""
    @ObservationIgnored private var disk: (size: Int64, modified: Date?)?
    @ObservationIgnored private var autosave: Task<Void, Never>?
    @ObservationIgnored private var watcher: AnyObject?
    /// Where the file is: this Mac, or the Mac a chat from another device runs on.
    @ObservationIgnored private let executor: any Executor
    @ObservationIgnored private let watch: @MainActor ([String], @escaping () -> Void) -> AnyObject?
    /// Called on the first edit, so a preview tab is kept.
    @ObservationIgnored var onFirstEdit: (() -> Void)?

    static let editableLimit: Int64 = 2 * 1024 * 1024
    static let readLimit: Int64 = 10 * 1024 * 1024
    private static let images: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "tif", "bmp", "ico", "icns", "svg", "pdf"]

    init(root: String, path: String, executor: any Executor = LocalExecutor.shared,
         watch: @escaping @MainActor ([String], @escaping () -> Void) -> AnyObject? = { WorktreeWatcher(paths: $0, onChange: $1) }) {
        self.root = root
        self.path = path
        self.executor = executor
        self.watch = watch
    }

    var isDirty: Bool { status == .dirty || status == .conflict || (status == .saving && text != saved) }

    // MARK: Reading

    func load() async {
        guard content == .loading else { return }
        await read()
        watcher = watch([(absolute as NSString).deletingLastPathComponent]) { [weak self] in
            Task { await self?.diskChanged() }
        }
    }

    private func read() async {
        let url = URL(fileURLWithPath: absolute)
        guard let info = await executor.fileInfo(absolute), !info.isDirectory else { content = .missing; return }
        size = info.size
        disk = (size, info.modified)
        let isImage = Self.images.contains(url.pathExtension.lowercased())
        guard size <= Self.readLimit || isImage else { content = .tooLarge; return }
        let data: Data
        do { data = try await executor.readData(absolute) } catch { content = .unreadable(error.localizedDescription); return }
        if isImage, let image = NSImage(data: data) {
            content = .image(image)
            return
        }
        // Paseo's test: a NUL, or bytes that aren't UTF-8, mean binary.
        guard !data.prefix(8000).contains(0), let string = String(data: data, encoding: .utf8) else { content = .binary; return }
        text = string
        saved = string
        lineCount = Self.lines(in: string)
        content = .text(editable: size <= Self.editableLimit)
        status = .clean
        revision += 1
    }

    // MARK: Editing

    /// The editor's text changed as you typed.
    func edited(_ string: String) {
        if text == saved, string != saved { onFirstEdit?() }
        text = string
        lineCount = Self.lines(in: string)
        guard status != .conflict, status != .deleted else { return }
        status = text == saved ? .clean : .dirty
        autosave?.cancel()
        guard status == .dirty else { return }
        autosave = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            await self?.save()
        }
    }

    /// Writes your text, unless the file changed on disk since it was read.
    func save() async {
        autosave?.cancel()
        guard case .text(true) = content, text != saved, status != .conflict else { return }
        if let known = disk, !Self.same(known, await stat()) {
            status = .conflict
            return
        }
        await write()
    }

    /// Keep your version over the one on disk.
    func overwrite() async {
        await write()
    }

    /// Take the version on disk, dropping your edits.
    func reload() async {
        content = .loading
        await read()
    }

    private func write() async {
        let snapshot = text
        status = .saving
        do {
            // In place, not atomically, so the file keeps its permissions.
            try await executor.writeData(Data(snapshot.utf8), to: absolute)
            saved = snapshot
            disk = await stat()
            size = disk?.size ?? size
            status = text == saved ? .clean : .dirty
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    /// Something in the file's folder changed: see whether it was this file.
    private func diskChanged() async {
        guard let now = await stat() else {
            if case .text = content { status = .deleted } else { content = .missing }
            return
        }
        guard let known = disk, !Self.same(known, now), status != .saving else { return }
        if status == .clean || status == .deleted {
            content = .loading
            await read()
        } else {
            status = .conflict
        }
    }

    private static func same(_ a: (size: Int64, modified: Date?), _ b: (size: Int64, modified: Date?)?) -> Bool {
        guard let b else { return false }
        return a.size == b.size && a.modified == b.modified
    }

    private func stat() async -> (size: Int64, modified: Date?)? {
        await executor.fileInfo(absolute).map { ($0.size, $0.modified) }
    }

    /// Lines as Paseo counts them: a trailing newline starts one more.
    static func lines(in text: String) -> Int {
        text.utf8.reduce(1) { $1 == 0x0A ? $0 + 1 : $0 }
    }

    /// "36.4 KB", as Paseo shows sizes.
    static func format(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / 1024 / 1024)
    }
}

/// Open documents by worktree and path, so a tab that comes back keeps its
/// edits, caret and undo.
@MainActor
final class EditorStore {
    static let shared = EditorStore()
    private var documents: [String: EditorDocument] = [:]

    /// A chat's file, opened where its worktree is.
    func document(root: String, path: String, in sessionId: String, model: AppModel) -> EditorDocument {
        let key = Self.key(root, path, sessionId)
        if let existing = documents[key] { return existing }
        let document = EditorDocument(root: root, path: path, executor: model.executor(for: sessionId)) { [weak model] paths, change in
            model?.watch(paths, for: sessionId, onChange: change)
        }
        documents[key] = document
        return document
    }

    func existing(root: String, path: String, in sessionId: String) -> EditorDocument? { documents[Self.key(root, path, sessionId)] }

    /// The same path on two Macs is two files.
    private static func key(_ root: String, _ path: String, _ sessionId: String) -> String {
        (RemoteService.split(sessionId)?.device ?? "") + "\u{0}" + root + "\u{0}" + path
    }
}
