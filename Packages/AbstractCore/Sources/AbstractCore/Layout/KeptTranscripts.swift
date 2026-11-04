import Foundation

/// The transcripts of the chats shown last, kept whole so showing one of them
/// again takes what's there instead of building it anew. Newest first, at
/// most `limit` of them; a chat that falls off the end, or is deleted or
/// archived, lets go of its transcript.
public struct KeptTranscripts<Transcript> {
    public static var defaultLimit: Int { 4 }

    public let limit: Int
    /// Chat ids, most recently shown first.
    public private(set) var order: [String] = []
    private var kept: [String: Transcript] = [:]

    public init(limit: Int = Self.defaultLimit) {
        self.limit = max(1, limit)
    }

    public var count: Int { order.count }

    public func transcript(_ chatId: String) -> Transcript? { kept[chatId] }

    /// The chat's transcript is showing: it moves to the front, kept or new
    /// (made by `make`). Returns it, and those that fell off the end.
    public mutating func show(_ chatId: String, make: () -> Transcript) -> (transcript: Transcript, released: [Transcript]) {
        let transcript = kept[chatId] ?? make()
        kept[chatId] = transcript
        order.removeAll { $0 == chatId }
        order.insert(chatId, at: 0)
        var released: [Transcript] = []
        while order.count > limit {
            let dropped = order.removeLast()
            if let gone = kept.removeValue(forKey: dropped) { released.append(gone) }
        }
        return (transcript, released)
    }

    /// Lets go of a chat's transcript: deleted, archived, or gone.
    @discardableResult
    public mutating func release(_ chatId: String) -> Transcript? {
        order.removeAll { $0 == chatId }
        return kept.removeValue(forKey: chatId)
    }

    /// Lets go of every chat `keeps` says no to. Returns what was let go.
    @discardableResult
    public mutating func release(unless keeps: (String) -> Bool) -> [Transcript] {
        order.filter { !keeps($0) }.compactMap { release($0) }
    }
}
