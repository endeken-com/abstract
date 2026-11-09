import Foundation

/// The agents plugins add (ABS-185): Abstract's own, bundled with the app
/// and on by default, and any you install. Each plugin's script is loaded
/// once, the first time one of its agents is needed.
public final class AgentPlugins: @unchecked Sendable {
    public static let shared = AgentPlugins()

    /// Abstract's own agent plugins, in the order the app lists agents.
    public static let bundledPluginIds = ["sh.abstract.agent.claude", "sh.abstract.agent.codex",
                                          "sh.abstract.agent.opencode", "sh.abstract.agent.muse",
                                          "sh.abstract.agent.gemini"]

    private let lock = NSLock()
    private var bundledAgents: [ScriptedProvider]?
    /// The usable installed plugins' agents, once the app or `abstract` has
    /// said what's installed. Until then, the bundled ones.
    private var installedAgents: [ScriptedProvider]?
    /// Scripts by the folder they were read from.
    private var scripts: [String: AgentScript] = [:]
    private var folders: [URL]?

    init(folders: [URL]? = nil) { self.folders = folders }

    /// The agents to offer: the installed ones when known, else the bundled.
    public var agents: [ScriptedProvider] {
        lock.lock(); defer { lock.unlock() }
        return installedAgents ?? loadBundled()
    }

    /// Every agent there is to read a chat with, a bundled one turned off
    /// included, so an old chat still reads back.
    public func anyAgent(_ id: String) -> ScriptedProvider? {
        lock.lock(); defer { lock.unlock() }
        return (installedAgents ?? []).first { $0.id == id } ?? loadBundled().first { $0.id == id }
    }

    /// What's installed now; only plugins that are on and hold the `agents`
    /// grant count. A bundled agent never offered yet (Abstract hasn't
    /// installed its defaults on this Mac) counts as on; one you turned off
    /// or removed doesn't. A bundled agent's id can't be taken by another plugin.
    public func setInstalled(_ plugins: [InstalledPlugin], offered: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        let usable = plugins.filter { $0.isUsable && $0.record.grantedCapabilities.contains(.agents) }
        let loaded = usable.flatMap { plugin -> [ScriptedProvider] in
            guard let manifest = plugin.manifest else { return [] }
            return load(folder: plugin.packageURL, manifest: manifest)
        }
        let recorded = Set(plugins.map(\.id))
        let unoffered = loadBundled().filter { !recorded.contains($0.pluginId) && !offered.contains($0.pluginId) }
        installedAgents = Self.ordered(loaded + unoffered, reserved: Set(loadBundled().map(\.id)))
    }

    /// What `manager` has installed, as above.
    public func setInstalled(from manager: PluginManager) {
        setInstalled(manager.installed(saving: false), offered: manager.offeredDefaults)
    }

    /// Back to the bundled agents alone, as before anything was installed.
    public func reset(folders: [URL]? = nil) {
        lock.lock(); defer { lock.unlock() }
        installedAgents = nil
        if let folders { self.folders = folders; bundledAgents = nil }
    }

    private func loadBundled() -> [ScriptedProvider] {
        if let bundledAgents { return bundledAgents }
        let found = (folders ?? Self.bundledFolders()).flatMap { folder -> [ScriptedProvider] in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")),
                  let manifest = try? PluginManifest.decode(data), (try? manifest.validate()) != nil,
                  Self.bundledPluginIds.contains(manifest.id) else { return [] }
            return load(folder: folder, manifest: manifest)
        }
        let agents = Self.ordered(found, reserved: [])
        bundledAgents = agents
        return agents
    }

    private func load(folder: URL, manifest: PluginManifest) -> [ScriptedProvider] {
        guard let file = manifest.agent, !manifest.contributes.agents.isEmpty else { return [] }
        let key = folder.standardizedFileURL.path + "#" + manifest.version
        let script: AgentScript
        if let kept = scripts[key] {
            script = kept
        } else {
            guard let source = try? String(contentsOf: folder.appendingPathComponent(file), encoding: .utf8) else { return [] }
            script = AgentScript(pluginId: manifest.id, folder: folder, source: source)
            scripts[key] = script
        }
        guard script.loadError == nil else { return [] }
        return manifest.contributes.agents.map { ScriptedProvider(declaration: $0, script: script) }
    }

    /// Bundled first in their order, then by label; one agent per id.
    static func ordered(_ agents: [ScriptedProvider], reserved: Set<String>) -> [ScriptedProvider] {
        var seen = Set<String>()
        let sorted = agents.sorted { a, b in
            let ia = bundledPluginIds.firstIndex(of: a.pluginId) ?? bundledPluginIds.count
            let ib = bundledPluginIds.firstIndex(of: b.pluginId) ?? bundledPluginIds.count
            return ia != ib ? ia < ib : a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        return sorted.filter { agent in
            let bundled = bundledPluginIds.contains(agent.pluginId)
            guard bundled || !reserved.contains(agent.id) else { return false }
            return seen.insert(agent.id).inserted
        }
    }

    /// Where the bundled plugins are: inside the app; beside `abstract` in
    /// the app's Helpers folder; `ABSTRACT_PLUGINS_DIR`; or, in a debug
    /// build, the repository the package was built from.
    static func bundledFolders() -> [URL] {
        var roots: [URL] = []
        if let resources = Bundle.main.resourceURL { roots.append(resources.appendingPathComponent("Plugins")) }
        if let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            roots.append(executable.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Resources/Plugins"))
        }
        if let dir = ProcessInfo.processInfo.environment["ABSTRACT_PLUGINS_DIR"], !dir.isEmpty {
            roots.append(URL(fileURLWithPath: dir))
        }
        #if DEBUG
        roots.append(URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Abstract/Resources/Plugins"))
        #endif
        var seen = Set<String>()
        return roots.flatMap { root -> [URL] in
            let children = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            return children.filter { $0.lastPathComponent.hasPrefix("agent-") && $0.pathExtension == "abstractplugin" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }.filter { seen.insert($0.lastPathComponent).inserted }
    }
}
