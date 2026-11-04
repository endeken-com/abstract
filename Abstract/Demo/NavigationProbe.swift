import AppKit
import SwiftUI
import AbstractCore

/// Demo mode's timing of everyday actions (ABS-184), in any build.
/// `ABSTRACT_DEMO_NAV=<delay>` waits, adds ABS-159's synthetic profile (50
/// projects, 1,000 chats) with long chats of `ABSTRACT_DEMO_NAV_LINES` lines
/// (6,000 by default), sets ten of them streaming, then switches chats and
/// tabs, opens Automations and New Chat, and sends a message, several times
/// each. For each it logs how long until the window had drawn the change
/// (the main thread going back to waiting), the longest stretch it was busy
/// in the second after, and the signposted work in that first stretch. Then
/// (ABS-186) whether a chat comes back where you were reading, and how much
/// memory the kept transcripts hold.
enum NavigationProbe {
    /// The window the probe opened, when the app's own never did.
    private static var probeWindow: NSWindow?

    static func runIfRequested(_ model: AppModel, repo: Project?) {
        guard let spec = ProcessInfo.processInfo.environment["ABSTRACT_DEMO_NAV"], let delay = Double(spec) else { return }
        HangMonitor.shared.start()
        Task {
            try? await Task.sleep(for: .seconds(delay))
            await run(model, repo: repo)
        }
    }

