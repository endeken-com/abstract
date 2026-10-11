import Foundation

/// How the line above the reply box names a chat's branch, so it reads as the
/// git branch and not as the worktree folder the chat also has.
public struct BranchLine: Sendable, Equatable {
    public var branch: String
    /// The folder the chat works in, when its name differs from the branch.
    public var folder: String?
    /// A project chat's folder is its worktree; a standalone chat's is just a folder.
    public var isWorktree: Bool

    public init(branch: String, worktreePath: String?, isWorktree: Bool = true) {
        self.branch = branch
        let name = worktreePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
        self.folder = name.isEmpty || name == "/" || name == branch ? nil : name
        self.isWorktree = isWorktree
    }

    /// nil when the chat has no branch.
    public init?(session: Session) {
        guard let branch = session.branch, !branch.isEmpty else { return nil }
        self.init(branch: branch, worktreePath: session.worktreePath, isWorktree: session.projectId != nil)
    }

    /// The tooltip: "Branch: abstract/fix-login in worktree abuja".
    public var help: String {
        guard let folder else { return "Branch: \(branch)" }
        return "Branch: \(branch) in \(isWorktree ? "worktree" : "folder") \(folder)"
    }

    /// What VoiceOver reads: "Branch abstract/fix-login".
    public var accessibilityLabel: String { "Branch \(branch)" }
}
