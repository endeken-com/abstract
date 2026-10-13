import Foundation

/// When a chat on another Mac should notify you here, worked out from that
/// Mac's snapshots: the moments a chat on this Mac notifies on, by the same
/// settings. One per paired Mac.
public struct RemoteNotices: Sendable, Equatable {
    public struct Notice: Sendable, Hashable {
        /// The chat's id on the other Mac.
        public var sessionId: String
        /// `.waitingInput`, `.finished` or `.errored`.
        public var status: SessionStatus

        public init(sessionId: String, status: SessionStatus) {
            self.sessionId = sessionId; self.status = status
        }
    }

    /// Each chat's status in the last snapshot.
    private var statuses: [String: SessionStatus] = [:]
    /// Chats whose current wait you were told about, or saw on screen.
    private var toldWaiting: Set<String> = []
    /// Chats whose turn ended with tasks still at work in the background:
    /// done once they've finished, even if no snapshot caught the turn between.
    private var doneWithheld: Set<String> = []
    /// Chats you stopped from here: their turn ending tells you nothing.
    private var stopped: Set<String> = []

    public init() {}

    /// A stop asked for from this Mac, for a turn under way.
    public mutating func stopRequested(_ sessionId: String) {
        if statuses[sessionId].map(Self.working) == true { stopped.insert(sessionId) }
    }

    /// What to post for a new snapshot. `fresh` is the first since the link
    /// (re)connected: only a wait you weren't told about notifies then.
    /// `onScreen` is the chat you're looking at, nil while Abstract is in the background.
    public mutating func next(_ snapshot: RemoteSnapshot, fresh: Bool, notifyAttention: Bool, notifyFinished: Bool,
                              onScreen: String?) -> [Notice] {
        let background = Set(snapshot.backgroundTasks ?? [])
        var notices: [Notice] = []
        func tell(_ id: String, _ status: SessionStatus) -> Bool {
            if id == onScreen { return true }
            switch status {
            case .waitingInput where !notifyAttention: return false
            case .finished where !notifyFinished: return true
            default: break
            }
            notices.append(Notice(sessionId: id, status: status))
            return true
        }
        for session in snapshot.sessions {
            let id = session.id, now = session.status, before = fresh ? nil : statuses[id]
            if now == .waitingInput {
                if before != .waitingInput, !toldWaiting.contains(id), tell(id, .waitingInput) { toldWaiting.insert(id) }
            } else {
                toldWaiting.remove(id)
            }
            if now != .idle { doneWithheld.remove(id) }
            guard !fresh else {
                if now == .idle, background.contains(id) { doneWithheld.insert(id) }
                continue
            }
            switch now {
            case .idle, .finished:
                guard before.map(Self.working) == true || doneWithheld.contains(id) else { break }
                if stopped.remove(id) != nil { doneWithheld.remove(id); break }
                if now == .idle, background.contains(id) { doneWithheld.insert(id); break }
                doneWithheld.remove(id)
                _ = tell(id, .finished)
            case .errored:
                stopped.remove(id)
                if let before, before != .errored { _ = tell(id, .errored) }
            default:
                break
            }
        }
        statuses = Dictionary(snapshot.sessions.map { ($0.id, $0.status) }, uniquingKeysWith: { $1 })
        let present = Set(statuses.keys)
        toldWaiting.formIntersection(present)
        doneWithheld.formIntersection(present)
        stopped.formIntersection(present)
        return notices
    }

    /// A turn under way: ending it is "done".
    private static func working(_ status: SessionStatus) -> Bool {
        status == .created || status == .provisioning || status == .running || status == .waitingInput
    }
}
