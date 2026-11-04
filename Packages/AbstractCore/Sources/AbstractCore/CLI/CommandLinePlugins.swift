import Foundation

/// A plugin `abstract plugin add` installed, as it prints it.
struct PluginAddJSON: Encodable {
    let id: String
    let name: String
    let version: String
    let repository: String
    let ref: String?
    let commit: String
    /// Off until it's reviewed in Settings → Plugins, unless it updated one
    /// that was on and asks for nothing new.
    let enabled: Bool
    /// Capability names the manifest asks for.
    let capabilities: [String]
    let message: String

    private enum Keys: String, CodingKey { case id, name, version, repository, ref, commit, enabled, capabilities, message }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(version, forKey: .version)
        try c.encode(repository, forKey: .repository)
        try c.encode(ref, forKey: .ref)
        try c.encode(commit, forKey: .commit)
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

    /// `abstract plugin add <source> [--ref <ref>]` (ABS-190): fetches the
    /// repository at that ref, checks the package as the app does, and
    /// installs it pinned to the commit — off, since what it may access is
    /// reviewed in the app when it's turned on.
    func addPlugin(_ text: String, ref: String?, fetcher: any PluginGitFetching) async throws -> PluginAddJSON {
        let source: PluginGitSource
        do { source = try PluginGitSource.parse(text, ref: ref) }
        catch { throw CLIError(.invalidArguments, error.localizedDescription) }
        let manager = plugins
        let candidate: PluginGitCandidate
        do { candidate = try await manager.inspectGit(source, fetcher: fetcher) }
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
            commit: candidate.source.commit ?? "", enabled: record.enabled,
            capabilities: manifest.capabilities.sorted(),
            message: record.enabled
                ? "\(record.name) is updated to \(candidate.source.shortCommit ?? "") and stays on."
                : "\(record.name) is installed at \(candidate.source.shortCommit ?? ""). Turn it on in Settings → Plugins, where you review what it can access.")
    }
}
