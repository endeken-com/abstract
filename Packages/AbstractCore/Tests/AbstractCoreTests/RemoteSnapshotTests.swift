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

    @Test func stallsRoundTripAndOlderSnapshotsDecode() throws {
        let since = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let snapshot = RemoteSnapshot(projects: [], sessions: [], providers: [], alive: [],
                                      stalls: ["chat-id": RemoteStall(state: "stalled", since: since)])
        let decoded = try JSONDecoder().decode(RemoteSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(decoded.stalls?["chat-id"] == RemoteStall(state: "stalled", since: since))

        let oldData = Data(#"{"projects":[],"sessions":[],"providers":[],"alive":[]}"#.utf8)
        #expect(try JSONDecoder().decode(RemoteSnapshot.self, from: oldData).stalls == nil)

        #expect(RemoteStall(.working) == nil)
        #expect(RemoteStall(.quiet(since: since)) == RemoteStall(state: "quiet", since: since))
        #expect(RemoteStall(.stalled(since: since)) == RemoteStall(state: "stalled", since: since))
    }

    @Test func codeHistoryRequestsRoundTripAndOlderSnapshotsLackTheFlag() throws {
        let ask = RemoteMessage.request(id: 7, .askAuthor(root: "/repo", path: "Sources/A.swift", lineStart: 3, lineEnd: 5,
                                                          code: ["a", "b", "c"], revision: "HEAD", sessionId: "chat-1"))
        let decodedAsk = try JSONDecoder().decode(RemoteMessage.self, from: JSONEncoder().encode(ask))
        guard case let .request(id, .askAuthor(root, path, first, last, code, revision, session)) = decodedAsk else {
            Issue.record("askAuthor did not round-trip"); return
        }
        #expect(id == 7)
        #expect(root == "/repo" && path == "Sources/A.swift" && first == 3 && last == 5)
        #expect(code == ["a", "b", "c"] && revision == "HEAD" && session == "chat-1")

        let answer = RemoteMessage.response(id: 7, .askAuthor(RemoteAskAuthor(sessionId: "chat-1", projectId: "p1", draft: "About A.swift…", notice: nil)))
        let decodedAnswer = try JSONDecoder().decode(RemoteMessage.self, from: JSONEncoder().encode(answer))
        guard case let .response(_, .askAuthor(reply)) = decodedAnswer else { Issue.record("askAuthor reply did not round-trip"); return }
        #expect(reply.sessionId == "chat-1" && reply.projectId == "p1" && reply.draft == "About A.swift…" && reply.notice == nil)

        let setting = RemoteMessage.request(id: 8, .setAgentHistory(projectId: "p1", enabled: false))
        let decodedSetting = try JSONDecoder().decode(RemoteMessage.self, from: JSONEncoder().encode(setting))
        guard case let .request(_, .setAgentHistory(projectId, enabled)) = decodedSetting else {
            Issue.record("setAgentHistory did not round-trip"); return
        }
        #expect(projectId == "p1" && enabled == false)

        let snapshot = RemoteSnapshot(projects: [], sessions: [], providers: [], alive: [], codeHistory: true)
        let decoded = try JSONDecoder().decode(RemoteSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(decoded.codeHistory == true)
        let oldSnapshot = try JSONDecoder().decode(RemoteSnapshot.self, from: Data(#"{"projects":[],"sessions":[],"providers":[],"alive":[]}"#.utf8))
        #expect(oldSnapshot.codeHistory == nil, "an older Mac never advertises code-history requests")
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
