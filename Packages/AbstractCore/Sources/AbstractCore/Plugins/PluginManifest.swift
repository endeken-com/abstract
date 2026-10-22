import Foundation

/// A capability a plugin may ask for. The list is closed: an unknown
/// string fails the install, so a plugin built for a newer host is never
/// half-granted. See docs/spikes/ABS-84.md §4. The action capabilities
/// (ABS-92) arrived with API 2 and ask first, one kind at a time, until
/// the person always allows that kind.
public enum PluginCapability: String, Sendable, Hashable, Codable, CaseIterable {
    case projectsRead = "projects.read"
    case chatsRead = "chats.read"
    case chatsOpen = "chats.open"
    case storageOwn = "storage.own"
    case network = "network"
    case secrets = "secrets"
    case usageRead = "usage.read"
    case turnsRead = "turns.read"
    case transcriptsRead = "transcripts.read"
    case automationsRead = "automations.read"
    case chatsCreate = "chats.create"
    case chatsMessage = "chats.message"
    case chatsControl = "chats.control"
    case permissionsAnswer = "permissions.answer"
    case automationsRun = "automations.run"
    /// Add line comments to a chat's Review (ABS-112). Nothing reaches the
    /// agent until you send them, so it doesn't ask first.
    case reviewComment = "review.comment"
    /// Read a chat's pull request in full: its checks, reviews and
    /// comments, the way its Pull Request tab shows them (ABS-109).
    case pullRequestsRead = "pullRequests.read"
    /// Give agents the tools its manifest lists (ABS-97), run by its
    /// background script. Each project sets each tool Allowed, Ask first
    /// or Off.
    case agentTools = "agent.tools"
    /// Run the command-line tool its manifest names, with only the
    /// subcommands it lists (ABS-139). Writes ask first until always allowed.
    case cli = "cli"

    /// The capabilities that do something to a chat or an automation, as
    /// opposed to reading. Each asks first until always allowed.
    public static let actionCases: [PluginCapability] = [
        .chatsCreate, .chatsMessage, .chatsControl, .permissionsAnswer, .automationsRun,
    ]

    public var isAction: Bool { Self.actionCases.contains(self) }

    /// The kinds that ask first and that the person may always allow: the
    /// actions, and a CLI's write commands.
    public static let askingCases: [PluginCapability] = actionCases + [.cli]

    public var asksFirst: Bool { Self.askingCases.contains(self) }

    /// The sentence shown when the person reviews the plugin.
    public var plainWords: String {
        switch self {
        case .projectsRead: "See your projects' names"
        case .chatsRead: "See your chats' titles, agents and progress"
        case .chatsOpen: "Open a chat when you click it"
        case .storageOwn: "Remember its own settings on this Mac"
        case .network: "Reach the web addresses it lists"
        case .secrets: "Use the secrets you give it, without seeing them"
        case .usageRead: "See what your chats used and cost"
        case .turnsRead: "See when your agents worked"
        case .transcriptsRead: "Read your chats' messages in the projects you pick"
        case .automationsRead: "See your automations and when they last ran"
        case .chatsCreate: "Start chats in your projects"
        case .chatsMessage: "Send messages to your chats"
        case .chatsControl: "Stop and resume your agents"
        case .permissionsAnswer: "See and answer your agents' questions and permission requests, with what each one asks"
        case .automationsRun: "Run your automations"
        case .reviewComment: "Add comments to your chats' Review, for you to send or delete"
        case .pullRequestsRead: "Read your chats' pull requests: their checks, reviews and comments"
        case .agentTools: "Give your agents tools it runs, which ask you first until you allow them in a project's settings"
        case .cli: "Run the command-line tool it names, with only the commands it lists"
        }
    }

    /// The review sentence, with the picked projects named for
    /// `transcripts.read`. No projects picked means no messages at all.
    public func plainWords(transcriptProjects: [String]) -> String {
        guard self == .transcriptsRead else { return plainWords }
        guard !transcriptProjects.isEmpty else {
            return "Read your chats' messages in no projects yet"
        }
        return "Read your chats' messages in \(transcriptProjects.joined(separator: ", "))"
    }
}

