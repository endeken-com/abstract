import Foundation

/// A plugin installed from a git repository (ABS-190): a GitHub repository,
/// or any git URL, a folder in it, the ref asked for and the commit the
/// install is pinned to. The source syntax follows Paseo's plugin sources
/// (Apache-2.0, see THIRD_PARTY_NOTICES.md).
public struct PluginGitSource: Sendable, Hashable, Codable {
    /// The GitHub owner; for another host, the folder above the repository.
    public var owner: String
    public var repo: String
    /// The plugin's folder inside the repository; nil is its root.
    public var path: String?
    /// The branch, tag or commit asked for; nil follows the default branch.
    public var ref: String?
    /// The exact commit installed. Nil only before it's resolved.
    public var commit: String?
    /// The git URL of a repository not on GitHub; nil on GitHub.
    public var url: String?
    /// The reviewed registry listing (`owner/slug`) it was installed from:
    /// it follows that listing's approved commit, never the branch.
    public var listing: String?

    public init(owner: String, repo: String, path: String? = nil, ref: String? = nil,
                commit: String? = nil, url: String? = nil, listing: String? = nil) {
        self.owner = owner; self.repo = repo; self.path = path; self.ref = ref
        self.commit = commit; self.url = url; self.listing = listing
    }

    public var isGitHub: Bool { url == nil }

    /// Where git fetches it from. `githubBase` stands in for GitHub in tests.
    public func remote(githubBase: String = PluginGitSource.githubBase) -> String {
        url ?? "\(githubBase)\(owner)/\(repo).git"
    }

    public static let githubBase = "https://github.com/"

    /// `owner/repo/path`, as typed, without the ref.
    public var repository: String {
        let base = url ?? "\(owner)/\(repo)"
        return path.map { url == nil ? "\(base)/\($0)" : "\(base):\($0)" } ?? base
    }

    /// The first seven characters of the commit, as git shows it.
    public var shortCommit: String? { commit.map { String($0.prefix(7)) } }

    /// The page to look at it on, for a GitHub repository.
    public var webURL: URL? {
        guard isGitHub else { return nil }
        var text = "https://github.com/\(owner)/\(repo)"
        if let commit { text += "/tree/\(commit)" + (path.map { "/\($0)" } ?? "") }
        return URL(string: text)
    }

    /// Reads what's typed in the gallery's "Add from GitHub…" field or after
    /// `abstract plugin add`:
    ///
    ///     owner/repo                      a GitHub repository
    ///     owner/repo/path/to/plugin       a folder in a monorepo
    ///     owner/repo@v1.2                 at a branch, tag or commit
    ///     https://github.com/owner/repo[/tree/<ref>/<path>]
    ///     github:owner/repo  git:owner/repo
    ///     git:https://host/acme/mono.git:plugins/x   another host, `:path` for a folder
    ///     git@host:acme/review.git  ssh://…  file://…
    ///
    /// `ref`, when given, wins over an `@ref` suffix.
    public static func parse(_ text: String, ref explicitRef: String? = nil) throws -> PluginGitSource {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw PluginSourceError.empty }
        guard !body.contains(where: { $0.isWhitespace }) else { throw PluginSourceError.unreadable(body) }
        if [".", "..", "/", "~"].contains(where: { body == $0 || body.hasPrefix($0 + "/") })
            || body.hasPrefix("./") || body.hasPrefix("../") {
            throw PluginSourceError.localFolder
        }
        var githubOnly = false
        if body.hasPrefix("github:") { body.removeFirst(7); githubOnly = true }
        else if body.hasPrefix("git:"), !body.hasPrefix("git://") { body.removeFirst(4) }

        var ref: String?
        (body, ref) = splitRef(body)
        if let explicitRef = explicitRef?.trimmingCharacters(in: .whitespacesAndNewlines), !explicitRef.isEmpty {
            ref = explicitRef
        }
        if let ref, !isValidRef(ref) { throw PluginSourceError.invalidRef(ref) }

