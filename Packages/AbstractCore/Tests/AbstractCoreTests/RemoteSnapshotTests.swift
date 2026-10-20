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
                                      pullRequests: ["chat-id": request], turnStartedAt: ["chat-id": turnStart], pagedHistory: true,
                                      execInput: true)
        let decoded = try JSONDecoder().decode(RemoteSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(decoded.pullRequests?["chat-id"] == request)
        #expect(decoded.turnStartedAt?["chat-id"] == turnStart)
        #expect(decoded.pagedHistory == true)
        #expect(decoded.execInput == true)

        let oldData = Data(#"{"projects":[],"sessions":[],"providers":[],"alive":[]}"#.utf8)
        let oldSnapshot = try JSONDecoder().decode(RemoteSnapshot.self, from: oldData)
        #expect(oldSnapshot.pullRequests == nil)
        #expect(oldSnapshot.automations == nil)
        #expect(oldSnapshot.pendingPermissions == nil)
        #expect(oldSnapshot.turnStartedAt == nil)
        #expect(oldSnapshot.pagedHistory == nil)
        #expect(oldSnapshot.execInput == nil, "an older Mac can't take input to accept a patch")
        #expect(oldSnapshot.permissionRules == nil, "an older Mac keeps no rules a phone may edit")

        let olderRequest = Data(#"{"number":42,"title":"Improve sidebar","state":"OPEN","isDraft":false}"#.utf8)
        let decodedOlderRequest = try JSONDecoder().decode(RemotePullRequest.self, from: olderRequest)
        #expect(decodedOlderRequest.checks.isEmpty)
        #expect(decodedOlderRequest.reviews.isEmpty)
        #expect(decodedOlderRequest.comments.isEmpty)
        #expect(decodedOlderRequest.threads.isEmpty)
        #expect(decodedOlderRequest.standing == nil)
    }

    @Test func permissionRulesRoundTripAndPhoneRequestsDecode() throws {
        let rule = PermissionRule(id: "r1", projectId: "p1", kind: .command, pattern: "npm test*",
                                  decision: .allow, expiresAt: Date(timeIntervalSinceReferenceDate: 900_000_000),
                                  createdAt: Date(timeIntervalSinceReferenceDate: 800_000_000))
        let snapshot = RemoteSnapshot(projects: [], sessions: [], providers: [], alive: [],
                                      permissionRules: ["p1": [rule], "p2": []])
        let decoded = try JSONDecoder().decode(RemoteSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(decoded.permissionRules?["p1"] == [rule])
        #expect(decoded.permissionRules?["p2"] == [], "a project with no rules still advertises the feature")

        // The frames the phone sends: dates as seconds since the reference date.
        let save = Data(#"{"request":{"id":7,"_1":{"savePermissionRule":{"_0":{"id":"r1","projectId":"p1","kind":"command","pattern":"npm test*","decision":"allow","expiresAt":null,"createdAt":800000000}}}}}"#.utf8)
        guard case let .request(_, .savePermissionRule(saved)) = try JSONDecoder().decode(RemoteMessage.self, from: save)
        else { Issue.record("phone savePermissionRule did not decode"); return }
        #expect(saved == PermissionRule(id: "r1", projectId: "p1", kind: .command, pattern: "npm test*",
                                        decision: .allow, createdAt: Date(timeIntervalSinceReferenceDate: 800_000_000)))

        let delete = Data(#"{"request":{"id":8,"_1":{"deletePermissionRule":{"id":"r1"}}}}"#.utf8)
        guard case let .request(_, .deletePermissionRule(id)) = try JSONDecoder().decode(RemoteMessage.self, from: delete)
        else { Issue.record("phone deletePermissionRule did not decode"); return }
        #expect(id == "r1")
    }
}
