import Foundation
import Testing
@testable import AbstractCore

@Suite struct AskAuthorTests {
    private func turn(number: Int = 3, session: String = "s1", chat: String = "Fix the diff",
                      files: [String] = ["Abstract/Features/Diff/DiffView.swift"],
                      startedAt: Date? = Date(timeIntervalSince1970: 2_000)) -> TurnRecord {
        TurnRecord(projectId: "p1", sessionId: session, chatName: chat, providerId: "claude", number: number,
                   startedAt: startedAt, endedAt: Date(timeIntervalSince1970: 2_060),
                   request: "Fix it", summary: "Fixed it", files: files, pullRequest: 43)
    }

    private func origin(turns: [TurnRecord], sha: String = "0123456789abcdef0123456789abcdef01234567") -> CommitOrigin {
        CommitOrigin(sha: sha, author: "Ana", subject: "Fix the diff (#43)", turns: turns, link: .turn, pullRequest: 43)
    }

    // MARK: The reply-box quote

    @Test func theQuoteNamesTheFileLinesCommitAndTurn() {
        let quote = AskAuthor.quote(path: "Abstract/Features/Diff/DiffView.swift", lines: 120...121,
                                    code: ["let a = 1", "let b = 2"],
                                    commit: "0123456789abcdef", turn: turn())
        #expect(quote == """
        About Abstract/Features/Diff/DiffView.swift lines 120–121 (commit 0123456) — you wrote this in turn 3:

        ```
        let a = 1
        let b = 2
        ```


        """)
    }

    @Test func theQuoteForOneLineSaysLineAndNeedsNoCommit() {
        let quote = AskAuthor.quote(path: "a.swift", lines: 7...7, code: ["x"], commit: nil, turn: turn(number: 1))
        #expect(quote.hasPrefix("About a.swift line 7 — you wrote this in turn 1:"))
    }

    // MARK: Who is asked

    @Test func theChatThatWroteTheLinesIsAsked() {
        let written = turn()
        #expect(AskAuthor.target(turns: [written], archived: false, worktreeExists: true)
            == .originalChat(turn: written, archived: false, canEdit: true))
        #expect(AskAuthor.target(turns: [written], archived: false, worktreeExists: true).menuTitle
            == "Ask the chat that wrote this…")
    }

    @Test func anArchivedChatIsStillAskedAndBroughtBack() {
        let written = turn()
        #expect(AskAuthor.target(turns: [written], archived: true, worktreeExists: true)
            == .originalChat(turn: written, archived: true, canEdit: true))
    }

    @Test func aGoneWorktreeStillAnswersQuestions() {
        let written = turn()
        #expect(AskAuthor.target(turns: [written], archived: false, worktreeExists: false)
            == .originalChat(turn: written, archived: false, canEdit: false))
    }

    @Test func aDeletedChatOrNoChatMeansANewOne() {
        #expect(AskAuthor.target(turns: [turn()], archived: nil, worktreeExists: false) == .newChat)
        #expect(AskAuthor.target(turns: [], archived: nil, worktreeExists: false) == .newChat)
        #expect(AskAuthor.Target.newChat.menuTitle == "Ask a new chat about this…")
    }

    @Test func theLastTurnThatTouchedTheLinesIsAsked() {
        let first = turn(number: 1), last = turn(number: 5)
        #expect(AskAuthor.target(turns: [first, last], archived: false, worktreeExists: true)
            == .originalChat(turn: last, archived: false, canEdit: true))
    }

    // MARK: A new chat's first message

    @Test func aNewChatGetsTheHistoryABS62Found() {
        let deleted = turn()
        let message = AskAuthor.newChatMessage(path: "a.swift", lines: 3...3, code: ["x"],
                                               origin: origin(turns: [deleted]), deletedTurn: deleted)
        #expect(message.contains("Commit 0123456 by Ana"))
        #expect(message.contains("pull request #43"))
        #expect(message.contains("“Fix the diff”, turn 3, which has been deleted"))
    }

    @Test func aNewChatIsToldWhenNothingIsKnown() {
        let message = AskAuthor.newChatMessage(path: "a.swift", lines: 3...3, code: ["x"], origin: nil, deletedTurn: nil)
        #expect(message.contains("No chat in Abstract wrote these lines"))
    }

    // MARK: Review headers

    @Test func fileHeadersListEachChatThatChangedTheFile() {
        let one = turn(number: 3, session: "s1", chat: "Fix the diff")
        let two = turn(number: 2, session: "s2", chat: "Rename the pane")
        let other = turn(number: 1, session: "s3", chat: "Elsewhere", files: ["other.swift"])
        let byFile = AskAuthor.fileTurns(origins: [origin(turns: [one, other]), origin(turns: [two, one], sha: "aaaaaaaabbbbbbbbccccccccddddddddeeeeeeee")])
        #expect(byFile["Abstract/Features/Diff/DiffView.swift"] == [one, two])
        #expect(byFile["other.swift"] == [other])
        #expect(byFile["never.swift"] == nil)
        #expect(AskAuthor.changedIn([one, two]) == ["Changed in Fix the diff, turn 3", "Changed in Rename the pane, turn 2"])
    }

    // MARK: Turn lines and merges

    @Test func aTurnLineFindsItsRecordByItsStartThenByItsPlace() {
        let start = Date(timeIntervalSince1970: 2_000)
        let one = turn(number: 1, startedAt: Date(timeIntervalSince1970: 1_000))
        let two = turn(number: 2, startedAt: start)
        #expect(AskAuthor.record(startedAt: start, ordinal: 0, in: [one, two], turnCount: 9) == two)
        #expect(AskAuthor.record(startedAt: nil, ordinal: 0, in: [one, two], turnCount: 2) == one)
        #expect(AskAuthor.record(startedAt: nil, ordinal: 0, in: [one, two], turnCount: 3) == nil)
    }

    @Test func aMergedPullRequestSaysWhereItMerged() {
        #expect(AskAuthor.mergedLine(pullRequest(state: .merged)) == "Merged into main in #43")
        #expect(AskAuthor.mergedLine(pullRequest(state: .open)) == nil)
        #expect(AskAuthor.mergedLine(nil) == nil)
    }

    private func pullRequest(state: PullRequest.State) -> PullRequest {
        PullRequest(number: 43, title: "Fix the diff", state: state, isDraft: false, url: nil, head: "fix", base: "main",
                    author: nil, reviewDecision: nil, mergeable: nil, mergeState: nil, additions: nil, deletions: nil,
                    changedFiles: nil, createdAt: nil, updatedAt: nil, body: nil, mergeCommit: nil,
                    checks: [], reviews: [], comments: [])
    }
}

extension GitHeavy {
    /// From a real repository, through ABS-62's blame lookup, to who is
    /// asked and what Review's header for the file says.
    @Suite("Asking about lines, end to end", .serialized)
    struct AskAuthorLookupTests {
        @Test func blameLeadsToTheChatAndTheHeader() async throws {
            let exec = LocalExecutor.shared
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ask-\(UUID().uuidString)").path
            defer { try? FileManager.default.removeItem(atPath: dir) }
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            func git(_ args: [String]) async throws -> String {
                let out = try await exec.run("git", args, cwd: dir)
                try #require(out.ok, "git \(args) failed: \(out.stderr)")
                return out.stdout
            }
            _ = try await git(["init", "-q", "-b", "main"])
            _ = try await git(["config", "user.email", "test@abstract.local"])
            _ = try await git(["config", "user.name", "Ana"])
            try "one\ntwo\nthree\n".write(toFile: dir + "/code.swift", atomically: true, encoding: .utf8)
            _ = try await git(["add", "-A"])
            _ = try await git(["commit", "-qm", "Add code"])
            let sha = GitText.trimmed(try await git(["rev-parse", "HEAD"]))

            let store = try Store.inMemory()
            let written = TurnRecord(projectId: "p1", sessionId: "s1", chatName: "Add code", providerId: "claude",
                                     number: 2, files: ["code.swift"])
            try store.save(written)
            try store.link([TurnCommit(sha: sha, turnId: written.id, link: .turn)])

            let history = TurnHistory(store: store, projectId: "p1")
            let origins = try await history.blame("code.swift", lines: 2...2, exec: exec, repo: dir)
            #expect(origins.first?.turns == [written])
            #expect(AskAuthor.target(turns: origins.flatMap(\.turns), archived: true, worktreeExists: true)
                == .originalChat(turn: written, archived: true, canEdit: true))

            // Review's header, from the same lookup's commit origin.
            let origin = try #require(await history.origin(of: sha, exec: exec, repo: dir))
            #expect(AskAuthor.changedIn(AskAuthor.fileTurns(origins: [origin])["code.swift"] ?? [])
                == ["Changed in Add code, turn 2"])

            // A line of a commit nobody made in a chat asks a new chat.
            try "one\ntwo\nthree\nfour\n".write(toFile: dir + "/code.swift", atomically: true, encoding: .utf8)
            _ = try await git(["commit", "-qam", "By hand"])
            let byHand = try await history.blame("code.swift", lines: 4...4, exec: exec, repo: dir)
            #expect(byHand.first?.commit?.author == "Ana")
            #expect(byHand.flatMap(\.turns).isEmpty)
            #expect(AskAuthor.target(turns: byHand.flatMap(\.turns), archived: nil, worktreeExists: true) == .newChat)
        }
    }
}
