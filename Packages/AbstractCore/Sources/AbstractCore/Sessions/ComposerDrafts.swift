import Foundation
import Observation

/// What's in a composer and not sent yet.
public struct ComposerDraft: Codable, Sendable, Hashable {
    public var text: String
    public var attachments: [PromptAttachment]

    public init(text: String = "", attachments: [PromptAttachment] = []) {
        self.text = text
        self.attachments = attachments
    }

    public var isEmpty: Bool { text.isEmpty && attachments.isEmpty }
}

/// Each composer's unsent draft, by chat (and one for New Chat), kept above
/// the screens so it outlives them (ABS-182). Every composer watches only its
/// own draft, so typing in one doesn't redraw the others. Drafts are written
/// to `file` a moment after typing stops, off the main thread, and read back
/// at launch.
@MainActor @Observable
public final class ComposerDrafts {
    /// The New Chat composer's draft, on the New screen and in the sheet.
    public static let newChat = "new-chat"

    @MainActor @Observable
    public final class Draft {
        public var text = "" { didSet { if text != oldValue { owner?.changed() } } }
        public var attachments: [PromptAttachment] = [] { didSet { if attachments != oldValue { owner?.changed() } } }
        @ObservationIgnored fileprivate weak var owner: ComposerDrafts?

        fileprivate init(_ value: ComposerDraft, owner: ComposerDrafts) {
            text = value.text
            attachments = value.attachments
            self.owner = owner
        }

        public var value: ComposerDraft { ComposerDraft(text: text, attachments: attachments) }

        /// After it's sent, or on purpose.
        public func clear() {
            text = ""
            attachments = []
        }
    }

    @ObservationIgnored private var drafts: [String: Draft] = [:]
    @ObservationIgnored private let file: URL?
    @ObservationIgnored private let delay: Duration
    @ObservationIgnored private var pending: Task<Void, Never>?
    /// One write at a time, in order.
    @ObservationIgnored private let writer = DispatchQueue(label: "abstract.composer-drafts", qos: .utility)

    /// `file` nil keeps drafts in memory only.
    public init(file: URL?, delay: Duration = .seconds(1)) {
        self.file = file
        self.delay = delay
        let saved = file.map { Self.read($0) } ?? [:]
        for (key, value) in saved { drafts[key] = Draft(value, owner: self) }
    }

    /// The draft for `key` (a chat's id, or `newChat`), empty until something's typed.
    public func draft(_ key: String) -> Draft {
        if let draft = drafts[key] { return draft }
        let draft = Draft(ComposerDraft(), owner: self)
        drafts[key] = draft
        return draft
    }

    /// Forgets a deleted chat's draft.
    public func remove(_ key: String) {
        guard let draft = drafts.removeValue(forKey: key) else { return }
        draft.owner = nil
        if !draft.value.isEmpty { changed() }
    }

    /// The drafts worth keeping, by key.
    public var snapshot: [String: ComposerDraft] {
        drafts.compactMapValues { $0.value.isEmpty ? nil : $0.value }
    }

    /// Writes now instead of waiting, e.g. when the app quits.
    public func flush() {
        guard let file, pending != nil else { return }
        pending?.cancel()
        pending = nil
        let snapshot = snapshot
        writer.sync { Self.write(snapshot, to: file) }
    }

    fileprivate func changed() {
        guard let file else { return }
        pending?.cancel()
        pending = Task { [delay, writer] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            let snapshot = self.snapshot
            self.pending = nil
            writer.async { Self.write(snapshot, to: file) }
        }
    }

    nonisolated static func read(_ file: URL) -> [String: ComposerDraft] {
        guard let data = try? Data(contentsOf: file),
              let saved = try? JSONDecoder().decode([String: ComposerDraft].self, from: data) else { return [:] }
        // Attached files are pruned after a while; a draft drops the ones that are gone.
        return saved.compactMapValues { draft in
            var draft = draft
            draft.attachments.removeAll { attachment in
                guard let path = attachment.path, attachment.kind == .file || attachment.kind == .image else { return false }
                return !FileManager.default.fileExists(atPath: path)
            }
            return draft.isEmpty ? nil : draft
        }
    }

    nonisolated static func write(_ drafts: [String: ComposerDraft], to file: URL) {
        if drafts.isEmpty { try? FileManager.default.removeItem(at: file); return }
        guard let data = try? JSONEncoder().encode(drafts) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}
