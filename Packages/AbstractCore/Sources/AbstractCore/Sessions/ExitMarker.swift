import Foundation

/// An agent's process ending mid-turn, kept in its chat's log as an `.exit`
/// line. The agent can't log its own end when it crashes, is stopped, or
/// (Codex, OpenCode) simply exits after its turn, so the replay reads it from
/// here: the turn ends, as it did live, at the line's time.
public struct ExitMarker: Sendable, Codable, Hashable {
    public var code: Int32?
    /// You pressed Stop: the turn was stopped, however the process ended.
    public var stopped: Bool

    public init(code: Int32?, stopped: Bool) {
        self.code = code; self.stopped = stopped
    }

    public init?(_ line: OutputLine) {
        guard line.stream == .exit, let marker = try? JSONDecoder().decode(Self.self, from: Data(line.line.utf8)) else { return nil }
        self = marker
    }

    public var line: OutputLine {
        let data = (try? JSONEncoder().encode(self)) ?? Data()
        return OutputLine(stream: .exit, line: String(decoding: data, as: UTF8.self))
    }
}
