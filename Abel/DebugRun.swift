#if DEBUG
import AbelKit
import AbstractCore
import AppKit

/// Debug-only ways to drive the real pipeline without a microphone, for
/// tests, demos and pull requests (ABS-203). See `AbelMain`.
@MainActor
struct DebugRun {
    enum Mode {
        case simulate([String])
        case audio([URL])
        case snapshot(URL)
    }

    let mode: Mode
    let language: String
    let wake: Bool
    let speechOut: URL?
    let resources: URL?

    init?(_ arguments: [String]) {
        func values(_ flag: String) -> [String] {
            arguments.indices.filter { arguments[$0] == flag && $0 + 1 < arguments.count }.map { arguments[$0 + 1] }
        }
        language = values("--language").first ?? "en-US"
        wake = arguments.contains("--wake")
        speechOut = values("--speech-out").first.map { URL(fileURLWithPath: $0) }
        resources = values("--resources").first.map { URL(fileURLWithPath: $0) }
        if !values("--simulate").isEmpty {
            mode = .simulate(values("--simulate"))
        } else if let first = arguments.firstIndex(of: "--simulate-audio") {
            let files = arguments[(first + 1)...].prefix { !$0.hasPrefix("--") }.map { URL(fileURLWithPath: $0) }
            mode = .audio(files)
        } else if let dir = values("--snapshot").first {
            mode = .snapshot(URL(fileURLWithPath: dir))
        } else {
            return nil
        }
    }

    func perform() async -> Int32 {
        switch mode {
        case let .simulate(transcripts):
            if let speechOut { try? FileManager.default.createDirectory(at: speechOut, withIntermediateDirectories: true) }
            let apps = MacAppControl()
            if let tool = ProcessInfo.processInfo.environment["ABEL_SHORTCUTS_TOOL"] { apps.shortcutsTool = tool }
            let report = await AbelSimulation.run(transcripts, language: language, abstract: LinkedAbstract(), renderTo: speechOut,
                                                  trigger: wake ? .wakePhrase : .pushToTalk, apps: apps)
            // Rendering into files finishes in the background.
            if speechOut != nil { try? await Task.sleep(for: .seconds(3)) }
            print(json(report))
            return 0
        case let .audio(files):
            return await hear(files)
        case let .snapshot(dir):
            return snapshot(into: dir)
        }
    }

    /// The files go through the real recognizer and wake listener as if
    /// spoken into the microphone, at real speed.
    private func hear(_ files: [URL]) async -> Int32 {
        guard #available(macOS 26, *) else { return 2 }
        let source = FileAudioSource(urls: files, realTime: true, gap: 2, holdsOpen: true)
        let ears = DeviceEars(source: source, silenceAfterWake: .seconds(4))
        let voice = RecordingVoice()
        let abstract = Overriding(base: LinkedAbstract(), wake: wake, language: language)
        let engine = AbelEngine(ears: ears, voice: voice, abstract: abstract)
        engine.lingering = .seconds(1)
        let timeline = Timeline(engine: engine)
        timeline.observe()
        // The real panel, over whatever app is in front, which must stay in front.
        let frontBefore = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        let panel = PanelController(engine: engine)
        var panelWasKey = false, sawExpanded = false
        await engine.start()
        var ended = false
        source.onEnd = { ended = true }
        if !wake { engine.pushDown() }
        while !ended {
            try? await Task.sleep(for: .milliseconds(100))
            panelWasKey = panelWasKey || panel.isKey
            sawExpanded = sawExpanded || engine.display.isExpanded
        }
        if !wake { engine.pushUp() }
        try? await Task.sleep(for: .seconds(wake ? 5 : 4))
        source.stop()
        let report: [String: Any] = [
            "events": engine.history.map { ["kind": $0.kind.rawValue, "text": $0.text] },
            "spoken": voice.spoken.map(\.text),
            "panel": timeline.entries,
            "frontmostBefore": frontBefore,
            "frontmostAfter": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "",
            "panelBecameKey": panelWasKey,
            "panelExpanded": sawExpanded,
            "abelActive": NSApp.isActive,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        print(String(decoding: data, as: UTF8.self))
        return 0
    }

    /// The panel idle, listening and answering, in Graphite, Paper and Ink.
    private func snapshot(into dir: URL) -> Int32 {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let themes = AbelPalette.themes(in: resources ?? AbelPalette.containingAppResources())
        let states: [(String, AbelDisplay)] = [
            ("idle", AbelDisplay()),
            ("hover", AbelDisplay()),
            ("listening", AbelDisplay(mode: .listening, words: "add a test for the sidebar grouping")),
            ("answering", AbelDisplay(mode: .answering, words: "",
                                      answer: "Sidebar fix says: I added a test for the grouping, and 12 lines of code.")),
            ("asking", AbelDisplay(mode: .answering, words: "approve",
                                   answer: "Let Sidebar fix run swift test? Say yes to allow.")),
            ("script", AbelDisplay(mode: .answering, words: "Notes",
                                   answer: "Run this 3-line AppleScript in Notes? It's on the panel. Say yes to run it.",
                                   detail: "tell application \"Notes\"\n    make new note with properties {body:\"Build log\"}\nend tell")),
            ("paused", AbelDisplay(mode: .paused, answer: AbelMachine.PauseReason.screenShared.sentence)),
        ]
        var written: [String] = []
        for id in [ThemeCatalog.graphiteId, ThemeCatalog.paperId, ThemeCatalog.inkId] {
            let theme = themes.theme(id)
            for (name, display) in states {
                let palette = AbelPalette(theme: theme)
                // A desktop-like backdrop, as the widget really floats over one.
                let desk = Swatch(0x4A3426)
                guard let png = AbelSnapshot.png(display: display, palette: palette, backdrop: desk,
                                                 hovered: name == "hover", needsYou: name == "hover" ? 1 : 0)
                else { continue }
                let url = dir.appendingPathComponent("abel-\(theme.shortId)-\(name).png")
                try? png.write(to: url)
                written.append(url.lastPathComponent)
            }
        }
        print(json(["written": written]))
        return written.isEmpty ? 1 : 0
    }

    private func json(_ value: some Encodable) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}

/// The panel's modes as they change, with the seconds since the start.
@MainActor
final class Timeline {
    let engine: AbelEngine
    let started = Date()
    var entries: [[String: String]] = []

    init(engine: AbelEngine) { self.engine = engine }

    func observe() {
        withObservationTracking { _ = engine.display } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.entries.append(["t": String(format: "%.2f", Date().timeIntervalSince(self.started)),
                                     "mode": self.engine.display.mode.rawValue, "words": self.engine.display.words,
                                     "answer": self.engine.display.answer])
                self.observe()
            }
        }
    }
}

/// The real Abstract, with the wake phrase and language this run asks for.
nonisolated struct Overriding: AbstractConnection {
    let base: any AbstractConnection
    let wake: Bool
    let language: String

    func ask(_ request: AbelLink.Request) async -> AbelLink.Reply? {
        var reply = await base.ask(request)
        if request.kind == .context {
            var context = reply?.context ?? AbelLink.Context()
            context.settings.wakePhrase = wake
            context.settings.languages = [language]
            reply = AbelLink.Reply(ok: true, context: context)
        }
        return reply
    }
}
#endif
