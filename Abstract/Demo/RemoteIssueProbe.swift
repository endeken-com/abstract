import AppKit
import Observation
import AbstractCore

/// Demo mode's check of linking issues in a chat from another Mac (ABS-215),
/// for two demo instances on one Mac. Run the host with
/// `ABSTRACT_DEMO_REMOTE=host` (pairing) and `ABSTRACT_DEMO_REMOTE_ISSUES=host`;
/// it links payments-api to its trackers as `<dir>/state` says ("jira" or
/// "none") and logs a message that arrives with an issue. The controller,
/// `ABSTRACT_DEMO_REMOTE_ISSUES=controller`, pairs, opens the host's
/// payments-api chat, sets each state and logs and shoots what its composer
/// and pickers show. `ABSTRACT_DEMO_REMOTE_ISSUES_DIR` holds the state file
/// and the shots; `ABSTRACT_DEMO_REMOTE_PORT` is the host's port.
/// `ABSTRACT_DEMO_OLD_HOST` makes the host answer as a Mac before ABS-211.
enum RemoteIssueProbe {
    private static let env = ProcessInfo.processInfo.environment
    private static let dir = env["ABSTRACT_DEMO_REMOTE_ISSUES_DIR"] ?? NSTemporaryDirectory()
    private static var stateURL: URL { URL(fileURLWithPath: dir).appendingPathComponent("state") }

    static var oldHost: Bool { env["ABSTRACT_DEMO_OLD_HOST"] != nil }

    static func runIfRequested(_ model: AppModel) {
        switch env["ABSTRACT_DEMO_REMOTE_ISSUES"] {
        case "host": Task { await host(model) }
        case "controller": Task { await control(model) }
        default: break
        }
    }

    // MARK: The host

