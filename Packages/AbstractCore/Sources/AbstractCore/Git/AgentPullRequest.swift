import Foundation

/// A pull request a chat's agent reports opening (ABS-207): kept in the
/// repository it is in, a submodule's say, never the project's own by its
/// number alone, which there is another pull request.
public enum AgentPullRequest {
    /// Where pull request `number` is: the repository its link names, or
    /// outside the project when it names none of them. With no link, the
    /// first repository, in `order`, whose pull request on `branch` is
    /// `number`; failing that, the project's own, as before.
    public static func place(number: Int, url: URL?, branch: String?, repos: [ProjectRepo], ahead: Set<String>,
                             host: @Sendable (ProjectRepo) async -> CodeHost?) async -> PullRequestLink.Place {
        if let url, let place = PullRequestLink.place(url, in: repos) { return place }
        if let branch {
            for repo in order(repos, ahead: ahead) {
                guard let host = await host(repo), let found = try? await host.pullRequest(branch: branch),
                      found.number == number else { continue }
                return PullRequestLink.Place(repoPath: repo.path, repoName: repo.name)
            }
        }
        return PullRequestLink.Place(repoPath: "", repoName: repos.first(where: \.isMain)?.name)
    }

    /// The order a branch is asked of the repositories in: those the chat
    /// has commits in ahead of their base (`ahead`, by path), then the
    /// project's own, then the rest.
    public static func order(_ repos: [ProjectRepo], ahead: Set<String>) -> [ProjectRepo] {
        let first = repos.filter { !$0.isMain && ahead.contains($0.path) }
        return first + repos.filter(\.isMain) + repos.filter { !$0.isMain && !ahead.contains($0.path) }
    }

    /// What the chat holds until its code host is read: number, link and
    /// branches, in its repository.
    public static func placeholder(number: Int, url: URL?, head: String, base: String, place: PullRequestLink.Place) -> PullRequest {
        var pr = PullRequest(number: number, title: "", state: .open, isDraft: false, url: url, head: head, base: base,
                             checks: [], reviews: [], comments: [])
        pr.repoPath = place.repoPath
        pr.repoName = place.repoName
        return pr
    }
}

public extension ProjectRepos {
    /// The repository whose code host a pull request held as `repoPath`'s
    /// is read from: one of `repos`, or, for a web address, that outside
    /// repository. A path no longer listed (or not yet read) is the
    /// project's own, as before.
    static func repo(forPullRequest repoPath: String, in repos: [ProjectRepo]) -> ProjectRepo? {
        if PullRequestLink.isExternal(repoPath) { return ProjectRepo(path: repoPath, remote: repoPath) }
        return repos.first { $0.path == repoPath } ?? repos.first(where: \.isMain)
    }
}
