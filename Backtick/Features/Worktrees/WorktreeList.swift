import Foundation
import Observation
import BacktickCore

/// One worktree, placed against the chats that use it.
struct WorktreeEntry: Identifiable, Hashable {
    enum Kind: Hashable { case main, chat(Session), abandoned }

    let info: WorktreeInfo
    let kind: Kind
    /// False when git still lists the worktree but its folder is gone.
    let exists: Bool

    var id: String { info.path }
    var path: String { info.path }
    var session: Session? { if case .chat(let s) = kind { s } else { nil } }

    /// Branch name, or the short commit a detached worktree sits on.
    var refLabel: String {
        if let branch = info.branch { return branch }
        if let head = info.head { return "detached at \(head.prefix(7))" }
        return info.isBare ? "bare" : "detached"
    }
}

/// Worktrees of one project, grouped into main / chats / abandoned.
@Observable
final class WorktreeList {
    enum Phase: Equatable { case idle, loading, loaded, failed(String) }

    private(set) var phase: Phase = .idle
    private(set) var main: WorktreeEntry?
    private(set) var chats: [WorktreeEntry] = []
    private(set) var abandoned: [WorktreeEntry] = []
    private(set) var isBusy = false
    private(set) var loadedProjectId: String?
    @ObservationIgnored private var generation = 0

    var total: Int { (main == nil ? 0 : 1) + chats.count + abandoned.count }

    func load(_ project: Project, model: AppModel) async {
        generation += 1
        let current = generation
        if loadedProjectId != project.id { phase = .loading; main = nil; chats = []; abandoned = [] }
        do {
            let infos = try await Git.worktrees(model.executor, root: project.rootPath)
            guard current == generation else { return }
            place(infos, project: project, model: model)
            loadedProjectId = project.id
            phase = .loaded
        } catch {
            guard current == generation else { return }
            phase = .failed(error.localizedDescription)
        }
    }

    private func place(_ infos: [WorktreeInfo], project: Project, model: AppModel) {
        let root = Self.canonical(project.rootPath)
        var bySession: [String: Session] = [:]
        for s in model.sessions {
            if let path = s.worktreePath, !path.isEmpty { bySession[Self.canonical(path)] = s }
        }
        var main: WorktreeEntry?
        var chats: [WorktreeEntry] = []
        var abandoned: [WorktreeEntry] = []
        for (i, info) in infos.enumerated() {
            let key = Self.canonical(info.path)
            let exists = model.executor.fileExists(info.path)
            if key == root || (i == 0 && main == nil && !infos.contains { Self.canonical($0.path) == root }) {
                main = WorktreeEntry(info: info, kind: .main, exists: exists)
            } else if let s = bySession[key] {
                chats.append(WorktreeEntry(info: info, kind: .chat(s), exists: exists))
            } else {
                abandoned.append(WorktreeEntry(info: info, kind: .abandoned, exists: exists))
            }
        }
        self.main = main
        self.chats = chats.sorted { ($0.session?.lastEventAt ?? .distantPast) > ($1.session?.lastEventAt ?? .distantPast) }
        self.abandoned = abandoned.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    func prune(_ project: Project, model: AppModel) async {
        isBusy = true
        do {
            try await Git.prune(model.executor, root: project.rootPath)
            model.flash("Pruned stale worktree records")
        } catch {
            model.flash("Prune failed: \(error.localizedDescription)", isError: true)
        }
        isBusy = false
        await load(project, model: model)
    }

    func remove(_ entry: WorktreeEntry, deleteBranch: Bool, project: Project, model: AppModel) async {
        isBusy = true
        if let s = entry.session, model.isAlive(s.id) { model.stop(s.id) }
        do {
            try await Git.removeWorktree(model.executor, root: project.rootPath, path: entry.path,
                                         deleteBranch: deleteBranch ? entry.info.branch : nil)
            model.flash(deleteBranch && entry.info.branch != nil ? "Removed worktree and branch" : "Removed worktree")
        } catch {
            model.flash("Couldn't remove worktree: \(error.localizedDescription)", isError: true)
        }
        isBusy = false
        await load(project, model: model)
    }

    /// Symlinks resolved (`/var` vs `/private/var`) and trailing slashes gone,
    /// so paths from git and from the store compare equal.
    static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }
}