/// Why a plugin package or manifest was refused, in words a person can read.
public enum PluginValidationError: Error, Sendable, Hashable, CustomStringConvertible {
    case invalidManifest(String)
    case unsupportedAPI(Int, plugin: String)
    case unknownCapability(String)
    case missingEntry(String)
    case escapingPath(String)
    case symlink(String)
    case executableFile(String)
    case tooLarge
    case missingPackage
    case changedSinceInstall
    case corruptStorage

    public var description: String {
        switch self {
        case .invalidManifest: "This plugin isn't a valid Abstract plugin."
        case .unsupportedAPI(_, let plugin): "\(plugin) needs a newer version of Abstract."
        case .unknownCapability: "This plugin isn't a valid Abstract plugin."
        case .missingEntry: "This plugin isn't a valid Abstract plugin."
        case .escapingPath, .symlink, .executableFile: "This plugin isn't a valid Abstract plugin."
        case .tooLarge: "This plugin isn't a valid Abstract plugin."
        case .missingPackage: "Its files are missing, so it's off."
        case .changedSinceInstall: "It changed since you installed it, so it's off."
        case .corruptStorage: "Its saved settings couldn't be read, so it's off."
        }
    }

    /// The detail, for tests and logs.
    public var detail: String {
        switch self {
        case .invalidManifest(let why): why
        case .unsupportedAPI(let api, _): "api \(api), this host supports \(PluginManifest.supportedAPI)"
        case .unknownCapability(let name): "unknown capability \(name)"
        case .missingEntry(let entry): "missing entry \(entry)"
        case .escapingPath(let path): "path escapes the package: \(path)"
        case .symlink(let path): "symlink in package: \(path)"
        case .executableFile(let path): "executable file in package: \(path)"
        case .tooLarge: "package over the size limit"
        case .missingPackage: "package folder missing"
        case .changedSinceInstall: "package hash mismatch"
        case .corruptStorage: "plugin storage unreadable"
        }
    }
}

/// Where a plugin can appear (ABS-96). Every place runs the same sandboxed
/// web view; what differs is the context the host hands it.
public enum PluginPlace: String, Sendable, Hashable, Codable, CaseIterable {
    case main
    case chatPanel
    case chatMenu
    case palette
    case settings
    case home
    /// A command in a chat's Review (ABS-112). Its background script is
    /// handed the run; nothing opens.
    case review
    /// A switch in a chat's Pull Request tab (ABS-109), on or off per
    /// chat. Its background script is told each time you flip it.
    case pullRequest
    /// A status after links in chats that match its patterns (ABS-126).
    /// Its background script is asked for each one; nothing opens.
    case link
    /// A section under Issue tracker in a project's settings (ABS-143),
    /// for an issue tracker's link to that project.
    case projectSettings

    /// The place in plain words, for the review screen.
    public var plainWords: String {
        switch self {
        case .main: "Its own screen in the sidebar"
        case .chatPanel: "A tab in a chat's side panel, next to Review, Files and Terminal"
        case .chatMenu: "An item in a chat's More menu"
        case .palette: "A command in ⌘K"
        case .settings: "A page under Settings → Plugins"
        case .home: "A card on the Home screen"
        case .review: "A command in a chat's Review"
        case .pullRequest: "A switch in a chat's Pull Request tab"
        case .link: "A status after links in your chats"
        case .projectSettings: "A section under Issue tracker in each project's settings"
        }
    }
}

/// Where one showing of a plugin sits, and the chat it sits beside when it
/// has one. The chat's id is the user's own target (they opened this tab or
/// menu item on that chat); the chat's details still need `chats.read`.
public struct PluginPlacement: Sendable, Hashable, Codable {
    public var place: PluginPlace
    public var contributionId: String
    public var chatId: String?
    /// The project whose settings a `projectSettings` section sits in
    /// (ABS-143): the user's own target, like `chatId`.
    public var projectKey: String?
    public init(place: PluginPlace, contributionId: String, chatId: String? = nil, projectKey: String? = nil) {
        self.place = place; self.contributionId = contributionId; self.chatId = chatId; self.projectKey = projectKey
    }
}

