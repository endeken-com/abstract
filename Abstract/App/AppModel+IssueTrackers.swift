import AppKit
import Foundation
import AbstractCore

/// Issue trackers (ABS-141): the composer's issue search asks every
/// enabled tracker plugin. Each answers in its background script; this
/// side keeps the search, the chip and the line the agent reads.
extension AppModel {
    /// The trackers of plugins that can run now.
    var issueTrackers: [ResolvedIssueTracker] { PluginIssueTrackers.resolve(plugins.installed) }

    func askTracker(_ tracker: ResolvedIssueTracker, _ request: TrackerRequest) async -> TrackerAnswer {
        guard let pluginBackground else { return .failed("\(tracker.title) isn't running.") }
        return await pluginBackground.askTracker(tracker.pluginId, request)
    }

    /// The trackers a project links to (ABS-143), as saved on this Mac,
    /// among the ones that can run now.
    func projectIssueTrackers(_ projectId: String?) -> ProjectIssueTrackers {
        _ = plugins.trackerLinksRevision
        return ProjectIssueTrackers(projectId: projectId, installed: plugins.installed, links: plugins.trackerLinks)
    }

    /// A project's tracker link changed: the composer, the headers and
    /// plugins' snapshots follow.
    func noteTrackerLinksChanged() { plugins.noteTrackerLinksChanged() }

    /// Every tracker's results for what was typed, grouped by tracker:
    /// the project's linked trackers within their link, or with
    /// `searchAll` every tracker everywhere. `trackerId` asks only that
    /// one (the phone's "Link a Jira issue", ABS-211).
    func searchIssueTrackers(_ query: String, projectId: String? = nil, searchAll: Bool = false,
                             trackerId: String? = nil) async -> [PluginIssueTrackers.Group] {
        let project = projectIssueTrackers(projectId)
        let trackers = project.shown(searchAll: searchAll).filter { trackerId == nil || $0.pluginId == trackerId }
        return await PluginIssueTrackers.search(query, trackers: trackers,
                                                scopes: project.scopes(searchAll: searchAll)) { [weak self] tracker, request in
            await self?.askTracker(tracker, request) ?? .failed("\(tracker.title) isn't running.")
        }
    }

    /// The issue as it goes with the message: a search lists issues
    /// without their descriptions, so the picked one is asked for whole.
    /// If that fails it goes as it was listed.
    func completeTrackerIssue(_ attachment: PromptAttachment) async -> PromptAttachment {
        guard attachment.kind == .trackerIssue, let reference = attachment.reference,
              let tracker = issueTrackers.first(where: { $0.pluginId == attachment.tracker }) else { return attachment }
        let lookup = tracker.pluginId == PromptAttachment.linearTrackerId ? (attachment.url ?? reference) : reference
        guard case .issue(let issue?) = await askTracker(tracker, .issue(lookup)) else { return attachment }
        var whole = issue.attachment(trackerId: tracker.pluginId, trackerName: tracker.title)
        whole.id = attachment.id
        return whole
    }

    /// Whether a project's composer offers "Link a GitHub issue": its
    /// origin is on GitHub, or the GitHub plugin handles it.
    func offersGitHubIssues(_ project: Project) async -> Bool {
        let origin = await origin(of: project)
        return origin.flatMap(GitRemote.host) == "github.com"
            || codeHost(remote: origin, context: CodeHostContext())?.pluginId == "sh.abstract.github"
    }

    /// Why a code host search found nothing to list: no host, its tool
    /// missing or signed out. Said in a sentence, as the picker shows it.
    struct CodeHostLinkProblem: LocalizedError {
        var errorDescription: String?
    }

    /// The project's code host's issues or pull requests for what was
    /// typed (ABS-139), with the host that answered. Throws a
    /// `CodeHostLinkProblem` when there's nothing it can ask.
    func searchCodeHostLinks(_ query: String, project: Project, chatId: String?,
                             pullRequests: Bool) async throws -> (host: CodeHost, items: [ForgeItem]) {
        guard let host = await codeHost(for: project, chatId: chatId), host.answers(.searchIssuesAndPullRequests) else {
            throw CodeHostLinkProblem(errorDescription: await codeHostMissing(project))
        }
        switch await host.access() {
        case .missing(let install):
            throw CodeHostLinkProblem(errorDescription: "Linking \(host.title) needs its command-line tool."
                                      + (install.map { " Install it with `\($0)`." } ?? ""))
        case .signedOut(let hint):
            throw CodeHostLinkProblem(errorDescription: "\(host.title) isn't signed in."
                                      + (hint.map { " Run `\($0)` in a terminal, then try again." } ?? ""))
        case .ready, .unavailable: break
        }
        return (host, try await host.search(query, pullRequests: pullRequests))
    }

    /// Reads each tracker's icon from its package, once per version.
    func refreshTrackerIcons() {
        TrackerIcons.update(plugins.installed)
    }

    // MARK: Upgrading from Linear in core

