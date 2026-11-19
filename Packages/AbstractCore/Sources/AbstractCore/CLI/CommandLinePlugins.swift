import Foundation

/// One command an enabled issue tracker contributes to `abstract`.
struct PluginCommandJSON: Encodable {
    let plugin: String
    let name: String
    let command: String
}

/// The same project link the plugin's Project Settings page reads and saves.
struct PluginProjectLinkJSON: Encodable {
    let plugin: String
    let projectId: String
    let projectName: String
    let link: TrackerProjectLink?
}

/// A plugin `abstract plugin add` installed, as it prints it.
struct PluginAddJSON: Encodable {
    let id: String
    let name: String
    let version: String
    let repository: String
    let ref: String?
    let commit: String
    /// The registry listing it came from, `owner/slug`; null for a repository.
    let listing: String?
    /// Whether a person reviewed this exact commit (ABS-190).
    let reviewed: Bool
    /// Off until it's reviewed in Settings → Plugins, unless it updated one
    /// that was on and asks for nothing new.
    let enabled: Bool
    /// Capability names the manifest asks for.
    let capabilities: [String]
    let message: String

    private enum Keys: String, CodingKey { case id, name, version, repository, ref, commit, listing, reviewed, enabled, capabilities, message }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(version, forKey: .version)
        try c.encode(repository, forKey: .repository)
        try c.encode(ref, forKey: .ref)
        try c.encode(commit, forKey: .commit)
        try c.encode(listing, forKey: .listing)
        try c.encode(reviewed, forKey: .reviewed)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(capabilities, forKey: .capabilities)
        try c.encode(message, forKey: .message)
    }
}

extension Commands {
    /// The plugin folders beside this store, as the app keeps them.
    var plugins: PluginManager {
        let base = URL(fileURLWithPath: storePath).deletingLastPathComponent()
        return PluginManager(store: store, pluginsRoot: base.appendingPathComponent("Plugins"),
                             dataRoot: base.appendingPathComponent("PluginData"))
    }

    /// A tracker's existing `issueTracker` contribution makes these
    /// commands available while the plugin is enabled and reviewed. No
    /// tracker-specific executable or running app is needed to read or
    /// change its project link.
    func pluginCommands() -> [PluginCommandJSON] {
        let trackers = plugins.installed(saving: false).filter { plugin in
            plugin.isUsable && plugin.record.grantedBackground && plugin.manifest?.contributes.issueTracker != nil
        }
        return trackers.flatMap { plugin in
            let name = plugin.manifest?.name ?? plugin.id
            let suffix = plugin.id.split(separator: ".").last.map(String.init) ?? plugin.id
            let selector = trackers.filter {
                $0.id.split(separator: ".").last.map(String.init)?.caseInsensitiveCompare(suffix) == .orderedSame
            }.count == 1 ? suffix : plugin.id
            return ["project-link", "link-project", "unlink-project"].map { command in
                PluginCommandJSON(plugin: plugin.id, name: name, command: "abstract plugin \(selector) \(command)")
            }
        }
    }

    /// Accept a full id, or an unambiguous tracker name or id suffix.
    private func trackerPlugin(_ selector: String) throws -> InstalledPlugin {
        let installed = plugins.installed(saving: false)
        let exact = installed.filter { $0.id.caseInsensitiveCompare(selector) == .orderedSame }
        let matches = exact.isEmpty ? installed.filter { plugin in
            plugin.record.name.caseInsensitiveCompare(selector) == .orderedSame
                || plugin.id.split(separator: ".").last.map(String.init)?.caseInsensitiveCompare(selector) == .orderedSame
        } : exact
        guard !matches.isEmpty else {
            throw CLIError(.pluginFailed, "No installed plugin “\(selector)”. Use abstract plugin commands to see available commands.")
        }
        guard matches.count == 1, let plugin = matches.first else {
            throw CLIError(.invalidArguments, "Several plugins match “\(selector)”; use the full plugin id.")
        }
        guard plugin.isUsable, plugin.record.grantedBackground,
              plugin.manifest?.contributes.issueTracker != nil else {
            throw CLIError(.pluginFailed, "\(plugin.record.name) is not an enabled issue tracker plugin.")
        }
        return plugin
    }

    /// Without --project, the current folder identifies a project root or
    /// one of its active chat worktrees. A nested folder works as well.
    private func linkProject(_ reference: String?, cwd: String) throws -> Project {
        if let reference { return try resolveProject(reference) }
        let here = Self.canonical(cwd)
        let roots = try store.projects().filter { project in
            let root = Self.canonical(project.rootPath)
            return here == root || here.hasPrefix(root + "/")
        }
        if let match = roots.max(by: { Self.canonical($0.rootPath).count < Self.canonical($1.rootPath).count }) {
            return match
        }
        let worktrees = try store.sessions().compactMap { session -> (path: String, projectId: String)? in
            guard session.archivedAt == nil, let path = session.worktreePath, let projectId = session.projectId else { return nil }
            let root = Self.canonical(path)
            return here == root || here.hasPrefix(root + "/") ? (root, projectId) : nil
        }
        if let match = worktrees.max(by: { $0.path.count < $1.path.count }),
           let project = try store.project(match.projectId) {
            return project
        }
        throw CLIError(.projectNotFound, "No Abstract project contains the current folder. Run from a project or use --project <name|id|path>.")
    }

