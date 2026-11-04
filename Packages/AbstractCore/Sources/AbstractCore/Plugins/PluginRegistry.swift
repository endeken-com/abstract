import Foundation

/// The reviewed plugin registry (ABS-190): `registry.json` in
/// `endeken-com/abstract-plugins`. Each listing names a repository folder
/// and the exact commit a person reviewed; installing a listing installs
/// that commit and nothing else. Modelled on Paseo's registry
/// (`getpaseo/plugins`, Apache-2.0; see THIRD_PARTY_NOTICES.md).
public struct PluginRegistry: Sendable, Equatable {
    public static let url = URL(string: "https://raw.githubusercontent.com/endeken-com/abstract-plugins/main/registry.json")!
    public static let supportedFormat = 1

    public struct Entry: Sendable, Hashable, Identifiable, Codable {
        /// `owner/slug`, what `abstract plugin add` takes.
        public var id: String { "\(owner)/\(slug)" }
        public var owner: String
        public var slug: String
        public var name: String
        public var description: String
        /// The manifest id the approved package must carry.
        public var pluginId: String
        /// `owner/repo` on GitHub.
        public var repository: String
        /// The plugin's folder in the repository; absent is its root.
        public var path: String?
        /// The reviewed commit, all 40 characters.
        public var commit: String
        /// HTTPS images of the plugin, first one first.
        public var screenshots: [URL]
        public var reviewedAt: Date?

        public init(owner: String, slug: String, name: String, description: String, pluginId: String,
                    repository: String, path: String? = nil, commit: String, screenshots: [URL] = [],
                    reviewedAt: Date? = nil) {
            self.owner = owner; self.slug = slug; self.name = name; self.description = description
            self.pluginId = pluginId; self.repository = repository; self.path = path; self.commit = commit
            self.screenshots = screenshots; self.reviewedAt = reviewedAt
        }

        private enum CodingKeys: String, CodingKey {
            case owner, slug, name, description, pluginId, repository, path, commit, screenshots, reviewedAt
        }

        public init(from decoder: Decoder) throws {
            let box = try decoder.container(keyedBy: CodingKeys.self)
            owner = try box.decode(String.self, forKey: .owner)
            slug = try box.decode(String.self, forKey: .slug)
            name = try box.decode(String.self, forKey: .name)
            description = try box.decode(String.self, forKey: .description)
            pluginId = try box.decode(String.self, forKey: .pluginId)
            repository = try box.decode(String.self, forKey: .repository)
            path = try box.decodeIfPresent(String.self, forKey: .path)
            commit = try box.decode(String.self, forKey: .commit)
            screenshots = try box.decodeIfPresent([URL].self, forKey: .screenshots) ?? []
            reviewedAt = try box.decodeIfPresent(Date.self, forKey: .reviewedAt)
        }

        /// The approved package: this repository folder, pinned to the reviewed commit.
        public var source: PluginGitSource {
            let parts = repository.split(separator: "/", maxSplits: 1).map(String.init)
            return PluginGitSource(owner: parts.first ?? "", repo: parts.count > 1 ? parts[1] : "",
                                   path: path, commit: commit, listing: id)
        }
    }

    public var plugins: [Entry]

    public init(plugins: [Entry]) { self.plugins = plugins }

    private struct Document: Decodable {
        let format: Int
        let plugins: [Entry]
    }

    /// Reads `registry.json`. A listing that doesn't name a GitHub folder
    /// and a full commit is refused, and so is the whole file with it.
    public static func decode(_ data: Data) throws -> PluginRegistry {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let document = try? decoder.decode(Document.self, from: data),
              document.format == supportedFormat else { throw PluginRegistryError.invalid }
        let registry = PluginRegistry(plugins: document.plugins)
        guard Set(registry.plugins.map(\.id)).count == registry.plugins.count,
              registry.plugins.allSatisfy(\.isWellFormed) else { throw PluginRegistryError.invalid }
        return registry
    }

