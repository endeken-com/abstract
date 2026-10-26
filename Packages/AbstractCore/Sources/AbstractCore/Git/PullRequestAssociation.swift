import Foundation

/// Keeps a chat's explicitly selected pull request attached when its branch
/// changes, while ordinary branch matches continue following the new branch.
public enum PullRequestAssociation {
    public static func retained(_ current: PullRequest?, pinnedNumber: Int?) -> PullRequest? {
        guard current?.number == pinnedNumber else { return nil }
        return current
    }

    public static func candidates(_ requests: [PullRequest], branch: String?, pinnedNumber: Int?) -> [PullRequest] {
        requests.filter { $0.head == branch || $0.number == pinnedNumber }
    }
}
