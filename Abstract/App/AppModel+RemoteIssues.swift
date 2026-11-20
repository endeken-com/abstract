import AppKit
import Foundation
import AbstractCore

/// Linking issues in a chat on another Mac (ABS-215): that Mac's trackers,
/// links and code host answer, through the requests the phone uses
/// (ABS-211). This Mac's own plugins, links and folders are never used for it.
extension AppModel {
    /// Where a composer's issue buttons ask: a chat from another Mac, or a
    /// new chat starting on one (`device`, from the launcher), asks that Mac.
    func issueLinkPlace(sessionId: String?, projectId: String?, device: String? = nil) -> IssueLinkPlace {
        if let device, sessionId == nil { return .mac(device: device, projectId: projectId, chatId: nil) }
        return IssueLinkPlace.of(chat: sessionId.flatMap(RemoteService.split), chatProjectId: session(sessionId)?.projectId,
                                 projectId: projectId, isLocalProject: { id in self.projects.contains { $0.id == id } },
                                 deviceOfProject: { self.remote.device(ofProject: $0) })
    }

    /// The questions to ask the Mac at `place`; nil for this Mac, or a Mac no longer paired.
    func remoteIssueLinking(_ place: IssueLinkPlace) -> RemoteIssueLinking? {
        guard case let .mac(device, projectId, chatId) = place, let link = remote.links[device] else { return nil }
        return RemoteIssueLinking(macName: link.device.peer.name, projectId: projectId, chatId: chatId) { [weak link] request in
            guard let link else { throw AbstractError.message("That Mac isn't paired anymore.") }
            return try await link.request(request)
        }
    }

    /// What the buttons show for a place on another Mac: its sources, as
    /// last answered, or why there are none to ask for. Both nil while the
    /// first answer is on its way.
    func remoteIssueSources(_ place: IssueLinkPlace) -> (sources: RemoteIssueSources?, refusal: String?) {
        guard case let .mac(device, projectId, chatId) = place else { return (nil, nil) }
        guard let link = remote.links[device] else { return (nil, "That Mac isn't paired anymore.") }
        let cached = link.issueSourceCache.sources(RemoteIssueSourceCache.key(projectId: projectId, chatId: chatId))
        guard let snapshot = link.snapshot else { return (cached, cached == nil ? link.unreachableMessage : nil) }
        guard RemoteIssueLinking.answers(snapshot) else {
            return (nil, RemoteIssueLinking.updateSentence(macName: link.device.peer.name))
        }
        return (cached, nil)
    }

    /// Asks the Mac at `place` for its sources unless the last answer still
    /// holds: until its snapshot says a tracker link changed, or for a
    /// minute from a Mac that doesn't say.
    func refreshRemoteIssueSources(_ place: IssueLinkPlace) async {
        guard case let .mac(device, projectId, chatId) = place, let link = remote.links[device],
              link.state == .online, RemoteIssueLinking.answers(link.snapshot),
              let linking = remoteIssueLinking(place) else { return }
        let key = RemoteIssueSourceCache.key(projectId: projectId, chatId: chatId)
        let revision = link.snapshot?.issueSourcesRevision
        guard !link.issueSourceCache.isFresh(key, revision: revision),
              link.issueSourceFetches.insert(key).inserted else { return }
        defer { link.issueSourceFetches.remove(key) }
        guard let sources = try? await linking.sources(iconVersions: link.issueSourceCache.iconVersions) else { return }
        TrackerIcons.remember(sources.trackers + (sources.others ?? []))
        link.issueSourceCache.store(sources, for: key, revision: revision)
    }

    /// The trackers a chat's project links to, on the Mac the chat runs on.
    func chatIssueTrackers(_ sessionId: String) -> ProjectIssueTrackers {
        let place = issueLinkPlace(sessionId: sessionId, projectId: nil)
        guard case .mac = place else { return projectIssueTrackers(session(sessionId)?.projectId) }
        return remoteIssueSources(place).sources.map(ProjectIssueTrackers.init) ?? ProjectIssueTrackers(available: [], links: [:])
    }

    /// What changes the sources of a chat on another Mac, for a view's task id.
    func remoteIssueRevision(_ place: IssueLinkPlace) -> String {
        guard case let .mac(device, _, _) = place, let link = remote.links[device] else { return "here" }
        return "\(link.state == .online)\(link.snapshot?.issueSearch == true)\(link.snapshot?.issueSourcesRevision ?? 0)"
    }

    /// Changes whenever what this Mac's `issueSources` answers may: a
    /// project's tracker link, a tracker turned on or off or updated. Paired
    /// Macs keep their answers until it does.
    var issueSourcesRevision: Int {
        var hasher = Hasher()
        hasher.combine(plugins.trackerLinksRevision)
        for tracker in issueTrackers {
            hasher.combine(tracker.pluginId)
            hasher.combine(plugins.plugin(tracker.pluginId)?.record.version)
        }
        return hasher.finalize()
    }
}
