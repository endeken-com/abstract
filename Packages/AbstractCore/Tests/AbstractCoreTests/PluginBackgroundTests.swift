import Foundation
import Testing
@testable import AbstractCore

/// Background scripts (ABS-93): events filtered by what the plugin may
/// read, jobs that never overlap and skip what they missed, and a
/// watchdog for scripts that loop, throw or hog the Mac.
@Suite struct PluginBackgroundTests {
    let fm = FileManager.default

    func tempRoot() throws -> URL {
        let url = fm.temporaryDirectory.appendingPathComponent("abstract-plugin-background-tests-\(UUID().uuidString)")
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func package(in root: URL, version: String = "1.0.0", background: String? = "background.js",
                 writeBackground: Bool = true) throws -> URL {
        let folder = root.appendingPathComponent("pkg-\(UUID().uuidString)")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var manifest: [String: Any] = [
            "api": 2, "id": "sh.example.counter", "name": "Counter", "version": version,
            "entry": "index.html", "capabilities": ["chats.read", "storage.own"],
            "contributes": ["views": [["id": "main", "title": "Counter", "location": "main"]]],
        ]
        if let background { manifest["background"] = background }
        try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent("manifest.json"))
        try "<html></html>".write(to: folder.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        if writeBackground, let background {
            try "AbstractPlugin.events.subscribe(['chat.statusChanged'], () => {});"
                .write(to: folder.appendingPathComponent(background), atomically: true, encoding: .utf8)
        }
        return folder
    }

    func chat(_ id: String, status: SessionStatus = .running, progress: PluginSnapshot.Progress = .working,
              pullRequest: PluginSnapshot.PullRequest? = nil) -> PluginSnapshot.Chat {
        PluginSnapshot.Chat(id: id, title: "Chat \(id)", projectKey: nil, agentId: "claude", branch: nil,
                            status: status.rawValue, progress: progress, pinned: false, archived: false,
                            createdAt: "2026-10-20T00:00:00Z", lastActivityAt: "2026-10-20T00:00:00Z",
                            hasChanges: nil, backgroundTasks: 0, pullRequest: pullRequest, macId: "mac-1")
    }

    // MARK: Manifest

    @Test func aBackgroundScriptIsDeclaredReviewedAndChecked() throws {
        var manifest = PluginManifest(id: "sh.example.counter", name: "Counter", version: "1.0.0",
                                      capabilities: ["chats.read"], background: "background.js")
        // A background script alone is something the plugin adds.
        try manifest.validate()
        #expect(manifest.appearanceSentences.contains { $0.contains("In the background") })

        manifest.background = "../escape.js"
        #expect(throws: PluginValidationError.self) { try manifest.validate() }
        manifest.background = "background.html"
        #expect(throws: PluginValidationError.self) { try manifest.validate() }

        let root = try tempRoot()
        #expect(throws: PluginValidationError.self) {
            try PluginPackage.inspect(folder: package(in: root, writeBackground: false))
        }
        let inspected = try PluginPackage.inspect(folder: package(in: root))
        #expect(inspected.manifest.background == "background.js")

        // A background-only manifest needs no `contributes`.
        let backgroundOnly = #"{"api":2,"id":"sh.example.notify","name":"Notify","version":"1.0.0","entry":"index.html","capabilities":["chats.read"],"background":"bg.js"}"#
        let decoded = try PluginManifest.decode(Data(backgroundOnly.utf8))
        try decoded.validate()
        #expect(decoded.contributes.views.isEmpty && decoded.background == "bg.js")
    }

    @Test func enablingGrantsTheBackgroundAndAnUpdateAddingOneIsReviewedAgain() throws {
        let root = try tempRoot()
        let host = PluginManager(store: try Store.inMemory(), pluginsRoot: root.appendingPathComponent("Plugins"),
                                 dataRoot: root.appendingPathComponent("PluginData"))
        let plain = try host.install(from: package(in: root, background: nil), sourceKind: .user)
        host.setEnabled(plain.id, true)
        #expect(host.records().first?.grantedBackground == false)

        let withBackground = try host.install(from: package(in: root, version: "1.1.0"), sourceKind: .user)
        #expect(withBackground.enabled == false)
        #expect(withBackground.grantedBackground == false)

        host.setEnabled(plain.id, true)
        #expect(host.records().first?.grantedBackground == true)
        // The same background again carries its grant over.
        let again = try host.install(from: package(in: root, version: "1.2.0"), sourceKind: .user)
        #expect(again.enabled && again.grantedBackground)
    }

