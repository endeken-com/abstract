import SwiftUI

/// What you opened and closed in a chat's transcript: a command's output,
/// a run of calls, an edit's diff. Kept with the chat rather than in each
/// row's views, so the transcript hears of it at once and places the rows
/// again in the same frame (nothing overlaps or leaves a gap), and a row
/// scrolled away and back is as you left it.
@MainActor
final class TranscriptExpansion {
    private var values: [String: Bool] = [:]
    /// A row's content changed: re-measure it and place the rows again.
    var onChange: ((Int) -> Void)?

    func value(_ key: String) -> Bool? { values[key] }

    func set(_ key: String, _ value: Bool, row: Int?) {
        guard values[key] != value else { return }
        values[key] = value
        if let row { onChange?(row) }
    }
}

/// The transcript row a view sits in; its version goes up whenever
/// something in it opens or closes, which redraws the views that read it.
struct TranscriptRowKey: Equatable {
    let id: Int
    let version: Int
}

extension EnvironmentValues {
    @Entry var transcriptExpansion: TranscriptExpansion? = nil
    @Entry var transcriptRow: TranscriptRowKey? = nil
}

/// Open or closed, from the chat's record inside a transcript, or the view's
/// own state elsewhere (a permission card, a pull request's thread).
struct ExpansionSwitch {
    let key: String
    let expansion: TranscriptExpansion?
    let row: TranscriptRowKey?

    func value(local: Bool?) -> Bool? {
        _ = row?.version
        return expansion?.value(key) ?? local
    }

    /// Sets it; returns false when there's no transcript to keep it, so the view keeps it itself.
    func set(_ value: Bool) -> Bool {
        guard let expansion else { return false }
        expansion.set(key, value, row: row?.id)
        return true
    }
}