    public static func fetch(session: URLSession = .shared) async throws -> PluginRegistry {
        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 2_000_000 else {
            throw PluginRegistryError.unavailable
        }
        return try decode(data)
    }

    public func entry(_ id: String) -> Entry? {
        plugins.first { $0.id.caseInsensitiveCompare(id) == .orderedSame }
    }

    public func entry(pluginId: String) -> Entry? {
        plugins.first { $0.pluginId == pluginId }
    }

    /// Whether a person reviewed exactly this: a listing's install, or a
    /// direct one that happens to be at a listing's approved folder and commit.
    public func isReviewed(_ source: PluginGitSource) -> Bool {
        if source.listing != nil { return true }
        return plugins.contains { entry in
            let approved = entry.source
            return source.isGitHub && approved.owner.lowercased() == source.owner.lowercased()
                && approved.repo.lowercased() == source.repo.lowercased()
                && approved.path == source.path && approved.commit == source.commit?.lowercased()
        }
    }

    /// What's typed after `abstract plugin add` or in "Add from GitHub…":
    /// a bare `owner/slug` that names a listing installs its approved
    /// commit; anything else is a repository. `github:` or `git:` always
    /// means the repository.
    public func source(for text: String, ref: String? = nil) throws -> PluginGitSource {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if ref?.isEmpty ?? true, !trimmed.contains("@"), !trimmed.contains(":"),
           trimmed.split(separator: "/").count == 2, let entry = entry(trimmed) {
            return entry.source
        }
        return try PluginGitSource.parse(text, ref: ref)
    }
}

extension PluginRegistry.Entry {
    var isWellFormed: Bool {
        let parts = repository.split(separator: "/", omittingEmptySubsequences: false)
        guard let parsed = try? PluginGitSource.parse(repository + (path.map { "/\($0)" } ?? "")) else { return false }
        return parts.count == 2 && parsed.owner == String(parts[0]) && parsed.path == path
            && PluginGitSource.isCommit(commit) && commit == commit.lowercased()
            && (try? PluginGitSource.parse("\(owner)/\(slug)"))?.path == nil
            && !name.isEmpty && !pluginId.isEmpty
            && screenshots.allSatisfy { $0.scheme == "https" && $0.host != nil }
    }
}

public enum PluginRegistryError: Error, LocalizedError, Sendable, Equatable {
    case invalid, unavailable
    /// The fetched package isn't the plugin the listing approved.
    case notApproved(String)

    public var errorDescription: String? {
        switch self {
        case .invalid: "The plugin registry couldn't be read."
        case .unavailable: "The plugin registry isn't available right now."
        case .notApproved(let name): "What's at \(name)'s approved commit isn't the plugin that was reviewed, so it wasn't installed."
        }
    }
}

extension PluginManager {
    /// Fetches a listing's approved commit and checks it is the plugin a
    /// person reviewed. The ref and the branch's head never come into it.
    public func inspectListing(_ entry: PluginRegistry.Entry, fetcher: any PluginGitFetching,
                               fileManager fm: FileManager = .default) async throws -> PluginGitCandidate {
        let candidate = try await inspectGit(entry.source, fetcher: fetcher, fileManager: fm)
        guard candidate.source.commit == entry.commit, candidate.inspection.manifest.id == entry.pluginId else {
            try? fm.removeItem(at: candidate.cleanup)
            throw PluginRegistryError.notApproved(entry.name)
        }
        return candidate
    }

    /// `inspectGit`, except that a source from a listing goes through the
    /// listing's checks.
    public func inspect(_ source: PluginGitSource, registry: PluginRegistry?, fetcher: any PluginGitFetching,
                        fileManager fm: FileManager = .default) async throws -> PluginGitCandidate {
        if let listing = source.listing {
            guard let entry = registry?.entry(listing) else { throw PluginRegistryError.unavailable }
            return try await inspectListing(entry, fetcher: fetcher, fileManager: fm)
        }
        return try await inspectGit(source, fetcher: fetcher, fileManager: fm)
    }
}
