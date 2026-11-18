import AppKit
import AbstractCore

/// Demo mode's bulk actions and deletion check (ABS-181, ABS-206).
/// `ABSTRACT_DEMO_BULK_DELETE=<delay>` waits, adds a dozen chats with real
/// worktrees to two demo projects (some quiet for three weeks, one holding a
/// generated `node_modules` of `ABSTRACT_DEMO_BULK_DELETE_FILES` files,
/// 100,000 by default), then, grouped by Project:
/// - ⌘-clicks three active chats in two projects and archives them at once;
/// - ⇧-clicks a run and picks everything shown with ⌘A;
/// - deletes the big chat and times how soon it leaves the rail and its path;
/// - deletes ten chats at once, timing the main thread's longest stall, and
///   checks `git worktree list`;
/// - resumes an unfinished job and leftover trash the way a launch does;
/// - opens Project Settings › Clean up, reviews, deletes, and logs the result.
/// `ABSTRACT_DEMO_BULK_DELETE_SHOT=<png>` saves the window at each step, the
/// step's name before the extension.
enum BulkDeleteProbe {
    static func runIfRequested(_ model: AppModel) {
        guard let spec = ProcessInfo.processInfo.environment["ABSTRACT_DEMO_BULK_DELETE"], let delay = Double(spec) else { return }
        Task {
            try? await Task.sleep(for: .seconds(delay))
            await run(model)
        }
    }

    private static func run(_ model: AppModel) async {
        guard let abstract = model.projects.first(where: { $0.name == "abstract" }),
              let payments = model.projects.first(where: { $0.name == "payments-api" }) else { log("bulk probe: no projects"); return }
        // The demo's teardown (`docker compose down`) isn't what's measured here.
        for p in [abstract, payments] { model.updateProject(p.id) { $0.teardownScript = nil } }
        let files = Int(ProcessInfo.processInfo.environment["ABSTRACT_DEMO_BULK_DELETE_FILES"] ?? "") ?? 100_000

        // Recent chats to pick and delete, and old ones for the clean-up.
        var recent: [Session] = [], old: [Session] = []
        for i in 1...7 { if let s = await seed(model, abstract, "Recent change \(i)") { recent.append(s) } }
        for i in 1...5 { if let s = await seed(model, payments, "Recent fix \(i)") { recent.append(s) } }
        for i in 1...6 { if let s = await seed(model, abstract, "Old experiment \(i)", daysAgo: 21) { old.append(s) } }
        guard let big = await seed(model, abstract, "Old dependency upgrade", daysAgo: 1) else { return }
        let generated = generate(files, in: (big.worktreePath ?? "") + "/node_modules")
        log("bulk probe: seeded \(recent.count) recent, \(old.count) old, \(generated) files in one worktree")
        model.reload()

        // The demo shares the app's defaults: put back what it changes.
        let arrangement = UserDefaults.standard.string(forKey: "sidebar.arrangement"), showArchived = model.showArchived
        defer {
            if let arrangement { UserDefaults.standard.set(arrangement, forKey: "sidebar.arrangement") }
            else { UserDefaults.standard.removeObject(forKey: "sidebar.arrangement") }
            model.showArchived = showArchived
        }
        UserDefaults.standard.set(SidebarChats.Arrangement.project.rawValue, forKey: "sidebar.arrangement")
        model.showArchived = false
        model.destination = .home
        try? await Task.sleep(for: .seconds(1.5))
        await pickAndArchive(model, abstract: abstract, payments: payments)
        await rangeAndAll(model)
        await deleteBig(model, big, project: abstract)
        await deleteTen(model, Array(recent.suffix(10)), projects: [abstract, payments])
        await resume(model, abstract)
        await cleanUp(model, abstract, old: old)
        log("bulk probe: done")
    }

    // MARK: Steps

    private static func pickAndArchive(_ model: AppModel, abstract: Project, payments: Project) async {
        let order = model.shownChatOrder
        let inAbstract = order.filter { model.session($0)?.projectId == abstract.id && model.session($0)?.name.hasPrefix("Recent") == true }
        let inPayments = order.filter { model.session($0)?.projectId == payments.id && model.session($0)?.name.hasPrefix("Recent") == true }
        guard inAbstract.count >= 2, let third = inPayments.first else { log("bulk probe: not enough chats shown"); return }
        log("bulk probe: grouped by \(UserDefaults.standard.string(forKey: "sidebar.arrangement") ?? "?"), \(order.count) chats shown")
        for id in [inAbstract[0], inAbstract[1], third] { model.pickChat(id, .toggle) }
        let picked = model.chatSelection.ids
        log("bulk probe: ⌘-clicked 3 active chats in 2 projects, \(picked.count) picked")
        let items = model.bulkItems(picked)
        log("bulk probe: menu offers " + BulkChatAction.offered(items).map { "“\($0.title(for: items))”" }.joined(separator: ", "))
        await shot("-project-picked")
        let text = BulkChatAction.archiveConfirmation(count: picked.count, working: items.filter(\.working).count)
        log("bulk probe: asks once “\(text.title)” \(text.message)")
        model.archiveChats(picked, stopping: items.filter(\.working).map(\.id))
        let archived = picked.filter { model.session($0)?.archivedAt != nil }.count
        log("bulk probe: archived \(archived) of \(picked.count)")
        // Mixed picks say what fits: one archived, two not.
        let mixed = [picked[0]] + inAbstract.dropFirst(2).prefix(2)
        let mixedItems = model.bulkItems(Array(mixed))
        log("bulk probe: a mixed pick offers “\(BulkChatAction.archive.title(for: mixedItems))” and “\(BulkChatAction.unarchive.title(for: mixedItems))”")
        for id in picked { model.setArchived(id, false) }
        try? await Task.sleep(for: .seconds(0.5))
    }

