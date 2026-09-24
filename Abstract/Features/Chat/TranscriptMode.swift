import SwiftUI

/// How much of an agent's work the transcript shows.
enum TranscriptMode: String, CaseIterable, Identifiable {
    case normal, thinking, verbose

    var id: String { rawValue }

    var title: String {
        switch self {
        case .normal: "Normal"
        case .thinking: "Thinking"
        case .verbose: "Verbose"
        }
    }

    var detail: String {
        switch self {
        case .normal: "Replies, with tool activity folded into short lines."
        case .thinking: "Replies with the agent's thinking before them."
        case .verbose: "Everything: thinking, and every tool call open with its input and output."
        }
    }

    var showsThinking: Bool { self != .normal }
    /// Tool calls stand alone and open, instead of folding into summaries.
    var opensTools: Bool { self == .verbose }
}

private struct TranscriptModeKey: EnvironmentKey { static let defaultValue = TranscriptMode.normal }

extension EnvironmentValues {
    var transcriptMode: TranscriptMode {
        get { self[TranscriptModeKey.self] }
        set { self[TranscriptModeKey.self] = newValue }
    }
}
