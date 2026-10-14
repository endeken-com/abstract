import Foundation
import Testing
@testable import AbstractCore

/// Lines of a Claude chat's log, as the engine logs them.
enum ClaudeTurnLines {
    static func user(_ text: String) -> OutputLine { OutputLine(stream: .user, line: text) }

    static func write(_ id: String, path: String) -> OutputLine {
        stdout(#"{"type":"assistant","message":{"id":"m-\#(id)","role":"assistant","content":[{"type":"tool_use","id":"\#(id)","name":"Write","input":{"file_path":"\#(path)","content":"x\n"}}]}}"#)
    }

    static func bash(_ id: String, command: String) -> OutputLine {
        stdout(#"{"type":"assistant","message":{"id":"m-\#(id)","role":"assistant","content":[{"type":"tool_use","id":"\#(id)","name":"Bash","input":{"command":"\#(command)"}}]}}"#)
    }

    static func result(_ id: String, _ output: String) -> OutputLine {
        stdout(#"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"\#(id)","content":"\#(output)","is_error":false}]}}"#)
    }

    static func reply(_ text: String) -> OutputLine {
        stdout(#"{"type":"assistant","message":{"id":"m-reply-\#(UUID().uuidString)","role":"assistant","content":[{"type":"text","text":"\#(text)"}]}}"#)
    }

    static func summary(_ text: String) -> OutputLine {
        stdout(#"{"type":"system","subtype":"post_turn_summary","status_detail":"\#(text)"}"#)
    }

    static let end = stdout(#"{"type":"result","subtype":"success","duration_ms":1000,"num_turns":1,"total_cost_usd":0.01,"usage":{"input_tokens":1,"output_tokens":1}}"#)

    static func stdout(_ line: String) -> OutputLine { OutputLine(stream: .stdout, line: line) }
}

@Suite struct TurnRecordTests {
    private func record(_ session: String = "s1", number: Int = 1, files: [String] = ["a.txt"]) -> TurnRecord {
        TurnRecord(projectId: "p1", sessionId: session, chatName: "Add a", providerId: "claude", number: number,
                   startedAt: Date(timeIntervalSince1970: 1_000), endedAt: Date(timeIntervalSince1970: 1_060),
                   request: "Add a", corrections: ["Not like that"], summary: "Added a", files: files, uncommitted: ["a.txt"],
                   headBefore: "aaa", headAfter: "bbb", branch: "feature/abs-62", pullRequest: 43, ticket: "ABS-62",
                   logStart: 1, logEnd: 9)
    }

    // MARK: Storing them

    @Test func aTurnRecordRoundTrips() throws {
        let store = try Store.inMemory()
        let turn = record()
        try store.save(turn)
        #expect(try store.turnRecord(turn.id) == turn)
        #expect(try store.turnRecords(sessionId: "s1") == [turn])
        #expect(try store.lastTurnRecord(sessionId: "s1") == turn)
        #expect(try store.turnRecords(projectId: "p1", pullRequest: 43) == [turn])
        #expect(try store.turnRecords(projectId: "p1", branch: "feature/abs-62") == [turn])
        #expect(try store.turnRecords(projectId: "other", branch: "feature/abs-62").isEmpty)
    }

    @Test func commitsAreTiedToTurnsOnceEach() throws {
        let store = try Store.inMemory()
        let one = record(number: 1), two = record(number: 2)
        try store.save(one)
        try store.save(two)
        try store.link([TurnCommit(sha: "c1", turnId: one.id, link: .turn, patchId: "p1"),
                        TurnCommit(sha: "c1", turnId: two.id, link: .commitButton),
                        TurnCommit(sha: "c1", turnId: one.id, link: .merge)])
        let found = try store.turns(commit: "c1")
        #expect(found.map(\.turn.id) == [one.id, two.id])
        #expect(found.map(\.link) == [.turn, .commitButton], "the first link a pair got stays")
        #expect(try store.turns(patchId: "p1").map(\.turn.id) == [one.id])
        #expect(try store.commits(turnId: one.id) == [TurnCommit(sha: "c1", turnId: one.id, link: .turn, patchId: "p1")])
    }

    @Test func aDeletedChatKeepsItsTurns() throws {
        let store = try Store.inMemory()
        let project = Project(id: "p1", name: "App", rootPath: "/tmp/app")
        try store.save(project)
        let chat = Session(id: "s1", projectId: "p1", name: "Add a", providerId: "claude")
        try store.save(chat)
        let turn = record()
        try store.save(turn)
        try store.link([TurnCommit(sha: "c1", turnId: turn.id, link: .turn)])
        try store.save(CodeNote(sessionId: "s1", turnId: turn.id, kind: .lineComment, path: "a.txt", line: 3, commit: "c0", body: "Why?"))
        try store.deleteSession("s1")
        try store.deleteProject("p1")
        #expect(try store.session("s1") == nil)
        #expect(try store.turnRecords(sessionId: "s1") == [turn])
        #expect(try store.turns(commit: "c1").map(\.turn.id) == [turn.id])
        #expect(try store.notes(turnId: turn.id).count == 1)
    }

    @Test func aChatsTurnsTakeItsPullRequestOnce() throws {
        let store = try Store.inMemory()
        var first = record(number: 1)
        first.pullRequest = nil
        first.ticket = nil
        var second = record(number: 2)
        second.pullRequest = 40
        try store.save(first)
        try store.save(second)
        #expect(try store.setPullRequest(43, ticket: "ABS-62", sessionId: "s1") == 1)
        #expect(try store.turnRecords(sessionId: "s1").map(\.pullRequest) == [43, 40])
        #expect(try store.turnRecords(sessionId: "s1").map(\.ticket) == ["ABS-62", "ABS-62"])
    }

    @Test func notesKeepTheirFileLineAndCommitAndJoinTheTurnTheyLedTo() throws {
        let store = try Store.inMemory()
        let line = CodeNote(sessionId: "s1", kind: .lineComment, path: "Sources/a.swift", line: 12, commit: "abc123",
                            body: "This should guard against nil", createdAt: Date(timeIntervalSince1970: 10))
        let review = CodeNote(sessionId: "s1", kind: .reviewComment, path: "Sources/b.swift", line: 4, commit: "def456",
                              body: "Rename this", author: "reviewer", createdAt: Date(timeIntervalSince1970: 20))
        try store.save(line)
        try store.save(review)
        try store.save(CodeNote(sessionId: "s2", kind: .lineComment, path: "x", line: 1, commit: nil, body: "Other chat"))
        #expect(try store.notes(sessionId: "s1") == [line, review])

        let turn = record()
        try store.save(turn)
        try store.attachPendingNotes(sessionId: "s1", to: turn.id)
        let attached = try store.notes(turnId: turn.id)
        #expect(attached.map(\.path) == ["Sources/a.swift", "Sources/b.swift"])
        #expect(attached.map(\.line) == [12, 4])
        #expect(attached.map(\.commit) == ["abc123", "def456"])
        #expect(attached.map(\.kind) == [.lineComment, .reviewComment])
        #expect(attached.last?.author == "reviewer")
        #expect(try store.notes(sessionId: "s2").first?.turnId == nil, "another chat's note waits for its own turn")
    }

    @Test func turnRecordsArriveWithTheMigration() throws {
        let store = try Store.inMemory(migratedTo: "v9-name-source", thenRunning: """
            INSERT INTO sessions (id, name, provider_id, created_at) VALUES ('s1', 'Old chat', 'claude', '2026-10-01 00:00:00.000');
            """)
        #expect(try store.session("s1")?.name == "Old chat")
        #expect(try store.turnRecords(sessionId: "s1").isEmpty)
        let turn = record()
        try store.save(turn)
        #expect(try store.lastTurnRecord(sessionId: "s1") == turn)
    }

    // MARK: Reading a turn

    @Test func aTurnReadsAsItsRequestCorrectionsSummaryAndEdits() {
        let stream = ChatStream(providerId: "claude")
        let at = Date(timeIntervalSince1970: 100)
        var lines = [ClaudeTurnLines.user("Add a"), ClaudeTurnLines.write("t1", path: "/repo/a.txt"),
                     ClaudeTurnLines.user("Also b, please"), ClaudeTurnLines.write("t2", path: "/repo/b.txt"),
                     ClaudeTurnLines.reply("Added a and b."), ClaudeTurnLines.summary("Added a and b to the repo"),
                     ClaudeTurnLines.end]
        for i in lines.indices { lines[i].at = at.addingTimeInterval(Double(i)) }
        let turn = TurnTranscript(stream.replay(lines).entries)
        #expect(turn.request == "Add a")
        #expect(turn.corrections == ["Also b, please"])
        #expect(turn.summary == "Added a and b to the repo")
        #expect(turn.editedPaths == ["/repo/a.txt", "/repo/b.txt"])
        #expect(turn.startedAt == at)
        #expect(turn.endedAt == at.addingTimeInterval(6))
        #expect(turn.worked)
    }

    @Test func withoutASummaryTheLastReplyIsCutShort() {
        let stream = ChatStream(providerId: "claude")
        let reply = (1...10).map { "Line \($0)" }.joined(separator: "\\n")
        let turn = TurnTranscript(stream.replay([ClaudeTurnLines.user("Explain"), ClaudeTurnLines.reply(reply), ClaudeTurnLines.end]).entries)
        #expect(turn.summary == "Line 1\nLine 2\nLine 3\nLine 4…")
    }

    @Test func aStoppedTurnHasNoSummaryFromItsRule() {
        let turn = TurnTranscript([TimelineEntry(id: 1, event: .text(role: .user, text: "Go", blockId: nil, partial: false)),
                                   TimelineEntry(id: 2, event: TurnStop.rule)])
        #expect(turn.summary == nil)
    }

    @Test func pathsAreKeptRelativeToTheWorktree() {
        #expect(TurnTranscript.relative("/wt/a/b.swift", to: "/wt") == "a/b.swift")
        #expect(TurnTranscript.relative("/wt/a/b.swift", to: "/wt/") == "a/b.swift")
        #expect(TurnTranscript.relative("/other/b.swift", to: "/wt") == nil)
        #expect(TurnTranscript.relative("/wt2/b.swift", to: "/wt") == nil)
        #expect(TurnTranscript.relative("c.swift", to: "/wt") == "c.swift")
    }

    @Test func aTicketComesFromWhatThePullRequestFixesElseTheBranch() {
        #expect(TurnRecorder.ticket(pullRequestBody: "Why…\n\nFixes ABS-62", branch: "feature/other") == "ABS-62")
        #expect(TurnRecorder.ticket(pullRequestBody: "closes abs-7", branch: nil) == "ABS-7")
        #expect(TurnRecorder.ticket(pullRequestBody: "No ticket", branch: "feature/abs-62") == "ABS-62")
        #expect(TurnRecorder.ticket(pullRequestBody: nil, branch: "auto/roadmap-build-the-next-ticket/2026-10-14-1400") == nil)
        #expect(TurnRecorder.ticket(pullRequestBody: nil, branch: "fix-utf-8-names") == nil)
    }

    // MARK: Reading git

    @Test func statusPathsIncludeBothNamesOfARename() {
        let porcelain = " M a.txt\0R  new name.txt\0old.txt\0?? dir/u.txt\0 D gone.txt\0"
        #expect(TurnGit.changedPaths(porcelain) == ["a.txt", "new name.txt", "old.txt", "dir/u.txt", "gone.txt"])
    }

    @Test func aStateTellsWhichFilesChangedBetweenTwoMoments() {
        let before = TurnGit.State(head: "a", dirty: ["kept.txt": "1", "edited.txt": "1", "committed.txt": "1"])
        let after = TurnGit.State(head: "b", dirty: ["kept.txt": "1", "edited.txt": "2", "new.txt": "3"])
        #expect(after.changed(since: before) == ["edited.txt", "committed.txt", "new.txt"])
    }

    @Test func blameRunsAreGroupedByCommit() {
        let a = String(repeating: "a", count: 40), b = String(repeating: "b", count: 40)
        let porcelain = """
            \(a) 1 10 2
            author One
            \tline ten
            \(a) 2 11
            \tline eleven
            \(b) 5 12 1
            author Two
            \tline twelve
            \(a) 3 13 1
            \tline thirteen
            """
        let runs = TurnHistory.blameRanges(porcelain)
        #expect(runs.map(\.0) == [10...11, 12...12, 13...13])
        #expect(runs.map(\.1) == [a, b, a])
    }

    @Test func aMergeOrSquashNamesItsPullRequest() {
        #expect(TurnHistory.pullRequest(subject: "Merge pull request #55 from endeken-com/feature/restructure-test-suites", parents: 2)?.number == 55)
        #expect(TurnHistory.pullRequest(subject: "Merge pull request #55 from endeken-com/feature/restructure-test-suites", parents: 2)?.branch
                == "feature/restructure-test-suites")
        #expect(TurnHistory.pullRequest(subject: "Name chats for their work (#43)", parents: 1)?.number == 43)
        #expect(TurnHistory.pullRequest(subject: "Name chats for their work (#43)", parents: 1)?.branch == nil)
        #expect(TurnHistory.pullRequest(subject: "Fix #43 properly", parents: 1) == nil)
    }

    // MARK: Old logs

    @Test func anOldLogSplitsIntoTurnsWithTheCommitsAndPullRequestItPrinted() {
        let lines = [ClaudeTurnLines.user("Add a"), ClaudeTurnLines.write("t1", path: "a.txt"),
                     ClaudeTurnLines.bash("t2", command: "git commit -am 'Add a'"),
                     ClaudeTurnLines.result("t2", "[feature/a 1a2b3c4] Add a\\n 1 file changed"),
                     ClaudeTurnLines.user("Not that way"),
                     ClaudeTurnLines.end,
                     ClaudeTurnLines.user("Open the pull request"),
                     ClaudeTurnLines.bash("t3", command: "gh pr create --title Add"),
                     ClaudeTurnLines.result("t3", "https://github.com/owner/repo/pull/43"),
                     ClaudeTurnLines.end]
        let turns = HistoryBackfill.turns(lines.enumerated().map { ($0.offset + 1, $0.element) }, providerId: "claude")
        #expect(turns.count == 2)
        #expect(turns.map(\.lines) == [1...6, 7...10])
        #expect(turns.first?.transcript.request == "Add a")
        #expect(turns.first?.transcript.corrections == ["Not that way"])
        #expect(turns.first?.commits == ["1a2b3c4"])
        #expect(turns.last?.pullRequest == 43)
    }
}