    private static func rangeAndAll(_ model: AppModel) async {
        let order = model.shownChatOrder
        guard order.count >= 5 else { return }
        model.chatSelection = ChatSelection()
        model.pickChat(order[1], .toggle)
        model.pickChat(order[4], .extend)
        log("bulk probe: ⇧-click picked \(model.chatSelection.count) (\(model.chatSelection.ids == Array(order[1...4]) ? "the run" : "NOT THE RUN"))")
        await shot("-range")
        model.pickAllShown()
        log("bulk probe: ⌘A picked \(model.chatSelection.count) of \(order.count) shown")
        await shot("-select-all")
        model.chatSelection = ChatSelection()
    }

    private static func deleteBig(_ model: AppModel, _ big: Session, project: Project) async {
        guard let path = big.worktreePath else { return }
        let clock = ContinuousClock()
        let start = clock.now
        await model.delete(big.id, removeWorktree: true, quiet: true)
        let rail = clock.now - start
        let shown = model.sidebarChats().contains { $0.id == big.id } || model.session(big.id) != nil
        while FileManager.default.fileExists(atPath: path), clock.now - start < .seconds(30) { try? await Task.sleep(for: .milliseconds(5)) }
        let pathGone = clock.now - start
        log("bulk probe: big chat out of the rail and store in \(ms(rail)) (\(shown ? "STILL SHOWN" : "gone")), deleting line shows \(model.deletingChats.count)")
        await shot("-deleting")
        await model.waitUntilCleared([big.id])
        let cleared = clock.now - start
        log("bulk probe: big chat's worktree path gone in \(ms(pathGone)), trash cleared in \(ms(cleared))")
        let listed = await worktrees(model, project)
        log("bulk probe: git worktree list \(listed.contains(AppModel.canonical(path)) ? "STILL LISTS IT" : "no longer lists it")")
    }

    private static func deleteTen(_ model: AppModel, _ chats: [Session], projects: [Project]) async {
        let ids = chats.map(\.id)
        let paths = chats.compactMap(\.worktreePath)
        // The main thread's longest gap between ticks while they go.
        let clock = ContinuousClock()
        let gaps = Gaps()
        let ticker = Task { @MainActor in
            var last = clock.now
            while gaps.ticking {
                try? await Task.sleep(for: .milliseconds(10))
                let now = clock.now
                gaps.longest = max(gaps.longest, now - last)
                last = now
            }
        }
        let start = clock.now
        let report = await model.deleteChats(ids)
        let rail = clock.now - start
        log("bulk probe: \(report.summary) Out of the rail in \(ms(rail)); deleting line shows \(model.deletingChats.count)")
        await model.waitUntilCleared(ids)
        let cleared = clock.now - start
        gaps.ticking = false
        await ticker.value
        log("bulk probe: 10 chats' files cleared in \(ms(cleared)); longest main-thread gap \(ms(gaps.longest))")
        var listed: Set<String> = []
        for p in projects { listed.formUnion(await worktrees(model, p)) }
        let left = paths.filter { listed.contains(AppModel.canonical($0)) || FileManager.default.fileExists(atPath: $0) }
        log("bulk probe: \(left.isEmpty ? "git worktree list shows none of them and their folders are gone" : "\(left.count) STILL THERE")")
    }

    /// What a launch does after a quit: an unfinished job and leftover trash.
    private static func resume(_ model: AppModel, _ project: Project) async {
        guard let s = await seed(model, project, "Interrupted delete") , let path = s.worktreePath else { return }
        // As if the app quit after removing the chat, before moving its folder,
        // and after moving another's into the trash.
        try? model.store.deleteSession(s.id)
        model.reload()
        let trash = model.trashRoot
        ChatTrash.record(ChatTrash.Job(chatId: s.id, path: path, projectRoot: project.rootPath, branch: s.branch), trash: trash)
        let stray = trash.appendingPathComponent("left-by-a-quit/node_modules/pkg")
        try? FileManager.default.createDirectory(at: stray, withIntermediateDirectories: true)
        log("bulk probe: before relaunch, \(ChatTrash.pending(trash: trash).count) unfinished, \(ChatTrash.leftovers(trash: trash).count) in the trash")
        model.resumeTrash()
        await model.waitUntilCleared([s.id])
        for _ in 0..<100 where !ChatTrash.leftovers(trash: trash).isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
        let listed = await worktrees(model, project)
        log("bulk probe: after resume, \(ChatTrash.pending(trash: trash).count) unfinished, \(ChatTrash.leftovers(trash: trash).count) in the trash, worktree \(FileManager.default.fileExists(atPath: path) || listed.contains(AppModel.canonical(path)) ? "STILL THERE" : "gone")")
    }

