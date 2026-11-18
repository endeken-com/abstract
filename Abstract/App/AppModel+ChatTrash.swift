import Foundation
import AbstractCore

/// A deleted chat's worktree or folder, cleared in the background (ABS-206):
/// its teardown (three at a time), a rename into `~/.abstract/trash`,
/// `git worktree prune`, then a low-priority `rm -rf`, one at a time. The
/// rail says "Deleting 3 chats…" until it's done; a toast names what's left.
extension AppModel {
    /// Why a chat's folder stays where it is.
    struct KeptFiles: Error { let message: String }

    var trashRoot: URL { ChatTrash.root(home: executor.homeDirectory) }

    /// The job that clears `s`'s worktree or folder, checked against the
    /// store: the path is the one stored for it, no other chat works there
    /// (reviewers aside), and it's a project's worktree or a standalone
    /// chat's own folder. `ChatTrash` checks the disk and git again.
    func trashJob(for s: Session) -> Result<ChatTrash.Job, KeptFiles>? {
        guard let path = s.worktreePath else { return nil }
        guard let stored = try? store.session(s.id), stored.worktreePath.map(Self.canonical) == Self.canonical(path) else {
            return .failure(KeptFiles(message: "Its folder was left at \(path): it isn't the one stored for the chat."))
        }
        let key = Self.canonical(path)
        let others = ((try? store.sessions()) ?? sessions).filter {
            $0.id != s.id && $0.reviewsSessionId == nil && $0.worktreePath.map(Self.canonical) == key
        }
        if let other = others.first {
            return .failure(KeptFiles(message: "Its worktree stays: “\(other.name)” works in it too."))
        }
        if let projectId = s.projectId {
            guard let project = projects.first(where: { $0.id == projectId }) else { return nil }
            return .success(ChatTrash.Job(chatId: s.id, path: path, projectRoot: project.rootPath, branch: s.branch,
                                          deleteBranch: false, teardownScript: project.teardownScript))
        }
        guard Workspace.isChatFolder(path, home: executor.homeDirectory) else { return nil }
        return .success(ChatTrash.Job(chatId: s.id, path: path, projectRoot: nil))
    }

    /// Runs `job` off the main actor; its chat is already gone.
    func clearInBackground(_ job: ChatTrash.Job, name: String) {
        deletingChats[job.chatId] = name
        let exec = executor, home = executor.homeDirectory, trash = trashRoot
        let roots = ChatTrash.worktreeRoots(home: home), teardowns = teardowns, line = purgeLine
        let task = Task.detached(priority: .utility) { [weak self] in
            let (outcome, teardown) = await ChatTrash.run(job, exec: exec, home: home, trash: trash, roots: roots, teardowns: teardowns)
            var problem = teardown
            switch outcome {
            case .trashed(let item):
                ChatTrash.finish(job.chatId, trash: trash)
                // One `rm -rf` at a time.
                if !(await line.run { await ChatTrash.purge(item, trash: trash) }) {
                    problem = (problem.map { $0 + " " } ?? "") + "Some of its files are still in \(trash.path); they're cleared on the next launch."
                }
            case .removed:
                ChatTrash.finish(job.chatId, trash: trash)
            case .left(let why):
                ChatTrash.finish(job.chatId, trash: trash)
                problem = (problem.map { $0 + " " } ?? "") + "Its folder is still at \(job.path): \(why)"
            }
            let reported = problem
            await MainActor.run { self?.cleared(job.chatId, name: name, problem: reported) }
        }
        trashTasks[job.chatId] = task
    }

    private func cleared(_ chatId: String, name: String, problem: String?) {
        deletingChats[chatId] = nil
        trashTasks[chatId] = nil
        if let problem { trashProblems.append(name.isEmpty ? problem : "“\(name)”: \(problem)") }
        // One toast when the batch is done, naming what's left.
        guard deletingChats.isEmpty, !trashProblems.isEmpty else { return }
        let problems = trashProblems
        trashProblems = []
        flash(problems.count == 1 ? problems[0] : "\(problems.count) chats' files weren't all removed. \(problems[0])", isError: true)
    }

    /// Waits until the folders of `ids` are cleared (or were never there).
    func waitUntilCleared(_ ids: [String]) async {
        for id in ids { await trashTasks[id]?.value }
    }

    /// On launch: finishes jobs a quit interrupted, then empties the trash.
    func resumeTrash() {
        let trash = trashRoot
        let leftovers = ChatTrash.leftovers(trash: trash)
        let used = Set(((try? store.sessions()) ?? sessions).compactMap { $0.worktreePath.map(Self.canonical) })
        for job in ChatTrash.pending(trash: trash) {
            // Its chat came back, or another works there now: the folder stays.
            if session(job.chatId) != nil || used.contains(Self.canonical(job.path)) {
                ChatTrash.finish(job.chatId, trash: trash)
                continue
            }
            clearInBackground(job, name: "")
        }
        guard !leftovers.isEmpty else { return }
        let key = "trash:leftovers"
        deletingChats[key] = ""
        let line = purgeLine
        Task.detached(priority: .utility) { [weak self] in
            for item in leftovers { _ = await line.run { await ChatTrash.purge(item, trash: trash) } }
            await MainActor.run { self?.deletingChats[key] = nil }
        }
    }
}
