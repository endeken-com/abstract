import SwiftUI

/// Shows streamed text at a steady pace. Agents deliver text in bursts
/// (claude sends a hundred small chunks in half a second, then pauses), and
/// shown as it arrives each burst lands as whole lines at once. This
/// reveals it up to 60 times a second, each frame showing as much of what's
/// waiting as clears it in 150 ms, so it never trails the agent by more than
/// a moment. Pacing after Paseo's text reveal (Apache-2.0, Copyright (c)
/// 2025-present Mohamed Boudra); here each step ends after a word.
struct Revealing<Content: View>: View {
    let text: String
    /// Whether more text may still arrive.
    let streaming: Bool
    /// The part to show, and whether it's still catching up.
    @ViewBuilder let content: (String, Bool) -> Content

    /// Characters shown; nil shows everything (text that was already there).
    @State private var shown: Int?

    private static var tick: Duration { .milliseconds(16) }
    /// How long a backlog takes to clear.
    private static var horizon: Double { 0.150 }

    var body: some View {
        let count = text.count
        let visible = min(shown ?? count, count)
        content(visible < count ? String(text.prefix(visible)) : text, visible < count)
            .onAppear {
                // A reply that has only just begun plays in; one already
                // under way when the chat opens shows as it stands.
                if streaming, shown == nil, count < 240 { shown = 0 }
            }
            .onChange(of: text) { old, _ in
                if shown == nil, streaming { shown = old.count }
            }
            .task(id: text) {
                let clock = ContinuousClock()
                var last = clock.now
                while let current = shown, current < text.count {
                    try? await Task.sleep(for: Self.tick)
                    guard !Task.isCancelled else { return }
                    let now = clock.now
                    let elapsed = min(0.25, Double((now - last).components.attoseconds) / 1e18 + Double((now - last).components.seconds))
                    last = now
                    shown = Self.next(after: current, in: text, elapsed: elapsed)
                }
            }
    }

    /// The next stopping point: the share of what's left that `elapsed`
    /// covers of the horizon (at least a character), ending after a word so
    /// words appear whole.
    static func next(after current: Int, in text: String, elapsed: Double = 0.016) -> Int {
        let count = text.count
        let step = max(1, Int((Double(count - current) * elapsed / horizon).rounded(.up)))
        var end = min(count, current + step)
        let characters = Array(text)
        while end < count, !characters[end - 1].isWhitespace, end - current < step + 24 { end += 1 }
        return end
    }
}

/// Closes what a cut-off stretch of Markdown left open, so a reply shown
/// part-way reads as it will when finished: a half-typed `**bold` shows bold,
/// not two stars, and an open code fence is a code block.
enum MarkdownHealing {
    static func heal(_ markdown: String) -> String {
        var text = markdown
        // A marker with nothing after it yet would print as itself.
        while let last = text.last, "*_`~[#".contains(last) || (last == "-" && text.dropLast().last == "\n") {
            text.removeLast()
        }
        let fences = text.components(separatedBy: "\n").filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }.count
        if fences % 2 == 1 { return text + "\n```" }
        let paragraph = text.components(separatedBy: "\n\n").last ?? text
        if paragraph.filter({ $0 == "`" }).count % 2 == 1 { return text + "`" }
        let outsideCode = paragraph.split(separator: "`", omittingEmptySubsequences: false).enumerated()
            .filter { $0.offset % 2 == 0 }.map(\.element).joined()
        if outsideCode.components(separatedBy: "**").count % 2 == 0 { text += "**" }
        return text
    }
}
