import Foundation

/// Keeps a chat's explicitly selected pull request attached when its branch
/// changes, while ordinary branch matches continue following the new branch.
/// The selection is the pull request's id (repository and number, ABS-163),
/// so the same number in another repository never stands in for it.
public enum PullRequestAssociation {
    public static func retained(_ current: PullRequest?, pinned: String?) -> PullRequest? {
        guard current?.id == pinned else { return nil }
        return current
    }

    public static func candidates(_ requests: [PullRequest], branch: String?, pinned: String?) -> [PullRequest] {
        requests.filter { $0.head == branch || $0.id == pinned }
    }
}