    // MARK: Events

    @Test func eventsCarryOnlyWhatTheGrantsAllow() throws {
        let status = PluginEvent.chatStatusChanged(chatId: "c", status: "needsYou", previous: "working")
        #expect(status.payload(capabilities: [.storageOwn]) == nil)
        let payload = try #require(status.payload(capabilities: [.chatsRead]))
        #expect(payload["type"] == .string("chat.statusChanged"))
        #expect(payload["status"] == .string("needsYou"))

        let turn = PluginEvent.turnFinished(chatId: "c", outcome: "done", endedAt: Date(timeIntervalSince1970: 0))
        #expect(turn.payload(capabilities: [.chatsRead]) == nil)
        #expect(turn.payload(capabilities: [.turnsRead])?["endedAt"] == .string("1970-01-01T00:00:00Z"))

        let permission = PluginEvent.permissionRequested(chatId: "c", requestId: "r1", kind: "permission",
                                                         toolName: "Bash", questions: [])
        let readOnly = try #require(permission.payload(capabilities: [.chatsRead]))
        #expect(Set(readOnly.object.map { Array($0.keys) } ?? []) == ["type", "chatId", "kind"])
        let answerable = try #require(permission.payload(capabilities: [.chatsRead, .permissionsAnswer]))
        #expect(answerable["requestId"] == .string("r1"))
        #expect(answerable["toolName"] == .string("Bash"))

        let run = PluginEvent.automationRunFinished(automationId: "a", outcome: "failed", at: Date(), chatId: nil)
        #expect(run.payload(capabilities: [.chatsRead]) == nil)
        #expect(run.payload(capabilities: [.automationsRead])?["outcome"] == .string("failed"))

        let pr = PluginEvent.pullRequestUpdated(
            chatId: "c", pullRequest: .init(number: 4, state: "open", isDraft: false, checks: "failing", changesRequested: false),
            changes: ["checks"])
        #expect(pr.payload(capabilities: [.chatsRead])?["pullRequest"]?["checks"] == .string("failing"))
    }

