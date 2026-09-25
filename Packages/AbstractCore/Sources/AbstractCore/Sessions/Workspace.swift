import Foundation

public enum WorkspaceError: Error, LocalizedError, Equatable {
    /// An exact branch was asked for and git already has it.
    case branchExists(String)

    public var errorDescription: String? {
        switch self {
        case .branchExists(let branch): "The branch “\(branch)” already exists."
        }
    }
}

/// Creates the isolated place a chat's agent works in.
public enum Workspace {
    public struct Provisioned: Sendable {
        public var path: String
        public var branch: String
    }

    /// Pick a free worktree path and branch from the templates, then create
    /// the worktree. Suffixes `-1`, `-2`… until both are unused. `slug` names
    /// the branch and may hold a type folder (`fix/login-button`). When given,
    /// `worktreeName` independently supplies the folder's `{slug}` token.
    /// The project's sparse-checkout folders apply.
    ///
    /// `exactBranch` is created exactly as given, with no prefix and never
    /// suffixed: only the folder moves aside. It must not exist yet
    /// (`WorkspaceError.branchExists`).
    public static func provision(
        executor: any Executor,
        project: Project,
        name: String,
        baseRef: String?,
        template: String,
        prefix: String,
        slug: String? = nil,
        worktreeName: String? = nil,
        exactBranch: String? = nil
    ) async throws -> Provisioned {
        let repo = URL(fileURLWithPath: project.rootPath).lastPathComponent
        let hash = WorktreeNaming.shortHash(project.rootPath)
        let baseSlug = slug.flatMap { WorktreeNaming.branchSlug($0) } ?? WorktreeNaming.slugify(name)
        let baseFolderSlug = worktreeName.map { WorktreeNaming.slugify($0) }
            ?? baseSlug.replacingOccurrences(of: "/", with: "-")
        let base = (baseRef?.isEmpty == false ? baseRef : nil) ?? project.defaultBaseRef

        if let exactBranch, await Git.branchExists(executor, root: project.rootPath, branch: "refs/heads/\(exactBranch)") {
            throw WorkspaceError.branchExists(exactBranch)
        }
        for attempt in 0..<50 {
            let branchSlug = attempt == 0 ? baseSlug : "\(baseSlug)-\(attempt)"
            let folderSlug = attempt == 0 ? baseFolderSlug : "\(baseFolderSlug)-\(attempt)"
            let branch = exactBranch ?? "\(prefix)\(branchSlug)"
            let path = WorktreeNaming.render(
                template: template, home: executor.homeDirectory, repo: repo, hash: hash,
                slug: folderSlug, branch: branch, prefix: exactBranch == nil ? prefix : ""
            )
            if executor.fileExists(path) { continue }
            if exactBranch == nil, await Git.branchExists(executor, root: project.rootPath, branch: branch) { continue }
            do {
                try await Git.addWorktree(executor, root: project.rootPath, path: path, branch: branch, baseRef: base,
                                          sparse: project.sparseCheckout, attachExisting: exactBranch == nil)
            } catch where exactBranch != nil {
                // Someone else made the branch since the check above.
                if await Git.branchExists(executor, root: project.rootPath, branch: "refs/heads/\(branch)") {
                    throw WorkspaceError.branchExists(branch)
                }
                throw error
            }
            return Provisioned(path: path, branch: branch)
        }
        throw AbstractError.message("Could not find a free worktree path or branch name for “\(name)”.")
    }

    /// Where a new worktree starts.
    public struct Base: Sendable, Equatable {
        /// What `git worktree add` starts from, e.g. `origin/main`.
        public var ref: String
        /// Why `origin` couldn't be asked, when it couldn't; the base is then
        /// the newest copy already here.
        public var fetchError: String?

        public init(ref: String, fetchError: String? = nil) { self.ref = ref; self.fetchError = fetchError }
    }

