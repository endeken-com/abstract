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

    /// Every tracker's results for what was typed, grouped by tracker.
    func searchIssueTrackers(_ query: String) async -> [PluginIssueTrackers.Group] {
        let trackers = issueTrackers
        return await PluginIssueTrackers.search(query, trackers: trackers) { [weak self] tracker, request in
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

    /// Abstract used to keep a Linear API key of its own (Settings →
    /// Integrations). The first launch after Linear became a plugin
    /// installs and turns on the bundled Linear plugin and moves the key
    /// to it, so Linear search keeps working. Done once it's moved, or
    /// when there was no key; a launch where it couldn't be moved tries
    /// again next time and keeps the old copy.
    func adoptLinearPlugin() {
        guard !isDemo, store.setting(Self.linearAdoptedKey, as: Bool.self) != true else { return }
        // Only a Mac that had connected Linear has a key to read: reading
        // the keychain can ask for the password.
        guard UserDefaults.standard.bool(forKey: Self.legacyLinearConnectedKey),
              let key = Keychain.read(Self.legacyLinearAccount) else {
            try? store.setSetting(Self.linearAdoptedKey, true)
            return
        }
        guard let folder = plugins.bundledFolders.first(where: { $0.lastPathComponent == "linear.abstractplugin" }) else { return }
        let pluginId = PromptAttachment.linearTrackerId
        if plugins.plugin(pluginId) == nil {
            guard (try? plugins.install(from: folder, sourceKind: .bundled, enable: true)) != nil else { return }
        } else if plugins.plugin(pluginId)?.record.enabled != true {
            setPluginEnabled(pluginId, true)
        }
        if !plugins.hasSecret(pluginId: pluginId, name: "api-key") {
            plugins.setSecret(key, pluginId: pluginId, name: "api-key")
        }
        // The old copy goes only once the plugin's is there.
        guard plugins.hasSecret(pluginId: pluginId, name: "api-key") else { return }
        Keychain.write(Self.legacyLinearAccount, nil)
        UserDefaults.standard.removeObject(forKey: Self.legacyLinearConnectedKey)
        try? store.setSetting(Self.linearAdoptedKey, true)
    }

    static let linearAdoptedKey = "plugins.linearAdopted"
    /// Where core kept the key before ABS-141.
    static let legacyLinearAccount = "linear-api-key"
    static let legacyLinearConnectedKey = "integrations.linear"
}

/// Trackers' icons, drawn in the text colour. Read from each plugin's
/// package when plugins change, so a chip in an old chat finds its icon
/// without asking the plugin anything.
@MainActor
enum TrackerIcons {
    private static var images: [String: (version: String, image: NSImage)] = [:]

    static func image(_ pluginId: String?) -> NSImage? {
        pluginId.flatMap { images[$0]?.image }
    }

    static func update(_ installed: [InstalledPlugin]) {
        var next: [String: (version: String, image: NSImage)] = [:]
        for plugin in installed where plugin.isUsable {
            guard let icon = plugin.manifest?.contributes.issueTracker?.icon else { continue }
            if let kept = images[plugin.id], kept.version == plugin.record.version {
                next[plugin.id] = kept
                continue
            }
            guard let data = PluginPackage.fileData(in: plugin.packageURL, relativePath: icon),
                  let image = NSImage(data: data) else { continue }
            image.isTemplate = true
            next[plugin.id] = (plugin.record.version, image)
        }
        images = next
    }
}
