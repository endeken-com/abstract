import Foundation
import AbstractCore

/// Shipping a chat whose worktree holds submodules (see `Shipping`), for the
/// git actions, the Pull Request tab and the delete confirmations.
extension AppModel {
    /// What deleting `worktree` loses beyond its uncommitted work: commits in
    /// its submodules that no remote has. They live in the worktree's own
    /// clone of each and go with it. Nil when there are none.
    func unpushedSubmoduleWarning(_ exec: any Executor, worktree: String) async -> String? {
        let repos = await Submodules.list(exec, worktree: worktree)
        let lost = await Shipping.unpushedWork(exec, worktree: worktree, repos: repos)
        guard !lost.isEmpty else { return nil }
        let list = lost.map { "\($0.repo.path) (\($0.commits) commit\($0.commits == 1 ? "" : "s"))" }.joined(separator: ", ")
        return "\(list) \(lost.count == 1 ? "has" : "have") commits no remote has. They're only in this worktree and are lost with it."
    }
}
