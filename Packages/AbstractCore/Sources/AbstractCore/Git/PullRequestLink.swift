import Foundation

/// Which repository a pull request belongs to, from its link (ABS-207). An
/// agent that opens one in a submodule reports the submodule's link, and
/// the same number in the project's own repository is another pull
/// request: a number alone never says which.
public enum PullRequestLink {
    /// A pull request's page: its host, its repository's path there, and its number.
    public struct Page: Sendable, Hashable {
        public var host: String
        public var repository: String
        public var number: Int

        public init(host: String, repository: String, number: Int) {
            self.host = host; self.repository = repository; self.number = number
        }

        /// The repository's web address: an outside pull request's `repoPath`.
        public var repositoryURL: String { "https://\(host)/\(repository)" }
    }

    /// Where a pull request is: one of the project's repositories, by path
    /// ("" its own), or the web address of one outside it; and the name its
    /// label shows.
    public struct Place: Sendable, Hashable {
        public var repoPath: String
        public var repoName: String?

        public init(repoPath: String, repoName: String?) { self.repoPath = repoPath; self.repoName = repoName }
    }

    /// The page `url` opens: GitHub's `/owner/repo/pull/n`, GitLab's
    /// `/group/repo/-/merge_requests/n`, Bitbucket Cloud's
    /// `/workspace/repo/pull-requests/n` and Bitbucket Server's
    /// `/projects/KEY/repos/repo/pull-requests/n`. Nil for anything else.
    public static func page(_ url: URL) -> Page? {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 4, let number = Int(parts[parts.count - 1]) else { return nil }
        var repo = Array(parts.dropLast(2))
        switch parts[parts.count - 2] {
        case "pull", "pull-requests": break
        case "merge_requests": if repo.last == "-" { repo.removeLast() }
        default: return nil
        }
        // Bitbucket Server spells the repository as its clone URLs do: KEY/repo.
        if let projects = repo.lastIndex(of: "projects"), repo.count == projects + 4, repo[projects + 2] == "repos" {
            repo = [repo[projects + 1], repo[projects + 3]]
        }
        guard repo.count >= 2 else { return nil }
        return Page(host: host, repository: repo.joined(separator: "/"), number: number)
    }

    /// The project's repository `page` is in: the one whose origin, or the
    /// URL its parent's `.gitmodules` registers, is that repository on that
    /// host; failing that (an SSH alias for the host), the only one with
    /// that repository's path. Nil when none is.
    public static func repo(for page: Page, in repos: [ProjectRepo]) -> ProjectRepo? {
        let wanted = page.repository.lowercased()
        let keyed = repos.map { repo in (repo, [repo.remote, repo.registered].compactMap(key)) }
        if let exact = keyed.first(where: { $0.1.contains { $0.host == page.host && $0.path == wanted } }) { return exact.0 }
        let byPath = keyed.filter { $0.1.contains { $0.path == wanted } }
        return byPath.count == 1 ? byPath[0].0 : nil
    }

    /// Where the pull request at `url` is, among the project's `repos`:
    /// in one of them, or outside the project, never the project's own by
    /// default. Nil when `url` isn't a pull request's page.
    public static func place(_ url: URL, in repos: [ProjectRepo]) -> Place? {
        guard let page = page(url) else { return nil }
        if let repo = repo(for: page, in: repos) { return Place(repoPath: repo.path, repoName: repo.name) }
        return Place(repoPath: page.repositoryURL, repoName: page.repository)
    }

    /// Whether `repoPath` is an outside repository's web address rather
    /// than a path in the project.
    public static func isExternal(_ repoPath: String) -> Bool { repoPath.contains("://") }

    /// A pull request held as one repository's whose own link names another
    /// (one pinned by number alone, `#n`, before ABS-207): where it really
    /// is. Nil when it's where it says, its link says nothing, or the
    /// project's repositories aren't known yet.
    public static func misplaced(_ pr: PullRequest, in repos: [ProjectRepo]) -> Place? {
        guard !repos.isEmpty, let url = pr.url, let page = page(url), page.number == pr.number,
              let place = place(url, in: repos), place.repoPath != pr.repoPath else { return nil }
        return place
    }

    /// Host and path of a remote, lowercased, as a pull request's page
    /// spells them: Bitbucket Server's `scm/` dropped.
    private static func key(_ remote: String?) -> (host: String, path: String)? {
        guard let remote, let host = GitRemote.host(remote), let path = GitRemote.repository(remote) else { return nil }
        var parts = path.lowercased().split(separator: "/").map(String.init)
        if let scm = parts.lastIndex(of: "scm"), parts.count == scm + 3 { parts.removeFirst(scm + 1) }
        return (host, parts.joined(separator: "/"))
    }
}
