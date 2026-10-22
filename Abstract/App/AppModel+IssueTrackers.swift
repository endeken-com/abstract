import AppKit
import Foundation
import AbstractCore

/// Issue trackers (ABS-141): the composer's issue search asks every
/// enabled tracker plugin. Each answers in its background script; this
/// side keeps the search, the chip and the line the agent reads.
extension AppModel {
    /// The trackers of plugins that can run now.
    var issueTrackers: [ResolvedIssueTracker] { PluginIssueTrackers.resolve(plugins.installed) }

    func askTracker(_ tracker: ResolvedIssueTracker, _ request: TrackerRequest) async -> TrackerAnswer {
        guard let pluginBackground else { return .failed("\(tracker.title) isn't running.") }
        return await pluginBackground.askTracker(tracker.pluginId, request)
    }

    /// The trackers a project links to (ABS-143), as saved on this Mac,
    /// among the ones that can run now.
    func projectIssueTrackers(_ projectId: String?) -> ProjectIssueTrackers {
        _ = plugins.trackerLinksRevision
        return ProjectIssueTrackers(projectId: projectId, installed: plugins.installed, links: plugins.trackerLinks)
    }

    /// A project's tracker link changed: the composer, the headers and
    /// plugins' snapshots follow.
    func noteTrackerLinksChanged() { plugins.noteTrackerLinksChanged() }

    /// Every tracker's results for what was typed, grouped by tracker:
    /// the project's linked trackers within their link, or with
    /// `searchAll` every tracker everywhere.
    func searchIssueTrackers(_ query: String, projectId: String? = nil,
                             searchAll: Bool = false) async -> [PluginIssueTrackers.Group] {
        let project = projectIssueTrackers(projectId)
        return await PluginIssueTrackers.search(query, trackers: project.shown(searchAll: searchAll),
                                                scopes: project.scopes(searchAll: searchAll)) { [weak self] tracker, request in
            await self?.askTracker(tracker, request) ?? .failed("\(tracker.title) isn't running.")
        }
    }

    /// The issue as it goes with the message: a search lists issues
    /// without their descriptions, so the picked one is asked for whole.
    /// If that fails it goes as it was listed.
    func completeTrackerIssue(_ attachment: PromptAttachment) async -> PromptAttachment {
        guard attachment.kind == .trackerIssue, let reference = attachment.reference,
              let tracker = issueTrackers.first(where: { $0.pluginId == attachment.tracker }),
              case .issue(let issue?) = await askTracker(tracker, .issue(reference)) else { return attachment }
        var whole = issue.attachment(trackerId: tracker.pluginId, trackerName: tracker.title)
        whole.id = attachment.id
        return whole
    }

    /// Reads each tracker's icon from its package, once per version.
    func refreshTrackerIcons() {
        TrackerIcons.update(plugins.installed)
    }

    // MARK: Upgrading from Linear in core

    /// Linear is a bundled plugin, on when you have a way into Linear
    /// (ABS-141). Abstract used to keep a Linear API key of its own
    /// (Settings → Integrations): the first launch after Linear became a
    /// plugin installs and turns on the Linear plugin and moves the key to
    /// it. With no key, it's turned on if the Linear CLI is signed in on
    /// this Mac. Done once; a key that couldn't be moved is tried again
    /// next launch, and its old copy kept until then.
    func adoptLinearPlugin() async {
        guard !isDemo, store.setting(Self.linearAdoptedKey, as: Bool.self) != true else { return }
        let pluginId = PromptAttachment.linearTrackerId
        // Only a Mac that had connected Linear has a key to read: reading
        // the keychain can ask for the password.
        if UserDefaults.standard.bool(forKey: Self.legacyLinearConnectedKey),
           let key = Keychain.read(Self.legacyLinearAccount) {
            guard turnOnLinearPlugin() else { return }
            if !plugins.hasSecret(pluginId: pluginId, name: "api-key") {
                plugins.setSecret(key, pluginId: pluginId, name: "api-key")
            }
            // The old copy goes only once the plugin's is there.
            guard plugins.hasSecret(pluginId: pluginId, name: "api-key") else { return }
            Keychain.write(Self.legacyLinearAccount, nil)
            UserDefaults.standard.removeObject(forKey: Self.legacyLinearConnectedKey)
        } else if plugins.plugin(pluginId) == nil {
            // Couldn't tell (it timed out, say): ask again next launch.
            guard let signedIn = await linearCLISignedIn() else { return }
            if signedIn { guard turnOnLinearPlugin() else { return } }
        }
        try? store.setSetting(Self.linearAdoptedKey, true)
    }

    /// Installs the bundled Linear plugin if needed and turns it on.
    private func turnOnLinearPlugin() -> Bool {
        let pluginId = PromptAttachment.linearTrackerId
        if plugins.plugin(pluginId) == nil {
            guard let folder = plugins.bundledFolders.first(where: { $0.lastPathComponent == "linear.abstractplugin" }),
                  (try? plugins.install(from: folder, sourceKind: .bundled, enable: true)) != nil else { return false }
        } else if plugins.plugin(pluginId)?.record.enabled != true {
            setPluginEnabled(pluginId, true)
        }
        return plugins.plugin(pluginId)?.isUsable == true
    }

    /// Whether `linear auth list` names a workspace: the bundled plugin's
    /// own declared read, run the way the plugin would run it. Nil when
    /// the CLI is there but didn't answer.
    private func linearCLISignedIn() async -> Bool? {
        guard let folder = plugins.bundledFolders.first(where: { $0.lastPathComponent == "linear.abstractplugin" }),
              let cli = try? PluginPackage.inspect(folder: folder).manifest.cli,
              let command = cli.command(for: ["auth", "list"]) else { return nil }
        guard await executor.which(cli.binary) != nil else { return false }
        guard let out = try? await PluginCLIRunner().run(PluginCLIRequest(args: command.args, command: command), cli: cli,
                                                         executor: executor, cwd: nil, readable: []) else { return nil }
        return out.code == 0 && out.stdout.contains("WORKSPACE")
    }

    static let linearAdoptedKey = "plugins.linearAdopted"
    /// Where core kept the key before ABS-141.
    static let legacyLinearAccount = "linear-api-key"
    static let legacyLinearConnectedKey = "integrations.linear"
}

/// Trackers' icons. Read from each installed plugin's package when
/// plugins change, so a chip in an old chat finds its icon without asking
/// the plugin anything, even while it's off. A one-colour icon is drawn in
/// the text colour; one with colours of its own, like Jira's, keeps them
/// (ABS-143).
@MainActor
enum TrackerIcons {
    private static var images: [String: (version: String, image: NSImage)] = [:]

    static func image(_ pluginId: String?) -> NSImage? {
        pluginId.flatMap { images[$0]?.image }
    }

    static func update(_ installed: [InstalledPlugin]) {
        var next: [String: (version: String, image: NSImage)] = [:]
        for plugin in installed {
            guard let icon = plugin.manifest?.contributes.issueTracker?.icon else { continue }
            if let kept = images[plugin.id], kept.version == plugin.record.version {
                next[plugin.id] = kept
                continue
            }
            guard let data = PluginPackage.fileData(in: plugin.packageURL, relativePath: icon),
                  let image = NSImage(data: data) else { continue }
            image.isTemplate = PluginIssueTrackerDeclaration.iconIsTemplate(data, path: icon)
            next[plugin.id] = (plugin.record.version, image)
        }
        images = next
    }
}
