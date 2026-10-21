import Foundation
import AbstractCore

/// Plugin tools for agents (ABS-97), from the model's side: which tools
/// a chat's agent gets, answering its `abstract-plugins` server, and
/// running each call in the plugin's background script once the
/// project's setting allows it.
extension AppModel {
    /// Every usable plugin whose tools were reviewed and whose script
    /// can run them.
    func pluginToolOffers() -> [PluginToolOffer] {
        plugins.installed.compactMap { plugin in
            guard plugin.isUsable, plugin.record.grantedBackground,
                  plugin.record.grantedCapabilities.contains(.agentTools),
                  let manifest = plugin.manifest, !manifest.agentTools.isEmpty,
                  plugins.backgroundProblems[plugin.id] == nil else { return nil }
            return PluginToolOffer(pluginId: plugin.id, pluginName: manifest.name, tools: manifest.agentTools)
        }
    }

    /// Every plugin tool with this project's setting, Off ones too, for
    /// Project Settings.
    func pluginTools(in project: Project) -> [PublishedPluginTool] {
        PluginTools.all(pluginToolOffers(), project: project)
    }

    func setPluginToolMode(_ projectId: String, _ tool: PublishedPluginTool, _ mode: PluginToolMode) {
        updateProject(projectId) { project in
            var modes = project.pluginTools ?? [:]
            modes[tool.key] = mode == .default ? nil : mode
            project.pluginTools = modes.isEmpty ? nil : modes
        }
    }

    /// The command that serves a chat's plugin tools, when any plugin
    /// offers some to a project chat on this Mac. Given even when they're
    /// all Off now, so turning one on reaches a running chat.
    func pluginToolsCommand(for session: Session) -> String? {
        guard session.projectId != nil, !pluginToolOffers().isEmpty else { return nil }
        let tool = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/abstract").path
        return FileManager.default.isExecutableFile(atPath: tool) ? tool : nil
    }

    /// Lets each chat's plugin-tools server ask the app what to list and
    /// run its calls, while the app is open.
    func servePluginTools() {
        PluginToolLabels.shared.update(PluginTools.all(pluginToolOffers(), project: nil))
        pluginToolLink = PluginToolLink.Server(path: PluginToolLink.socketPath(storePath: storePath)) { [weak self] request in
            guard let self else { return PluginToolLink.Reply(text: "Abstract is quitting.", isError: true) }
            return await self.answerPluginTools(request)
        }
    }

    func answerPluginTools(_ request: PluginToolLink.Request) async -> PluginToolLink.Reply {
        let offers = pluginToolOffers()
        PluginToolLabels.shared.update(PluginTools.all(offers, project: nil))
        let session = session(request.chatId)
        let project = project(session?.projectId)
        switch request.op {
        case "list":
            return PluginToolLink.Reply(tools: PluginTools.published(offers, project: project).map(\.listing))
        case "call":
            guard let session, let project else {
                return PluginToolLink.Reply(text: "Plugin tools only work in a project's chats.", isError: true)
            }
            let arguments = request.arguments ?? .object([:])
            let tool: PublishedPluginTool
            switch PluginTools.route(request.name ?? "", among: PluginTools.all(offers, project: project)) {
            case .refused(let why):
                return PluginToolLink.Reply(text: why, isError: true)
            case .run(let allowed):
                tool = allowed
            case .ask(let asking):
                guard await askPluginTool(session.id, toolName: streamName(asking.name, providerId: session.providerId),
                                          input: arguments) else {
                    return PluginToolLink.Reply(text: "You declined \(asking.label) this time.", isError: true)
                }
                tool = asking
            }
            let outcome = await pluginBackground?.callTool(tool.pluginId, name: tool.tool.name, input: arguments,
                                                           chatId: session.id)
                ?? .failed("\(tool.pluginName) isn't running, so its tool can't answer.")
            switch outcome {
            case .result(let text): return PluginToolLink.Reply(text: text, isError: false)
            case .failed(let why): return PluginToolLink.Reply(text: why, isError: true)
            }
        default:
            return PluginToolLink.Reply(text: "Abstract doesn't know “\(request.op)”.", isError: true)
        }
    }

    /// The tool's name as the chat's agent reports the call, so the card
    /// lands on its row.
    private func streamName(_ name: String, providerId: String) -> String {
        providerId == "opencode" ? "\(PluginTools.serverName)_\(name)" : "mcp__\(PluginTools.serverName)__\(name)"
    }
}

/// The plugin a tool row's call belongs to, by the name agents call it,
/// for rows drawn outside the model.
final class PluginToolLabels: @unchecked Sendable {
    static let shared = PluginToolLabels()
    private let lock = NSLock()
    private var labels: [String: String] = [:]

    func update(_ tools: [PublishedPluginTool]) {
        let fresh = Dictionary(tools.map { ($0.name, $0.label) }, uniquingKeysWith: { first, _ in first })
        lock.withLock { labels.merge(fresh) { _, new in new } }
    }

    /// "Echo: echo" for a plugin tool's call under any agent's spelling;
    /// a plugin no longer installed reads by the name it had. Nil for
    /// any other tool.
    func label(_ streamName: String) -> String? {
        guard let name = PluginTools.toolName(inStreamName: streamName) else { return nil }
        if let known = lock.withLock({ labels[name] }) { return known }
        guard let split = name.firstIndex(of: "_") else { return name }
        return "\(name[..<split]): \(name[name.index(after: split)...])"
    }
}
