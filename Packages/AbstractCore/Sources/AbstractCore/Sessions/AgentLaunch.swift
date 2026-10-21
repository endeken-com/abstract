import Foundation

/// A custom binary or extra arguments for one agent, from Settings → Agents.
public struct ProviderOverride: Codable, Hashable, Sendable {
    public var path: String?
    public var extraArgs: [String]?

    public init(path: String? = nil, extraArgs: [String]? = nil) {
        self.path = path; self.extraArgs = extraArgs
    }
}

/// Abstract's launch choices for one agent, from Settings → Agents. A nil
/// value leaves that choice to the agent's own configuration.
public struct AgentDefaults: Codable, Hashable, Sendable {
    public var model: String?
    public var effort: String?

    public init(model: String? = nil, effort: String? = nil) {
        self.model = model; self.effort = effort
    }
}

/// What serves a chat's code-history tool (ABS-61), when its project
/// gives agents that history: this Mac's `abstract` command, and the
/// instruction as a file for agents that read instructions from files.
public struct CodeHistorySettings: Sendable, Hashable {
    public var command: String
    public var instructionFile: String?

    public init(command: String, instructionFile: String? = nil) {
        self.command = command; self.instructionFile = instructionFile
    }

    /// Writes the instruction into `directory` (once per launch is fine:
    /// the text never changes) and names the file. Nil if it can't.
    public static func instructionFile(in directory: String) -> String? {
        let path = directory + "/code-history-instruction.md"
        do {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try (CodeHistory.instruction + "\n").write(toFile: path, atomically: true, encoding: .utf8)
            return path
        } catch { return nil }
    }
}

/// The settings every agent launch reads, wherever it starts: the app, or
/// `abstract` with the app closed.
public struct LaunchSettings: Sendable {
    public var providerOverrides: [String: ProviderOverride]
    public var outputStyle: OutputStyle
    /// The Claude profile (a `CLAUDE_CONFIG_DIR`) chats sign in with; nil is the standard one.
    public var claudeProfile: String?
    /// `~/.claude`: a chat on it needs no `CLAUDE_CONFIG_DIR`.
    public var standardClaudeProfile: String
    /// Where attachments are kept; agents may read it without asking.
    public var attachmentsDirectory: String
    /// By agent id: what a chat that chooses no model or effort runs with.
    public var agentDefaults: [String: AgentDefaults]
    /// By agent id: the models last discovered, which say what efforts each takes.
    public var modelCatalogs: [String: ModelCatalog]
    /// The code-history tool for this launch's chat, when its project
    /// gives agents that history; nil leaves the agent without it.
    public var codeHistory: CodeHistorySettings?
    /// The `abstract` command that serves this launch's plugin tools
    /// (ABS-97), when a plugin offers any; nil leaves the agent without.
    public var pluginToolsCommand: String?
    /// The MCP servers of the launch's project (ABS-123); each agent gets
    /// the ones chosen for it.
    public var toolServers: [ProjectToolServer]
    /// Where each chat's own launch files go (`ChatConfigFiles`); nil
    /// passes everything inline.
    public var agentConfigRoot: String?

    public init(providerOverrides: [String: ProviderOverride], outputStyle: OutputStyle, claudeProfile: String?,
                standardClaudeProfile: String = NSHomeDirectory() + "/.claude", attachmentsDirectory: String,
                agentDefaults: [String: AgentDefaults] = [:], modelCatalogs: [String: ModelCatalog] = [:],
                codeHistory: CodeHistorySettings? = nil, toolServers: [ProjectToolServer] = [], agentConfigRoot: String? = nil) {
        self.providerOverrides = providerOverrides; self.outputStyle = outputStyle; self.claudeProfile = claudeProfile
        self.standardClaudeProfile = standardClaudeProfile; self.attachmentsDirectory = attachmentsDirectory
        self.agentDefaults = agentDefaults; self.modelCatalogs = modelCatalogs; self.codeHistory = codeHistory
        self.toolServers = toolServers; self.agentConfigRoot = agentConfigRoot
    }