/// A menu item or ⌘K command being run: the host opens the plugin's screen
/// and hands it this, so the plugin can act on the chat it was run from.
public struct PluginInvocation: Sendable, Hashable, Codable {
    public var place: PluginPlace
    public var contributionId: String
    public var chatId: String?
    /// A Review command run for one agent: the one you picked (ABS-112).
    public var agentId: String?
    /// What the Review compared when you ran it: "uncommitted",
    /// "committed" or "commit <sha>".
    public var scope: String?
    /// A Pull Request switch you just flipped: on or off (ABS-109).
    public var on: Bool?
    public init(place: PluginPlace, contributionId: String, chatId: String? = nil,
                agentId: String? = nil, scope: String? = nil, on: Bool? = nil) {
        self.place = place; self.contributionId = contributionId; self.chatId = chatId
        self.agentId = agentId; self.scope = scope; self.on = on
    }
    public func jsonValue() -> JSONValue {
        var object: [String: JSONValue] = ["place": .string(place.rawValue),
                                           "contributionId": .string(contributionId)]
        if let chatId { object["chatId"] = .string(chatId) }
        if let agentId {
            object["agentId"] = .string(agentId)
            object["agentName"] = .string(ProviderRegistry.name(agentId))
        }
        if let scope { object["scope"] = .string(scope) }
        if let on { object["on"] = .bool(on) }
        return .object(object)
    }
}

/// A plugin's `manifest.json`. Unknown keys are ignored. API 1 plugins
/// keep working under API 2 (ABS-84 §3); only an API 2 manifest may ask
/// for action capabilities.
public struct PluginManifest: Sendable, Hashable, Codable {
    public static let supportedAPI = 2
    public static let supportedAPIs: Set<Int> = [1, 2]
    public static let fallbackSymbol = "puzzlepiece.extension"

    public var api: Int
    public var id: String
    public var name: String
    public var version: String
    public var description: String?
    public var entry: String
    /// As written in the manifest, before validation.
    public var capabilities: [String]
    public var network: Network?
    public var secrets: [Secret]?
    public var contributes: Contributes
    /// A script Abstract runs from launch while the plugin is on, with its
    /// screen closed (ABS-93): same sandbox, no page of its own.
    public var background: String?
    /// Tools it gives agents (ABS-97), under `agent.tools`.
    public var tools: [PluginAgentTool]?
    /// The command-line tool it runs (ABS-139), under `cli`.
    public var cli: PluginCLI?

    /// The exact hosts a plugin with `network` may reach (ABS-94). No
    /// wildcards: every host is shown at review and checked per request.
    public struct Network: Sendable, Hashable, Codable {
        public var hosts: [String]
        public init(hosts: [String]) { self.hosts = hosts }
    }

    /// One secret the user enters in Settings → Plugins (ABS-94). The
    /// plugin knows `name`; the value stays in the Keychain and is put
    /// into a request header by the host at send time.
    public struct Secret: Sendable, Hashable, Codable, Identifiable {
        public var name: String
        public var title: String
        public var id: String { name }
        public init(name: String, title: String) { self.name = name; self.title = title }
    }

    /// Lowercased, as hosts are case-insensitive.
    public var networkHosts: [String] { (network?.hosts ?? []).map { $0.lowercased() } }
    public var secretDeclarations: [Secret] { secrets ?? [] }

    /// One plain sentence per host and secret, for the review screen.
    public var networkSentences: [String] {
        networkHosts.map { "Reach \($0)." } + secretDeclarations.map { "Use your \($0.title), without seeing it." }
    }

