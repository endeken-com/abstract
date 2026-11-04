import Foundation

// Agents are plugin contributions (ABS-185, docs/spikes/ABS-185.md). The
// declaration follows Paseo's `ProviderRegistration` (`id`, `label`, `icon`,
// a default `command`) and its capability negotiation
// (packages/plugin/src/server/provider.ts in getpaseo/paseo, Apache-2.0; see
// THIRD_PARTY_NOTICES.md). What differs: the plugin never spawns anything.
// Its agent script returns launch arguments and stdin lines; the host runs
// the declared program through the chat's executor and hands the script each
// output line to turn into `AgentEvent`s.

/// One agent in a plugin's `contributes.agents`.
public struct PluginAgentDeclaration: Sendable, Hashable, Codable, Identifiable {
    /// The id chats store, like `opencode`.
    public var id: String
    public var label: String
    /// A package-relative SVG, as Paseo's `icon`.
    public var icon: String?
    /// An app asset for the logo, used by Abstract's own agent plugins.
    public var asset: String?
    /// The program and the arguments every run starts with, as Paseo's
    /// `command`. The program is a plain name on the login shell's PATH,
    /// never a shell or an interpreter, and the only thing the agent runs.
    public var command: [String]
    /// How to install it, shown when it isn't.
    public var install: String?
    /// The arguments that print its version, to find it.
    public var detect: [String]?
    /// What the agent can do, from `PluginAgentDeclaration.capabilities`.
    /// Abstract offers the ones it knows; anything else is left out.
    public var capabilities: [String]?
    /// How it takes library skills (ABS-122): `addedDirectory`, `codexHome`
    /// or `skillsPath`.
    public var skills: String?
    /// How much of a project's MCP servers it can take (ABS-123): `none`,
    /// `allowOrOff` or `askFirst`.
    public var toolServers: String?
    /// Abstract's own `/` commands it gets, and its commands they replace.
    public var commands: [String]?
    public var replaces: [String: String]?
    /// `/compact` sent as a turn; nil compacts through the script's
    /// `compact` job, when it has the `compaction` capability.
    public var compactPrompt: String?
    /// Files under the home folder the script may read, for the model and
    /// effort the CLI uses by default (`.config/opencode/opencode.json`).
    public var config: [String]?

    public init(id: String, label: String, icon: String? = nil, asset: String? = nil, command: [String],
                install: String? = nil, detect: [String]? = nil, capabilities: [String]? = nil, skills: String? = nil,
                toolServers: String? = nil, commands: [String]? = nil, replaces: [String: String]? = nil,
                compactPrompt: String? = nil, config: [String]? = nil) {
        self.id = id; self.label = label; self.icon = icon; self.asset = asset; self.command = command
        self.install = install; self.detect = detect; self.capabilities = capabilities; self.skills = skills
        self.toolServers = toolServers; self.commands = commands; self.replaces = replaces
        self.compactPrompt = compactPrompt; self.config = config
    }

    /// What an agent can declare, after Paseo's `PROVIDER_CAPABILITIES`,
    /// in Abstract's terms. Each turns on one part of the agent contract;
    /// without it Abstract says the agent can't (ABS-23).
    public static let knownCapabilities: [String] = [
        "prompt.message",     // it takes a prompt (required)
        "prompt.image",       // images ride with the prompt
        "prompt.steer",       // follow-ups go to the live process's stdin; else each turn respawns
        "interrupt",          // a stdin line ends the turn and keeps the agent
        "permission",         // Abstract answers its permission requests on stdin
        "permission.mode",    // the permission mode changes live
        "session.persistence",// a later turn resumes the conversation
        "task.stop",          // one of its background tasks can be stopped
        "task.background",    // running work can move to the background
        "naming",             // it can name chats
        "compaction",         // `/compact`
        "models.discover",    // it lists the account's models
        "lines.enrich",       // it fills in its lines before they're logged
    ]

    /// Paseo's `negotiateProviderCapabilities`: what both sides know, once each.
    public static func negotiate(offered: [String], supported: [String]) -> [String] {
        let known = Set(supported)
        var seen = Set<String>()
        return offered.filter { known.contains($0) && seen.insert($0).inserted }
    }

    public var negotiatedCapabilities: Set<String> {
        Set(Self.negotiate(offered: capabilities ?? [], supported: Self.knownCapabilities))
    }

    public var binary: String { command.first ?? "" }

    static let skillValues: Set<String> = ["addedDirectory", "codexHome", "skillsPath"]
    static let toolServerValues: Set<String> = ["none", "allowOrOff", "askFirst"]

    func validate() throws {
        func refuse(_ why: String) -> PluginValidationError { .invalidManifest("agent \(id): \(why)") }
        guard !id.isEmpty, id.count <= 32, id.first?.isLetter == true,
              id.allSatisfy({ ($0.isLowercase && $0.isASCII) || $0.isNumber || $0 == "-" }) else {
            throw PluginValidationError.invalidManifest("an agent needs an id of lowercase letters, digits and -")
        }
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= 40 else { throw refuse("needs a label of at most 40 characters") }
        guard let program = command.first, PluginCLI.isWord(program, allowDots: true),
              !PluginCLI.refusedBinaries.contains(program.lowercased()) else {
            throw refuse("command must start with a plain program name, not a path, shell or interpreter")
        }
        guard command.count <= 8, command.allSatisfy({ !$0.isEmpty && $0.count <= 64 }) else {
            throw refuse("command is too long")
        }
        if let icon {
            guard icon.hasSuffix(".svg"), PluginPackage.isContained(relativePath: icon) else {
                throw refuse("icon must be an SVG inside the package")
            }
        }
        guard (install?.count ?? 0) <= PluginCLI.installLimit else { throw refuse("install is too long") }
        guard (detect ?? []).count <= 4, (detect ?? []).allSatisfy({ !$0.isEmpty && $0.count <= 40 }) else {
            throw refuse("detect takes up to four short arguments")
        }
        let declared = capabilities ?? []
        guard declared.contains("prompt.message") else { throw refuse("needs the prompt.message capability") }
        // One this host doesn't know is left out, as Paseo negotiates: a
        // plugin for a newer Abstract still runs, without that part.
        if let skills, !Self.skillValues.contains(skills) { throw refuse("unknown skills delivery \(skills)") }
        if let toolServers, !Self.toolServerValues.contains(toolServers) { throw refuse("unknown toolServers \(toolServers)") }
        for name in (commands ?? []) + Array((replaces ?? [:]).values) where AppCommand(rawValue: name) == nil {
            throw refuse("unknown command \(name)")
        }
        guard (config ?? []).count <= 4, (config ?? []).allSatisfy({ PluginPackage.isContained(relativePath: $0) }) else {
            throw refuse("config names up to four files inside the home folder")
        }
    }

    /// The review sentence: the program it runs is named.
    var sentence: String {
        "\(label) — an agent for your chats, which runs \(binary) in their worktrees."
    }
}
