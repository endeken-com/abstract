import Foundation

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
    public static func provision(
        executor: any Executor,
        project: Project,
        name: String,
        baseRef: String?,
        template: String,
        prefix: String,
        slug: String? = nil,
        worktreeName: String? = nil
    ) async throws -> Provisioned {
        let repo = URL(fileURLWithPath: project.rootPath).lastPathComponent
        let hash = WorktreeNaming.shortHash(project.rootPath)
        let baseSlug = slug.flatMap { WorktreeNaming.branchSlug($0) } ?? WorktreeNaming.slugify(name)
        let baseFolderSlug = worktreeName.map { WorktreeNaming.slugify($0) }
            ?? baseSlug.replacingOccurrences(of: "/", with: "-")
        let base = (baseRef?.isEmpty == false ? baseRef : nil) ?? project.defaultBaseRef

        for attempt in 0..<50 {
            let branchSlug = attempt == 0 ? baseSlug : "\(baseSlug)-\(attempt)"
            let folderSlug = attempt == 0 ? baseFolderSlug : "\(baseFolderSlug)-\(attempt)"
            let branch = "\(prefix)\(branchSlug)"
            let path = WorktreeNaming.render(
                template: template, home: executor.homeDirectory, repo: repo, hash: hash,
                slug: folderSlug, branch: branch, prefix: prefix
            )
            if executor.fileExists(path) { continue }
            if await Git.branchExists(executor, root: project.rootPath, branch: branch) { continue }
            try await Git.addWorktree(executor, root: project.rootPath, path: path, branch: branch, baseRef: base,
                                      sparse: project.sparseCheckout)
            return Provisioned(path: path, branch: branch)
        }
        throw AbstractError.message("Could not find a free worktree path or branch name for “\(name)”.")
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