    /// The base branch as `origin` has it now: fetched, then its `origin/`
    /// copy, unless the local branch already holds all of that and more
    /// (commits not pushed yet). When the fetch fails (offline, say), the
    /// newer of the two copies already here. A base that isn't a branch
    /// (`HEAD`, a tag, a commit), or a repository without `origin`, is used
    /// as given.
    public static func freshBase(executor: any Executor, root: String, base: String) async -> Base {
        let explicitRemote = base.hasPrefix("origin/")
        let name = explicitRemote ? String(base.dropFirst("origin/".count)) : base
        guard !name.isEmpty, name != "HEAD", await Git.hasOrigin(executor, root: root) else { return Base(ref: base) }
        let local = "refs/heads/\(name)", remote = "refs/remotes/origin/\(name)"
        let hasLocal = await Git.branchExists(executor, root: root, branch: local)
        let hadRemote = await Git.branchExists(executor, root: root, branch: remote)
        guard explicitRemote || hasLocal || hadRemote else { return Base(ref: base) }
        var fetchError: String?
        do {
            try await Fetches.shared.fetch(root: root, branch: name) {
                try await Git.fetch(executor, root: root, branch: name)
            }
        } catch {
            fetchError = error.localizedDescription
        }
        guard await Git.branchExists(executor, root: root, branch: remote) else { return Base(ref: base, fetchError: fetchError) }
        // Unpushed work on the local branch: it has everything origin has.
        if !explicitRemote, hasLocal {
            let holdsRemote = await Git.isAncestor(executor, root: root, remote, of: local)
            let behindRemote = await Git.isAncestor(executor, root: root, local, of: remote)
            if holdsRemote, !behindRemote { return Base(ref: name, fetchError: fetchError) }
        }
        return Base(ref: "origin/\(name)", fetchError: fetchError)
    }

    /// A new standalone chat's own folder (it belongs to no project), named
    /// for a city none of the others has, under `standaloneRoot`.
    public static func standaloneFolder(home: String) throws -> String {
        let root = standaloneRoot(home: home)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let used = Set((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
        let dir = root.appendingPathComponent(WorktreeNaming.slugify(WorktreeNaming.cityName(avoiding: used)), isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        return dir.path
    }

    /// `~/.abstract/chats`, beside the worktrees; the data directory's own
    /// when one is set (demo, tests).
    public static func standaloneRoot(home: String) -> URL {
        if let dir = ProcessInfo.processInfo.environment["ABSTRACT_DATA_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath).appendingPathComponent("chats", isDirectory: true)
        }
        return URL(fileURLWithPath: home).appendingPathComponent(".abstract/chats", isDirectory: true)
    }

    /// Whether `path` is a folder Abstract made for a chat with no project
    /// (a standalone chat's, or an automation run's scratch folder), and so
    /// may delete with it. Nothing else ever is.
    public static func isChatFolder(_ path: String, home: String) -> Bool {
        let folder = URL(fileURLWithPath: path).standardizedFileURL
        let roots = [standaloneRoot(home: home), URL(fileURLWithPath: Store.defaultPath()).deletingLastPathComponent().appendingPathComponent("scratch")]
        return roots.contains { folder.deletingLastPathComponent().path == $0.standardizedFileURL.path }
    }

    /// A throwaway directory for "No project" automation runs.
    public static func scratchDirectory(runId: String) throws -> String {
        let dir = URL(fileURLWithPath: Store.defaultPath()).deletingLastPathComponent()
            .appendingPathComponent("scratch", isDirectory: true)
            .appendingPathComponent(runId, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    /// First non-empty line of a prompt, trimmed to a chat title.
    public static func title(fromPrompt prompt: String) -> String {
        let first = prompt.split(separator: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let text = String(first ?? "New chat").trimmingCharacters(in: .whitespaces)
        return text.count > 60 ? String(text.prefix(60)).trimmingCharacters(in: .whitespaces) + "…" : text
    }
}

/// One fetch of a branch at a time per repository: chats started together
/// share it rather than race for git's ref locks.
actor Fetches {
    static let shared = Fetches()
    private var running: [String: Task<Void, any Error>] = [:]

    func fetch(root: String, branch: String, _ perform: @escaping @Sendable () async throws -> Void) async throws {
        let key = root + "\u{0}" + branch
        if let task = running[key] { return try await task.value }
        let task = Task { try await perform() }
        running[key] = task
        defer { running[key] = nil }
        try await task.value
    }
}
