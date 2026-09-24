import Foundation

/// A custom binary or extra arguments for one agent, from Settings → Agents.
public struct ProviderOverride: Codable, Hashable, Sendable {
    public var path: String?
    public var extraArgs: [String]?

    public init(path: String? = nil, extraArgs: [String]? = nil) {
        self.path = path; self.extraArgs = extraArgs
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

    public init(providerOverrides: [String: ProviderOverride], outputStyle: OutputStyle, claudeProfile: String?,
                standardClaudeProfile: String = NSHomeDirectory() + "/.claude", attachmentsDirectory: String) {
        self.providerOverrides = providerOverrides; self.outputStyle = outputStyle; self.claudeProfile = claudeProfile
        self.standardClaudeProfile = standardClaudeProfile; self.attachmentsDirectory = attachmentsDirectory
    }

    /// As the app last saved them, for a launch that doesn't go through the app.
    public init(store: Store, dataDirectory: URL) {
        self.init(providerOverrides: store.setting("providerOverrides", as: [String: ProviderOverride].self) ?? [:],
                  outputStyle: store.setting("outputStyle", as: OutputStyle.self) ?? .default,
                  claudeProfile: store.setting("claudeProfile", as: String.self),
                  attachmentsDirectory: dataDirectory.appendingPathComponent("attachments").path)
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
                                binaryOverride: override?.path.flatMap { $0.isEmpty ? nil : $0 }, model: session.model,
                                effort: session.effort, outputStyle: settings.outputStyle, images: images,
                                readableDirs: [settings.attachmentsDirectory])
        var spec = resumeId.map { provider.buildResume(ctx, resumeId: $0) } ?? provider.buildLaunch(ctx)
        if provider.id == "claude", let profile = settings.claudeProfile, profile != settings.standardClaudeProfile {
            spec.env["CLAUDE_CONFIG_DIR"] = profile
        }
        return spec
    }
}