    private static func host(_ model: AppModel) async {
        for name in ["linear.abstractplugin", "jira.abstractplugin"] {
            guard let folder = model.plugins.bundledFolders.first(where: { $0.lastPathComponent == name }) else { continue }
            _ = try? model.plugins.install(from: folder, sourceKind: .bundled, enable: true)
        }
        guard let project = model.projects.first(where: { $0.name == "payments-api" }) else { return log("issues host: FAIL no payments-api") }
        log("issues host: trackers \(model.issueTrackers.map(\.title)), old=\(oldHost)")
        let jira = model.plugins.manager.storage(for: "sh.abstract.jira")
        let linear = model.plugins.manager.storage(for: PromptAttachment.linearTrackerId)
        let shop = TrackerProjectLink(project: .init(id: "project:PROJ", name: "Sample project", key: "PROJ"))
        var current = ""
        var delivered = false
        while true {
            let state = ((try? String(contentsOf: stateURL, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if state != current, !state.isEmpty {
                current = state
                TrackerProjectLink.write(state == "jira" ? shop : nil, to: jira, projectId: project.id)
                TrackerProjectLink.write(nil, to: linear, projectId: project.id)
                model.noteTrackerLinksChanged()
                let trackers = model.projectIssueTrackers(project.id)
                log("issues host: state \(state), linked \(trackers.linked.map { "\($0.tracker.title):\($0.link.title)" }), revision \(model.issueSourcesRevision)")
            }
            // It goes to the agent now, or waits for its turn to end.
            if !delivered, let chat = model.sessions.first(where: { $0.projectId == project.id }) {
                let queued = (model.queues[chat.id] ?? []).flatMap(\.attachments).first { $0.reference == "PROJ-1381" }
                let sent = model.feed(chat.id).rows.first { "\($0)".contains("PROJ-1381") }.map { "\($0)" }
                if let text = queued?.promptText ?? sent {
                    delivered = true
                    log("issues host: message arrived with PROJ-1381 (\(queued != nil ? "queued for the agent's next turn" : "sent")), description included: \(text.contains("The retry handler runs again"))")
                }
            }
            try? await Task.sleep(for: .milliseconds(400))
        }
    }

    // MARK: The viewing Mac

    private static func control(_ model: AppModel) async {
        let remote = model.remote
        remote.start(model: model)
        guard let port = env["ABSTRACT_DEMO_REMOTE_PORT"] else { return log("issues: FAIL no port") }
        remote.pair(address: "127.0.0.1:\(port)")
        guard let link = await wait(60, { remote.links.values.first { $0.snapshot != nil } }) else { return log("issues: FAIL not paired") }
        let snapshot = link.snapshot!
        log("issues: paired with \(link.device.peer.name), issueSearch=\(snapshot.issueSearch.map(String.init) ?? "nil") revision=\(snapshot.issueSourcesRevision.map(String.init) ?? "nil")")
        log("issues: this Mac's own trackers \(model.issueTrackers.map(\.title))")
        guard let project = snapshot.projects.first(where: { $0.name == "payments-api" }),
              let chat = snapshot.sessions.first(where: { $0.projectId == project.id }) else { return log("issues: FAIL no payments-api chat") }
        let mirror = RemoteService.mirrorId(device: link.device.id, session: chat.id)
        model.open(mirror)
        let place = model.issueLinkPlace(sessionId: mirror, projectId: nil)
        log("issues: place \(place)")
        let launcher = model.issueLinkPlace(sessionId: nil, projectId: project.id, device: link.device.id)
        log("issues: launcher place \(launcher)")
        try? await Task.sleep(for: .seconds(3))

        if oldHost {
            await model.refreshRemoteIssueSources(place)
            log("issues: old host → sources \(model.remoteIssueSources(place).sources == nil ? "none" : "SOME"), refusal “\(model.remoteIssueSources(place).refusal ?? "nil")”")
            await shoot("old-host-composer", settle: 2)
            return finish()
        }

        for state in ["jira", "none"] {
            let before = link.snapshot?.issueSourcesRevision
            try? state.write(to: stateURL, atomically: true, encoding: .utf8)
            _ = await wait(15, { link.snapshot?.issueSourcesRevision != before ? true : nil })
            await model.refreshRemoteIssueSources(place)
            // The composer may be asking already: wait for its answer.
            guard let sources = await wait(10, { model.remoteIssueSources(place).sources.flatMap { $0.linked == (state == "jira") ? $0 : nil } })
            else { log("issues: FAIL \(state) sources never followed the host"); continue }
            let trackers = ProjectIssueTrackers(sources)
            log("issues: \(state) buttons trackers=\(trackers.shown().map(\.title)) help=“\(AttachmentButtons.trackerHelp(trackers))” githubIssues=\(sources.githubIssues) pullRequests=\(sources.pullRequests) codeHost=\(sources.codeHost ?? "nil")")
            log("issues: \(state) details popover links \(model.chatIssueTrackers(mirror).linked.map { "\($0.tracker.title):\($0.link.title)" })")
            await shoot("\(state)-composer", settle: 2)
            guard let linking = model.remoteIssueLinking(place) else { log("issues: FAIL no link"); continue }
            AttachmentButtons.demoOpen.source = .tracker
            await shoot("\(state)-tracker-picker", settle: 4)
            AttachmentButtons.demoOpen.source = nil
            do {
                let groups = try await linking.search("", searchAll: false)
                log("issues: \(state) search → \(groups.map { "\($0.title): \($0.results.map(\.reference))\($0.problem.map { " (\($0))" } ?? "")" })")
                if state == "jira", let first = groups.first?.results.first {
                    let whole = await linking.complete(first.attachment)
                    log("issues: completed \(whole.reference ?? "") with description: \(whole.body?.isEmpty == false)")
                    try await remote.send(mirror, text: "Please take this issue.", attachments: [whole])
                    log("issues: sent with \(whole.reference ?? "")")
                }
            } catch { log("issues: \(state) search FAIL \(error.localizedDescription)") }
            if state == "jira" {
                AttachmentButtons.demoOpen.source = .pullRequest
                await shoot("pull-request-picker", settle: 4)
                AttachmentButtons.demoOpen.source = nil
                do {
                    let found = try await linking.searchCodeHost("", pullRequests: true)
                    log("issues: pull requests from \(found.title): \(found.results.map { "\($0.reference) \($0.title)" })")
                } catch { log("issues: pull requests FAIL \(error.localizedDescription)") }
            }
            try? await Task.sleep(for: .seconds(1))
        }
        finish()
    }

    private static func finish() {
        log("issues: done")
    }

    private static func shoot(_ name: String, settle: Double) async {
        try? await Task.sleep(for: .seconds(settle))
        guard let image = WindowCapture.image() ?? WindowCapture.image(method: .cacheDisplay) else { return log("issues: no shot \(name)") }
        let url = URL(fileURLWithPath: dir).appendingPathComponent(name + ".png")
        try? image.write(to: url)
        log("issues: shot \(url.path)")
    }

    private static func wait<T>(_ seconds: Double, _ check: () -> T?) async -> T? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let value = check() { return value }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return check()
    }
}

/// Opens an issue picker from a demo probe, which can't click.
@Observable
final class AttachDemoOpen {
    var source: AttachSource?
}