    private static func cleanUp(_ model: AppModel, _ project: Project, old: [Session]) async {
        guard old.count >= 6 else { return }
        // One reason to keep each: pinned, waiting on you, an open pull
        // request, a commit never pushed. The other two go.
        model.setPinned(old[0].id, true)
        if var s = model.session(old[1].id) { s.status = .waitingInput; try? model.store.save(s) }
        if let path = old[3].worktreePath {
            try? "work\n".write(toFile: path + "/notes.txt", atomically: true, encoding: .utf8)
            _ = try? await model.executor.run("git", ["add", "."], cwd: path)
            _ = try? await model.executor.run("git", ["-c", "user.name=demo", "-c", "user.email=demo@example.com", "commit", "-qm", "Notes"], cwd: path)
        }
        model.reload()
        openPullRequest(model, for: old[2])
        model.destination = .projectSettings(project.id)
        try? await Task.sleep(for: .seconds(1))
        model.cleanupReviewProject = project.id
        try? await Task.sleep(for: .seconds(4))
        openPullRequest(model, for: old[2])
        await shot("-cleanup-review")
        let list = await model.cleanupCandidates(project.id, olderThan: .twoWeeks)
        for c in list {
            log("bulk probe: clean-up lists “\(c.facts.session.name)”: \(c.reason.map { "kept, \($0.text)" } ?? "deleted")")
        }
        let going = ChatCleanup.toDelete(list)
        model.cleanupProbeConfirm = true
        try? await Task.sleep(for: .seconds(0.4))
        await shot("-cleanup-deleting")
        await model.waitUntilCleared(going)
        try? await Task.sleep(for: .seconds(0.5))
        log("bulk probe: clean-up says “\(model.toast?.message ?? "nothing")”")
        await shot("-cleanup-done")
        let kept = old.filter { model.session($0.id) != nil }.map(\.name)
        log("bulk probe: clean-up kept \(kept.joined(separator: ", "))")
    }

    // MARK: Helpers

    @MainActor private final class Gaps {
        var ticking = true
        var longest: Duration = .zero
    }

    /// A finished chat with its own worktree, last active `daysAgo` days ago.
    private static func seed(_ model: AppModel, _ project: Project, _ name: String, daysAgo: Double = 0) async -> Session? {
        do {
            let made = try await Workspace.provision(executor: model.executor, project: project, name: name, baseRef: nil,
                                                     template: model.worktreeTemplate, prefix: "abstract/")
            let at = Date().addingTimeInterval(-daysAgo * 86_400 - 60)
            var s = Session(id: UUID().uuidString, projectId: project.id, name: name, providerId: "claude", status: .finished,
                            createdAt: at, lastEventAt: at)
            s.worktreePath = made.path
            s.branch = made.branch
            try model.store.save(s)
            return s
        } catch {
            log("bulk probe: couldn't seed \(name): \(error.localizedDescription)")
            return nil
        }
    }

    private static func openPullRequest(_ model: AppModel, for chat: Session) {
        let json = #"{"number": 77, "title": "\#(chat.name)", "state": "open", "isDraft": false, "head": "\#(chat.branch ?? "")", "base": "main", "author": "wes", "updatedAt": "2026-11-01T10:00:00Z"}"#
        if let pr = (try? JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))).flatMap(PullRequest.init(contract:)) {
            model.pullRequests[chat.id] = pr
        }
    }

    /// `count` small files in folders of 1,000, like a `node_modules`.
    private static func generate(_ count: Int, in root: String) -> Int {
        let data = Data("module.exports = {}\n".utf8)
        var made = 0, folder = 0
        while made < count {
            let dir = root + "/pkg-\(folder)/lib"
            guard (try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)) != nil else { break }
            for i in 0..<min(1_000, count - made) where FileManager.default.createFile(atPath: dir + "/f\(i).js", contents: data) { made += 1 }
            folder += 1
        }
        return made
    }

    private static func worktrees(_ model: AppModel, _ project: Project) async -> Set<String> {
        Set(((try? await Git.worktrees(model.executor, root: project.rootPath)) ?? []).map { AppModel.canonical($0.path) })
    }

    private static func ms(_ d: Duration) -> String {
        let millis = Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
        return millis < 10_000 ? String(format: "%.0f ms", millis) : String(format: "%.1f s", millis / 1000)
    }

    private static func shot(_ step: String) async {
        try? await Task.sleep(for: .seconds(0.8))
        guard let path = ProcessInfo.processInfo.environment["ABSTRACT_DEMO_BULK_DELETE_SHOT"], let image = WindowCapture.image() else { return }
        let url = URL(fileURLWithPath: path)
        let named = url.deletingPathExtension().path + step + "." + (url.pathExtension.isEmpty ? "png" : url.pathExtension)
        try? image.write(to: URL(fileURLWithPath: named))
        log("bulk probe: shot \(named)")
    }
}