    /// One thing a plugin adds outside its sidebar screen: a tab, a menu
    /// item, a ⌘K command, its Settings page, a Home card, a Review command
    /// or a Pull Request switch.
    public struct Contribution: Sendable, Hashable, Codable, Identifiable {
        public var id: String
        public var title: String
        public var symbol: String?
        /// The grants it can't work without (ABS-102). It shows only while
        /// the plugin holds every one, so revoking one hides it instead of
        /// leaving an item that fails when chosen.
        public var needs: [PluginCapability]?
        /// The links a link decorator follows (ABS-126), like
        /// `https://github.com/*/*/pull/*`. Only `linkDecorators` have them.
        public var patterns: [String]?
        public init(id: String, title: String, symbol: String? = nil, needs: [PluginCapability]? = nil,
                    patterns: [String]? = nil) {
            self.id = id; self.title = title; self.symbol = symbol; self.needs = needs; self.patterns = patterns
        }
        public var symbolOrFallback: String {
            symbol.flatMap { $0.isEmpty ? nil : $0 } ?? PluginManifest.fallbackSymbol
        }

        /// Whether a plugin holding `granted` can offer it.
        public func isOffered(granted: Set<PluginCapability>) -> Bool {
            Set(needs ?? []).isSubset(of: granted)
        }

        /// A Review command whose title holds `{agent}` is offered once per
        /// agent other than the chat's own, named in the title (ABS-112).
        public static let agentPlaceholder = "{agent}"
        public var isPerAgent: Bool { title.contains(Self.agentPlaceholder) }
        public func title(agentName: String) -> String {
            title.replacingOccurrences(of: Self.agentPlaceholder, with: agentName)
        }
    }

    public struct Contributes: Sendable, Hashable, Codable {
        public var views: [View]
        public var chatPanelTabs: [Contribution]
        public var chatMenuItems: [Contribution]
        public var paletteCommands: [Contribution]
        public var settingsPage: Contribution?
        public var homeWidgets: [Contribution]
        public var reviewActions: [Contribution]
        public var pullRequestSwitches: [Contribution]
        public var linkDecorators: [Contribution]
        /// Its section in each project's settings (ABS-143): only an issue
        /// tracker has one, to link the project to its team or project.
        public var projectSettings: Contribution?
        /// The issue tracker its background script answers for (ABS-141).
        public var issueTracker: PluginIssueTrackerDeclaration?
        /// The code host it answers for (ABS-139): core asks it for the
        /// pull requests of projects whose remote is on one of its hosts.
        public var codeHost: CodeHostDeclaration?

        public init(views: [View] = [], chatPanelTabs: [Contribution] = [], chatMenuItems: [Contribution] = [],
                    paletteCommands: [Contribution] = [], settingsPage: Contribution? = nil,
                    homeWidgets: [Contribution] = [], reviewActions: [Contribution] = [],
                    pullRequestSwitches: [Contribution] = [], linkDecorators: [Contribution] = [],
                    issueTracker: PluginIssueTrackerDeclaration? = nil,
                    codeHost: CodeHostDeclaration? = nil, projectSettings: Contribution? = nil) {
            self.projectSettings = projectSettings
            self.views = views; self.chatPanelTabs = chatPanelTabs; self.chatMenuItems = chatMenuItems
            self.paletteCommands = paletteCommands; self.settingsPage = settingsPage; self.homeWidgets = homeWidgets
            self.reviewActions = reviewActions; self.pullRequestSwitches = pullRequestSwitches
            self.linkDecorators = linkDecorators; self.issueTracker = issueTracker
            self.codeHost = codeHost
        }

