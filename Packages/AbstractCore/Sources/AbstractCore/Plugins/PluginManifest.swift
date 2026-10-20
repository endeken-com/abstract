import Foundation

/// A capability a plugin may ask for (API 1). The list is closed: an unknown
/// string fails the install, so a plugin built for a newer host is never
/// half-granted. See docs/spikes/ABS-84.md §4.
public enum PluginCapability: String, Sendable, Hashable, Codable, CaseIterable {
    case projectsRead = "projects.read"
    case chatsRead = "chats.read"
    case chatsOpen = "chats.open"
    case storageOwn = "storage.own"
    case usageRead = "usage.read"
    case turnsRead = "turns.read"
    case transcriptsRead = "transcripts.read"
    case automationsRead = "automations.read"

    /// The sentence shown when the person reviews the plugin.
    public var plainWords: String {
        switch self {
        case .projectsRead: "See your projects' names"
        case .chatsRead: "See your chats' titles, agents and progress"
        case .chatsOpen: "Open a chat when you click it"
        case .storageOwn: "Remember its own settings on this Mac"
        case .usageRead: "See what your chats used and cost"
        case .turnsRead: "See when your agents worked"
        case .transcriptsRead: "Read your chats' messages in the projects you pick"
        case .automationsRead: "See your automations and when they last ran"
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

    /// The place in plain words, for the review screen.
    public var plainWords: String {
        switch self {
        case .main: "Its own screen in the sidebar"
        case .chatPanel: "A tab in a chat's side panel, next to Review, Files and Terminal"
        case .chatMenu: "An item in a chat's More menu"
        case .palette: "A command in ⌘K"
        case .settings: "A page under Settings → Plugins"
        case .home: "A card on the Home screen"
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
    public init(place: PluginPlace, contributionId: String, chatId: String? = nil) {
        self.place = place; self.contributionId = contributionId; self.chatId = chatId
    }
}

/// A menu item or ⌘K command being run: the host opens the plugin's screen
/// and hands it this, so the plugin can act on the chat it was run from.
public struct PluginInvocation: Sendable, Hashable, Codable {
    public var place: PluginPlace
    public var contributionId: String
    public var chatId: String?
    public init(place: PluginPlace, contributionId: String, chatId: String? = nil) {
        self.place = place; self.contributionId = contributionId; self.chatId = chatId
    }
    public func jsonValue() -> JSONValue {
        var object: [String: JSONValue] = ["place": .string(place.rawValue),
                                           "contributionId": .string(contributionId)]
        if let chatId { object["chatId"] = .string(chatId) }
        return .object(object)
    }
}

/// A plugin's `manifest.json` (API 1). Unknown keys are ignored.
public struct PluginManifest: Sendable, Hashable, Codable {
    public static let supportedAPI = 1
    public static let fallbackSymbol = "puzzlepiece.extension"

    public var api: Int
    public var id: String
    public var name: String
    public var version: String
    public var description: String?
    public var entry: String
    /// As written in the manifest, before validation.
    public var capabilities: [String]
    public var contributes: Contributes

    /// One thing a plugin adds outside its sidebar screen: a tab, a menu
    /// item, a ⌘K command, its Settings page, or a Home card.
    public struct Contribution: Sendable, Hashable, Codable, Identifiable {
        public var id: String
        public var title: String
        public var symbol: String?
        public init(id: String, title: String, symbol: String? = nil) {
            self.id = id; self.title = title; self.symbol = symbol
        }
        public var symbolOrFallback: String {
            symbol.flatMap { $0.isEmpty ? nil : $0 } ?? PluginManifest.fallbackSymbol
        }
    }

    public struct Contributes: Sendable, Hashable, Codable {
        public var views: [View]
        public var chatPanelTabs: [Contribution]
        public var chatMenuItems: [Contribution]
        public var paletteCommands: [Contribution]
        public var settingsPage: Contribution?
        public var homeWidgets: [Contribution]

        public init(views: [View] = [], chatPanelTabs: [Contribution] = [], chatMenuItems: [Contribution] = [],
                    paletteCommands: [Contribution] = [], settingsPage: Contribution? = nil,
                    homeWidgets: [Contribution] = []) {
            self.views = views; self.chatPanelTabs = chatPanelTabs; self.chatMenuItems = chatMenuItems
            self.paletteCommands = paletteCommands; self.settingsPage = settingsPage; self.homeWidgets = homeWidgets
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
                capabilities: [String], views: [View] = [],
                chatPanelTabs: [Contribution] = [], chatMenuItems: [Contribution] = [],
                paletteCommands: [Contribution] = [], settingsPage: Contribution? = nil,
                homeWidgets: [Contribution] = []) {
        self.api = api; self.id = id; self.name = name; self.version = version
        self.description = description; self.entry = entry
        self.capabilities = capabilities
        self.contributes = Contributes(views: views, chatPanelTabs: chatPanelTabs, chatMenuItems: chatMenuItems,
                                       paletteCommands: paletteCommands, settingsPage: settingsPage, homeWidgets: homeWidgets)
    }

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
        ]
        for (place, items) in places {
            sentences += items.map { sentence($0.title, place) }
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

    /// Fails closed on anything outside API 1 (ABS-84 §3).
    public func validate() throws {
        guard api == Self.supportedAPI else {
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
        for name in capabilities where PluginCapability(rawValue: name) == nil {
            throw PluginValidationError.unknownCapability(name)
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
        }
        let total = contributes.views.count + places.map(\.1.count).reduce(0, +)
        guard total > 0 else {
            throw PluginValidationError.invalidManifest("the plugin doesn't add anything")
        }
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
