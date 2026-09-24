import Foundation
import Testing
@testable import AbstractCore

struct RemoteSnapshotTests {
    @Test func pullRequestsRoundTripAndOlderSnapshotsDecode() throws {
        let request = RemotePullRequest(number: 42, title: "Improve sidebar", state: "OPEN",
                                        isDraft: false, url: URL(string: "https://example.com/pr/42"))
        let snapshot = RemoteSnapshot(projects: [], sessions: [], providers: [], alive: [],
                                      pullRequests: ["chat-id": request])
        let decoded = try JSONDecoder().decode(RemoteSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(decoded.pullRequests?["chat-id"] == request)

        let oldData = Data(#"{"projects":[],"sessions":[],"providers":[],"alive":[]}"#.utf8)
        let oldSnapshot = try JSONDecoder().decode(RemoteSnapshot.self, from: oldData)
        #expect(oldSnapshot.pullRequests == nil)
    }
}
