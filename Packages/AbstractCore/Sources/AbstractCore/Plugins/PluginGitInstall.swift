import Foundation

/// A package fetched from a repository and checked, waiting on the review
/// screen. `source.commit` is the commit it would be pinned to.
public struct PluginGitCandidate: Sendable {
    public var source: PluginGitSource
    public var folder: URL
    public var inspection: PluginPackage.Inspection
    /// The staging folder to delete once it's installed or cancelled.
    public var cleanup: URL
}

/// A newer commit for a plugin installed from a repository, and what it
/// changes: the summary shown before you accept it.
public struct PluginGitUpdate: Sendable, Identifiable {
    public var pluginId: String
    public var fromCommit: String
    public var candidate: PluginGitCandidate
    public var changes: PluginGitChanges?
    /// More than it holds now: the ABS-98 rule makes it wait for review.
    public var grants: PluginGrantChanges

    public var id: String { pluginId }

    /// One plain sentence for the update's summary.
    public var summary: String {
        var parts: [String] = []
        if let commits = changes?.commits {
            parts.append(commits == 1 ? "1 commit" : "\(commits) commits")
        }
        if let files = changes?.files {
            parts.append(files.count == 1 ? "1 file changed" : "\(files.count) files changed")
        }
        parts.append(grants.asksForMore ? "asks for more access" : "no new access")
        let to = candidate.source.shortCommit ?? ""
        return "\(String(fromCommit.prefix(7))) → \(to): " + parts.joined(separator: ", ") + "."
    }
}

extension PluginManager {
    /// Fetches `source` at its ref (or its pinned commit) and checks it as a
    /// folder install is checked. Nothing is installed.
    public func inspectGit(_ source: PluginGitSource, fetcher: any PluginGitFetching,
                           fileManager fm: FileManager = .default) async throws -> PluginGitCandidate {
        var source = source
        let commit: String
        if let pinned = source.commit { commit = pinned } else { commit = try await fetcher.resolve(source) }
        source.commit = commit
        let staging = fm.temporaryDirectory.appendingPathComponent("abstract-plugin-\(UUID().uuidString)")
        do {
            let folder = staging.appendingPathComponent("package")
            try await fetcher.download(source, commit: commit, into: folder)
            let inspection = try PluginPackage.inspect(folder: folder, fileManager: fm)
            return PluginGitCandidate(source: source, folder: folder, inspection: inspection, cleanup: staging)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
    }

    /// Installs a reviewed candidate, pinned to its commit. The usual rules
    /// apply: installed is off, unless an update asks for nothing new.
    @discardableResult
    public func install(_ candidate: PluginGitCandidate, fileManager fm: FileManager = .default) throws -> PluginRecord {
        try install(from: candidate.folder, sourceKind: .git(candidate.source), fileManager: fm)
    }

    /// Settings → Plugins → Check for updates: each plugin installed from a
    /// repository whose ref now points at another commit, fetched and
    /// checked, with what changed. Nothing is installed; a plugin pinned to
    /// a commit has none. One installed from a registry listing follows the
    /// listing's approved commit instead, and waits while the registry
    /// can't be read. Plugins whose repository can't be reached are
    /// returned in `problems`.
    public func checkGitUpdates(fetcher: any PluginGitFetching, registry: PluginRegistry? = nil,
                                fileManager fm: FileManager = .default) async
        -> (updates: [PluginGitUpdate], problems: [String: String]) {
        var updates: [PluginGitUpdate] = []
        var problems: [String: String] = [:]
        for record in records() {
            guard let source = record.source.git, let installed = source.commit,
                  !(source.ref.map(PluginGitSource.isCommit) ?? false) else { continue }
            do {
                let candidate: PluginGitCandidate
                if let listing = source.listing {
                    guard let entry = registry?.entry(listing), entry.commit != installed else { continue }
                    candidate = try await inspectListing(entry, fetcher: fetcher, fileManager: fm)
                } else {
                    var latest = source
                    latest.commit = try await fetcher.resolve(source)
                    guard latest.commit != installed else { continue }
                    candidate = try await inspectGit(latest, fetcher: fetcher, fileManager: fm)
                }
                guard candidate.inspection.manifest.id == record.id else {
                    try? fm.removeItem(at: candidate.cleanup)
                    problems[record.id] = "The repository now holds a different plugin, so it wasn't offered as an update."
                    continue
                }
                let previous = try? PluginPackage.inspect(folder: packageURL(for: record), fileManager: fm).manifest
                let changes = try? await fetcher.compare(source, from: installed, to: candidate.source.commit ?? "")
                updates.append(PluginGitUpdate(pluginId: record.id, fromCommit: installed, candidate: candidate,
                                               changes: changes,
                                               grants: PluginGrantChanges(new: candidate.inspection.manifest,
                                                                          old: record, previous: previous)))
            } catch {
                problems[record.id] = error.localizedDescription
            }
        }
        return (updates, problems)
    }
}
