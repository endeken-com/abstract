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

    /// `owner/name` for a GitHub remote, else nil.
    public static func githubSlug(_ remote: String) -> String? {
        guard let (host, path) = hostAndPath(remote), host.lowercased() == "github.com" else { return nil }
        let parts = path.split(separator: "/")
        return parts.count == 2 ? parts.joined(separator: "/") : nil
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

    /// A submodule URL as git resolves it against its parent's remote:
    /// each leading `../` drops the parent path's last part, so a sibling
    /// repository is `../name`. Anything that isn't relative, or whose
    /// parent names no host, is returned as it is.
    public static func resolveRelative(_ url: String, against parent: String) -> String {
        var rest = GitText.trimmed(url)
        guard rest.hasPrefix("./") || rest.hasPrefix("../") else { return url }
        let parent = GitText.trimmed(parent)
        let prefix: String, parentPath: String
        if let scheme = parent.range(of: "://"), let slash = parent[scheme.upperBound...].firstIndex(of: "/") {
            prefix = String(parent[...slash]); parentPath = String(parent[parent.index(after: slash)...])
        } else if !parent.contains("://"), let at = parent.firstIndex(of: "@"),
                  let colon = parent[at...].firstIndex(of: ":") {
            prefix = String(parent[...colon]); parentPath = String(parent[parent.index(after: colon)...])
        } else { return url }
        var parts = parentPath.split(separator: "/").map(String.init)
        while rest.hasPrefix("../") {
            guard !parts.isEmpty else { return url }
            parts.removeLast(); rest.removeFirst(3)
        }
        if rest.hasPrefix("./") { rest.removeFirst(2) }
        return prefix + (parts + [rest]).filter { !$0.isEmpty }.joined(separator: "/")
    }

    /// The remote's host, lowercased: what picks its code host (ABS-139).
    public static func host(_ remote: String) -> String? {
        hostAndPath(remote).map { $0.host.lowercased() }
    }

    /// Resolve an SSH alias before selecting a code host. Keep the original
    /// remote for git; this URL is only for code-host matching and gh.
    public static func codeHostRemote(_ remote: String, executor: any Executor) async -> String {
        let ssh = remote.lowercased().hasPrefix("ssh://") || (!remote.contains("://") && remote.contains("@"))
        guard ssh, let (alias, path) = hostAndPath(remote) else { return remote }
        let output = try? await executor.run("ssh", ["-G", alias], cwd: nil)
        let resolved = output.flatMap { $0.ok ? sshHostname($0.stdout) : nil } ?? alias
        let host = resolved.lowercased() == "ssh.github.com" ? "github.com" : resolved.lowercased()
        guard PluginManifest.isExactHost(host) else { return remote }
        return "https://\(host)/\(path)"
    }

    public static func sshHostname(_ configuration: String) -> String? {
        configuration.split(separator: "\n").first { $0.lowercased().hasPrefix("hostname ") }?
            .split(whereSeparator: \.isWhitespace).dropFirst().first.map(String.init)
    }

    /// Owner and repository without the transport or `.git` suffix.
    public static func repository(_ remote: String) -> String? { hostAndPath(remote)?.path }

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
