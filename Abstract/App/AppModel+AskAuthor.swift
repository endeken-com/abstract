import Foundation
import AbstractCore

/// Lines already looked up for asking about, so a line's menu can name
/// who would be asked before it is clicked.
struct AskAuthorKey: Hashable {
    let repo: String
    let path: String
    let lines: ClosedRange<Int>
    let revision: String?
}

/// Asking about some lines of code: looking up the chat that wrote them
/// (ABS-62's `TurnHistory`), opening it with the lines quoted in its reply
/// box, or starting a new chat whose first message carries the history.
/// Sending from the opened chat resumes its agent session, as any
/// follow-up does.
extension AppModel {
    func turnHistory(projectId: String?) -> TurnHistory {
        let key = projectId ?? ""
        if let history = turnHistories[key] { return history }
        let history = TurnHistory(store: store, projectId: projectId)
        turnHistories[key] = history
        return history
    }

    /// Who wrote `key`'s lines, and the blame behind the answer. The
    /// target is remembered, so the line's menu can name it next time.
    func resolveAsk(_ key: AskAuthorKey, projectId: String?, exec: any Executor) async -> (AskAuthor.Target, [LineOrigin]) {
        let origins = (try? await turnHistory(projectId: projectId)
            .blame(key.path, lines: key.lines, revision: key.revision, exec: exec, repo: key.repo)) ?? []
        let turns = origins.flatMap(\.turns)
        var archived: Bool?
        var worktreeExists = false
        if let last = turns.last, let chat = session(last.sessionId) {
            archived = chat.archivedAt != nil
            worktreeExists = chat.worktreePath.map { FileManager.default.fileExists(atPath: $0) } ?? false
        }
        let target = AskAuthor.target(turns: turns, archived: archived, worktreeExists: worktreeExists)
        askTargets[key] = target
        return (target, origins)
    }

    /// Look a line up ahead of its menu opening, so the menu can say
    /// whether the chat that wrote it would be asked, or a new one.
    func prepareAsk(_ key: AskAuthorKey, projectId: String?, exec: any Executor) {
        guard askTargets[key] == nil, askInFlight.insert(key).inserted else { return }
        Task {
            // A line only passed over on the way somewhere else isn't looked up.
            try? await Task.sleep(for: .milliseconds(300))
            _ = await resolveAsk(key, projectId: projectId, exec: exec)
            askInFlight.remove(key)
        }
    }

    /// Ask about `key`'s lines: open the chat that wrote them (unarchived
    /// first) with the lines quoted in its reply box, or open New Chat
    /// with the history in its prompt.
    func askAbout(_ key: AskAuthorKey, code: [String], projectId: String?, exec: any Executor) async {
        let (target, origins) = await resolveAsk(key, projectId: projectId, exec: exec)
        switch target {
        case let .originalChat(turn, archived, canEdit):
            if archived { setArchived(turn.sessionId, false) }
            pendingDrafts[turn.sessionId] = AskAuthor.quote(
                path: key.path, lines: key.lines, code: code,
                commit: origins.last?.commit?.sha, turn: turn)
            composerNotices[turn.sessionId] = canEdit ? nil
                : "This chat's worktree is gone, so it can answer questions but can't edit files there."
            open(turn.sessionId)
        case .newChat:
            let turns = origins.flatMap(\.turns)
            newChatPrompt = AskAuthor.newChatMessage(
                path: key.path, lines: key.lines, code: code,
                origin: origins.last?.commit ?? origins.first?.commit,
                deletedTurn: turns.last.flatMap { session($0.sessionId) == nil ? $0 : nil })
            showNewChat(in: projectId)
        }
    }

    /// The origins of a review's commits, for its file headers.
    func commitOrigins(_ shas: [String], projectId: String?, exec: any Executor, repo: String) async -> [CommitOrigin] {
        let history = turnHistory(projectId: projectId)
        var out: [CommitOrigin] = []
        for sha in shas {
            if let origin = await history.origin(of: sha, exec: exec, repo: repo) { out.append(origin) }
        }
        return out
    }

    /// Fill in each turn line's commits for a chat, from its turn records.
    /// Merge and squash commits belong to every turn, so they are left
    /// out; the chat says where it merged separately.
    func loadTurnCommits(_ sessionId: String) {
        let records = (try? store.turnRecords(sessionId: sessionId)) ?? []
        let turns = feed(sessionId).timeline.blocks.compactMap { block -> (Int, TurnInfo)? in
            if case let .turn(id, info) = block { (id, info) } else { nil }
        }
        var byBlock: [Int: [String]] = [:]
        for (ordinal, (id, info)) in turns.enumerated() {
            guard let record = AskAuthor.record(startedAt: info.startedAt, ordinal: ordinal,
                                                in: records, turnCount: turns.count) else { continue }
            let shas = ((try? store.commits(turnId: record.id)) ?? [])
                .filter { $0.link == .turn || $0.link == .commitButton || $0.link == .patch }
                .map(\.sha)
            if !shas.isEmpty { byBlock[id] = shas }
        }
        if turnCommits[sessionId] != byBlock { turnCommits[sessionId] = byBlock.isEmpty ? nil : byBlock }
    }

    /// Open the chat a turn belongs to, brought back first if archived.
    func openTurn(_ turn: TurnRecord) {
        guard session(turn.sessionId) != nil else { return }
        if session(turn.sessionId)?.archivedAt != nil { setArchived(turn.sessionId, false) }
        open(turn.sessionId)
    }

    /// A turn's commit, in the chat's Changes.
    func openCommitInReview(_ sha: String, in sessionId: String) {
        openDiffTab(in: sessionId)
        guard case .ready(let context) = diffAvailability(sessionId) else { return }
        let review = ReviewStore.shared.review(sessionId)
        let summary = CommitSummary(sha: sha, shortSha: AskAuthor.short(sha), author: "", date: nil, subject: "")
        Task { await review.show(.commit(summary), context) }
    }
}
