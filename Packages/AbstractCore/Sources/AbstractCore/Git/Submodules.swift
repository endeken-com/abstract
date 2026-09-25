import Foundation

/// One repository a chat's worktree holds: the worktree's own, or a
/// submodule checked out inside it, at any depth.
public struct ChatRepo: Sendable, Hashable, Identifiable {
    /// Relative to the worktree; empty for the worktree's own repository.
    public var path: String
    /// 0 for the worktree's own, 1 for its submodules, 2 for theirs.
    public var depth: Int
    /// The repository this one is a submodule of; nil for the worktree's own.
    public var parentPath: String?
    /// What's checked out; nil when HEAD is detached.
    public var branch: String?
    /// `owner/name` when origin is on GitHub.
    public var github: String?

    public var id: String { path }
    public var isSubmodule: Bool { !path.isEmpty }

    public init(path: String, depth: Int = 0, parentPath: String? = nil, branch: String? = nil, github: String? = nil) {
        self.path = path; self.depth = depth; self.parentPath = parentPath; self.branch = branch; self.github = github
    }

    /// Its folder, given the worktree's (or the project checkout's) path.
    public func directory(in worktree: String) -> String {
        path.isEmpty ? worktree : GitText.trimTrailingSlashes(worktree) + "/" + path
    }

    /// `other`, a path relative to the worktree, as this repository sees it;
    /// nil when it's somewhere else.
    public func inside(_ other: String) -> String? {
        if path.isEmpty { return other }
        return GitText.hasPrefix(other, path + "/") ? GitText.dropPrefix(other, path + "/") : nil
    }
}

/// The repositories in a chat's worktree, read with git alone so it works the
/// same for a worktree on another Mac.
public enum Submodules {
    /// The worktree's own repository, then every checked-out submodule in the
    /// order git visits them (each before its own submodules). Ones that
    /// aren't checked out aren't listed.
    public static func list(_ exec: any Executor, worktree: String) async -> [ChatRepo] {
        let branch = (try? await Git.currentBranch(exec, root: worktree)) ?? nil
        let top = ChatRepo(path: "", branch: branch, github: await Git.originURL(exec, root: worktree).flatMap(GitRemote.githubSlug))
        guard let out = try? await Git.git(exec, cwd: worktree, ["submodule", "foreach", "--quiet", "--recursive", listing]),
              out.ok else { return [top] }
        return [top] + parse(out.stdout)
    }

    /// Run in each submodule: its path from the worktree, branch and origin, tab-separated.
    static let listing = #"printf '%s\t%s\t%s\n' "$displaypath" "$(git symbolic-ref --quiet --short HEAD)" "$(git remote get-url origin 2>/dev/null)""#

    static func parse(_ output: String) -> [ChatRepo] {
        var repos: [ChatRepo] = []
        for line in GitText.lines(output) {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 3, !fields[0].isEmpty else { continue }
            // git lists a submodule's parent before it, so the nearest listed
            // repository containing it is its parent.
            let parent = repos.last { $0.inside(fields[0]) != nil }
            repos.append(ChatRepo(path: fields[0], depth: (parent?.depth ?? 0) + 1, parentPath: parent?.path ?? "",
                                  branch: fields[1].isEmpty ? nil : fields[1], github: GitRemote.githubSlug(fields[2])))
        }
        return repos
    }

    /// The submodule paths `.gitmodules` registers in `root`, checked out or not.
    public static func registered(_ exec: any Executor, root: String) async -> [String] {
        guard let out = try? await Git.git(exec, cwd: root, ["config", "-z", "-f", ".gitmodules", "--get-regexp", #"^submodule\..*\.path$"#]),
              out.ok else { return [] }
        // With -z each entry is "key\nvalue\0"; a name may hold spaces, so no splitting on them.
        return out.stdout.split(separator: "\0").compactMap { entry in
            entry.split(separator: "\n", maxSplits: 1).dropFirst().first.map(String.init)
        }
    }

    /// Every path the worktree's status lists, a submodule's own path when
    /// anything in it (or in one inside it) changed; nil when git can't say.
    /// The review reads a submodule only when it's here.
    static func changedPaths(_ exec: any Executor, worktree: String) async -> Set<String>? {
        // A submodule's own status.showUntrackedFiles=no would hide one whose
        // only change is a new file; -c reaches the status git runs inside it.
        guard let out = try? await Git.git(exec, cwd: worktree, ["-c", "status.showUntrackedFiles=normal", "--no-optional-locks", "status",
                                                                 "--porcelain=v1", "-z", "--ignore-submodules=none"]),
              out.ok else { return nil }
        var paths: Set<String> = []
        var entries = out.stdout.split(separator: "\0").map(String.init)[...]
        while let entry = entries.popFirst(), entry.utf8.count > 3 {
            // "XY path", by bytes so a path starting with a combining mark stays whole.
            paths.insert(String(decoding: entry.utf8.dropFirst(3), as: UTF8.self))
            // A rename's entry is followed by its old path.
            let code = entry.utf8.prefix(2)
            if code.contains(UInt8(ascii: "R")) || code.contains(UInt8(ascii: "C")), let old = entries.popFirst() { paths.insert(old) }
        }
        return paths
    }

    /// Whether `directory` is the top of a repository of its own (a
    /// submodule that's checked out) rather than a folder of its parent's.
    public static func isCheckedOut(_ exec: any Executor, directory: String) async -> Bool {
        guard let out = try? await Git.git(exec, cwd: directory, ["rev-parse", "--show-prefix"]), out.ok else { return false }
        return GitText.trimmed(out.stdout).isEmpty
    }

    /// Where each repository stood when the chat's branch left `base`: the
    /// worktree's own at its merge base with `base` (key ""), each submodule
    /// at the commit its parent recorded for it there. A submodule with no
    /// entry didn't exist yet. Empty without a base.
    public static func baselines(_ exec: any Executor, worktree: String, repos: [ChatRepo], base: String?) async -> [String: String] {
        guard let base else { return [:] }
        let top = await Diff.mergeBase(exec, worktree: worktree, base: base) ?? base
        var found = ["": top]
        // Parents first, so each submodule finds its parent's baseline.
        for repo in repos.sorted(by: { $0.depth < $1.depth }) where repo.isSubmodule {
            guard let parentPath = repo.parentPath, let parent = repos.first(where: { $0.path == parentPath }),
                  let from = found[parentPath], let inside = parent.inside(repo.path),
                  let out = try? await Git.git(exec, cwd: parent.directory(in: worktree), ["rev-parse", "\(from):\(inside)"]),
                  out.ok else { continue }
            let sha = GitText.trimmed(out.stdout)
            if !sha.isEmpty { found[repo.path] = sha }
        }
        return found
    }
}