        // Manifests written before the extra places carry only `views`.
        public init(from decoder: Decoder) throws {
            let box = try decoder.container(keyedBy: CodingKeys.self)
            views = try box.decodeIfPresent([View].self, forKey: .views) ?? []
            chatPanelTabs = try box.decodeIfPresent([Contribution].self, forKey: .chatPanelTabs) ?? []
            chatMenuItems = try box.decodeIfPresent([Contribution].self, forKey: .chatMenuItems) ?? []
            paletteCommands = try box.decodeIfPresent([Contribution].self, forKey: .paletteCommands) ?? []
            settingsPage = try box.decodeIfPresent(Contribution.self, forKey: .settingsPage)
            homeWidgets = try box.decodeIfPresent([Contribution].self, forKey: .homeWidgets) ?? []
            reviewActions = try box.decodeIfPresent([Contribution].self, forKey: .reviewActions) ?? []
            pullRequestSwitches = try box.decodeIfPresent([Contribution].self, forKey: .pullRequestSwitches) ?? []
            linkDecorators = try box.decodeIfPresent([Contribution].self, forKey: .linkDecorators) ?? []
            projectSettings = try box.decodeIfPresent(Contribution.self, forKey: .projectSettings)
            issueTracker = try box.decodeIfPresent(PluginIssueTrackerDeclaration.self, forKey: .issueTracker)
            codeHost = try box.decodeIfPresent(CodeHostDeclaration.self, forKey: .codeHost)
        }
    }

    public struct View: Sendable, Hashable, Codable, Identifiable {
        public var id: String
        public var title: String
        public var symbol: String?
        public var location: String
        public init(id: String, title: String, symbol: String? = nil, location: String = "main") {
            self.id = id; self.title = title; self.symbol = symbol; self.location = location
        }
        public var symbolOrFallback: String {
            symbol.flatMap { $0.isEmpty ? nil : $0 } ?? PluginManifest.fallbackSymbol
        }
    }

    public init(api: Int = supportedAPI, id: String, name: String, version: String,
                description: String? = nil, entry: String = "index.html",
                capabilities: [String], networkHosts: [String] = [], secrets: [Secret] = [],
                views: [View] = [],
                chatPanelTabs: [Contribution] = [], chatMenuItems: [Contribution] = [],
                paletteCommands: [Contribution] = [], settingsPage: Contribution? = nil,
                homeWidgets: [Contribution] = [], reviewActions: [Contribution] = [],
                pullRequestSwitches: [Contribution] = [], linkDecorators: [Contribution] = [],
                issueTracker: PluginIssueTrackerDeclaration? = nil,
                codeHost: CodeHostDeclaration? = nil,
                background: String? = nil, tools: [PluginAgentTool] = [], cli: PluginCLI? = nil) {
        self.api = api; self.id = id; self.name = name; self.version = version
        self.background = background
        self.tools = tools.isEmpty ? nil : tools
        self.cli = cli
        self.description = description; self.entry = entry
        self.capabilities = capabilities
        self.network = networkHosts.isEmpty ? nil : Network(hosts: networkHosts)
        self.secrets = secrets.isEmpty ? nil : secrets
        self.contributes = Contributes(views: views, chatPanelTabs: chatPanelTabs, chatMenuItems: chatMenuItems,
                                       paletteCommands: paletteCommands, settingsPage: settingsPage, homeWidgets: homeWidgets,
                                       reviewActions: reviewActions, pullRequestSwitches: pullRequestSwitches,
                                       linkDecorators: linkDecorators, issueTracker: issueTracker, codeHost: codeHost)
    }

