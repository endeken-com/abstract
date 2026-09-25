import Foundation
import AbstractCore

/// One row of a transcript: a timeline block, with a reply cut into its
/// Markdown blocks so each paragraph, list or code block is its own row.
struct ChatRow: Identifiable, Hashable {
    let id: Int
    let block: TimelineBlock
    /// A later Markdown block of the reply above: set at paragraph spacing.
    let continues: Bool
}

/// A row's height at a width, for the content it had then.
struct MeasuredRow {
    let signature: Int
    let width: CGFloat
    let height: CGFloat
}

/// The row still changing, observed on its own so its updates redraw only it.
@Observable
final class ChatHead {
    fileprivate(set) var row: ChatRow?
}

/// One chat's timeline as its views see it. A streaming agent adds events
/// many times a second; the views take them in batches, at most one per
/// `interval`, with the rows built once per batch instead of per view.
///
/// Settled rows (`history`) change only when a new row starts; the newest
/// row (`head`) takes every streamed update. The transcript observes them
/// separately, so streaming never redraws or re-measures the rows above.
/// The idea is Paseo's head/tail stream (Apache-2.0, Copyright (c)
/// 2025-present Mohamed Boudra).
@Observable
final class ChatFeed {
    private(set) var history: [ChatRow] = []
    let head = ChatHead()
    /// Every tool call so far, for matching approvals to their calls. Changes
    /// only when a call starts or ends, not as text streams.
    private(set) var calls: [ToolCall] = []
    private(set) var turns = 0
    private(set) var last: AgentEvent?
    /// The agent's suggested next message, until you send one yourself.
    private(set) var suggestion: String?
    /// The commands the agent last reported, since the chat last changed agent.
    private(set) var commands: AgentCommandList?
    private(set) var toolResults = 0
    /// What the agent runs beside the conversation, oldest first.
    private(set) var tasks: [AgentTask] = []
    /// How many things subagents have done, so their tasks' views know to look again.
    private(set) var subagentSteps = 0
    /// When each task was first seen running here: the CLI doesn't say when one started.
    @ObservationIgnored private(set) var taskSeenAt: [String: Date] = [:]

    /// All rows, settled and live.
    var rows: [ChatRow] { history + (head.row.map { [$0] } ?? []) }

    /// What's open in the transcript, kept with the chat.
    @ObservationIgnored let expansion = TranscriptExpansion()
    /// Rows' measured heights, kept across openings, with what they were measured for.
    @ObservationIgnored var measured: [Int: MeasuredRow] = [:]

    /// Every event so far, including those not shown yet.
    @ObservationIgnored private(set) var timeline = Timeline()
    /// Whether the saved log has been read, or the chat started here.
    @ObservationIgnored private(set) var isLoaded = false
    @ObservationIgnored private var flush: Task<Void, Never>?
    /// Replies already cut into blocks, by block id, while their text is unchanged.
    @ObservationIgnored private var parts: [Int: (text: String, blocks: [String])] = [:]
    static let interval: Duration = .milliseconds(50)
    /// Row ids for a reply's blocks: the block id, then the part.
    private static let partsPerBlock = 4096

    func append(_ event: AgentEvent) {
        timeline.append(event)
        guard flush == nil else { return }
        flush = Task { [weak self] in
            try? await Task.sleep(for: Self.interval)
            guard !Task.isCancelled else { return }
            self?.publish()
        }
    }

    func reset(_ timeline: Timeline = Timeline()) {
        self.timeline = timeline
        parts = [:]
        isLoaded = true
        publish()
    }

    private func publish() {
        flush?.cancel()
        flush = nil
        let blocks = timeline.blocks
        let rows = rows(for: blocks)
        let settled = Array(rows.dropLast())
        if settled != history { history = settled }
        if rows.last != head.row { head.row = rows.last }

        let calls = blocks.flatMap { block -> [ToolCall] in if case let .tools(_, calls) = block { calls } else { [] } }
        if calls != self.calls { self.calls = calls }
        let turns = blocks.count { if case .turn = $0 { true } else { false } }
        if turns != self.turns { self.turns = turns }
        if timeline.last != last { last = timeline.last }
        if timeline.pendingSuggestion != suggestion { suggestion = timeline.pendingSuggestion }
        if timeline.latestCommands != commands { commands = timeline.latestCommands }
        let results = timeline.entries.count { if case .toolResult = $0.event { true } else { false } }
        if results != toolResults { toolResults = results }
        let tasks = timeline.tasks
        for task in tasks where task.status == .running && taskSeenAt[task.id] == nil { taskSeenAt[task.id] = Date() }
        if tasks != self.tasks { self.tasks = tasks }
        let steps = timeline.entries.count { if case .subagent = $0.event { true } else { false } }
        if steps != subagentSteps { subagentSteps = steps }
    }

    /// What the subagent started by `toolUseId` has done so far.
    func subagent(_ toolUseId: String) -> Timeline { timeline.subagent(toolUseId) }

    /// Longest finished reply drawn as one row.
    static let wholeReplyLimit = 24_000

    private func rows(for blocks: [TimelineBlock]) -> [ChatRow] {
        var out: [ChatRow] = []
        out.reserveCapacity(blocks.count + 8)
        for block in blocks {
            if case let .tools(id, calls) = block {
                // One row per call, or per folded run of them, as Paseo does:
                // a long stretch of tool use is many small rows, and only the
                // newest takes updates.
                for (i, segment) in ToolSegment.split(calls, asking: []).prefix(Self.partsPerBlock).enumerated() {
                    let calls: [ToolCall] = switch segment { case let .run(_, run): run; case let .single(call): [call] }
                    out.append(ChatRow(id: id * Self.partsPerBlock + i, block: .tools(id: id * Self.partsPerBlock + i, calls: calls), continues: i > 0))
                }
                continue
            }
            guard case let .assistant(id, text, streaming, opensTurn) = block else {
                out.append(ChatRow(id: block.id * Self.partsPerBlock, block: block, continues: false))
                continue
            }
            // Split while it streams, so only its newest block redraws; once
            // it's done, one row again, so a selection can run across all of
            // it (a very long reply stays split).
            let split: [String]
            if !streaming, text.count <= Self.wholeReplyLimit {
                split = [text]
            } else if let cached = parts[id], cached.text == text {
                split = cached.blocks
            } else {
                split = MarkdownBlocks.split(text)
                parts[id] = (text, split)
            }
            for (i, part) in split.prefix(Self.partsPerBlock).enumerated() {
                let last = i == split.count - 1
                out.append(ChatRow(id: id * Self.partsPerBlock + i,
                                   block: .assistant(id: id * Self.partsPerBlock + i, text: part, streaming: streaming && last, opensTurn: opensTurn && i == 0),
                                   continues: i > 0))
            }
        }
        return out
    }
}
