import Testing
@testable import AbstractCore

@Suite("Pull request standing")
struct PullRequestStandingTests {
    private func request(state: PullRequest.State = .open, draft: Bool = false) -> PullRequest {
        PullRequest(number: 42, title: "Update navigation", state: state, isDraft: draft, url: nil,
                    head: "feature/navigation", base: "main", author: nil, reviewDecision: nil,
                    mergeable: nil, mergeState: nil, additions: nil, deletions: nil, changedFiles: nil,
                    createdAt: nil, updatedAt: nil, body: nil, mergeCommit: nil,
                    checks: [], reviews: [], comments: [])
    }

    @Test func failedChecksAndRequestedChangesBothRemainVisible() {
        var pr = request()
        pr.mergeable = "CONFLICTING"
        pr.checks = [.init(name: "Build", workflow: nil, outcome: .failed, url: nil)]
        pr.reviewDecision = .changesRequested
        #expect(pr.standingDetails.map(\.kind) == [.conflicts, .failedChecks, .changesRequested])
        #expect(pr.standingDetails.map(\.title) == ["Conflicts with main", "1 check failing", "Changes requested"])
    }

    @Test func runningChecksAndApprovalAreSeparate() {
        var pr = request(draft: true)
        pr.checks = [.init(name: "Build", workflow: nil, outcome: .pending, url: nil)]
        pr.reviewDecision = .approved
        #expect(pr.standingDetails.map(\.kind) == [.runningChecks, .approved])
    }

    @Test func completedChecksAndWaitingForReviewAreSeparate() {
        var pr = request()
        pr.checks = [.init(name: "Build", workflow: nil, outcome: .passed, url: nil)]
        pr.reviewDecision = .reviewRequired
        #expect(pr.standingDetails.map(\.title) == ["Checks passed", "Waiting for review"])
    }

    @Test func closedAndMergedRequestsDoNotShowStaleStanding() {
        for state in [PullRequest.State.closed, .merged] {
            var pr = request(state: state)
            pr.checks = [.init(name: "Build", workflow: nil, outcome: .failed, url: nil)]
            pr.reviewDecision = .changesRequested
            #expect(pr.standingDetails.isEmpty)
        }
    }
}