    private static func run(_ model: AppModel, repo: Project?) async {
        let lines = Int(ProcessInfo.processInfo.environment["ABSTRACT_DEMO_NAV_LINES"] ?? "") ?? 6_000
        let (projects, sessions) = SyntheticChats.profile()
        let log = SyntheticChats.log(lines: lines)
        let encoder = JSONEncoder()
        let logText = log.map { String(decoding: try! encoder.encode($0), as: UTF8.self) }.joined(separator: "\n") + "\n"
        // Long chats to open, in the demo's real repository so their worktree reads work.
        let long = Array(sessions.filter { $0.status == .idle }.prefix(6))
        let streaming = Array(sessions.filter { $0.status == .running }.prefix(10))
        for project in projects { try? model.store.save(project) }
        for var session in sessions {
            if long.contains(where: { $0.id == session.id }), let repo {
                session.projectId = repo.id
                session.worktreePath = repo.rootPath
                session.branch = "main"
            }
            try? model.store.save(session)
        }
        for session in long {
            try? logText.write(to: model.engine.logsURL.appendingPathComponent("\(session.id).jsonl"), atomically: true, encoding: .utf8)
        }
        model.reload()
        // Only a window in front draws. Launched beside another copy of the
        // app, the window may never have opened: open one like it.
        NSApp.activate()
        if !NSApp.windows.contains(where: { $0.canBecomeMain }) {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.toolbarStyle = .unified
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: RootView().font(.btBody).environment(model).environment(Updater()))
            window.setContentSize(NSSize(width: 1280, height: 820))
            window.center()
            probeWindow = window
        }
        let window = probeWindow ?? NSApp.windows.first { $0.canBecomeMain }
        window?.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .seconds(1))
        Swift.print("nav probe: window " + (window.map { "\(Int($0.frame.width))×\(Int($0.frame.height)), "
            + "visible \($0.occlusionState.contains(.visible)), key \($0.isKeyWindow), opened here \(probeWindow != nil)" } ?? "none: nothing will draw"))
        Swift.print("nav probe: \(model.projects.count) projects, \(model.sessions.count) chats, \(long.count) of \(lines) lines, \(streaming.count) streaming")

        // Agents print from their own reader threads, a few lines a second each.
        let engine = model.engine
        let ids = streaming.map(\.id)
        let streamer = Task.detached {
            var beat = 0
            while !Task.isCancelled {
                for id in ids { engine.record(sessionId: id, SyntheticChats.streamingBeat(beat)) }
                beat += 1
                try? await Task.sleep(for: .milliseconds(40))
            }
        }
        var results: [(String, [Timing])] = []
        // Switching chats: each long chat's first opening, then back and forth.
        var cold: [Timing] = []
        for session in long.prefix(4) { cold.append(await time(drawn: "body.BlockView") { model.open(session.id) }) }
        results.append(("switch chat, first opening", cold))
        var warm: [Timing] = []
        for i in 0..<6 { warm.append(await time(drawn: "body.BlockView") { model.open(long[i % 2].id) }) }
        results.append(("switch chat", warm))
        // For profiling one action: `ABSTRACT_DEMO_NAV_LOOP=<n>` switches back and forth n times more, or opens Automations from a chat.
        if let spec = ProcessInfo.processInfo.environment["ABSTRACT_DEMO_NAV_LOOP"], let n = Int(spec) {
            let automations = ProcessInfo.processInfo.environment["ABSTRACT_DEMO_NAV_LOOP_ACTION"] == "automations"
            Swift.print("nav probe: loop start")
            for i in 0..<n {
                if automations {
                    model.open(long[0].id)
                    try? await Task.sleep(for: .milliseconds(300))
                    model.destination = .automations
                } else {
                    model.open(long[i % 2].id)
                }
                try? await Task.sleep(for: .milliseconds(300))
            }
            Swift.print("nav probe: loop end")
        }
        // Tabs: two chats in tabs, back and forth.
        model.open(long[0].id)
        model.open(long[1].id, newTab: true)
        try? await Task.sleep(for: .milliseconds(500))
        let tabs = model.mainTabs.tabs.suffix(2).map(\.id)
        var tabTimes: [Timing] = []
        for i in 0..<6 { tabTimes.append(await time(drawn: "body.BlockView") { model.activateTab(tabs[i % 2]) }) }
        results.append(("switch tab", tabTimes))
        // Automations and New Chat, each from a chat.
        var automations: [Timing] = []
        var newChat: [Timing] = []
        for _ in 0..<4 {
            model.open(long[0].id)
            try? await Task.sleep(for: .milliseconds(300))
            automations.append(await time(drawn: "body.Automations") { model.destination = .automations })
            model.open(long[1].id)
            try? await Task.sleep(for: .milliseconds(300))
            newChat.append(await time(drawn: "body.Home") { model.startNew() })
        }
        results.append(("open Automations", automations))
        results.append(("open New Chat", newChat))
        // Sending: the composer clears and the message shows.
        var sends: [Timing] = []
        for i in 0..<4 {
            let chat = long[2 + i % 2]
            model.open(chat.id)
            try? await Task.sleep(for: .seconds(1))
            sends.append(await time(drawn: "body.UserBubble") {
                do { try model.sendFollowUp(chat.id, text: "Check the callback again, pass \(i).") }
                catch { Swift.print("nav probe: send failed: \(error.localizedDescription)") }
            })
            try? await Task.sleep(for: .seconds(2))
            if model.isAlive(chat.id) { model.stopAgent(chat.id) }
        }
        results.append(("send a message", sends))
        streamer.cancel()
        // A chat read further up keeps its place when you come back to it.
        model.open(long[0].id)
        try? await Task.sleep(for: .seconds(1))
        if let scrollView = model.keptTranscripts.transcript(long[0].id)?.scrollView {
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: max(0, scrollView.documentView!.frame.height / 2)))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            try? await Task.sleep(for: .milliseconds(500))
            let before = scrollView.contentView.bounds.minY
            model.open(long[1].id)
            try? await Task.sleep(for: .milliseconds(500))
            model.open(long[0].id)
            try? await Task.sleep(for: .milliseconds(500))
            let after = model.keptTranscripts.transcript(long[0].id)?.scrollView.contentView.bounds.minY ?? -1
            Swift.print("nav probe: reading position \(Int(before)) before leaving, \(Int(after)) after coming back")
        }
        // With every long chat shown once: what the app holds, and what the kept transcripts take of it.
        for session in long { model.open(session.id); try? await Task.sleep(for: .milliseconds(600)) }
        model.destination = .automations
        try? await Task.sleep(for: .seconds(1))
        let kept = model.keptTranscripts.count
        let rows = model.keptTranscripts.order.compactMap { model.keptTranscripts.transcript($0)?.rowViews }
        let withKept = footprintMB()
        model.keptTranscripts.release { _ in false }
        try? await Task.sleep(for: .seconds(2))
        let without = footprintMB()
        Swift.print("nav probe: memory after showing \(long.count) long chats: \(withKept) MB with \(kept) transcripts kept (\(rows.map(String.init).joined(separator: ", ")) row views), \(without) MB after letting them go")

        for (name, timings) in results {
            let shown = timings.map(\.shown).sorted()
            let cpu = timings.map(\.cpu).sorted()
            let worst = timings.map(\.longest).max() ?? .zero
            Swift.print("nav probe: \(name): shown median \(HangMonitor.ms(shown[shown.count / 2])) ms, max \(HangMonitor.ms(shown.last ?? .zero)) ms; "
                        + "on the processor median \(HangMonitor.ms(cpu[cpu.count / 2])) ms, max \(HangMonitor.ms(cpu.last ?? .zero)) ms; "
                        + "longest stall in the second after \(HangMonitor.ms(worst)) ms (n=\(timings.count))")
            if let slowest = timings.max(by: { $0.shown < $1.shown }) {
                Swift.print("nav probe:   slowest: \(HangMonitor.describe(slowest.intervals))")
            }
        }
        Swift.print("nav probe: done")
    }

    /// The process's memory as Activity Monitor counts it, in megabytes.
    private static func footprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : -1
    }

    struct Timing {
        /// From the action to the window having drawn it.
        let shown: Duration
        /// The main thread's processor time until then, in the stretches up to it.
        let cpu: Duration
        /// The longest the main thread was busy at a stretch in the second after.
        let longest: Duration
        let intervals: [String: (time: Duration, count: Int)]
    }

    /// Runs `action` and waits a second, then reads the main thread's busy
    /// stretches since: the change shows once the stretch that built the
    /// view counted as `drawn` (a row of the transcript, the screen) ends.
    private static func time(drawn: String, _ action: () -> Void) async -> Timing {
        try? await Task.sleep(for: .milliseconds(300))
        let start = ContinuousClock.now
        action()
        try? await Task.sleep(for: .seconds(1))
        let after = HangMonitor.shared.recent.filter { $0.end > start }
        // The action ran inside the first stretch, which began before it.
        let drawnIn = after.firstIndex { $0.intervals[drawn] != nil } ?? 0
        let upTo = after.prefix(drawnIn + 1)
        let shown = (upTo.last?.end ?? start) - start
        let cpu = upTo.reduce(Duration.zero) { $0 + $1.cpu }
        var intervals: [String: (time: Duration, count: Int)] = [:]
        for busy in upTo {
            for (name, entry) in busy.intervals {
                let sum = intervals[name] ?? (.zero, 0)
                intervals[name] = (sum.time + entry.time, sum.count + entry.count)
            }
        }
        let longest = after.map { $0.end - max($0.start, start) }.max() ?? .zero
        return Timing(shown: shown, cpu: cpu, longest: longest, intervals: intervals)
    }
}
