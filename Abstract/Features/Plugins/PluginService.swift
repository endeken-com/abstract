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
    /// Background scripts stopped for misbehaving (ABS-93), with why.
    /// They stay stopped until restarted or the plugin is turned back on.
    private(set) var backgroundProblems: [String: String] = [:]
    /// The count each plugin shows on its sidebar row (ABS-111); none is 0.
    private(set) var badges: [String: Int] = [:]
    /// Called after every change to what's installed, enabled or granted,
    /// so background scripts follow.
    @ObservationIgnored var onChange: () -> Void = {}

    init(store: Store) {
        manager = PluginManager(store: store)
        // The GitHub plugin is on unless you turned it off (ABS-139).
        manager.installDefaults(from: PluginManager.bundledFolders(in: Bundle.main.resourceURL))
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

    /// Offer Bitbucket's bundled code host once a Bitbucket remote appears.
    /// installDefaults remembers the offer, so turning it off or removing it sticks.
    func enableBitbucketForRemote(_ remote: String) {
        guard let host = GitRemote.host(remote),
              host == "bitbucket.org" || host.contains("bitbucket") || remote.lowercased().contains("/scm/") else { return }
        if manager.installDefaults(from: bundledFolders, ids: ["sh.abstract.bitbucket"]) { refresh() }
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
        switches = manager.switches()
        onChange()
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
    func install(from folder: URL, sourceKind: PluginSource, enable: Bool,
                 transcriptProjectKeys: [String] = []) throws -> PluginRecord {
        let record = try manager.install(from: folder, sourceKind: sourceKind)
        if enable { manager.setEnabled(record.id, true, transcriptProjectKeys: transcriptProjectKeys) }
        refresh()
        return record
    }

    func setEnabled(_ id: String, _ enabled: Bool, transcriptProjectKeys: [String]? = nil) {
        manager.setEnabled(id, enabled, transcriptProjectKeys: transcriptProjectKeys)
        // Turning it off and on again is a fresh start.
        backgroundProblems[id] = nil
        badges[id] = nil
        refresh()
    }

    func setBadge(_ id: String, _ count: Int) {
        guard badges[id, default: 0] != count else { return }
        badges[id] = count == 0 ? nil : count
    }

    func noteBackgroundStopped(_ id: String, _ note: String) {
        backgroundProblems[id] = note
        badges[id] = nil
        noteError(id, note)
    }

    /// Runs a stopped background script again.
    func restartBackground(_ id: String) {
        backgroundProblems[id] = nil
        refresh()
    }

    /// Always allow one action kind for this plugin, or ask first again.
    func setAlwaysAllowed(_ id: String, _ capability: PluginCapability, _ allowed: Bool) {
        manager.setAlwaysAllowed(id, capability, allowed)
        refresh()
    }

    /// Take one grant back; the plugin stays on without it.
    func revokeCapability(_ id: String, _ capability: PluginCapability) {
        manager.revokeCapability(id, capability)
        refresh()
    }

    func reviewChangedPackage(_ id: String) {
        manager.reviewChangedPackage(id)
        refresh()
    }

    func remove(_ id: String) {
        // Its secrets go with it (ABS-94).
        if let plugin = plugin(id) {
            for name in Set(plugin.record.grantedSecretNames + (plugin.manifest?.secretDeclarations.map(\.name) ?? [])) {
                setSecret(nil, pluginId: id, name: name)
            }
        }
        manager.remove(id)
        backgroundProblems[id] = nil
        badges[id] = nil
        refresh()
    }

    // MARK: Secrets and network activity (ABS-94)

    /// Bumped after every plugin web request, so Settings shows it.
    private(set) var networkActivity = 0

    func noteNetworkActivity() { networkActivity += 1 }

    func networkLogEntries(_ id: String) -> [PluginNetworkLog.Entry] {
        _ = networkActivity
        return manager.networkLog(for: id).entries()
    }

    nonisolated static func secretAccount(pluginId: String, name: String) -> String {
        "plugin.\(pluginId).\(name)"
    }

    /// Whether a value is kept — the value itself is never shown.
    func hasSecret(pluginId: String, name: String) -> Bool {
        Keychain.read(Self.secretAccount(pluginId: pluginId, name: name)) != nil
    }

    /// nil (or empty) removes it.
    func setSecret(_ value: String?, pluginId: String, name: String) {
        let value = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        Keychain.write(Self.secretAccount(pluginId: pluginId, name: name),
                       value?.isEmpty == false ? value : nil)
    }

    /// The fetcher for one showing of a plugin: the record's grants,
    /// Keychain secrets, the live transport and its activity log.
    func fetchService(for plugin: InstalledPlugin) -> PluginFetchService {
        PluginFetchService(pluginId: plugin.id,
                           allowedHosts: Set(plugin.record.grantedNetworkHosts),
                           secretNames: Set(plugin.record.grantedSecretNames),
                           secrets: KeychainPluginSecrets(),
                           transport: URLSessionPluginTransport(),
                           log: manager.networkLog(for: plugin.id))
    }

    func noteError(_ id: String, _ message: String?) {
        manager.noteError(id, message)
        refresh()
    }

    // MARK: Pull Request switches (ABS-109)

    /// Which chats each plugin's Pull Request switches are on for.
    private(set) var switches = PluginSwitches()

    func isSwitchOn(_ contribution: ResolvedPluginContribution, chatId: String) -> Bool {
        switches.isOn(pluginId: contribution.pluginId, contributionId: contribution.contribution.id, chatId: chatId)
    }

    func setSwitch(pluginId: String, contributionId: String, chatId: String, on: Bool) {
        manager.setSwitch(pluginId: pluginId, contributionId: contributionId, chatId: chatId, on: on)
        switches = manager.switches()
    }

    /// The switches that are on, for plugins that can run now.
    var switchesOn: [(pluginId: String, contributionId: String, chatId: String)] {
        switches.switchesOn(pluginIds: Set(usable.map(\.id)))
    }
}

/// Plugin secrets from the login Keychain (ABS-94). Read only while a
/// request is being sent, and only into its headers. Its own read because
/// a send may not be on the main actor; Keychain calls are thread-safe.
struct KeychainPluginSecrets: PluginSecretResolving {
    nonisolated func secretValue(pluginId: String, name: String) -> String? {
        let account = PluginService.secretAccount(pluginId: pluginId, name: name)
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: "Abstract",
                                      kSecAttrAccount: account, kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
