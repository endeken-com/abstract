import Foundation
import Testing
@testable import AbstractCore

struct RemoteSnapshotTests {
    @Test func pullRequestsRoundTripAndOlderSnapshotsDecode() throws {
        let request = RemotePullRequest(number: 42, title: "Improve sidebar", state: "OPEN",
                                        isDraft: false, url: URL(string: "https://example.com/pr/42"),
                                        standing: "1 check failing", reviewDecision: "CHANGES_REQUESTED",
                                        checks: [RemotePullRequestCheck(name: "Build", workflow: "CI", outcome: "failed", url: nil)],
                                        head: "fix/sidebar", base: "main", author: "teammate", additions: 12, deletions: 3,
                                        body: "Tightens the sidebar.",
                                        reviews: [RemotePullRequestReview(author: "reviewer", verdict: "CHANGES_REQUESTED", body: "Please adjust spacing.", submittedAt: nil)],
                                        comments: [RemotePullRequestComment(author: "reviewer", body: "Looks better.", createdAt: nil, isBot: false)],
                                        threads: [RemotePullRequestThread(id: "thread-1", path: "Sidebar.swift", line: 12,
                                                                           isResolved: false, isOutdated: false,
                                                                           comments: [RemotePullRequestComment(author: "reviewer", body: "Align this.", createdAt: nil, isBot: false)])])
        let turnStart = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let snapshot = RemoteSnapshot(projects: [], sessions: [], providers: [], alive: [],
                                      pullRequests: ["chat-id": request], turnStartedAt: ["chat-id": turnStart], pagedHistory: true)
        let decoded = try JSONDecoder().decode(RemoteSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(decoded.pullRequests?["chat-id"] == request)
        #expect(decoded.turnStartedAt?["chat-id"] == turnStart)
        #expect(decoded.pagedHistory == true)

        let oldData = Data(#"{"projects":[],"sessions":[],"providers":[],"alive":[]}"#.utf8)
        let oldSnapshot = try JSONDecoder().decode(RemoteSnapshot.self, from: oldData)
        #expect(oldSnapshot.pullRequests == nil)
        #expect(oldSnapshot.automations == nil)
        #expect(oldSnapshot.pendingPermissions == nil)
        #expect(oldSnapshot.turnStartedAt == nil)
        #expect(oldSnapshot.pagedHistory == nil)

        let olderRequest = Data(#"{"number":42,"title":"Improve sidebar","state":"OPEN","isDraft":false}"#.utf8)
        let decodedOlderRequest = try JSONDecoder().decode(RemotePullRequest.self, from: olderRequest)
        #expect(decodedOlderRequest.checks.isEmpty)
        #expect(decodedOlderRequest.reviews.isEmpty)
        #expect(decodedOlderRequest.comments.isEmpty)
        #expect(decodedOlderRequest.threads.isEmpty)
        #expect(decodedOlderRequest.standing == nil)
    }
}
