import Foundation

/// A compaction Abstract ran or started, kept in the chat's log as a
/// `.compaction` line so live streaming, replay and other Macs show the same.
public struct CompactionMarker: Sendable, Codable, Hashable {
    public enum Phase: String, Sendable, Codable { case started, finished, failed }

    public var phase: Phase
    public var trigger: CompactionTrigger?
    public var result: CompactionResult?
    public var durationMs: Int?
    public var message: String?

    public static func started(_ trigger: CompactionTrigger) -> Self { Self(phase: .started, trigger: trigger) }
    public static func finished(_ result: CompactionResult, trigger: CompactionTrigger?, durationMs: Int?) -> Self {
        Self(phase: .finished, trigger: trigger, result: result, durationMs: durationMs)
    }
    public static func failed(_ message: String) -> Self { Self(phase: .failed, message: message) }

    public init?(_ line: OutputLine) {
        guard line.stream == .compaction, let marker = try? JSONDecoder().decode(Self.self, from: Data(line.line.utf8)) else { return nil }
        self = marker
    }

    private init(phase: Phase, trigger: CompactionTrigger? = nil, result: CompactionResult? = nil,
                 durationMs: Int? = nil, message: String? = nil) {
        self.phase = phase; self.trigger = trigger; self.result = result
        self.durationMs = durationMs; self.message = message
    }

    public var line: OutputLine {
        let data = (try? JSONEncoder().encode(self)) ?? Data()
        return OutputLine(stream: .compaction, line: String(decoding: data, as: UTF8.self))
    }

    public var event: AgentEvent {
        switch phase {
        case .started: .compaction(.started(trigger ?? .manual))
        case .finished: .compaction(.finished(result ?? CompactionResult(), trigger: trigger, durationMs: durationMs))
        case .failed: .compaction(.failed(message ?? "Compacting failed."))
        }
    }
}
