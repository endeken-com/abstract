import Foundation

/// Where an installed plugin came from.
public enum PluginSource: String, Sendable, Hashable, Codable {
    case bundled
    case user

    public var plainWords: String {
        switch self {
        case .bundled: "With Abstract"
        case .user: "Installed by you"
        }
    }
}

/// The host's record of one installed plugin (ABS-84 §5), kept as the
/// `plugins.v1` JSON setting, apart from project/session records.
public struct PluginRecord: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    public var name: String
    public var version: String
    public var source: PluginSource
    public var enabled: Bool
    /// What the person granted at review; empty until then.
    public var grantedCapabilities: Set<PluginCapability>
    /// Action kinds this plugin may use without asking (ABS-92). Every
    /// other granted action kind asks first, one action at a time.
    public var alwaysAllowedActions: Set<PluginCapability>
    /// The exact hosts and secret names granted with `network`/`secrets`
    /// (ABS-94); an update adding one must be reviewed again.
    public var grantedNetworkHosts: [String]
    public var grantedSecretNames: [String]
    /// Project keys (`macId:projectId`) whose chats' messages a
    /// `transcripts.read` grant may read, picked at review. Empty reads none.
    public var transcriptProjectKeys: [String]
    /// Whether running its background script was reviewed (ABS-93); an
    /// update that adds one must be reviewed again.
    public var grantedBackground: Bool
    /// The command-line tool and commands granted with `cli` (ABS-139);
    /// an update adding a command, or making one a write, is reviewed again.
    public var grantedCLI: PluginCLI?
    public var packageHash: String
    public var installedAt: Date
    public var lastError: String?

    public init(id: String, name: String, version: String, source: PluginSource, enabled: Bool = false,
                grantedCapabilities: Set<PluginCapability> = [], alwaysAllowedActions: Set<PluginCapability> = [],
                grantedNetworkHosts: [String] = [],
                grantedSecretNames: [String] = [], transcriptProjectKeys: [String] = [],
                grantedBackground: Bool = false, grantedCLI: PluginCLI? = nil, packageHash: String,
                installedAt: Date = Date(), lastError: String? = nil) {
        self.id = id; self.name = name; self.version = version; self.source = source
        self.enabled = enabled; self.grantedCapabilities = grantedCapabilities
        self.alwaysAllowedActions = alwaysAllowedActions
        self.grantedNetworkHosts = grantedNetworkHosts; self.grantedSecretNames = grantedSecretNames
        self.transcriptProjectKeys = transcriptProjectKeys
        self.grantedBackground = grantedBackground
        self.grantedCLI = grantedCLI
        self.packageHash = packageHash; self.installedAt = installedAt; self.lastError = lastError
    }

    // Records written before ABS-94 have no host/secret grants, and records
    // saved before transcript scoping carry no project list.
    public init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        id = try box.decode(String.self, forKey: .id)
        name = try box.decode(String.self, forKey: .name)
        version = try box.decode(String.self, forKey: .version)
        source = try box.decode(PluginSource.self, forKey: .source)
        enabled = try box.decode(Bool.self, forKey: .enabled)
        grantedCapabilities = try box.decode(Set<PluginCapability>.self, forKey: .grantedCapabilities)
        // Records saved before plugin actions (ABS-92) ask first for all.
        alwaysAllowedActions = try box.decodeIfPresent(Set<PluginCapability>.self, forKey: .alwaysAllowedActions) ?? []
        grantedNetworkHosts = try box.decodeIfPresent([String].self, forKey: .grantedNetworkHosts) ?? []
        grantedSecretNames = try box.decodeIfPresent([String].self, forKey: .grantedSecretNames) ?? []
        transcriptProjectKeys = try box.decodeIfPresent([String].self, forKey: .transcriptProjectKeys) ?? []
        grantedBackground = try box.decodeIfPresent(Bool.self, forKey: .grantedBackground) ?? false
        grantedCLI = try box.decodeIfPresent(PluginCLI.self, forKey: .grantedCLI)
        packageHash = try box.decode(String.self, forKey: .packageHash)
        installedAt = try box.decode(Date.self, forKey: .installedAt)
        lastError = try box.decodeIfPresent(String.self, forKey: .lastError)
    }
}

