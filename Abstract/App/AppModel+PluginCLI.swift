import AppKit
import Foundation
import AbstractCore

/// Plugins that run a command-line tool, and code hosts (ABS-139), from
/// the model's side: which folder and Mac a run happens on, and the code
/// host core asks for a project's pull requests.
extension AppModel {
    /// A project by its plugin key, here or on a paired Mac, with the
    /// executor its commands run through.
    func pluginProject(forKey key: String) -> (project: Project, executor: any Executor)? {
        let thisMac = remote.identity.id
        if let project = projects.first(where: { PluginSnapshot.projectKey(macId: thisMac, projectId: $0.id) == key }) {
            return (project, executor)
        }
        for device in remote.paired {
            if let project = remote.links[device.id]?.snapshot?.projects.first(where: {
                PluginSnapshot.projectKey(macId: device.id, projectId: $0.id) == key
            }) {
                return (project, remote.executor(for: device.id))
            }
        }
        return nil
    }

    /// The folder a chat's commands run in: its worktree, else its
    /// project's. A chat here whose worktree is gone (archived, merged and
    /// cleaned up) runs in its project's folder, as nothing starts in a
    /// folder that isn't there.
    func pluginFolder(chatId: String) -> String? {
        guard let session = session(chatId) else { return nil }
        let projectRoot = project(session.projectId)?.rootPath
        if let worktree = session.worktreePath, !worktree.isEmpty {
            let local = RemoteService.split(chatId) == nil
            if !local || FileManager.default.fileExists(atPath: worktree) || projectRoot == nil { return worktree }
        }
        return projectRoot
    }

    /// Runs one checked `cli.run` for a plugin: in the chat's or project's
    /// folder, through the executor of the Mac it lives on. `chats` and
    /// `projectKeys` are what the plugin can read now; the folder must be
    /// one of theirs.
    func runPluginCLI(_ request: PluginCLIRequest, cli: PluginCLI,
                      chats: Set<String>, projectKeys: Set<String>) async throws -> PluginCLIResult {
        var readable = chats.compactMap { pluginFolder(chatId: $0) }
        readable += projectKeys.compactMap { pluginProject(forKey: $0)?.project.rootPath }
        let cwd: String?
        let exec: any Executor
        if let chatId = request.chatId {
            guard let folder = pluginFolder(chatId: chatId) else { throw PluginCLIError.refused("That chat has no folder to run in.") }
            cwd = folder
            exec = executor(for: chatId)
        } else if let key = request.projectKey {
            guard let found = pluginProject(forKey: key) else { throw PluginCLIError.refused("That project isn't here any more.") }
            cwd = found.project.rootPath
            exec = found.executor
        } else {
            cwd = nil
            exec = executor
        }
        return try await PluginCLIRunner().run(request, cli: cli, executor: exec, cwd: cwd, readable: readable)
    }

    /// Where a write is about, for the Ask first sheet.
    func pluginCLIPlace(_ request: PluginCLIRequest) -> String? {
        if let chatId = request.chatId, let session = session(chatId) { return "in \(session.name)" }
        if let key = request.projectKey, let found = pluginProject(forKey: key) { return "in \(found.project.name)" }
        return nil
    }

    /// The command-line tools this Mac's enabled plugins hold: what a
    /// paired device may run here for them.
    var pluginCLIs: [PluginCLI] {
        plugins.usable.compactMap { $0.record.grantedCapabilities.contains(.cli) ? $0.record.grantedCLI : nil }
    }

    // MARK: Code hosts

    /// The code host for a remote, from the enabled plugins that declare
    /// one and whose script runs. Nil when none handles its host.
    func codeHost(remote: String?, context: CodeHostContext) -> CodeHost? {
        guard let background = pluginBackground else { return nil }
        let candidates = plugins.usable.compactMap { plugin -> CodeHosts.Candidate? in
            guard let declaration = plugin.manifest?.contributes.codeHost, background.isRunning(plugin.id) else { return nil }
            return CodeHosts.Candidate(pluginId: plugin.id, declaration: declaration,
                                       extraHosts: background.codeHostExtraHosts(plugin.id))
        }
        guard let match = CodeHosts.match(remote: remote, among: candidates) else { return nil }
        var placed = context
        placed.remote = remote
        placed.host = remote.flatMap(GitRemote.host)
        placed.repository = remote.flatMap(GitRemote.repository)
        return codeHost(pluginId: match.pluginId, declaration: match.declaration, context: placed)
    }

    /// One code host plugin, asked about `context`; an empty context asks
    /// on this Mac, in no folder.
    func codeHost(pluginId: String, declaration: CodeHostDeclaration, context: CodeHostContext) -> CodeHost {
        CodeHost(pluginId: pluginId, declaration: declaration) { [weak pluginBackground] op, input in
            guard let pluginBackground else { throw CodeHostError.unavailable("Abstract is closing.") }
            return try await pluginBackground.callCodeHost(pluginId, op: op, input: input, context: context).value()
        }
    }

    /// A project's plugin key: on this Mac, or the paired Mac it lives on.
    func pluginProjectKey(_ projectId: String) -> String {
        let mac = projects.contains { $0.id == projectId } ? remote.identity.id : remote.device(ofProject: projectId) ?? remote.identity.id
        return PluginSnapshot.projectKey(macId: mac, projectId: projectId)
    }
}
