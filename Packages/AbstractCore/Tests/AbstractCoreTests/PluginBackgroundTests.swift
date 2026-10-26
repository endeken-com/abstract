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

    /// Ticks once a second from `from`, on time, until a verdict other
    /// than fine or `seconds` have passed. With `cpu`, the script's process
    /// is sampled each tick, using that share of a core.
    private func ticks(_ watchdog: inout PluginWatchdog, from: Date, seconds: Int, ready: Bool,
                       cpu: Double? = nil) -> (verdict: PluginWatchdog.Verdict, at: Date) {
        var now = from
        for second in 1...seconds {
            now += 1
            let verdict = watchdog.tick(now: now, ready: ready)
            if verdict != .fine { return (verdict, now) }
            if let cpu {
                _ = watchdog.sample(cpuSeconds: Double(second) * cpu, footprint: 50_000_000, now: now)
            }
        }
        return (.fine, now)
    }

    @Test func aScriptStuckInALoopIsStopped() {
        var watchdog = PluginWatchdog()
        let now = Date()
        #expect(watchdog.tick(now: now, ready: true) == .fine)
        let first = watchdog.shouldSendHeartbeat(ready: true)
        #expect(first)
        watchdog.heartbeatAnswered()
        #expect(ticks(&watchdog, from: now, seconds: 10, ready: true).verdict == .fine)

        let second = watchdog.shouldSendHeartbeat(ready: true)
        #expect(second)
        // A busy loop never answers; no second heartbeat piles up.
        let third = watchdog.shouldSendHeartbeat(ready: true)
        #expect(!third)
        // The host stays on time, so the wait counts, and it is stopped.
        let (verdict, at) = ticks(&watchdog, from: now + 10, seconds: 30, ready: true)
        #expect(verdict == .stopped(PluginWatchdog.stuckNote, recoverable: true))
        #expect(at.timeIntervalSince(now + 10) > PluginWatchdog.stuckAfter)
        #expect(at.timeIntervalSince(now + 10) <= PluginWatchdog.stuckAfter + 1)
    }

    @Test func noHeartbeatGoesBeforeThePageLoadsAndASlowStartIsTimed() {
        var watchdog = PluginWatchdog()
        let now = Date()
        #expect(watchdog.tick(now: now, ready: false) == .fine)
        // A slow Mac: the page takes 20 seconds to load. Nothing is sent
        // before it has, so nothing can go unanswered.
        var at = now
        for _ in 0..<20 {
            at += 1
            #expect(watchdog.tick(now: at, ready: false) == .fine)
            let sent = watchdog.shouldSendHeartbeat(ready: false)
            #expect(!sent)
        }
        #expect(watchdog.tick(now: at + 1, ready: true) == .fine)
        #expect(watchdog.startedAfter == 20)
        let sent = watchdog.shouldSendHeartbeat(ready: true)
        #expect(sent)

        // Loading slowly on a busy Mac, its process starved: waited for.
        var starved = PluginWatchdog()
        _ = starved.tick(now: now, ready: false)
        #expect(ticks(&starved, from: now, seconds: 120, ready: false, cpu: 0.02).verdict == .fine)
        #expect(starved.tick(now: now + 121, ready: true) == .fine)
        #expect(starved.startedAfter == 120)

        // Stuck in a loop before it finished loading.
        var looping = PluginWatchdog()
        _ = looping.tick(now: now, ready: false)
        let (loop, loopAt) = ticks(&looping, from: now, seconds: 120, ready: false, cpu: 0.99)
        #expect(loop == .stopped(PluginWatchdog.startupNote, recoverable: true))
        #expect(loopAt.timeIntervalSince(now) <= PluginWatchdog.startupLimit + 2)

        // A page that never loads, with the host on time: it didn't start.
        var stuck = PluginWatchdog()
        _ = stuck.tick(now: now, ready: false)
        let (verdict, stoppedAt) = ticks(&stuck, from: now, seconds: 60, ready: false)
        #expect(verdict == .stopped(PluginWatchdog.startupNote, recoverable: true))
        #expect(stoppedAt.timeIntervalSince(now) > PluginWatchdog.startupLimit)
        #expect(stuck.startedAfter == nil)
    }

    @Test func aLoopKeepingItsProcessBusyIsStoppedButASlowedQuietOneIsWaitedFor() {
        let now = Date()
        // Stuck in a loop: a whole core, no answer.
        var looping = PluginWatchdog()
        _ = looping.tick(now: now, ready: true)
        _ = looping.sample(cpuSeconds: 0, footprint: 50_000_000, now: now)
        let sent = looping.shouldSendHeartbeat(ready: true)
        #expect(sent)
        let (verdict, at) = ticks(&looping, from: now, seconds: 30, ready: true, cpu: 0.99)
        #expect(verdict == .stopped(PluginWatchdog.stuckNote, recoverable: true))
        #expect(at.timeIntervalSince(now) <= PluginWatchdog.stuckAfter + 1)

        // Starved while the Mac is busy (its page runs at background
        // priority): all but idle, its answer takes as long as the load
        // lasts. It isn't stopped for that.
        var slowed = PluginWatchdog()
        _ = slowed.tick(now: now, ready: true)
        _ = slowed.sample(cpuSeconds: 0, footprint: 50_000_000, now: now)
        let out = slowed.shouldSendHeartbeat(ready: true)
        #expect(out)
        #expect(ticks(&slowed, from: now, seconds: 60, ready: true, cpu: 0.01).verdict == .fine)
        slowed.heartbeatAnswered()
        #expect(ticks(&slowed, from: now + 60, seconds: 30, ready: true, cpu: 0.01).verdict == .fine)

        // But one that never answers is stopped in the end, with its reason.
        let again = slowed.shouldSendHeartbeat(ready: true)
        #expect(again)
        let (quiet, quietAt) = ticks(&slowed, from: now + 90, seconds: 700, ready: true, cpu: 0.01)
        #expect(quiet == .stopped(PluginWatchdog.quietNote, recoverable: true))
        #expect(quietAt.timeIntervalSince(now + 90) > PluginWatchdog.quietLimit)
    }

    @Test func aDelayedHeartbeatAnswerUnderLoadIsFine() {
        var watchdog = PluginWatchdog()
        let now = Date()
        _ = watchdog.tick(now: now, ready: true)
        let sent = watchdog.shouldSendHeartbeat(ready: true)
        #expect(sent)
        // The answer takes six seconds, longer than the old three-second
        // limit, then comes: still running.
        #expect(ticks(&watchdog, from: now, seconds: 6, ready: true).verdict == .fine)
        watchdog.heartbeatAnswered()
        #expect(ticks(&watchdog, from: now + 6, seconds: 30, ready: true).verdict == .fine)
    }

    @Test func aHeldUpHostIsNotHeldAgainstTheScript() {
        var watchdog = PluginWatchdog()
        let now = Date()
        _ = watchdog.tick(now: now, ready: true)
        let sent = watchdog.shouldSendHeartbeat(ready: true)
        #expect(sent)
        // Abstract's main thread busy for eight seconds, its tick late:
        // the answer is waiting behind it, so that time doesn't count.
        #expect(watchdog.hostWasLate(now: now + 8))
        #expect(watchdog.tick(now: now + 8, ready: true) == .fine)
        // The Mac slept overnight with a heartbeat out.
        #expect(watchdog.tick(now: now + 8 + 8 * 3600, ready: true) == .fine)
        // The clock was set back.
        #expect(watchdog.tick(now: now, ready: true) == .fine)
        #expect(!watchdog.hostWasLate(now: now + 1))
        // Back on time, it answers within a few ticks.
        #expect(ticks(&watchdog, from: now, seconds: 3, ready: true).verdict == .fine)
        watchdog.heartbeatAnswered()

        // The same while still loading: a held-up launch isn't a failed start.
        var starting = PluginWatchdog()
        _ = starting.tick(now: now, ready: false)
        var at = now
        for _ in 0..<12 {
            at += 4
            #expect(starting.tick(now: at, ready: false) == .fine)
        }
        #expect(starting.tick(now: at + 1, ready: true) == .fine)
        #expect(starting.startedAfter == 0)
    }

    @Test func severalScriptsStartingAtOnceOnABusyLaunchAllStart() {
        // Three plugins started in the same moment of a busy launch, as at
        // a cold launch: the host's ticks come late for a while, their pages
        // take ten seconds to load, and their first answers three more.
        let now = Date()
        var watchdogs = Array(repeating: PluginWatchdog(), count: 3)
        let times: [TimeInterval] = [1, 3.5, 4.5, 5.5, 7, 8, 9, 10, 11, 12, 13, 14, 15]
        for index in watchdogs.indices { _ = watchdogs[index].tick(now: now, ready: false) }
        for offset in times {
            for index in watchdogs.indices {
                let ready = offset >= 10
                #expect(watchdogs[index].tick(now: now + offset, ready: ready) == .fine)
                _ = watchdogs[index].shouldSendHeartbeat(ready: ready)
            }
        }
        for index in watchdogs.indices {
            watchdogs[index].heartbeatAnswered()
            #expect(watchdogs[index].startedAfter != nil)
            #expect(ticks(&watchdogs[index], from: now + 15, seconds: 30, ready: true).verdict == .fine)
        }
    }

    @Test func aStopASlowMacCausesIsRetriedAFewTimesThenSticks() {
        var restarts = PluginRestarts()
        let now = Date()
        #expect(restarts.delay(for: "a", now: now) == PluginRestarts.delays[0])
        #expect(restarts.delay(for: "b", now: now) == PluginRestarts.delays[0])
        #expect(restarts.delay(for: "a", now: now + 30) == PluginRestarts.delays[1])
        // Again and again: it stays stopped, with its reason in Settings.
        #expect(restarts.delay(for: "a", now: now + 60) == nil)
        // A while later, a slow moment is forgiven again.
        #expect(restarts.delay(for: "a", now: now + PluginRestarts.window + 60) == PluginRestarts.delays[0])
        // The person restarting it is a fresh start.
        restarts.forget("b")
        #expect(restarts.delay(for: "b", now: now + 1) == PluginRestarts.delays[0])
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
