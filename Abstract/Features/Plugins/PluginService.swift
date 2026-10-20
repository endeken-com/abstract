import Foundation
import Observation
import AbstractCore

/// The plugin host's state: what's installed, and in what shape. All the
/// rules (validation, grants, storage) live in AbstractCore's
/// `PluginManager`; this is its observable face for the views.
@Observable
@MainActor
final class PluginService {
    let manager: PluginManager
    private(set) var installed: [InstalledPlugin] = []
    private(set) var orphans: [(name: String, problem: String)] = []
    /// Monotonic snapshot revision, shared by every open plugin view.
    private(set) var revision = 0

    init(store: Store) {
        manager = PluginManager(store: store)
        refresh()
    }

    /// Test and demo builds can point the host at their own folders.
    init(manager: PluginManager) {
        self.manager = manager
        refresh()
    }

    /// Plugin folders inside the app, offered beside "Install…".
    var bundledFolders: [URL] {
        PluginManager.bundledFolders(in: Bundle.main.resourceURL)
    }

    /// Enabled plugins that can run: a sidebar row each.
    var usable: [InstalledPlugin] { installed.filter(\.isUsable) }

    /// Where usable plugins appear besides the sidebar (ABS-96). Derived
    /// from what's installed now, so disabling a plugin empties its places.
    func contributions(_ place: PluginPlace) -> [ResolvedPluginContribution] {
        PluginContributions.resolve(installed, place: place)
    }

    func plugin(_ id: String) -> InstalledPlugin? {
        installed.first { $0.id == id }
    }

    func refresh() {
        installed = manager.installed()
        orphans = manager.orphanedProblems()
    }

    func nextRevision() -> Int {
        revision += 1
        return revision
    }

    /// Validates a picked folder or zip for the review screen.
    func inspectPicked(_ url: URL) throws -> (folder: URL, inspection: PluginPackage.Inspection, cleanup: URL?) {
        try manager.inspectPicked(url)
    }

    @discardableResult
    func install(from folder: URL, sourceKind: PluginSource, enable: Bool) throws -> PluginRecord {
        let record = try manager.install(from: folder, sourceKind: sourceKind)
        if enable { manager.setEnabled(record.id, true) }
        refresh()
        return record
    }

    func setEnabled(_ id: String, _ enabled: Bool) {
        manager.setEnabled(id, enabled)
        refresh()
    }

    func reviewChangedPackage(_ id: String) {
        manager.reviewChangedPackage(id)
        refresh()
    }

    func remove(_ id: String) {
        manager.remove(id)
        refresh()
    }

    func noteError(_ id: String, _ message: String?) {
        manager.noteError(id, message)
        refresh()
    }
}