    // A plugin that only runs in the background (ABS-93) may leave out
    // `contributes`.
    public init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        api = try box.decode(Int.self, forKey: .api)
        id = try box.decode(String.self, forKey: .id)
        name = try box.decode(String.self, forKey: .name)
        version = try box.decode(String.self, forKey: .version)
        description = try box.decodeIfPresent(String.self, forKey: .description)
        entry = try box.decode(String.self, forKey: .entry)
        capabilities = try box.decode([String].self, forKey: .capabilities)
        network = try box.decodeIfPresent(Network.self, forKey: .network)
        secrets = try box.decodeIfPresent([Secret].self, forKey: .secrets)
        contributes = try box.decodeIfPresent(Contributes.self, forKey: .contributes) ?? Contributes()
        background = try box.decodeIfPresent(String.self, forKey: .background)
        tools = try box.decodeIfPresent([PluginAgentTool].self, forKey: .tools)
        cli = try box.decodeIfPresent(PluginCLI.self, forKey: .cli)
    }

    public var agentTools: [PluginAgentTool] { tools ?? [] }

    /// Every place this plugin appears, one plain sentence each, for the
    /// review screen.
    public var appearanceSentences: [String] {
        func sentence(_ title: String, _ place: PluginPlace) -> String {
            let words = place.plainWords
            return "\(title) — \(words.prefix(1).lowercased())\(words.dropFirst())."
        }
        var sentences: [String] = contributes.views.map { sentence($0.title, .main) }
        let places: [(PluginPlace, [Contribution])] = [
            (.chatPanel, contributes.chatPanelTabs), (.chatMenu, contributes.chatMenuItems),
            (.palette, contributes.paletteCommands),
            (.settings, contributes.settingsPage.map { [$0] } ?? []), (.home, contributes.homeWidgets),
            (.review, contributes.reviewActions), (.pullRequest, contributes.pullRequestSwitches),
            (.projectSettings, contributes.projectSettings.map { [$0] } ?? []),
        ]
        for (place, items) in places {
            sentences += items.map { sentence($0.title(agentName: "another agent"), place) }
        }
        // Which links it is handed is part of what it sees, so the review names their sites.
        sentences += contributes.linkDecorators.map { decorator in
            "\(decorator.title) — a status after links to \(PluginLinks.sites(decorator.patterns ?? []).joined(separator: " and ")) in your chats."
        }
        if let tracker = contributes.issueTracker {
            sentences.append("\(tracker.title) issues — found by the composer's issue search, to attach to your messages.")
        }
        if background != nil {
            sentences.append("In the background — it runs while it's on, even with its screen closed.")
        }
        if !agentTools.isEmpty {
            let names = agentTools.map(\.name).joined(separator: ", ")
            sentences.append("Tools for your agents — \(names).")
        }
        if let codeHost = contributes.codeHost {
            sentences.append("Pull requests for \(codeHost.hosts.joined(separator: " and ")) — Abstract asks it for the pull requests, checks and merging of projects there.")
        }
        return sentences
    }

    /// The capabilities, once validated. Empty when one is unknown.
    public var grantedCapabilities: Set<PluginCapability> {
        Set(capabilities.compactMap(PluginCapability.init(rawValue:)))
    }

    public var view: View? { contributes.views.first }

    public static func decode(_ data: Data) throws -> PluginManifest {
        do {
            return try JSONDecoder().decode(PluginManifest.self, from: data)
        } catch {
            throw PluginValidationError.invalidManifest(String(describing: error))
        }
    }

    /// Fails closed on anything outside the supported APIs (ABS-84 §3).
    public func validate() throws {
        guard Self.supportedAPIs.contains(api) else {
            throw PluginValidationError.unsupportedAPI(api, plugin: name.isEmpty ? "This plugin" : "\(name) \(version)")
        }
        guard Self.isReverseDNS(id) else {
            throw PluginValidationError.invalidManifest("id is not reverse-DNS: \(id)")
        }
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw PluginValidationError.invalidManifest("empty name")
        }
        guard Self.isSemver(version) else {
            throw PluginValidationError.invalidManifest("version is not semver: \(version)")
        }
        guard !entry.isEmpty else { throw PluginValidationError.missingEntry(entry) }
        guard PluginPackage.isContained(relativePath: entry) else {
            throw PluginValidationError.escapingPath(entry)
        }
        if let background {
            guard background.hasSuffix(".js"), PluginPackage.isContained(relativePath: background) else {
                throw PluginValidationError.invalidManifest("background must be a .js file inside the package")
            }
        }
        for name in capabilities where PluginCapability(rawValue: name) == nil {
            throw PluginValidationError.unknownCapability(name)
        }
        // Actions are API 2: an API 1 plugin was reviewed as read-only,
        // so it doesn't gain them by listing a new string.
        if api < 2, grantedCapabilities.contains(where: { $0.isAction || $0 == .reviewComment || $0 == .agentTools }) {
            throw PluginValidationError.invalidManifest("action capabilities need api 2")
        }
        // Hosts and secrets exist only under their grants, and a grant with
        // nothing listed is meaningless (ABS-94). Fail closed both ways.
        let granted = grantedCapabilities
        guard networkHosts.count <= 16, Set(networkHosts).count == networkHosts.count,
              networkHosts.allSatisfy(Self.isExactHost) else {
            throw PluginValidationError.invalidManifest("network hosts must be exact hosts like api.slack.com, with no wildcards")
        }
        guard granted.contains(.network) == !networkHosts.isEmpty else {
            throw PluginValidationError.invalidManifest("network needs its exact hosts listed, and hosts need the network capability")
        }
        guard secretDeclarations.count <= 8,
              Set(secretDeclarations.map(\.name)).count == secretDeclarations.count,
              secretDeclarations.allSatisfy({
                  Self.isSecretName($0.name) && !$0.title.trimmingCharacters(in: .whitespaces).isEmpty && $0.title.count <= 60
              }) else {
            throw PluginValidationError.invalidManifest("secrets need a short name and title")
        }
        guard granted.contains(.secrets) == !secretDeclarations.isEmpty else {
            throw PluginValidationError.invalidManifest("secrets need their names listed, and listed secrets need the secrets capability")
        }
        guard contributes.views.count <= 1 else {
            throw PluginValidationError.invalidManifest("at most one view is supported")
        }
        if let view = contributes.views.first {
            guard view.location == "main" else {
                throw PluginValidationError.invalidManifest("unknown view location: \(view.location)")
            }
            guard Self.isSound(id: view.id, title: view.title) else {
                throw PluginValidationError.invalidManifest("view needs an id and a title of at most 40 characters")
            }
        }
        let places: [(String, [Contribution])] = [
            ("chatPanelTabs", contributes.chatPanelTabs), ("chatMenuItems", contributes.chatMenuItems),
            ("paletteCommands", contributes.paletteCommands), ("homeWidgets", contributes.homeWidgets),
            ("settingsPage", contributes.settingsPage.map { [$0] } ?? []),
            ("reviewActions", contributes.reviewActions),
            ("pullRequestSwitches", contributes.pullRequestSwitches),
            ("linkDecorators", contributes.linkDecorators),
            ("projectSettings", contributes.projectSettings.map { [$0] } ?? []),
        ]
        for (place, items) in places {
            guard items.count <= 8 else {
                throw PluginValidationError.invalidManifest("too many \(place)")
            }
            guard Set(items.map(\.id)).count == items.count else {
                throw PluginValidationError.invalidManifest("duplicate id in \(place)")
            }
            for item in items where !Self.isSound(id: item.id, title: item.title) {
                throw PluginValidationError.invalidManifest("\(place) entries need an id and a title of at most 40 characters")
            }
            // An entry can only need what the plugin asks for.
            for item in items where !Set(item.needs ?? []).isSubset(of: grantedCapabilities) {
                throw PluginValidationError.invalidManifest("\(place) entries can only need capabilities the plugin lists")
            }
        }
        // A Review command or a Pull Request switch is handled by the
        // background script: there is no screen to hand it to.
        guard contributes.reviewActions.isEmpty || background != nil else {
            throw PluginValidationError.invalidManifest("reviewActions need a background script")
        }
        guard contributes.pullRequestSwitches.isEmpty || background != nil else {
            throw PluginValidationError.invalidManifest("pullRequestSwitches need a background script")
        }
        guard contributes.linkDecorators.isEmpty || background != nil else {
            throw PluginValidationError.invalidManifest("linkDecorators need a background script")
        }
        // Patterns say which links the plugin is handed: only a link
        // decorator has them, and each is checked (ABS-126).
        for (place, items) in places where place != "linkDecorators" {
            guard items.allSatisfy({ $0.patterns == nil }) else {
                throw PluginValidationError.invalidManifest("only linkDecorators have patterns")
            }
        }
        for decorator in contributes.linkDecorators {
            let patterns = decorator.patterns ?? []
            guard !patterns.isEmpty, patterns.count <= PluginLinks.patternLimit,
                  patterns.allSatisfy({ PluginLinks.Pattern($0) != nil }) else {
                throw PluginValidationError.invalidManifest(
                    "linkDecorators need up to \(PluginLinks.patternLimit) patterns like https://github.com/*/*/pull/*")
            }
        }
        if let tracker = contributes.issueTracker {
            // The background script answers the composer's searches.
            guard background != nil else {
                throw PluginValidationError.invalidManifest("issueTracker needs a background script")
            }
            try tracker.validate()
        }
        guard contributes.projectSettings == nil || contributes.issueTracker != nil else {
            throw PluginValidationError.invalidManifest("projectSettings is for an issueTracker's link to a project")
        }
        try validateTools()
        try validateCLI()
        if let codeHost = contributes.codeHost {
            // Core's calls go to its background script.
            guard background != nil else { throw PluginValidationError.invalidManifest("codeHost needs a background script") }
            try codeHost.validate()
        }
        let total = contributes.views.count + places.map(\.1.count).reduce(0, +) + (contributes.issueTracker == nil ? 0 : 1)
        guard total > 0 || background != nil else {
            throw PluginValidationError.invalidManifest("the plugin doesn't add anything")
        }
    }

    /// Tools exist only under their grant, and the grant needs tools; the
    /// background script runs them (ABS-97).
    private func validateTools() throws {
        guard grantedCapabilities.contains(.agentTools) == !agentTools.isEmpty else {
            throw PluginValidationError.invalidManifest("agent.tools needs its tools listed, and tools need the agent.tools capability")
        }
        guard agentTools.isEmpty || background != nil else {
            throw PluginValidationError.invalidManifest("tools need a background script")
        }
        guard agentTools.count <= PluginTools.limit, Set(agentTools.map(\.name)).count == agentTools.count else {
            throw PluginValidationError.invalidManifest("at most \(PluginTools.limit) tools, each with its own name")
        }
        for tool in agentTools {
            guard tool.hasSoundName else {
                throw PluginValidationError.invalidManifest("a tool's name is up to \(PluginAgentTool.nameLimit) letters, digits, _ or -")
            }
            let description = tool.description.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !description.isEmpty, description.count <= PluginAgentTool.descriptionLimit else {
                throw PluginValidationError.invalidManifest("tool \(tool.name) needs a description")
            }
            if let schema = tool.inputSchema {
                guard schema["type"]?.string == "object", schema.compact().count <= PluginAgentTool.schemaLimit else {
                    throw PluginValidationError.invalidManifest("tool \(tool.name)'s inputSchema must be a small object schema")
                }
            }
        }
    }

    /// A CLI exists only under its grant, and the grant needs one; it is
    /// API 2, as its writes ask first like actions (ABS-139).
    private func validateCLI() throws {
        guard grantedCapabilities.contains(.cli) == (cli != nil) else {
            throw PluginValidationError.invalidManifest("cli needs its binary and commands listed, and a listed cli needs the cli capability")
        }
        guard let cli else { return }
        guard api >= 2 else { throw PluginValidationError.invalidManifest("cli needs api 2") }
        try cli.validate()
    }

    /// An exact host name: dotted labels only. No wildcard, scheme, port,
    /// path or userinfo — those would widen what was reviewed.
    public static func isExactHost(_ host: String) -> Bool {
        let host = host.lowercased()
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, host.count <= 253 else { return false }
        return labels.allSatisfy { label in
            !label.isEmpty && label.count <= 63 && !label.hasPrefix("-") && !label.hasSuffix("-")
                && label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
        }
    }

    static func isSecretName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 40
            && name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }
    }

    static func isSound(id: String, title: String) -> Bool {
        !id.isEmpty && !title.trimmingCharacters(in: .whitespaces).isEmpty && title.count <= 40
    }

    static func isReverseDNS(_ id: String) -> Bool {
        let parts = id.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        }
    }

    static func isSemver(_ version: String) -> Bool {
        let core = version.split(separator: "-").first.map(String.init) ?? version
        let parts = core.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 3 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }
}
