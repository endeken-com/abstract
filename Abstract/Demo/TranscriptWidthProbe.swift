import AppKit
import AbstractCore

/// Demo mode's check that a transcript's rows are drawn at the chat column's
/// width (ABS-212). `ABSTRACT_DEMO_WIDTH=<delay>` waits, adds two long chats,
/// keeps an agent streaming into the first, shows the second for
/// `ABSTRACT_DEMO_WIDTH_HIDDEN` seconds (30 by default) and comes back; then
/// drags the side panel to its widest, leaving the chat its narrowest, and
/// back, while the agent streams. After each, every row on screen must have
/// been built at the column's width: it logs `width probe: PASS` or `FAIL`.
/// `ABSTRACT_DEMO_WIDTH_SHOT=<dir>` saves the window after each step.
/// The navigation probe runs the same check (`check`) on the chats it shows.
enum TranscriptWidthProbe {
    static func runIfRequested(_ model: AppModel, repo: Project?) {
        guard let spec = ProcessInfo.processInfo.environment["ABSTRACT_DEMO_WIDTH"], let delay = Double(spec) else { return }
        Task {
            try? await Task.sleep(for: .seconds(delay))
            await run(model, repo: repo)
        }
    }

    private static func run(_ model: AppModel, repo: Project?) async {
        let env = ProcessInfo.processInfo.environment
        let hidden = Double(env["ABSTRACT_DEMO_WIDTH_HIDDEN"] ?? "") ?? 30
        let shots = env["ABSTRACT_DEMO_WIDTH_SHOT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let shots { try? FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true) }

        // Two long chats in the demo's repository: one with an agent working, one idle.
        let (_, sessions) = SyntheticChats.profile(projects: 1, chats: 14)
        guard var streaming = sessions.first(where: { $0.status == .running }),
              var other = sessions.first(where: { $0.status == .idle }), let repo else {
            log("width probe: FAIL, no repository to put the chats in"); return
        }
        let encoder = JSONEncoder()
        let logText = SyntheticChats.log(lines: 400).map { String(decoding: try! encoder.encode($0), as: UTF8.self) }.joined(separator: "\n") + "\n"
        for session in [streaming, other] {
            try? logText.write(to: model.engine.logsURL.appendingPathComponent("\(session.id).jsonl"), atomically: true, encoding: .utf8)
        }
        for i in [0, 1] {
            var session = i == 0 ? streaming : other
            session.projectId = repo.id
            session.worktreePath = repo.rootPath
            session.branch = "main"
            session.name = i == 0 ? "Width probe: streaming" : "Width probe: other chat"
            try? model.store.save(session)
            if i == 0 { streaming = session } else { other = session }
        }
        model.reload()
        NSApp.activate()
        NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)

        // An agent printing a few words a second, from its own thread.
        let engine = model.engine
        let id = streaming.id
        func stream() -> Task<Void, Never> {
            Task.detached {
                var beat = 1
                while !Task.isCancelled {
                    engine.record(sessionId: id, SyntheticChats.streamingBeat(beat))
                    beat = beat % 40 == 39 ? beat + 2 : beat + 1
                    try? await Task.sleep(for: .milliseconds(40))
                }
            }
        }
        var streamer = stream()
        defer { streamer.cancel() }
        var failures = 0

        model.open(streaming.id)
        try? await Task.sleep(for: .seconds(2))
        failures += report("shown", check(model, streaming.id), shot: shots?.appendingPathComponent("1-shown.png"))

        // While another chat shows, the agent finishes its reply: the rows on
        // screen change once more, then not again.
        model.open(other.id)
        try? await Task.sleep(for: .seconds(2))
        streamer.cancel()
        if let result = SyntheticChats.turn(0, at: Date()).last { engine.record(sessionId: id, result) }
        try? await Task.sleep(for: .seconds(max(0, hidden - 2)))
        model.open(streaming.id)
        try? await Task.sleep(for: .seconds(1.5))
        failures += report("back after \(Int(hidden)) s hidden", check(model, streaming.id),
                           shot: shots?.appendingPathComponent("2-back-from-hidden.png"))

        // The side panel dragged to its widest and back, a step a frame, while it streams.
        streamer = stream()
        if !model.layout(for: streaming.id).side.isOpen { model.togglePanel(.side, in: streaming.id) }
        try? await Task.sleep(for: .seconds(1))
        let start = model.layout(for: streaming.id).side.size
        let widest = PanelSlot.side.sizes.upperBound
        func drag(from: Double, to: Double) async {
            let steps = 40
            for step in 1...steps {
                let size = from + (to - from) * Double(step) / Double(steps)
                model.updateLayout(streaming.id) { $0.resize(.side, to: size) }
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
        await drag(from: start, to: widest)
        try? await Task.sleep(for: .seconds(1.5))
        failures += report("side panel at its widest", check(model, streaming.id),
                           shot: shots?.appendingPathComponent("3-side-panel-widest.png"))
        await drag(from: widest, to: start)
        try? await Task.sleep(for: .seconds(1.5))
        failures += report("side panel back", check(model, streaming.id),
                           shot: shots?.appendingPathComponent("4-side-panel-back.png"))

        log("width probe: \(failures == 0 ? "PASS" : "FAIL, \(failures) checks with rows at the wrong width")")
    }

    /// Whether every row built in the chat's transcript (on screen, or kept
    /// near it for scrolling back), and its footer, was built at the column's
    /// width. Nil when the chat has no transcript.
    @MainActor
    static func check(_ model: AppModel, _ sessionId: String) -> (column: CGFloat, wrong: [CGFloat], rows: Int)? {
        guard let transcript = model.keptTranscripts.transcript(sessionId) else { return nil }
        let (column, rows) = transcript.builtWidths
        return (column, rows.filter { $0 != column }, rows.count)
    }

    /// Logs one check, saves the window, and counts a failure.
    private static func report(_ step: String, _ result: (column: CGFloat, wrong: [CGFloat], rows: Int)?, shot: URL?) -> Int {
        if let shot, let image = WindowCapture.image() { try? image.write(to: shot) }
        guard let result else { log("width probe: \(step): no transcript"); return 1 }
        let widths = Set(result.wrong).sorted().map { String(Int($0)) }.joined(separator: ", ")
        log("width probe: \(step): column \(Int(result.column)) pt, \(result.rows) rows, "
            + (result.wrong.isEmpty ? "all at the column's width" : "\(result.wrong.count) built at \(widths) pt"))
        return result.wrong.isEmpty ? 0 : 1
    }
}
