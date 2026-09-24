import QuartzCore
import SwiftUI
import Synchronization
import Textual

/// Streamed prose fades in: each chunk's characters rise to full opacity over
/// a moment from when they arrive, instead of popping in all at once.
///
/// Textual draws every block (paragraph, list item, table cell, code block)
/// as its own `Text`, and a streaming reply only grows its last block. The
/// parser notes that block's length, and the time, each time the reply grows;
/// the renderer picks out the `Text` of that length and fades its newest
/// characters. Nothing is tagged inside Textual, and everything else draws as
/// usual.
nonisolated final class StreamFade: Sendable {
    static let duration: CFTimeInterval = 0.45

    /// The growing block, in UTF-16 offsets (the unit of `Text.Layout`).
    private struct Tail {
        /// Where the block starts in the reply; a new start is a new block.
        var start: Int
        /// Characters below this are fully shown.
        var settled = 0
        /// Each growth: the block's new end, and when it arrived.
        var arrivals: [(end: Int, at: CFTimeInterval)] = []

        var end: Int { arrivals.last?.end ?? settled }

        func opacity(at index: Int, now: CFTimeInterval) -> Double {
            guard index >= settled, let arrival = arrivals.first(where: { index < $0.end }) else { return 1 }
            let p = min(max((now - arrival.at) / StreamFade.duration, 0), 1)
            return 1 - (1 - p) * (1 - p)
        }
    }

    /// The growing block and the one before it, whose last words may still be fading.
    private let tails = Mutex<[Tail]>([])

    /// Notes the reply's last block after each parse.
    func record(_ reply: AttributedString) {
        guard let (start, length) = Self.lastBlock(of: reply) else { return }
        record(start: start, length: length)
    }

    /// Notes a growing block directly: plain text is one block from 0.
    func record(start: Int = 0, length: Int) {
        let now = CACurrentMediaTime()
        tails.withLock { tails in
            guard var tail = tails.last, tail.start == start else {
                tails = tails.suffix(1) + [Tail(start: start, arrivals: [(length, now)])]
                return
            }
            if length > tail.end {
                tail.arrivals.append((length, now))
            } else if length < tail.end {
                // Markdown can shrink a block as it resolves (`**bold**` loses its stars).
                tail.arrivals = tail.arrivals.filter { $0.end < length } + [(length, tail.arrivals.last?.at ?? now)]
                tail.settled = min(tail.settled, length)
            }
            while let first = tail.arrivals.first, tail.arrivals.count > 1, now - first.at > Self.duration {
                tail.settled = first.end
                tail.arrivals.removeFirst()
            }
            tails[tails.count - 1] = tail
        }
    }

    /// How to show character `index` of a `Text` that is `length` long:
    /// nil when that `Text` isn't a block still fading in.
    fileprivate func opacity(length: Int, now: CFTimeInterval) -> ((Int) -> Double)? {
        let tail = tails.withLock { tails in
            // The Text can lag the parse by an update, so any recent length matches.
            tails.last { tail in
                guard let last = tail.arrivals.last, now - last.at < Self.duration else { return false }
                return tail.settled == length || tail.arrivals.contains { $0.end == length }
            }
        }
        return tail.map { tail in { tail.opacity(at: $0, now: now) } }
    }

    /// The last block's start and length, measured the way Textual draws it.
    private static func lastBlock(of reply: AttributedString) -> (start: Int, length: Int)? {
        guard let last = reply.runs.last else { return nil }
        let intent = last.presentationIntent
        var lower = last.range.lowerBound
        for run in reply.runs.reversed().dropFirst() {
            guard run.presentationIntent == intent else { break }
            lower = run.range.lowerBound
        }
        var text = String(reply[lower...].characters)
        // Textual drops a code block's closing newline.
        if intent?.components.contains(where: { if case .codeBlock = $0.kind { true } else { false } }) == true, text.hasSuffix("\n") {
            text.removeLast()
        }
        return (String(reply[..<lower].characters).utf16.count, text.utf16.count)
    }
}

/// Markdown parsing that tells `fade` how the reply grew, while it streams.
/// The finished reply that follows is not news, so it isn't recorded.
struct StreamFadeParser: MarkupParser {
    let fade: StreamFade
    let live: Bool
    private let markdown = AttributedStringMarkdownParser(baseURL: nil)

    init(fade: StreamFade, live: Bool) { self.fade = fade; self.live = live }

    func attributedString(for input: String) throws -> AttributedString {
        let reply = try markdown.attributedString(for: input)
        if live { fade.record(reply) }
        return reply
    }
}

/// Draws text as usual, except a streaming reply's newest characters, which
/// fade in. `tick` only animates to have SwiftUI redraw while they do.
nonisolated struct StreamFadeRenderer: TextRenderer {
    let fade: StreamFade
    var tick: Double

    var animatableData: Double {
        get { tick }
        set { tick = newValue }
    }

    func draw(layout: Text.Layout, in ctx: inout GraphicsContext) {
        guard let first = layout.first?.first?.characterIndices.first,
              let last = layout.last?.last?.characterIndices.last,
              let opacity = fade.opacity(length: first.distance(to: last) + 1, now: CACurrentMediaTime()) else {
            for line in layout { ctx.draw(line) }
            return
        }
        for line in layout {
            for run in line {
                for slice in run {
                    let alpha = slice.characterIndices.first.map { opacity(first.distance(to: $0)) } ?? 1
                    if alpha >= 1 {
                        ctx.draw(slice)
                    } else {
                        var faded = ctx
                        faded.opacity = alpha
                        faded.draw(slice)
                    }
                }
            }
        }
    }
}
