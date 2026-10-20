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

    @Test func pauseFieldsRoundTripAndOlderSnapshotsDecode() throws {
        let snapshot = RemoteSnapshot(projects: [], sessions: [], providers: [], alive: [],
                                      everythingPaused: true, pausedProjectIds: ["api", "web"], pauseControl: true)
        let decoded = try JSONDecoder().decode(RemoteSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(decoded.everythingPaused == true)
        #expect(decoded.pausedProjectIds == ["api", "web"])
        #expect(decoded.pauseControl == true)

        let oldData = Data(#"{"projects":[],"sessions":[],"providers":[],"alive":[]}"#.utf8)
        let oldSnapshot = try JSONDecoder().decode(RemoteSnapshot.self, from: oldData)
        #expect(oldSnapshot.everythingPaused == nil)
        #expect(oldSnapshot.pausedProjectIds == nil)
        #expect(oldSnapshot.pauseControl == nil, "an older Mac doesn't take pause requests")
    }

    @Test func pauseRequestsDecodeAsThePhoneSendsThem() throws {
        func request(_ json: String) throws -> RemoteRequest {
            guard case let .request(_, request) = try JSONDecoder().decode(RemoteMessage.self, from: Data(json.utf8))
            else { throw AbstractError.message("not a request") }
            return request
        }
        guard case .pauseEverything = try request(#"{"request":{"id":1,"_1":{"pauseEverything":{}}}}"#) else { Issue.record("pauseEverything"); return }
        guard case .resumeEverything = try request(#"{"request":{"id":2,"_1":{"resumeEverything":{}}}}"#) else { Issue.record("resumeEverything"); return }
        guard case .pauseProject(let paused) = try request(#"{"request":{"id":3,"_1":{"pauseProject":{"projectId":"web"}}}}"#) else { Issue.record("pauseProject"); return }
        #expect(paused == "web")
        guard case .resumeProject(let resumed) = try request(#"{"request":{"id":4,"_1":{"resumeProject":{"projectId":"web"}}}}"#) else { Issue.record("resumeProject"); return }
        #expect(resumed == "web")
    }
}
