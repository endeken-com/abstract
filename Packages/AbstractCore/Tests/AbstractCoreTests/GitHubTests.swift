import Foundation
import Testing
@testable import AbstractCore

@Suite("GitHub pull requests")
struct GitHubTests {
    private let detail = #"""
    {"number": 12, "title": "Derive chat status", "state": "OPEN", "isDraft": false,
     "url": "https://github.com/acme/app/pull/12", "headRefName": "abstract/derive-status", "baseRefName": "main",
     "author": {"login": "wes", "is_bot": false}, "reviewDecision": "CHANGES_REQUESTED",
     "mergeable": "CONFLICTING", "mergeStateStatus": "DIRTY", "additions": 10, "deletions": 2, "changedFiles": 2,
     "createdAt": "2026-09-22T21:16:26Z", "updatedAt": "2026-09-22T22:00:00Z", "body": "Rows derive status.",
     "statusCheckRollup": [
       {"__typename": "CheckRun", "name": "test", "workflowName": "CI", "status": "COMPLETED", "conclusion": "SUCCESS", "detailsUrl": "https://ci/1"},
       {"__typename": "CheckRun", "name": "lint", "workflowName": "CI", "status": "COMPLETED", "conclusion": "FAILURE", "detailsUrl": "https://ci/2"},
       {"__typename": "CheckRun", "name": "e2e", "workflowName": "CI", "status": "IN_PROGRESS", "conclusion": ""},
       {"__typename": "CheckRun", "name": "deploy", "status": "COMPLETED", "conclusion": "SKIPPED"},
       {"__typename": "StatusContext", "context": "vercel", "state": "PENDING", "targetUrl": "https://vercel/3"}
     ],
     "reviews": [{"author": {"login": "ana"}, "state": "CHANGES_REQUESTED", "body": "Keep stored status for archived chats.", "submittedAt": "2026-09-22T21:30:00Z"}],
     "comments": [
       {"author": {"login": "linear-code"}, "authorAssociation": "NONE", "body": "<p>DGDEV-1</p>", "createdAt": "2026-09-22T21:17:00Z"},
       {"author": {"login": "ana"}, "authorAssociation": "MEMBER", "body": "Looks close.", "createdAt": "2026-09-22T21:31:00Z"}
     ]}
    """#

    @Test func readsADetailedPullRequest() throws {
        let pr = try GitHub.decode(Data(detail.utf8))
        #expect(pr.number == 12)
        #expect(pr.state == .open)
        #expect(pr.head == "abstract/derive-status" && pr.base == "main")
        #expect(pr.reviewDecision == .changesRequested)
        #expect(pr.hasConflicts)
        #expect(pr.url?.absoluteString == "https://github.com/acme/app/pull/12")
        #expect(pr.reviews.first?.verdict == .changesRequested)
        #expect(pr.comments.map(\.isBot) == [true, false])
    }

    @Test func checkRunsAndCommitStatusesShareOneOutcome() throws {
        let pr = try GitHub.decode(Data(detail.utf8))
        #expect(pr.checks.map(\.outcome) == [.passed, .failed, .pending, .skipped, .pending])
        let sum = pr.checksSummary
        #expect((sum.passed, sum.failed, sum.pending, sum.skipped) == (1, 1, 2, 1))
        #expect(pr.checks.last?.name == "vercel")
    }

    @Test func checksRefreshEvenWhenPRTimestampDoesNot() throws {
        let detail = try GitHub.decode(Data(detail.utf8))
        var summary = detail
        summary.checks[2].outcome = .passed
        summary.reviews = []
        summary.comments = []
        summary.mergeable = nil
        let refreshed = detail.refreshingSummary(with: summary)
        #expect(refreshed.updatedAt == detail.updatedAt)
        #expect(refreshed.checks[2].outcome == .passed)
        #expect(refreshed.reviews == detail.reviews)
        #expect(refreshed.comments == detail.comments)
        #expect(refreshed.mergeable == detail.mergeable)
    }

    @Test func aListSkipsEntriesItCannotRead() throws {
        let list = #"[{"number": 3, "title": "A", "state": "MERGED", "headRefName": "x", "baseRefName": "main"}, {"oops": true}]"#
        let prs = try GitHub.decodeList(Data(list.utf8))
        #expect(prs.map(\.number) == [3])
        #expect(prs.first?.state == .merged)
        #expect(prs.first?.checks.isEmpty == true)
    }

    @Test func reviewThreadsKeepTheirRepliesInOrder() throws {
        let json = #"""
        {"data": {"repository": {"pullRequest": {"reviewThreads": {"nodes": [
          {"id": "T1", "isResolved": false, "isOutdated": true, "path": "app/layout.tsx", "line": null, "originalLine": 37,
           "comments": {"nodes": [
             {"id": "C1", "author": {"login": "ana", "avatarUrl": "https://avatars.githubusercontent.com/u/1"}, "body": "Blocker.", "createdAt": "2026-09-22T14:30:25Z", "diffHunk": "@@ -15,3 +15,4 @@"},
             {"id": "C2", "author": {"login": "wes", "avatarUrl": "https://avatars.githubusercontent.com/u/2"}, "body": "Fixed.", "createdAt": "2026-09-23T04:41:00Z"}
           ]}},
          {"id": "T2", "isResolved": true, "isOutdated": false, "path": "a.swift", "line": 4, "comments": {"nodes": []}}
        ]}}}}}
        """#
        let threads = try GitHub.decodeThreads(Data(json.utf8))
        #expect(threads.map(\.id) == ["T1", "T2"])
        #expect(threads[0].line == nil && threads[0].originalLine == 37 && threads[0].isOutdated)
        #expect(threads[0].comments.map(\.author) == ["ana", "wes"])
        #expect(threads[0].comments[0].avatar?.host == "avatars.githubusercontent.com")
        #expect(threads[0].diffHunk == "@@ -15,3 +15,4 @@")
        #expect(threads[1].isResolved)
    }

    @Test func publishingCommitsAndPushesTheBranch() async throws {
        let exec = LocalExecutor.shared
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("abstract-gh-\(UUID().uuidString)").path
        let remote = base + "/remote.git", work = base + "/work"
        defer { try? FileManager.default.removeItem(atPath: base) }
        try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
        func git(_ cwd: String, _ args: [String]) async throws {
            let out = try await exec.run("git", args, cwd: cwd)
            try #require(out.ok, "git \(args): \(out.stderr)")
        }
        try await git(base, ["init", "-q", "--bare", remote])
        try await git(work, ["init", "-q", "-b", "feature"])
        for (k, v) in [("user.email", "t@abstract.local"), ("user.name", "T"), ("commit.gpgsign", "false")] {
            try await git(work, ["config", k, v])
        }
        try await git(work, ["remote", "add", "origin", remote])
        try "hi\n".write(toFile: work + "/a.txt", atomically: true, encoding: .utf8)

        var state = await Git.publishState(exec, worktree: work, branch: "feature")
        #expect(state.uncommitted == 1)
        try await Git.commitAll(exec, worktree: work, message: "Add a")
        try await Git.commitAll(exec, worktree: work, message: "Nothing left")
        state = await Git.publishState(exec, worktree: work, branch: "feature")
        #expect(state.uncommitted == 0 && state.unpushed == 1)

        try await Git.push(exec, worktree: work, branch: "feature")
        try await git(work, ["fetch", "-q", "origin"])
        state = await Git.publishState(exec, worktree: work, branch: "feature")
        #expect(state.unpushed == 0)
    }
}
