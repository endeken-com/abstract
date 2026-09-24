import Foundation

/// What a project's `origin` says about where it lives.
public enum GitRemote {
    /// The page a remote opens in a browser: https URLs as they are (minus
    /// `.git` and any credentials), and `git@host:owner/repo.git` or
    /// `ssh://git@host/owner/repo` rewritten to https. nil for anything
    /// else (a local path, a `file://` URL).
    public static func webURL(_ remote: String) -> URL? {
        guard let (host, path) = hostAndPath(remote) else { return nil }
        return URL(string: "https://\(host)/\(path)")
    }

    /// `owner` for a GitHub remote, else nil.
    public static func githubOwner(_ remote: String) -> String? {
        guard let (host, path) = hostAndPath(remote), host.lowercased() == "github.com" else { return nil }
        let owner = path.split(separator: "/").first.map(String.init) ?? ""
        return owner.isEmpty ? nil : owner
    }

    /// The owner's avatar GitHub serves at a fixed size.
    public static func githubAvatarURL(owner: String, size: Int = 96) -> URL? {
        URL(string: "https://github.com/\(owner).png?size=\(size)")
    }

    /// Whether two remotes name the same repository, however each is spelled
    /// (ssh or https, with or without `.git`, any case in the host).
    public static func sameRepository(_ a: String, _ b: String) -> Bool {
        if let x = hostAndPath(a), let y = hostAndPath(b) {
            return x.host.lowercased() == y.host.lowercased() && x.path.lowercased() == y.path.lowercased()
        }
        return GitText.trimmed(a) == GitText.trimmed(b)
    }

    /// Host and `owner/repo` path, without `.git` or trailing slashes.
    private static func hostAndPath(_ remote: String) -> (host: String, path: String)? {
        let text = GitText.trimmed(remote)
        var host: String
        var path: String
        if let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["http", "https", "ssh", "git"].contains(scheme),
           let h = url.host, !h.isEmpty {
            host = h
            path = url.path
        } else if !text.contains("://"), let at = text.firstIndex(of: "@"), let colon = text[at...].firstIndex(of: ":") {
            // scp-like: git@github.com:owner/repo.git
            host = String(text[text.index(after: at)..<colon])
            path = String(text[text.index(after: colon)...])
        } else {
            return nil
        }
        path = String(path.drop(while: { $0 == "/" }))
        while path.hasSuffix("/") { path.removeLast() }
        if path.hasSuffix(".git") { path.removeLast(4) }
        guard !host.isEmpty, !path.isEmpty, !host.contains(" ") else { return nil }
        return (host, path)
    }
}

/// Cone-mode sparse checkout folders, as a project lists them.
public enum SparseCheckout {
    /// One folder per line: trimmed, `./` and surrounding slashes dropped,
    /// blanks, comments (`#`) and duplicates skipped, order kept.
    public static func normalize(_ lines: [String]) -> [String] {
        var seen = Set<String>()
        return lines.compactMap { raw -> String? in
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { return nil }
            while line.hasPrefix("./") { line.removeFirst(2) }
            line = String(line.drop(while: { $0 == "/" }))
            while line.hasSuffix("/") { line.removeLast() }
            if line.isEmpty || line == "." { return nil }
            return seen.insert(line).inserted ? line : nil
        }
    }

    public static func parse(_ text: String) -> [String] {
        normalize(text.components(separatedBy: .newlines))
    }
}

public extension Git {
    /// `git remote get-url origin`, or nil when there is no origin.
    static func originURL(_ exec: any Executor, root: String) async -> String? {
        guard let out = try? await git(exec, cwd: root, ["remote", "get-url", "origin"]), out.ok else { return nil }
        let url = GitText.trimmed(out.stdout)
        return url.isEmpty ? nil : url
    }

    /// The history's first commits: the same set means the same repository,
    /// wherever its folder now is.
    static func rootCommits(_ exec: any Executor, root: String) async -> Set<String> {
        guard let out = try? await git(exec, cwd: root, ["rev-list", "--max-parents=0", "HEAD"]), out.ok else { return [] }
        return Set(GitText.lines(out.stdout).map(GitText.trimmed).filter { !$0.isEmpty })
    }

    /// After the main repository moved: point its linked worktrees back at it
    /// and it at them. Best effort.
    static func repairWorktrees(_ exec: any Executor, root: String, paths: [String]) async {
        _ = try? await git(exec, cwd: root, ["worktree", "repair"] + paths)
    }
}
