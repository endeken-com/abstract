import Foundation

/// One repository whose pull requests a project shows: its own, a declared
/// nested repository, or a git submodule (ABS-163).
public struct ProjectRepo: Sendable, Hashable, Identifiable {
    /// Relative to the project's root; empty for the project's own repository.
    public var path: String
    /// Its `origin`; nil when it has none (or isn't checked out and
    /// `.gitmodules` names none).
    public var remote: String?

    public var id: String { path }
    public var isMain: Bool { path.isEmpty }

    /// What a pull request from it is labelled with: its repository's
    /// name, else its folder's.
    public var name: String? { ProjectRepos.name(path: path, remote: remote) }

    public init(path: String, remote: String? = nil) {
        self.path = path; self.remote = remote
    }

    /// Its folder, given the project root's path.
    public func directory(in root: String) -> String {
        path.isEmpty ? root : GitText.trimTrailingSlashes(root) + "/" + path
    }
}

/// The repositories a project's pull requests come from, and how pull
/// requests from several of them order and match. Discovery is host-side:
/// each repository is asked of the code-host plugin that handles its own
/// `origin`, so a repository whose host isn't signed in simply yields none.
public enum ProjectRepos {
    /// At most this many repositories are ever asked for one project (the
    /// nested-repo probe that fills project settings stops there too).
    public static let limit = 50

    /// The project's repositories: its own first, then its declared nested
    /// repositories, then its submodules, each once, with the `origin` git
    /// reports for it. A repository that is both nested and a submodule
    /// appears once; so does one whose remote repeats an earlier one's.
    public static func list(_ exec: any Executor, project: Project) async -> [ProjectRepo] {
        let root = project.rootPath
        async let checkedOut = Submodules.list(exec, worktree: root)
        async let registered = submoduleURLs(exec, root: root)
        let (repos, urls) = await (checkedOut, registered)
        let submodulePaths = repos.filter(\.isSubmodule).map(\.path) + urls.map(\.path)
        let mainRemote = await Git.originURL(exec, root: root)
        var found: [(path: String, remote: String)] = []
        for path in paths(nested: project.nestedRepos, submodules: submodulePaths) {
            let remote: String?
            if path.isEmpty {
                remote = mainRemote
            } else {
                let origin = await Git.originURL(exec, root: ProjectRepo(path: path).directory(in: root))
                if let origin, GitRemote.host(origin) != nil {
                    remote = origin
                } else if let url = urls.first(where: { $0.path == path })?.url {
                    // Not checked out (or cloned from a local path): what
                    // `.gitmodules` registers, resolved as git resolves it.
                    let resolved = mainRemote.map { GitRemote.resolveRelative(url, against: $0) } ?? url
                    remote = GitRemote.host(resolved) != nil ? resolved : origin
                } else {
                    remote = origin
                }
            }
            if let remote { found.append((path, remote)) }
            else if path.isEmpty { found.append((path, "")) }
        }
        return dedupeByRemote(found)
            .map { ProjectRepo(path: $0.path, remote: $0.remote.isEmpty ? nil : $0.remote) }
    }

    /// `""` (the project's own), then `nested`, then `submodules`:
    /// trimmed, `./`- and slash-free at the edges, blanks and repeats out.
    public static func paths(nested: [String], submodules: [String]) -> [String] {
        var seen: Set<String> = [""]
        var result = [""]
        for raw in nested + submodules {
            guard result.count < limit, let path = normalize(raw), seen.insert(path).inserted else { continue }
            result.append(path)
        }
        return result
    }

    /// One path as `paths` keeps it; nil when it names the root itself.
    static func normalize(_ raw: String) -> String? {
        var path = raw.trimmingCharacters(in: .whitespaces)
        while path.hasPrefix("./") { path.removeFirst(2) }
        path = String(path.drop(while: { $0 == "/" }))
        while path.hasSuffix("/") { path.removeLast() }
        return path.isEmpty || path == "." ? nil : path
    }

    /// The first path for each remote, however the remote is spelled.
    public static func dedupeByRemote(_ repos: [(path: String, remote: String)]) -> [(path: String, remote: String)] {
        var kept: [(path: String, remote: String)] = []
        for repo in repos where !kept.contains(where: { $0.remote == repo.remote || GitRemote.sameRepository($0.remote, repo.remote) }) {
            kept.append(repo)
        }
        return kept
    }

    /// A repository's name: the last part of its remote's path, else its
    /// folder's name. Nil for the project's own with no remote.
    public static func name(path: String, remote: String?) -> String? {
        if let remote, let repository = GitRemote.repository(remote) {
            return repository.split(separator: "/").last.map(String.init)
        }
        if let remote, !remote.isEmpty {
            var last = remote.split(separator: "/").last.map(String.init) ?? ""
            if last.hasSuffix(".git") { last.removeLast(4) }
            if !last.isEmpty { return last }
        }
        return path.isEmpty ? nil : path.split(separator: "/").last.map(String.init)
    }

    /// Pull requests to read: a nested repository's or submodule's first
    /// (the deeper, the earlier — it merges before the pointer that holds
    /// it can), the main repository's last. One repository's own order,
    /// as its host reported it, stands.
    public static func ordered(_ prs: [PullRequest]) -> [PullRequest] {
        prs.enumerated().sorted { a, b in
            let (x, y) = (rank(a.element.repoPath), rank(b.element.repoPath))
            return x != y ? x < y : a.offset < b.offset
        }.map(\.element)
    }

    /// The main repository last; among the rest, deeper paths first, then
    /// by path so the order doesn't depend on which host answered first.
    private static func rank(_ path: String) -> (Int, Int, String) {
        path.isEmpty ? (1, 0, "") : (0, -path.split(separator: "/").count, path)
    }

    /// The pull requests on `branch`, each in its own repository: the same
    /// branch name in two repositories matches both.
    public static func matching(branch: String, in prs: [PullRequest]) -> [PullRequest] {
        ordered(prs.filter { $0.head == branch })
    }

    /// Each pull request once, by repository and number: the same number
    /// in two repositories is two pull requests.
    public static func deduped(_ prs: [PullRequest]) -> [PullRequest] {
        var seen = Set<String>()
        return prs.filter { seen.insert($0.id).inserted }
    }

    /// Every submodule `.gitmodules` registers in `root`, with the URL it
    /// registers, checked out or not. Paths are from `root`; a submodule
    /// inside a submodule isn't registered here and isn't listed.
    static func submoduleURLs(_ exec: any Executor, root: String) async -> [(path: String, url: String?)] {
        guard let out = try? await Git.git(exec, cwd: root,
                                           ["config", "-z", "-f", ".gitmodules", "--get-regexp", #"^submodule\..*\.(path|url)$"#]),
              out.ok else { return [] }
        var byName: [String: (path: String?, url: String?)] = [:]
        var order: [String] = []
        for entry in out.stdout.split(separator: "\0") {
            // With -z each entry is "key\nvalue"; a name may hold dots, so
            // the kind is the key's last part.
            let parts = entry.split(separator: "\n", maxSplits: 1).map(String.init)
            guard parts.count == 2, let dot = parts[0].lastIndex(of: ".") else { continue }
            let name = String(parts[0][..<dot]), kind = String(parts[0][parts[0].index(after: dot)...])
            if byName[name] == nil { order.append(name) }
            if kind == "path" { byName[name, default: (nil, nil)].path = parts[1] }
            if kind == "url" { byName[name, default: (nil, nil)].url = parts[1] }
        }
        return order.compactMap { name in byName[name]?.path.map { (path: $0, url: byName[name]?.url ?? nil) } }
    }
}
