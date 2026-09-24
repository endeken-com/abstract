import AppKit
import AbstractCore

/// Demo mode's end-to-end check of pairing, for two demo instances on one
/// Mac. `ABSTRACT_DEMO_REMOTE=host` shares this instance and accepts the first
/// pairing; `ABSTRACT_DEMO_REMOTE=controller` finds it, pairs, opens one of its
/// chats, replies, and starts a new chat there, logging each step.
enum RemoteProbe {
    private static let hostName = "Abstract Demo Host \(ProcessInfo.processInfo.environment["ABSTRACT_DEMO_REMOTE_TAG"] ?? "")"
    private static let port = ProcessInfo.processInfo.environment["ABSTRACT_DEMO_REMOTE_PORT"].flatMap(UInt16.init)
    static func runIfRequested(_ model: AppModel) {
        switch ProcessInfo.processInfo.environment["ABSTRACT_DEMO_REMOTE"] {
        case "host": Task { await host(model) }
        case "controller": Task { await control(model) }
        default: break
        }
    }

    private static func host(_ model: AppModel) async {
        let remote = model.remote
        remote.start(model: model)
        // A name no real Mac has, so the controller pairs with this instance only.
        remote.customName = Self.hostName
        // A fixed port lets the controller pair by address, over loopback.
        if let port = port { remote.fixedPort = port }
        remote.hosting = true
        log("remote: hosting as \(remote.identity.name) \(remote.identity.peer.fingerprint)")
        while true {
            if let prompt = remote.prompt, prompt.incoming {
                log("remote: \(prompt.peer.name) asks to pair, code \(prompt.code)")
                try? await Task.sleep(for: .seconds(2))
                remote.answerPairing(true)
                // Drop every link a while later, as a restart or Wi-Fi drop would.
                if ProcessInfo.processInfo.environment["ABSTRACT_DEMO_REMOTE_DROP"] != nil {
                    Task {
                        try? await Task.sleep(for: .seconds(55))
                        remote.hosting = false
                        log("remote: host dropped its links")
                        try? await Task.sleep(for: .seconds(3))
                        remote.hosting = true
                        log("remote: host sharing again")
                    }
                }
                try? await Task.sleep(for: .seconds(20))
                showDevices(model)
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    private static func control(_ model: AppModel) async {
        let remote = model.remote
        remote.start(model: model)
        let link: RemoteLink
        if let port {
            remote.pair(address: "127.0.0.1:\(port)")
            if let code = await wait(10, { remote.prompt?.code }) { log("remote: pairing, code \(code)") }
            guard let found = await wait(40, { remote.links.values.first { $0.device.peer.name == Self.hostName && $0.snapshot != nil } }) else {
                return log("remote: FAIL no snapshot over loopback")
            }
            link = found
        } else {
            remote.startBrowsing()
            // Only the demo host: never another Abstract that happens to be on the network.
            guard let other = await wait(30, { remote.nearby.first { $0.name == Self.hostName } }) else { return log("remote: FAIL demo host not found") }
            log("remote: found \(other.name)")
            remote.pair(with: other)
            if let code = await wait(10, { remote.prompt?.code }) { log("remote: pairing, code \(code)") }
            guard let found = await wait(20, { remote.links[other.id].flatMap { $0.snapshot != nil ? $0 : nil } }) else {
                return log("remote: FAIL no snapshot (\(remote.prompt?.declined == true ? "declined" : String(describing: remote.links[other.id]?.state)))")
            }
            link = found
        }
        let other = (id: link.device.id, name: link.device.peer.name)
        let snapshot = link.snapshot!
        log("remote: paired, \(snapshot.projects.count) projects, \(snapshot.sessions.count) chats, agents \(snapshot.providers)")

        guard let first = snapshot.sessions.first(where: { $0.status == .idle }) ?? snapshot.sessions.first else { return log("remote: FAIL no chats") }
        let mirror = RemoteService.mirrorId(device: other.id, session: first.id)
        model.open(mirror)
        guard let blocks = await wait(15, { model.feed(mirror).rows.count > 2 ? model.feed(mirror).rows.count : nil }) else {
            return log("remote: FAIL transcript didn't arrive")
        }
        log("remote: opened “\(first.name)”, \(blocks) blocks")

        try? model.sendFollowUp(mirror, text: "Also add a short note to the README.")
        let grew = await wait(20, { model.feed(mirror).rows.count > blocks + 1 ? model.feed(mirror).rows.count : nil })
        log(grew.map { "remote: reply streamed back, \($0) blocks" } ?? "remote: FAIL reply didn't stream back")

        // Its worktree is on the host: review, files, editor and a shell work from here.
        if case .ready(let context) = model.diffAvailability(mirror) {
            let files = (try? await Diff.collect(context.executor, worktree: context.worktree, exclude: context.exclude)) ?? []
            log("remote: review over the link, \(files.count) changed files")
            let git = await GitActions.state(context.executor, worktree: context.worktree, preferredBase: nil)
            log("remote: git over the link, dirty \(git.dirty), ahead of base \(git.aheadOfBase)")
        } else {
            log("remote: FAIL no worktree context")
        }
        model.openDiffTab(in: mirror)
        await shoot("remote-review", settle: 4)
        model.openFile("src/sessions/SessionRow.swift", in: mirror)
        model.showPane(.files, in: mirror)
        await shoot("remote-files", settle: 4)
        model.showPane(.terminal, in: mirror)
        await shoot("remote-terminal", settle: 5)
        model.open(mirror)
        await shoot("remote-chat", settle: 2)

        guard let project = snapshot.projects.first else { return }
        model.showNewChat(in: project.id)
        await shoot("remote-new-chat", settle: 2)
        model.newChatProjectId = nil
        do {
            let id = try await remote.startChat(on: other.id, projectId: project.id, providerId: snapshot.providers.first ?? "claude",
                                                prompt: "Rename SessionRow to ChatRow", policy: .autoEdits)
            guard await wait(15, { model.session(id) }) != nil else { return log("remote: FAIL new chat not listed") }
            model.open(id)
            let streamed = await wait(20, { model.feed(id).rows.count > 1 ? model.feed(id).rows.count : nil })
            log(streamed.map { "remote: new chat in \(project.name) streaming, \($0) blocks" } ?? "remote: FAIL new chat silent")
        } catch {
            log("remote: FAIL start: \(error.localizedDescription)")
        }
        // A local model server on the other Mac, used from here through the pairing link.
        if ProcessInfo.processInfo.environment["ABSTRACT_DEMO_LOCAL_MODELS"] != nil {
            model.setLocalModelSource(.ollama, .pairedMac(deviceId: other.id))
            if let status = await wait(20, { model.localModelStatus[.ollama].flatMap { $0.reachable ? $0 : nil } }) {
                log("remote: ollama on \(other.name) through the link: \(status.models)")
            } else {
                log("remote: FAIL ollama through the link: \(model.localModelStatus[.ollama]?.error ?? "no status")")
            }
        }
        if ProcessInfo.processInfo.environment["ABSTRACT_DEMO_REMOTE_DROP"] != nil {
            guard await wait(90, { link.state != .online ? true : nil }) != nil else { return log("remote: FAIL link never dropped") }
            log("remote: link dropped")
            guard await wait(40, { link.state == .online ? true : nil }) != nil else { return log("remote: FAIL didn't reconnect") }
            log("remote: reconnected")
            let before = model.feed(mirror).rows.count
            do {
                try model.sendFollowUp(mirror, text: "Sent after reconnecting.")
                // The stand-in agent answers every follow-up under one id, so its reply replaces the last; your message is the new row.
                let grew = await wait(20, { model.feed(mirror).rows.count > before ? true : nil })
                log(grew != nil ? "remote: message after reconnect delivered" : "remote: FAIL message after reconnect not answered")
            } catch {
                log("remote: FAIL send after reconnect: \(error.localizedDescription)")
            }
        }
        log("remote: done")
        try? await Task.sleep(for: .seconds(4))
        showDevices(model)
    }

    /// The controller's window, for checking by eye.
    private static func shoot(_ name: String, settle: Double) async {
        try? await Task.sleep(for: .seconds(settle))
        guard let dir = ProcessInfo.processInfo.environment["ABSTRACT_DEMO_REMOTE_SHOTS"], let image = WindowCapture.image() else { return }
        let url = URL(fileURLWithPath: dir).appendingPathComponent(name + ".png")
        try? image.write(to: url)
        log("remote: shot \(url.path)")
    }

    private static func showDevices(_ model: AppModel) {
        UserDefaults.standard.set(SettingsTab.devices.rawValue, forKey: "settingsTab")
        model.isSettingsOpen = true
        log("remote: showing devices")
    }

    private static func wait<T>(_ seconds: Double, _ value: () -> T?) async -> T? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let v = value() { return v }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return value()
    }
}