/// One installed plugin as the host finds it now: its record, its manifest
/// when the package reads, and the problem when it doesn't.
public struct InstalledPlugin: Sendable, Identifiable {
    public var record: PluginRecord
    public var manifest: PluginManifest?
    /// A plain sentence when the plugin can't run (missing, changed, broken).
    public var problem: String?
    public var packageURL: URL

    public var id: String { record.id }
    /// Enabled and able to run: what gets a sidebar row and snapshots.
    public var isUsable: Bool { record.enabled && problem == nil && manifest != nil }
    public var view: PluginManifest.View? { manifest?.view }
}

/// Installs, enables, disables and removes plugin packages, and says what
/// state each is in. Discovery reads manifests only; no plugin code runs here.
public final class PluginManager: Sendable {
    public static let settingsKey = "plugins.v1"

    public let store: Store
    /// `…/Abstract/Plugins` — installed packages, `<id>/<version>/`.
    public let pluginsRoot: URL
    /// `…/Abstract/PluginData` — one storage file per plugin.
    public let dataRoot: URL

    public init(store: Store, pluginsRoot: URL, dataRoot: URL) {
        self.store = store; self.pluginsRoot = pluginsRoot; self.dataRoot = dataRoot
    }

    /// The folders beside the database, honouring the same data directory.
    public convenience init(store: Store) {
        let base = URL(fileURLWithPath: Store.defaultPath()).deletingLastPathComponent()
        self.init(store: store, pluginsRoot: base.appendingPathComponent("Plugins"),
                  dataRoot: base.appendingPathComponent("PluginData"))
    }

    public func records() -> [PluginRecord] {
        store.setting(Self.settingsKey, as: [PluginRecord].self) ?? []
    }

    private func save(_ records: [PluginRecord]) {
        try? store.setSetting(Self.settingsKey, records)
    }

    public func packageURL(for record: PluginRecord) -> URL {
        pluginsRoot.appendingPathComponent(record.id).appendingPathComponent(record.version)
    }

    public func storage(for pluginId: String) -> PluginStorage {
        PluginStorage(directory: dataRoot, pluginId: pluginId)
    }

    public func networkLog(for pluginId: String) -> PluginNetworkLog {
        PluginNetworkLog(directory: dataRoot, pluginId: pluginId)
    }

    /// Every installed plugin, checked against what's on disk now. A package
    /// that changed since install is turned off until it's reviewed again;
    /// a missing or unreadable one is listed with its problem. Never throws.
    public func installed() -> [InstalledPlugin] {
        var records = records()
        var changed = false
        let out = records.indices.map { index -> InstalledPlugin in
            let record = records[index]
            let folder = packageURL(for: record)
            do {
                let inspection = try PluginPackage.inspect(folder: folder)
                guard inspection.hash == record.packageHash else {
                    if record.enabled { records[index].enabled = false; changed = true }
                    return InstalledPlugin(record: records[index], manifest: inspection.manifest,
                                           problem: PluginValidationError.changedSinceInstall.description.replacingOccurrences(of: "It", with: record.name),
                                           packageURL: folder)
                }
                if inspection.manifest.id != record.id || inspection.manifest.version != record.version {
                    return InstalledPlugin(record: record, manifest: inspection.manifest,
                                           problem: "Its files don't match what was installed, so it's off.", packageURL: folder)
                }
                return InstalledPlugin(record: record, manifest: inspection.manifest, problem: nil, packageURL: folder)
            } catch let error as PluginValidationError {
                return InstalledPlugin(record: record, manifest: nil, problem: error.description, packageURL: folder)
            } catch {
                return InstalledPlugin(record: record, manifest: nil,
                                       problem: "Its files couldn't be read, so it's off.", packageURL: folder)
            }
        }
        if changed { save(records) }
        return out
    }