    /// As the app last saved them, for a launch that doesn't go through the app.
    public init(store: Store, dataDirectory: URL) {
        self.init(providerOverrides: store.setting("providerOverrides", as: [String: ProviderOverride].self) ?? [:],
                  outputStyle: store.setting("outputStyle", as: OutputStyle.self) ?? .default,
                  claudeProfile: store.setting("claudeProfile", as: String.self),
                  attachmentsDirectory: dataDirectory.appendingPathComponent("attachments").path,
                  agentDefaults: store.setting("agentDefaults", as: [String: AgentDefaults].self) ?? [:],
                  modelCatalogs: store.setting("modelCatalogs", as: [String: ModelCatalog].self) ?? [:],
                  agentConfigRoot: dataDirectory.appendingPathComponent("agent-config").path)
    }

    /// What `provider` gets of the project's MCP servers in `session`:
    /// only its own project's, only those chosen for it, and never one
    /// named like one of Abstract's own servers or an earlier one.
    func toolServers(for session: Session, provider: any ProviderDefinition) -> [MCPServerLaunch] {
        guard let projectId = session.projectId else { return [] }
        var taken: Set<String> = [CodeHistory.serverName, PluginTools.serverName]
        return toolServers.filter { $0.projectId == projectId }.compactMap { server in
            guard !server.name.isEmpty, ProjectToolServer.cleanName(server.name) == server.name,
                  taken.insert(server.name).inserted else { return nil }
            return server.launch(for: provider)
        }
    }

    /// The default effort, when the model that will run takes it; else nil,
    /// the agent's own. A chat's own effort is passed as chosen.
    func defaultEffort(for provider: any ProviderDefinition, model: String?, home: String) -> String? {
        guard let effort = agentDefaults[provider.id]?.effort else { return nil }
        let catalog = modelCatalogs[provider.id] ?? provider.fallbackModels
        let option = if let model { catalog.option(model) }
            else { catalog.defaultOption(configured: agentDefaults[provider.id]?.model ?? provider.configuredDefaultModel(home: home)) }
        return option?.efforts.contains(effort) == true ? effort : nil
    }
}

/// How a chat's agent is started, shared by the app and `abstract`.
public enum AgentLaunch {
    /// Exactly what to spawn for `session`'s agent: a fresh start, or
    /// resuming `resumeId`.
    public static func spec(for session: Session, provider: any ProviderDefinition, prompt: String, resumeId: String?,
                            images: [String] = [], settings: LaunchSettings, home: String) -> LaunchSpec {
        let override = settings.providerOverrides[provider.id]
        let ctx = LaunchContext(cwd: session.worktreePath ?? home, prompt: prompt,
                                permissionPolicy: session.permissionPolicy, extraArgs: override?.extraArgs ?? [],
                                binaryOverride: override?.path.flatMap { $0.isEmpty ? nil : $0 },
                                model: session.model ?? settings.agentDefaults[provider.id]?.model,
                                effort: session.effort ?? settings.defaultEffort(for: provider, model: session.model, home: home),
                                outputStyle: settings.outputStyle, images: images,
                                readableDirs: [settings.attachmentsDirectory],
                                historyTool: settings.codeHistory.map {
                                    HistoryToolLaunch(command: $0.command, chatId: session.id, instructionFile: $0.instructionFile)
                                },
                                instructions: session.profileInstructions,
                                pluginTools: settings.pluginToolsCommand.map {
                                    PluginToolsLaunch(command: $0, chatId: session.id)
                                },
                                toolServers: settings.toolServers(for: session, provider: provider),
                                configDirectory: settings.agentConfigRoot.map {
                                    ChatConfigFiles.directory(root: $0, chatId: session.id)
                                })
        var spec = resumeId.map { provider.buildResume(ctx, resumeId: $0) } ?? provider.buildLaunch(ctx)
        if provider.id == "claude", let profile = settings.claudeProfile, profile != settings.standardClaudeProfile {
            spec.env["CLAUDE_CONFIG_DIR"] = profile
        }
        return spec
    }
}