    /// Linear is a plugin, on when you have a way into Linear (ABS-141),
    /// installed from its reviewed listing since it left the app (ABS-190). Abstract used to keep a Linear API key of its own
    /// (Settings → Integrations): the first launch after Linear became a
    /// plugin installs and turns on the Linear plugin and moves the key to
    /// it. With no key, it's turned on if the Linear CLI is signed in on
    /// this Mac. Done once; a key that couldn't be moved is tried again
    /// next launch, and its old copy kept until then.
    func adoptLinearPlugin() async {
        guard !isDemo, store.setting(Self.linearAdoptedKey, as: Bool.self) != true else { return }
        let pluginId = PromptAttachment.linearTrackerId
        // Only a Mac that had connected Linear has a key to read: reading
        // the keychain can ask for the password.
        if UserDefaults.standard.bool(forKey: Self.legacyLinearConnectedKey),
           let key = Keychain.read(Self.legacyLinearAccount) {
            guard await turnOnLinearPlugin(nil) else { return }
            if !plugins.hasSecret(pluginId: pluginId, name: "api-key") {
                plugins.setSecret(key, pluginId: pluginId, name: "api-key")
            }
            // The old copy goes only once the plugin's is there.
            guard plugins.hasSecret(pluginId: pluginId, name: "api-key") else { return }
            Keychain.write(Self.legacyLinearAccount, nil)
            UserDefaults.standard.removeObject(forKey: Self.legacyLinearConnectedKey)
        } else if plugins.plugin(pluginId) == nil {
            // Without the registry, or if it couldn't tell (it timed out,
            // say): ask again next launch.
            guard let candidate = await linearCandidate() else { return }
            defer { try? FileManager.default.removeItem(at: candidate.cleanup) }
            guard let signedIn = await linearCLISignedIn(candidate.inspection.manifest.cli) else { return }
            if signedIn { guard await turnOnLinearPlugin(candidate) else { return } }
        }
        try? store.setSetting(Self.linearAdoptedKey, true)
    }

    /// Linear's reviewed listing, fetched at its approved commit.
    private func linearCandidate() async -> PluginGitCandidate? {
        guard let entry = await plugins.listing(for: PromptAttachment.linearTrackerId) else { return nil }
        return try? await plugins.inspectListing(entry)
    }

    /// Installs Linear from its listing if needed and turns it on.
    private func turnOnLinearPlugin(_ fetched: PluginGitCandidate?) async -> Bool {
        let pluginId = PromptAttachment.linearTrackerId
        if plugins.plugin(pluginId) == nil {
            var candidate = fetched
            if candidate == nil { candidate = await linearCandidate() }
            guard let candidate else { return false }
            defer { if fetched == nil { try? FileManager.default.removeItem(at: candidate.cleanup) } }
            guard (try? plugins.install(candidate, enable: true)) != nil else { return false }
        } else if plugins.plugin(pluginId)?.record.enabled != true {
            setPluginEnabled(pluginId, true)
        }
        return plugins.plugin(pluginId)?.isUsable == true
    }

    /// Whether `linear auth list` names a workspace: the plugin's own
    /// declared read, run the way the plugin would run it. Nil when the CLI
    /// is there but didn't answer.
    private func linearCLISignedIn(_ declared: PluginCLI?) async -> Bool? {
        guard let cli = declared, let command = cli.command(for: ["auth", "list"]) else { return nil }
        guard await executor.which(cli.binary) != nil else { return false }
        guard let out = try? await PluginCLIRunner().run(PluginCLIRequest(args: command.args, command: command), cli: cli,
                                                         executor: executor, cwd: nil, readable: []) else { return nil }
        return out.code == 0 && out.stdout.contains("WORKSPACE")
    }

    static let linearAdoptedKey = "plugins.linearAdopted"
    /// Where core kept the key before ABS-141.
    static let legacyLinearAccount = "linear-api-key"
    static let legacyLinearConnectedKey = "integrations.linear"
}

/// Trackers' icons. Read from each installed plugin's package when
/// plugins change, so a chip in an old chat finds its icon without asking
/// the plugin anything, even while it's off. A one-colour icon is drawn in
/// the text colour; one with colours of its own, like Jira's, keeps them
/// (ABS-143).
@MainActor
enum TrackerIcons {
    private static var images: [String: (version: String, image: NSImage)] = [:]
    /// Icons sent by paired Macs with their trackers (ABS-215), for
    /// trackers this Mac doesn't have.
    private static var remoteImages: [String: NSImage] = [:]

    static func image(_ pluginId: String?) -> NSImage? {
        pluginId.flatMap { images[$0]?.image ?? remoteImages[$0] }
    }

    static func remember(_ trackers: [RemoteIssueTracker]) {
        for tracker in trackers {
            guard let data = tracker.icon, let image = NSImage(data: data) else { continue }
            image.isTemplate = tracker.iconIsTemplate ?? false
            remoteImages[tracker.id] = image
        }
    }

    static func update(_ installed: [InstalledPlugin]) {
        var next: [String: (version: String, image: NSImage)] = [:]
        for plugin in installed {
            guard let icon = plugin.manifest?.contributes.issueTracker?.icon else { continue }
            if let kept = images[plugin.id], kept.version == plugin.record.version {
                next[plugin.id] = kept
                continue
            }
            guard let data = PluginPackage.fileData(in: plugin.packageURL, relativePath: icon),
                  let image = NSImage(data: data) else { continue }
            image.isTemplate = PluginIssueTrackerDeclaration.iconIsTemplate(data, path: icon)
            next[plugin.id] = (plugin.record.version, image)
        }
        images = next
    }
}
