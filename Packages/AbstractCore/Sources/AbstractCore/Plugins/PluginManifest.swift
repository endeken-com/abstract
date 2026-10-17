import Foundation

/// A capability a plugin may ask for (API 1). The list is closed: an unknown
/// string fails the install, so a plugin built for a newer host is never
/// half-granted. See docs/spikes/ABS-84.md §4.
public enum PluginCapability: String, Sendable, Hashable, Codable, CaseIterable {
    case projectsRead = "projects.read"
    case chatsRead = "chats.read"
    case chatsOpen = "chats.open"
    case storageOwn = "storage.own"

    /// The sentence shown when the person reviews the plugin.
    public var plainWords: String {
        switch self {
        case .projectsRead: "See your projects' names"
        case .chatsRead: "See your chats' titles, agents and progress"
        case .chatsOpen: "Open a chat when you click it"
        case .storageOwn: "Remember its own settings on this Mac"
        }
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

    public struct Contributes: Sendable, Hashable, Codable {
        public var views: [View]
        public init(views: [View]) { self.views = views }
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
                capabilities: [String], views: [View]) {
        self.api = api; self.id = id; self.name = name; self.version = version
        self.description = description; self.entry = entry
        self.capabilities = capabilities; self.contributes = Contributes(views: views)
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
        guard contributes.views.count == 1, let view = contributes.views.first else {
            throw PluginValidationError.invalidManifest("exactly one view is supported")
        }
        guard view.location == "main" else {
            throw PluginValidationError.invalidManifest("unknown view location: \(view.location)")
        }
        guard !view.id.isEmpty, !view.title.isEmpty, view.title.count <= 40 else {
            throw PluginValidationError.invalidManifest("view needs an id and a title of at most 40 characters")
        }
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