        let lower = body.lowercased()
        for prefix in ["https://github.com/", "http://github.com/", "https://www.github.com/", "github.com/", "www.github.com/"]
            where lower.hasPrefix(prefix) {
            if prefix.hasPrefix("http://") { throw PluginSourceError.insecure }
            return try gitHubURL(String(body.dropFirst(prefix.count)), ref: ref)
        }
        if body.contains("://") || isSCP(body) {
            guard !githubOnly else { throw PluginSourceError.unreadable(text) }
            return try gitURL(body, ref: ref)
        }
        return try shorthand(body, ref: ref, original: text)
    }

    // MARK: Parsing

    /// `…@ref` in the last path segment, after any `user@` or `host:`.
    private static func splitRef(_ body: String) -> (String, String?) {
        guard let at = body.lastIndex(of: "@") else { return (body, nil) }
        if let slash = body.lastIndex(of: "/"), slash > at { return (body, nil) }
        if let colon = body.lastIndex(of: ":"), colon > at { return (body, nil) }
        // Before a ref there's always a repository path; otherwise the @ is a user's.
        guard body[..<at].contains("/") else { return (body, nil) }
        let ref = String(body[body.index(after: at)...])
        return (String(body[..<at]), ref.isEmpty ? nil : ref)
    }

    /// `user@host:path`, git's scp-like syntax.
    private static func isSCP(_ body: String) -> Bool {
        guard !body.contains("://"), let colon = body.firstIndex(of: ":"),
              let at = body.firstIndex(of: "@"), at < colon else { return false }
        let host = body[body.index(after: at)..<colon]
        return !host.isEmpty && !host.contains("/")
    }

    static func isValidRef(_ ref: String) -> Bool {
        guard !ref.isEmpty, ref.count <= 200, !ref.hasPrefix("-"), !ref.hasPrefix("/"), !ref.hasSuffix("/"),
              !ref.contains(".."), !ref.contains("//"), !ref.hasSuffix(".lock") else { return false }
        return ref.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-/+".contains($0)) }
    }

    public static func isCommit(_ ref: String) -> Bool {
        ref.count == 40 && ref.allSatisfy(\.isHexDigit)
    }

    private static func isOwner(_ text: Substring) -> Bool {
        !text.isEmpty && text.count <= 39 && !text.hasPrefix("-")
            && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    private static func isRepo(_ text: Substring) -> Bool {
        !text.isEmpty && text.count <= 100 && text != "." && text != ".."
            && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }
    }

    /// A folder inside the repository: no empty, `.` or `..` segments.
    private static func cleanPath<S: Collection>(_ segments: S) throws -> String? where S.Element == Substring {
        let parts = segments.filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        guard parts.allSatisfy({ $0 != "." && $0 != ".." && !$0.contains("\\") && !$0.contains(":") }) else {
            throw PluginSourceError.invalidPath(parts.joined(separator: "/"))
        }
        return parts.joined(separator: "/")
    }

    private static func shorthand(_ body: String, ref: String?, original: String) throws -> PluginGitSource {
        let segments = body.split(separator: "/", omittingEmptySubsequences: false)
        guard segments.count >= 2, isOwner(segments[0]) else { throw PluginSourceError.unreadable(original) }
        var repo = segments[1]
        if repo.hasSuffix(".git") { repo = repo.dropLast(4) }
        guard isRepo(repo) else { throw PluginSourceError.unreadable(original) }
        return PluginGitSource(owner: String(segments[0]), repo: String(repo),
                               path: try cleanPath(segments.dropFirst(2)), ref: ref)
    }

    /// `owner/repo[.git][/tree/<ref>/<path>]` after `github.com/`.
    private static func gitHubURL(_ rest: String, ref: String?) throws -> PluginGitSource {
        let trimmed = rest.split(separator: "?").first.map(String.init) ?? rest
        let segments = trimmed.split(separator: "/", omittingEmptySubsequences: true)
        guard segments.count >= 2, isOwner(segments[0]) else { throw PluginSourceError.unreadable("github.com/" + rest) }
        var repo = segments[1]
        if repo.hasSuffix(".git") { repo = repo.dropLast(4) }
        guard isRepo(repo) else { throw PluginSourceError.unreadable("github.com/" + rest) }
        var source = PluginGitSource(owner: String(segments[0]), repo: String(repo), ref: ref)
        if segments.count > 2 {
            // A folder's page: /tree/<ref>/<path>. A file's page isn't a plugin.
            guard segments[2] == "tree", segments.count >= 4 else { throw PluginSourceError.unreadable("github.com/" + rest) }
            let pageRef = String(segments[3])
            guard isValidRef(pageRef) else { throw PluginSourceError.invalidRef(pageRef) }
            source.ref = ref ?? pageRef
            source.path = try cleanPath(segments.dropFirst(4))
        }
        return source
    }

    /// Any other git URL, with an optional `:path/in/repo` after it.
    private static func gitURL(_ body: String, ref: String?) throws -> PluginGitSource {
        var url = body
        var path: String?
        if let colon = body.lastIndex(of: ":") {
            let before = String(body[..<colon])
            let after = String(body[body.index(after: colon)...])
            let beforeIsWhole = before.contains("://")
                ? before.components(separatedBy: "://").last?.contains("/") == true
                : isSCP(before)
            if beforeIsWhole, !after.isEmpty, !after.hasPrefix("/") {
                url = before
                path = try cleanPath(after.split(separator: "/", omittingEmptySubsequences: false))
            }
        }
        let lower = url.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("git://") { throw PluginSourceError.insecure }
        guard lower.hasPrefix("https://") || lower.hasPrefix("ssh://") || lower.hasPrefix("file://") || isSCP(url) else {
            throw PluginSourceError.unreadable(body)
        }
        // On GitHub after all (ssh): keep it as owner/repo so updates and links work.
        let tail = url.split(separator: "/").suffix(2)
        let pieces = Array(tail)
        var repo = pieces.last.map(String.init) ?? ""
        if repo.hasSuffix(".git") { repo.removeLast(4) }
        var owner = pieces.count == 2 ? String(pieces[0]) : ""
        if let colon = owner.lastIndex(of: ":") { owner = String(owner[owner.index(after: colon)...]) }
        if pieces.count == 1, let colon = repo.lastIndex(of: ":") { repo = String(repo[repo.index(after: colon)...]) }
        guard isRepo(Substring(repo)) else { throw PluginSourceError.unreadable(body) }
        let onGitHub = lower.hasPrefix("git@github.com:") || lower.hasPrefix("ssh://git@github.com/")
        return PluginGitSource(owner: owner, repo: repo, path: path, ref: ref,
                               url: onGitHub && isOwner(Substring(owner)) ? nil : url)
    }
}

public enum PluginSourceError: Error, LocalizedError, Sendable, Equatable {
    case empty
    case unreadable(String)
    case localFolder
    case insecure
    case invalidRef(String)
    case invalidPath(String)

    public var errorDescription: String? {
        switch self {
        case .empty: "Type a GitHub repository, like owner/repo."
        case .unreadable(let text): "“\(text)” isn't a repository Abstract can read. Use owner/repo, owner/repo/folder, a GitHub link or a git URL."
        case .localFolder: "That's a folder on this Mac. Use Install from folder or zip… instead."
        case .insecure: "Abstract only installs plugins over a secure connection: use an https:// or ssh address."
        case .invalidRef(let ref): "“\(ref)” isn't a branch, tag or commit name."
        case .invalidPath(let path): "“\(path)” isn't a folder inside the repository."
        }
    }
}
