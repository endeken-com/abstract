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

        let olderRequest = Data(#"{"number":42,"title":"Improve sidebar","state":"OPEN","isDraft":false}"#.utf8)
        let decodedOlderRequest = try JSONDecoder().decode(RemotePullRequest.self, from: olderRequest)
        #expect(decodedOlderRequest.checks.isEmpty)
        #expect(decodedOlderRequest.reviews.isEmpty)
        #expect(decodedOlderRequest.comments.isEmpty)
        #expect(decodedOlderRequest.threads.isEmpty)
        #expect(decodedOlderRequest.standing == nil)
    }

    @Test func plansRoundTripAndOlderSnapshotsDecode() throws {
        var state = PlanState()
        state.add("# First")
        state.add("# Second")
        state.requestChanges()
        let snapshot = RemoteSnapshot(projects: [], sessions: [], providers: [], alive: [],
                                      plans: ["chat-id": RemotePlan(state)], planApproval: true)
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(RemoteSnapshot.self, from: data)
        #expect(decoded.plans?["chat-id"] == RemotePlan(revisions: ["# First", "# Second"], status: "changesRequested"))
        #expect(decoded.planApproval == true)
        // The phone encodes requests as JSON objects keyed by case name.
        #expect(String(decoding: data, as: UTF8.self).contains(#""planApproval":true"#))

        let oldSnapshot = try JSONDecoder().decode(RemoteSnapshot.self,
                                                   from: Data(#"{"projects":[],"sessions":[],"providers":[],"alive":[]}"#.utf8))
        #expect(oldSnapshot.plans == nil)
        #expect(oldSnapshot.planApproval == nil, "an older Mac can't take plan decisions")

        for request in [RemoteRequest.approvePlan(sessionId: "chat-id"),
                        .requestPlanChanges(sessionId: "chat-id"),
                        .discardPlan(sessionId: "chat-id")] {
            let message = RemoteMessage.request(id: 3, request)
            guard case .request(_, let decodedRequest) = try JSONDecoder().decode(RemoteMessage.self, from: JSONEncoder().encode(message)) else {
                Issue.record("plan request did not round-trip")
                continue
            }
            #expect(String(describing: decodedRequest) == String(describing: request))
        }
        // Exactly what the phone sends for an approval.
        let phone = Data(#"{"request":{"id":3,"_1":{"approvePlan":{"sessionId":"chat-id"}}}}"#.utf8)
        guard case .request(3, .approvePlan("chat-id")) = try JSONDecoder().decode(RemoteMessage.self, from: phone) else {
            Issue.record("the phone's approvePlan did not decode")
            return
        }
    }
}
