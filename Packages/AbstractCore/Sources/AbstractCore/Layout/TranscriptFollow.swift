import Foundation

/// Whether a transcript follows its end as new rows arrive.
///
/// Only the reader's own scrolling changes this: once they scroll away from
/// the end, arriving rows, rows changing height and turns finishing must
/// never move what they're reading, until they scroll back to the end (or
/// jump there). The Mac counterpart of the phone's `transcriptFollow.ts`;
/// the two share the rule, not code.
public struct TranscriptFollow: Equatable {
    /// This close to the end, in points, counts as at it.
    public static let endTolerance: Double = 4

    public private(set) var following = true

    public init() {}

    /// The reader scrolled — wheel, scrollbar, keys, a selection drag: how
    /// doesn't matter, where they landed does. Following resumes only at
    /// the end itself.
    public mutating func readerScrolled(distanceFromEnd: Double) {
        following = distanceFromEnd <= Self.endTolerance
    }

    /// The jump-to-latest control: go to the end and follow it again.
    public mutating func jump() { following = true }

    /// Stay on what the reader is looking at: a row they opened, a find match.
    public mutating func hold() { following = false }
}

/// Where a transcript the reader has scrolled up in sits, kept in place as
/// rows above it change height and rows arrive below it.
public enum TranscriptAnchor {
    /// The first row at the top of the view, and where its top sits against
    /// the view's top (its top minus the view's top: at most a gap below 0
    /// when the view's top falls between rows, otherwise 0 or less).
    public struct Anchor: Equatable {
        public let row: Int
        public let offset: Double
        public init(row: Int, offset: Double) {
            self.row = row
            self.offset = offset
        }
    }

    /// The anchor for a view whose top is at `viewportTop`, over rows laid
    /// out at `tops` with `heights`.
    public static func anchor(tops: [Double], heights: [Double], viewportTop: Double) -> Anchor? {
        for row in tops.indices where tops[row] + heights[row] > viewportTop {
            return Anchor(row: row, offset: tops[row] - viewportTop)
        }
        return nil
    }

    /// The view top that puts the anchor's row back where it was, over rows
    /// laid out again at `tops`. Nil when the row is gone: leave the view be.
    public static func target(_ anchor: Anchor, tops: [Double]) -> Double? {
        guard tops.indices.contains(anchor.row) else { return nil }
        return tops[anchor.row] - anchor.offset
    }
}