    /// Package folders in the plugins root that no record owns and that don't
    /// read — left there by hand, say. Abstract opens normally beside them.
    public func orphanedProblems(fileManager fm: FileManager = .default) -> [(name: String, problem: String)] {
        let owned = Set(records().map { packageURL(for: $0).path })
        guard let ids = try? fm.contentsOfDirectory(at: pluginsRoot, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        var out: [(String, String)] = []
        for idFolder in ids {
            let versions = (try? fm.contentsOfDirectory(at: idFolder, includingPropertiesForKeys: nil)) ?? []
            if versions.isEmpty {
                out.append((idFolder.lastPathComponent, PluginValidationError.invalidManifest("").description))
                continue
            }
            for version in versions where !owned.contains(version.path) {
                // A valid folder with no record is simply not installed.
                do { _ = try PluginPackage.inspect(folder: version, fileManager: fm) }
                catch let error as PluginValidationError {
                    out.append((idFolder.lastPathComponent, error.description))
                } catch {
                    out.append((idFolder.lastPathComponent, "Its files couldn't be read, so it's off."))
                }
            }
        }
        return out
    }

    /// Validates a picked package (folder, or `.zip` of one) for the review
    /// screen. Nothing is copied in.
    public func inspectPicked(_ picked: URL, fileManager fm: FileManager = .default) throws -> (folder: URL, inspection: PluginPackage.Inspection, cleanup: URL?) {
        if picked.pathExtension.lowercased() == "zip" {
            let staging = fm.temporaryDirectory.appendingPathComponent("abstract-plugin-\(UUID().uuidString)")
            let folder = try PluginPackage.unzip(picked, into: staging, fileManager: fm)
            return (folder, try PluginPackage.inspect(folder: folder, fileManager: fm), staging)
        }
        return (picked, try PluginPackage.inspect(folder: picked, fileManager: fm), nil)
    }

    /// Copies a validated package in, atomically. Installed is not enabled —
    /// except an update whose capabilities don't grow keeps its grant and
    /// its on/off state (ABS-84 §5).
    @discardableResult
    public func install(from source: URL, sourceKind: PluginSource, fileManager fm: FileManager = .default) throws -> PluginRecord {
        let inspection = try PluginPackage.inspect(folder: source, fileManager: fm)
        let manifest = inspection.manifest
        var records = records()
        let existing = records.first { $0.id == manifest.id }
        let wants = manifest.grantedCapabilities
        let grows = existing.map { existing in
            !wants.isSubset(of: existing.grantedCapabilities)
                || !Set(manifest.networkHosts).isSubset(of: Set(existing.grantedNetworkHosts))
                || !Set(manifest.secretDeclarations.map(\.name)).isSubset(of: Set(existing.grantedSecretNames))
                || (manifest.background != nil && !existing.grantedBackground)
                || manifest.cli.map { wanted in existing.grantedCLI.map { !$0.covers(wanted) } ?? true } == true
        } ?? false

        let idFolder = pluginsRoot.appendingPathComponent(manifest.id)
        let destination = idFolder.appendingPathComponent(manifest.version)
        try fm.createDirectory(at: idFolder, withIntermediateDirectories: true)
        let staging = idFolder.appendingPathComponent(".installing-\(UUID().uuidString)")
        do {
            try fm.copyItem(at: source, to: staging)
            // What landed is what was reviewed.
            let landed = try PluginPackage.inspect(folder: staging, fileManager: fm)
            guard landed.hash == inspection.hash else {
                throw PluginValidationError.invalidManifest("the copy didn't match what was reviewed")
            }
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.moveItem(at: staging, to: destination)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
        // One installed version per plugin.
        if let existing, existing.version != manifest.version {
            try? fm.removeItem(at: packageURL(for: existing))
        }

        let record = PluginRecord(
            id: manifest.id, name: manifest.name, version: manifest.version, source: sourceKind,
            enabled: existing != nil && !grows ? (existing?.enabled ?? false) : false,
            grantedCapabilities: existing != nil && !grows ? (existing?.grantedCapabilities ?? []) : [],
            alwaysAllowedActions: existing != nil && !grows
                ? (existing?.alwaysAllowedActions ?? []).intersection(wants) : [],
            grantedNetworkHosts: existing != nil && !grows ? manifest.networkHosts : [],
            grantedSecretNames: existing != nil && !grows ? manifest.secretDeclarations.map(\.name) : [],
            transcriptProjectKeys: existing != nil && !grows ? (existing?.transcriptProjectKeys ?? []) : [],
            grantedBackground: existing != nil && !grows && manifest.background != nil,
            grantedCLI: existing != nil && !grows ? manifest.cli : nil,
            packageHash: inspection.hash, installedAt: existing?.installedAt ?? Date())
        records.removeAll { $0.id == manifest.id }
        records.append(record)
        save(records.sorted { $0.name < $1.name })
        return record
    }

    /// Enables or disables. Enabling is the grant: the manifest's whole
    /// capability list, or nothing. `transcriptProjectKeys` is the project
    /// list picked at this review; passing nil keeps the last pick.
    public func setEnabled(_ pluginId: String, _ enabled: Bool, transcriptProjectKeys: [String]? = nil) {
        var records = records()
        guard let index = records.firstIndex(where: { $0.id == pluginId }) else { return }
        if enabled {
            guard let manifest = try? PluginPackage.inspect(folder: packageURL(for: records[index])).manifest else { return }
            records[index].grantedCapabilities = manifest.grantedCapabilities
            records[index].grantedNetworkHosts = manifest.networkHosts
            records[index].grantedSecretNames = manifest.secretDeclarations.map(\.name)
            records[index].grantedBackground = manifest.background != nil
            records[index].grantedCLI = manifest.cli
            if let transcriptProjectKeys {
                records[index].transcriptProjectKeys = transcriptProjectKeys
            }
            records[index].enabled = true
        } else {
            records[index].enabled = false
        }
        save(records)
    }

    /// Always allow one action kind, or back to asking first (ABS-92).
    /// Only a granted action kind can be always allowed.
    public func setAlwaysAllowed(_ pluginId: String, _ capability: PluginCapability, _ allowed: Bool) {
        var records = records()
        guard let index = records.firstIndex(where: { $0.id == pluginId }),
              capability.asksFirst else { return }
        if allowed, records[index].grantedCapabilities.contains(capability) {
            records[index].alwaysAllowedActions.insert(capability)
        } else {
            records[index].alwaysAllowedActions.remove(capability)
        }
        save(records)
    }

    /// Takes one grant back, without turning the plugin off (ABS-92).
    /// Turning it off and on again reviews the whole list anew.
    public func revokeCapability(_ pluginId: String, _ capability: PluginCapability) {
        var records = records()
        guard let index = records.firstIndex(where: { $0.id == pluginId }) else { return }
        records[index].grantedCapabilities.remove(capability)
        records[index].alwaysAllowedActions.remove(capability)
        if capability == .network { records[index].grantedNetworkHosts = [] }
        if capability == .secrets { records[index].grantedSecretNames = [] }
        if capability == .transcriptsRead { records[index].transcriptProjectKeys = [] }
        if capability == .cli { records[index].grantedCLI = nil }
        save(records)
    }

    /// Changes which projects' messages the plugin may read, without
    /// turning it off first.
    public func setTranscriptProjectKeys(_ pluginId: String, _ keys: [String]) {
        var records = records()
        guard let index = records.firstIndex(where: { $0.id == pluginId }) else { return }
        records[index].transcriptProjectKeys = keys
        save(records)
    }

    /// A changed package, reviewed again: the new files become the record,
    /// still off until it's enabled.
    public func reviewChangedPackage(_ pluginId: String) {
        var records = records()
        guard let index = records.firstIndex(where: { $0.id == pluginId }),
              let inspection = try? PluginPackage.inspect(folder: packageURL(for: records[index])) else { return }
        records[index].packageHash = inspection.hash
        records[index].name = inspection.manifest.name
        records[index].enabled = false
        records[index].grantedCapabilities = []
        records[index].alwaysAllowedActions = []
        records[index].grantedNetworkHosts = []
        records[index].grantedSecretNames = []
        records[index].transcriptProjectKeys = []
        records[index].grantedBackground = false
        records[index].grantedCLI = nil
        save(records)
    }

    /// Deletes the package, the record and the plugin's storage.
    public func remove(_ pluginId: String, fileManager fm: FileManager = .default) {
        var records = records()
        if let record = records.first(where: { $0.id == pluginId }) {
            try? fm.removeItem(at: pluginsRoot.appendingPathComponent(record.id))
        }
        records.removeAll { $0.id == pluginId }
        save(records)
        storage(for: pluginId).removeAll()
        networkLog(for: pluginId).removeAll()
        var switches = switches()
        switches.forget(pluginId: pluginId)
        saveSwitches(switches)
    }

    // MARK: Pull Request switches (ABS-109)

    public static let switchesKey = "plugins.switches.v1"

    public func switches() -> PluginSwitches {
        store.setting(Self.switchesKey, as: PluginSwitches.self) ?? PluginSwitches()
    }

    public func setSwitch(pluginId: String, contributionId: String, chatId: String, on: Bool) {
        var switches = switches()
        switches.set(pluginId: pluginId, contributionId: contributionId, chatId: chatId, on: on)
        saveSwitches(switches)
    }

    private func saveSwitches(_ switches: PluginSwitches) {
        try? store.setSetting(Self.switchesKey, switches)
    }

    public func noteError(_ pluginId: String, _ message: String?) {
        var records = records()
        guard let index = records.firstIndex(where: { $0.id == pluginId }) else { return }
        records[index].lastError = message
        save(records)
    }

    /// Plugin folders bundled with the app, offered through the same
    /// install button as any other.
    public static func bundledFolders(in resources: URL?, fileManager fm: FileManager = .default) -> [URL] {
        guard let root = resources?.appendingPathComponent("Plugins"),
              let children = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        return children.filter { fm.fileExists(atPath: $0.appendingPathComponent("manifest.json").path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

/// Which chats each plugin's Pull Request switches are on for (ABS-109).
/// The host keeps them, so the tab shows them whether or not the plugin's
/// script is running; the script is told each time one flips.
public struct PluginSwitches: Sendable, Hashable, Codable {
    /// `pluginId:contributionId` to the chats it's on for.
    public private(set) var on: [String: Set<String>] = [:]

    public init() {}

    static func key(_ pluginId: String, _ contributionId: String) -> String { "\(pluginId):\(contributionId)" }

    public func isOn(pluginId: String, contributionId: String, chatId: String) -> Bool {
        on[Self.key(pluginId, contributionId)]?.contains(chatId) ?? false
    }

    public mutating func set(pluginId: String, contributionId: String, chatId: String, on isOn: Bool) {
        let key = Self.key(pluginId, contributionId)
        var chats = on[key] ?? []
        if isOn { chats.insert(chatId) } else { chats.remove(chatId) }
        on[key] = chats.isEmpty ? nil : chats
    }

    public mutating func forget(pluginId: String) {
        on = on.filter { !$0.key.hasPrefix(pluginId + ":") }
    }

    /// Every switch that's on, for the plugins given.
    public func switchesOn(pluginIds: Set<String>) -> [(pluginId: String, contributionId: String, chatId: String)] {
        on.keys.sorted().flatMap { key -> [(pluginId: String, contributionId: String, chatId: String)] in
            guard let pluginId = pluginIds.first(where: { key.hasPrefix($0 + ":") }) else { return [] }
            let contributionId = String(key.dropFirst(pluginId.count + 1))
            return (on[key] ?? []).sorted().map { (pluginId, contributionId, $0) }
        }
    }
}