    @Test func snapshotsBecomeStatusAndPullRequestEvents() {
        var detector = PluginEventDetector()
        let baseline = detector.events(from: [chat("a")])
        #expect(baseline.isEmpty, "the first snapshot is the baseline")
        let unchanged = detector.events(from: [chat("a")])
        #expect(unchanged.isEmpty)

        let needsYou = detector.events(from: [chat("a", status: .waitingInput, progress: .needsYou), chat("b")])
        #expect(needsYou == [
            .chatStatusChanged(chatId: "a", status: "needsYou", previous: "working"),
            .chatStatusChanged(chatId: "b", status: "working", previous: nil),
        ])
        let failed = detector.events(from: [chat("a", status: .errored, progress: .done), chat("b")])
        #expect(failed == [.chatStatusChanged(chatId: "a", status: "failed", previous: "needsYou")])

        let open = PluginSnapshot.PullRequest(number: 9, state: "open", isDraft: false, checks: "running", changesRequested: false)
        let opened = detector.events(from: [chat("a", status: .errored, progress: .done), chat("b", pullRequest: open)])
        #expect(opened == [.pullRequestUpdated(chatId: "b", pullRequest: open, changes: ["opened"])])
        var reviewed = open
        reviewed.checks = "failing"
        reviewed.changesRequested = true
        let review = detector.events(from: [chat("a", status: .errored, progress: .done), chat("b", pullRequest: reviewed)])
        #expect(review == [.pullRequestUpdated(chatId: "b", pullRequest: reviewed, changes: ["checks", "review"])])
    }

    /// The test plugin of "Done when": with its screen closed it hears
    /// every status change, through the same bridge, filter and detector
    /// the host runs, and counts them.
    @Test func aBackgroundPluginCountsStatusChangesWithItsScreenClosed() throws {
        var bridge = PluginBridge(capabilities: [.chatsRead, .storageOwn])
        bridge.isBackground = true
        let root = try tempRoot()
        let storage = PluginStorage(directory: root, pluginId: "sh.example.counter")
        let message = #"{"api":2,"type":"events.subscribe","id":"1","payload":{"types":["chat.statusChanged"]}}"#
        guard case .subscribe(_, let subscribed) = bridge.handle(message, storage: storage) else {
            Issue.record("the subscription was refused"); return
        }

        var detector = PluginEventDetector()
        var count = 0
        let moves: [[PluginSnapshot.Chat]] = [
            [chat("a")],
            [chat("a", status: .waitingInput, progress: .needsYou)],
            [chat("a")],
            [chat("a", status: .idle, progress: .readyToReview)],
            [chat("a", status: .idle, progress: .readyToReview)],
        ]
        for chats in moves {
            for event in detector.events(from: chats) where subscribed.contains(event.type) {
                if event.payload(capabilities: bridge.capabilities) != nil { count += 1 }
            }
        }
        #expect(count == 3)
    }

    @Test func onlyABackgroundScriptSubscribesAndOnlyToWhatItMayRead() throws {
        let root = try tempRoot()
        let storage = PluginStorage(directory: root, pluginId: "sh.example.counter")
        func send(_ bridge: inout PluginBridge, _ type: String, _ payload: String) -> PluginBridge.Outcome {
            bridge.handle(#"{"api":2,"type":"\#(type)","id":"1","payload":\#(payload)}"#, storage: storage)
        }
        var screen = PluginBridge(capabilities: [.chatsRead])
        guard case .refused = send(&screen, "events.subscribe", #"{"types":["chat.statusChanged"]}"#) else {
            Issue.record("a screen subscribed"); return
        }
        guard case .refused = send(&screen, "jobs.schedule", #"{"id":"j","rrule":"FREQ=MINUTELY"}"#) else {
            Issue.record("a screen scheduled a job"); return
        }

        var background = PluginBridge(capabilities: [.chatsRead])
        background.isBackground = true
        guard case .refused(_, let reason) = send(&background, "events.subscribe", #"{"types":["turn.finished"]}"#) else {
            Issue.record("subscribed without turns.read"); return
        }
        #expect(reason.contains("turn.finished"))
        guard case .refused = send(&background, "events.subscribe", #"{"types":["chat.deleted"]}"#) else {
            Issue.record("subscribed to an unknown event"); return
        }
        let subscribed = send(&background, "events.subscribe", #"{"types":["chat.statusChanged","pullRequest.updated"]}"#)
        #expect(subscribed == .subscribe(id: "1", [.chatStatusChanged, .pullRequestUpdated]))
        let scheduled = send(&background, "jobs.schedule", #"{"id":"digest","rrule":"FREQ=MINUTELY","timezone":"UTC"}"#)
        #expect(scheduled == .scheduleJob(id: "1", jobId: "digest", rrule: "FREQ=MINUTELY", timezone: "UTC"))
        let cancelled = send(&background, "jobs.cancel", #"{"id":"digest"}"#)
        #expect(cancelled == .cancelJob(id: "1", jobId: "digest"))
        let done = send(&background, "jobs.done", #"{"id":"digest"}"#)
        #expect(done == .jobDone(jobId: "digest"))
    }

    // MARK: Jobs

    @Test func aJobEveryMinuteRunsOnceAMinuteAndNeverOverlaps() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var jobs = PluginJobs()
        try jobs.schedule(id: "tick", rrule: "FREQ=MINUTELY", timezone: "UTC", now: start)
        let first = try #require(jobs.nextDue)
        #expect(first > start && first.timeIntervalSince(start) <= 60)

        // Ticking every second for three minutes, finishing each run fast.
        var runs: [Date] = []
        var now = start
        while now <= start.addingTimeInterval(180) {
            for id in jobs.due(now: now) {
                runs.append(now)
                jobs.finished(id: id)
            }
            now += 1
        }
        #expect(runs.count == 3)
        for (a, b) in zip(runs, runs.dropFirst()) { #expect(b.timeIntervalSince(a) == 60) }

        // A run still going when the next is due: that one is skipped.
        let due = try #require(jobs.nextDue)
        let started = jobs.due(now: due)
        #expect(started == ["tick"])
        let overlapping = jobs.due(now: due + 60)
        #expect(overlapping.isEmpty)
        #expect(jobs.skipped["tick"] == 1)
        jobs.finished(id: "tick")
        let after = jobs.due(now: due + 120)
        #expect(after == ["tick"])
    }

    @Test func aMissedJobIsSkippedNotCaughtUp() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var jobs = PluginJobs()
        try jobs.schedule(id: "hourly", rrule: "FREQ=HOURLY", timezone: "UTC", now: start)
        let due = try #require(jobs.nextDue)
        // The Mac slept through it and woke three hours later.
        let late = jobs.due(now: due + 3 * 3600 + 5)
        #expect(late.isEmpty)
        #expect(jobs.skipped["hourly"] == 1)
        let next = try #require(jobs.nextDue)
        #expect(next > due + 3 * 3600)
        let onTime = jobs.due(now: next)
        #expect(onTime == ["hourly"])
    }

    @Test func jobsAreLimited() throws {
        var jobs = PluginJobs()
        #expect(throws: (any Error).self) {
            try jobs.schedule(id: "fast", rrule: "FREQ=MINUTELY;BYSECOND=0,30", timezone: "UTC")
        }
        #expect(throws: (any Error).self) { try jobs.schedule(id: "bad", rrule: "FREQ=SOMETIMES", timezone: "UTC") }
        for index in 0..<PluginJobs.limit {
            try jobs.schedule(id: "job-\(index)", rrule: "FREQ=DAILY", timezone: "UTC")
        }
        #expect(throws: (any Error).self) { try jobs.schedule(id: "one-more", rrule: "FREQ=DAILY", timezone: "UTC") }
        // Replacing one is not one more.
        try jobs.schedule(id: "job-0", rrule: "FREQ=HOURLY", timezone: "UTC")
        jobs.cancel(id: "job-0")
        #expect(jobs.jobs.count == PluginJobs.limit - 1)
    }

    // MARK: Watchdog

    @Test func aScriptStuckInALoopIsStopped() {
        var watchdog = PluginWatchdog()
        let now = Date()
        let first = watchdog.shouldSendHeartbeat(now: now)
        #expect(first)
        watchdog.heartbeatAnswered()
        #expect(watchdog.check(now: now + 10) == .fine)

        let second = watchdog.shouldSendHeartbeat(now: now + 10)
        #expect(second)
        // A busy loop never answers; no second heartbeat piles up.
        let third = watchdog.shouldSendHeartbeat(now: now + 11)
        #expect(!third)
        #expect(watchdog.check(now: now + 12) == .fine)
        guard case .stopped = watchdog.check(now: now + 10 + PluginWatchdog.stuckAfter + 0.5) else {
            Issue.record("a stuck script kept running"); return
        }
    }

    @Test func aScriptThatKeepsThrowingIsStopped() {
        var watchdog = PluginWatchdog()
        let now = Date()
        for index in 0..<(PluginWatchdog.errorLimit - 1) {
            let verdict = watchdog.scriptThrew(now: now + Double(index))
            #expect(verdict == .fine)
        }
        // Old errors age out of the window.
        let aged = watchdog.scriptThrew(now: now + PluginWatchdog.errorWindow + 30)
        #expect(aged == .fine)
        var last = PluginWatchdog.Verdict.fine
        for index in 0..<PluginWatchdog.errorLimit { last = watchdog.scriptThrew(now: now + 100 + Double(index)) }
        guard case .stopped = last else { Issue.record("a throwing script kept running"); return }
    }

    @Test func aScriptOverItsCPUOrMemoryIsStopped() {
        let now = Date()
        var idle = PluginWatchdog()
        for second in 0...20 {
            let verdict = idle.sample(cpuSeconds: Double(second) * 0.05, footprint: 50_000_000, now: now + Double(second))
            #expect(verdict == .fine)
        }

        var busy = PluginWatchdog()
        var verdict = PluginWatchdog.Verdict.fine
        for second in 0...20 where verdict == .fine {
            verdict = busy.sample(cpuSeconds: Double(second) * 0.95, footprint: 50_000_000, now: now + Double(second))
        }
        guard case .stopped = verdict else { Issue.record("a busy script kept running"); return }

        var big = PluginWatchdog()
        guard case .stopped = big.sample(cpuSeconds: 0, footprint: PluginWatchdog.memoryLimit + 1, now: now) else {
            Issue.record("a script over its memory kept running"); return
        }
    }
}