    func pluginProjectLink(plugin selector: String, project reference: String? = nil,
                           cwd: String = FileManager.default.currentDirectoryPath) throws -> PluginProjectLinkJSON {
        let plugin = try trackerPlugin(selector)
        let project = try linkProject(reference, cwd: cwd)
        return PluginProjectLinkJSON(plugin: plugin.id, projectId: project.id, projectName: project.name,
                                     link: TrackerProjectLink.read(plugins.storage(for: plugin.id), projectId: project.id))
    }

    func setPluginProjectLink(plugin selector: String, project reference: String? = nil, linkFile: String,
                              cwd: String = FileManager.default.currentDirectoryPath,
                              stdin: () -> Data) throws -> PluginProjectLinkJSON {
        let plugin = try trackerPlugin(selector)
        let project = try linkProject(reference, cwd: cwd)
        let data: Data
        if linkFile == "-" {
            data = stdin()
        } else {
            guard let contents = FileManager.default.contents(atPath: linkFile) else {
                throw CLIError(.invalidArguments, "Can't read \(linkFile) (--link-file).")
            }
            data = contents
        }
        guard data.count <= 16 * 1024, let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              let link = TrackerProjectLink(value) else {
            throw CLIError(.invalidArguments, "--link-file needs a JSON object with a workspace, team or project; targets need an id and name.")
        }
        guard TrackerProjectLink.write(link, to: plugins.storage(for: plugin.id), projectId: project.id) else {
            throw CLIError(.pluginFailed, "Couldn't save \(plugin.record.name)'s project link.")
        }
        StoreChanges.post(storePath: storePath)
        return PluginProjectLinkJSON(plugin: plugin.id, projectId: project.id, projectName: project.name, link: link)
    }

    func clearPluginProjectLink(plugin selector: String, project reference: String? = nil,
                                cwd: String = FileManager.default.currentDirectoryPath) throws -> PluginProjectLinkJSON {
        let plugin = try trackerPlugin(selector)
        let project = try linkProject(reference, cwd: cwd)
        guard TrackerProjectLink.write(nil, to: plugins.storage(for: plugin.id), projectId: project.id) else {
            throw CLIError(.pluginFailed, "Couldn't clear \(plugin.record.name)'s project link.")
        }
        StoreChanges.post(storePath: storePath)
        return PluginProjectLinkJSON(plugin: plugin.id, projectId: project.id, projectName: project.name, link: nil)
    }

    /// `abstract plugin add <source> [--ref <ref>]` (ABS-190): a registry
    /// listing's `owner/slug` installs its approved commit; a repository is
    /// fetched at that ref. Either is checked as the app checks a package
    /// and installed pinned to the commit — off, since what it may access
    /// is reviewed in the app when it's turned on.
    func addPlugin(_ text: String, ref: String?, fetcher: any PluginGitFetching,
                   registry: PluginRegistry?) async throws -> PluginAddJSON {
        let source: PluginGitSource
        do { source = try (registry ?? PluginRegistry(plugins: [])).source(for: text, ref: ref) }
        catch { throw CLIError(.invalidArguments, error.localizedDescription) }
        let manager = plugins
        let candidate: PluginGitCandidate
        do { candidate = try await manager.inspect(source, registry: registry, fetcher: fetcher) }
        catch let error as PluginValidationError { throw CLIError(.pluginFailed, error.description) }
        catch { throw CLIError(.pluginFailed, error.localizedDescription) }
        defer { try? FileManager.default.removeItem(at: candidate.cleanup) }
        let record: PluginRecord
        do { record = try manager.install(candidate) }
        catch let error as PluginValidationError { throw CLIError(.pluginFailed, error.description) }
        catch { throw CLIError(.pluginFailed, error.localizedDescription) }
        StoreChanges.post(storePath: storePath)
        let manifest = candidate.inspection.manifest
        return PluginAddJSON(
            id: record.id, name: record.name, version: record.version,
            repository: candidate.source.repository, ref: candidate.source.ref,
            commit: candidate.source.commit ?? "", listing: candidate.source.listing,
            reviewed: (registry ?? PluginRegistry(plugins: [])).isReviewed(candidate.source), enabled: record.enabled,
            capabilities: manifest.capabilities.sorted(),
            message: record.enabled
                ? "\(record.name) is updated to \(candidate.source.shortCommit ?? "") and stays on."
                : "\(record.name) is installed at \(candidate.source.shortCommit ?? ""). Turn it on in Settings → Plugins, where you review what it can access.")
    }
}
