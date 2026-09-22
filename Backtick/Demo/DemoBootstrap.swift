import AppKit
import Darwin
import SwiftUI
import BacktickCore

/// Demo mode: `Backtick.app/Contents/MacOS/Backtick --demo [--snapshot <dir>]`.
///
/// Seeds throwaway git repositories and starts real chats against a scripted
/// stand-in agent. With `--snapshot`, it walks every main screen in both
/// themes, writes PNGs of the window, and quits. Nothing touches the real
/// database or the developer's repositories.
@MainActor
final class DemoBootstrap {
    static let current: DemoBootstrap? = {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("--demo") else { return nil }
        let snapshot = args.firstIndex(of: "--snapshot").flatMap { i in i + 1 < args.count ? args[i + 1] : nil }
        setvbuf(stdout, nil, _IONBF, 0)
        return DemoBootstrap(snapshotDir: snapshot)
    }()

    let root: URL
    let snapshotDir: String?

    init(snapshotDir: String?) {
        self.snapshotDir = snapshotDir
        root = FileManager.default.temporaryDirectory.appendingPathComponent("backtick-demo-\(Int(Date().timeIntervalSince1970))")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("BACKTICK_DATA_DIR", root.appendingPathComponent("data").path, 1)
    }

    func makeModel() -> AppModel {
        let dataDir = root.appendingPathComponent("data")
        try? FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        let store = try! Store(path: dataDir.appendingPathComponent("backtick.sqlite").path)
        try? store.setSetting("worktreeTemplate", root.path + "/worktrees/{repo}-{hash}/{slug}")
        let engine = SessionEngine(executor: LocalExecutor.shared, logDirectory: dataDir.appendingPathComponent("sessions"))
        return AppModel(store: store, engine: engine, executor: LocalExecutor.shared, isDemo: true)
    }

    func run(_ model: AppModel) async {
        log("demo: seeding repositories in \(root.path)")
        let backtick = await makeRepo("backtick", model)
        let payments = await makeRepo("payments-api", model)
        let marketing = await makeRepo("marketing-site", model)
        model.reload()
        log("demo: \(model.projects.count) projects")

        await chat(model, backtick, "Derive chat status from process liveness", .autoEdits)
        await chat(model, marketing, "Tighten the hero copy and fix layout shift on mobile", .autoEdits, provider: "codex")
        await chat(model, payments, "Retry idempotent webhook deliveries with exponential backoff", .ask)
        log("demo: \(model.sessions.count) chats started")
        await waitUntil(model) { m in m.sessions.filter { [.idle, .waitingInput, .finished].contains($0.status) }.count >= 3 }
        log("demo: chat states " + model.sessions.map { "\($0.name.prefix(20))=\($0.status.rawValue)" }.joined(separator: ", "))

        let running = backtick.map { p in Task { await self.chat(model, p, "Add a command palette with fuzzy search", .autoEdits) } }
        _ = running

        try? model.store.save(Automation(name: "Nightly dependency bump", prompt: "Update dependencies, run the tests, and summarise anything that broke.",
                                         providerId: "claude", projectId: backtick?.id, rrule: "FREQ=DAILY;BYHOUR=9;BYMINUTE=0",
                                         timezone: TimeZone.current.identifier,
                                         nextRunAt: try? Schedule.nextOccurrence(rrule: "FREQ=DAILY;BYHOUR=9;BYMINUTE=0", timezone: TimeZone.current.identifier, dtstart: Date(), after: Date())))
        try? model.store.save(Automation(name: "Triage new issues", prompt: "Label and prioritise issues opened since yesterday.",
                                         providerId: "claude", projectId: payments?.id, rrule: "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR;BYHOUR=8;BYMINUTE=30",
                                         timezone: TimeZone.current.identifier,
                                         nextRunAt: try? Schedule.nextOccurrence(rrule: "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR;BYHOUR=8;BYMINUTE=30", timezone: TimeZone.current.identifier, dtstart: Date(), after: Date())))
        model.reload()

        guard let snapshotDir else { return }
        log("demo: capturing snapshots")
        await Snapshotter(model: model, directory: snapshotDir).captureAll()
        NSApp.terminate(nil)
    }

    private func makeRepo(_ name: String, _ model: AppModel) async -> Project? {
        let dir = root.appendingPathComponent("repos").appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent("src/sessions"), withIntermediateDirectories: true)
        let row = """
        import SwiftUI

        /// One chat in the sidebar.
        struct SessionRow: View {
            let session: Session

            // Rows read their status straight from the model.


            var body: some View {
            let status = session.status
            HStack(spacing: 8) {
                StatusDot(status: status)
                Text(session.name)
                    .lineLimit(1)
                Spacer()
            }
            }
        }

        """
        try? row.write(to: dir.appendingPathComponent("src/sessions/SessionRow.swift"), atomically: true, encoding: .utf8)
        try? "# \(name)\n\nDemo repository created by Backtick.\n".write(to: dir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let exec = model.executor
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "demo@backtick.local"], ["config", "user.name", "Backtick Demo"],
                     ["add", "-A"], ["commit", "-qm", "Initial commit"]] {
            _ = try? await exec.run("git", args, cwd: dir.path)
        }
        let probe: AppModel.Probe
        do { probe = try await model.probe(directory: dir.path) } catch { log("demo: probe failed for \(name): \(error.localizedDescription)"); return nil }
        try? model.addProject(probe, name: name, baseRef: "main", providerId: "claude", policy: .autoEdits)
        return model.projects.first { $0.rootPath == probe.rootPath }
    }

    private func chat(_ model: AppModel, _ project: Project?, _ prompt: String, _ policy: PermissionPolicy, provider: String = "claude") async {
        guard let project else { return }
        do {
            try await model.startChat(projectId: project.id, providerId: provider, prompt: prompt, baseRef: "main", policy: policy)
        } catch {
            log("demo: chat failed: \(error.localizedDescription)")
        }
    }

    func waitUntil(_ model: AppModel, timeout: TimeInterval = 30, _ condition: (AppModel) -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(model), Date() < deadline { try? await Task.sleep(for: .milliseconds(200)) }
    }
}

/// Walks the app through its screens and writes a PNG of each.
@MainActor
struct Snapshotter {
    let model: AppModel
    let directory: String

    func captureAll() async {
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        NSApp.activate()
        // Bootstrap starts at launch, so the window may not exist yet.
        let deadline = Date().addingTimeInterval(20)
        while !NSApp.windows.contains(where: { $0.canBecomeMain && $0.isVisible }), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(200))
        }
        NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .milliseconds(600))
        let idle = model.sessions.first { $0.status == .idle }
        let needsYou = model.sessions.first { $0.status == .waitingInput }

        let themes: [ThemeChoice] = ProcessInfo.processInfo.arguments.contains("--quick") ? [.graphite] : [.graphite, .paper]
        for theme in themes {
            UserDefaults.standard.set(theme.rawValue, forKey: "theme")
            try? await Task.sleep(for: .milliseconds(500))
            let t = theme.rawValue

            model.destination = .home
            await shot("\(t)-01-home")

            if let working = model.sessions.first(where: { $0.status == .running }) ?? idle {
                model.open(working.id)
                await shot("\(t)-02-chat-working")
            }
            if let idle {
                model.open(idle.id)
                await shot("\(t)-03-chat-done", settle: 1.2)
                model.chatTab = .changes
                await shot("\(t)-04-changes", settle: 1.5)
                model.chatTab = .chat
            }
            if let needsYou {
                model.open(needsYou.id)
                await shot("\(t)-05-needs-you", settle: 1.0)
            }

            model.showNewChat(in: model.projects.first?.id)
            await shot("\(t)-06-new-chat", settle: 0.8)
            model.newChatProjectId = nil

            model.isPaletteOpen = true
            await shot("\(t)-07-palette", settle: 0.6)
            model.isPaletteOpen = false

            model.destination = .automations
            await shot("\(t)-08-automations", settle: 0.8)
            model.destination = .worktrees
            await shot("\(t)-09-worktrees", settle: 1.2)
        }
        UserDefaults.standard.set(ThemeChoice.graphite.rawValue, forKey: "theme")
    }

    private func shot(_ name: String, settle: Double = 0.7) async {
        try? await Task.sleep(for: .seconds(settle))
        guard let image = WindowCapture.image() else {
            let states = NSApp.windows.map { w in
                "[\(w.className) visible=\(w.isVisible) main=\(w.canBecomeMain) activeSpace=\(w.isOnActiveSpace) occluded=\(!w.occlusionState.contains(.visible)) frame=\(Int(w.frame.width))x\(Int(w.frame.height))]"
            }
            log("snapshot failed: \(name) windows=\(states.joined(separator: " "))")
            return
        }
        let url = URL(fileURLWithPath: directory).appendingPathComponent("\(name).png")
        try? image.write(to: url)
        log("snapshot: \(url.path)")
    }
}

/// Renders the app's own main window, attached sheets composited on top.
/// Screen Recording permission is not needed because only our own views are
/// drawn. Drawing happens under the window's effective appearance so dynamic
/// colours resolve the way they do on screen.
@MainActor
enum WindowCapture {
    enum Method { case cacheDisplay, layer, windowServer }

    /// `CGWindowListCreateImage` is hidden from the macOS 15 SDK in favour of
    /// ScreenCaptureKit, but still works for the calling process's own windows
    /// without Screen Recording permission, and is the only path that includes
    /// window-server effects (glass, scroll views, sheets).
    private typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
    private static let createImage: CreateImage? = {
        guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW),
              let sym = dlsym(handle, "CGWindowListCreateImage") else { return nil }
        return unsafeBitCast(sym, to: CreateImage.self)
    }()

    static func windowServerImage() -> Data? {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }), let create = createImage else { return nil }
        // kCGWindowListOptionIncludingWindow = 1 << 3; imageOption: boundsIgnoreFraming (1) | bestResolution (1 << 3)
        guard let cg = create(.null, 1 << 3, UInt32(window.windowNumber), (1 << 0) | (1 << 3))?.takeRetainedValue() else { return nil }
        // Sheets are separate windows; composite them over the main one.
        let sheets = window.sheets.filter(\.isVisible)
        if sheets.isEmpty { return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) }
        let scale = CGFloat(cg.width) / window.frame.width
        guard let ctx = CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        for sheet in sheets {
            guard let img = create(.null, 1 << 3, UInt32(sheet.windowNumber), (1 << 0) | (1 << 3))?.takeRetainedValue() else { continue }
            let x = (sheet.frame.minX - window.frame.minX) * scale
            let y = (sheet.frame.minY - window.frame.minY) * scale
            ctx.draw(img, in: CGRect(x: x, y: y, width: CGFloat(img.width), height: CGFloat(img.height)))
        }
        guard let out = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:])
    }

    static func image(method: Method = .windowServer) -> Data? {
        if method == .windowServer { return windowServerImage() }
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }),
              let frameView = window.contentView?.superview else { return nil }
        let size = frameView.bounds.size
        let scale = window.backingScaleFactor
        let width = Int(size.width * scale), height = Int(size.height * scale)
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)

        func draw(_ view: NSView, at origin: CGPoint) {
            window.effectiveAppearance.performAsCurrentDrawingAppearance {
                ctx.saveGState()
                ctx.translateBy(x: origin.x, y: origin.y)
                switch method {
                case .layer:
                    if let layer = view.layer {
                        // CALayer draws top-down; flip into CG's bottom-up space.
                        ctx.translateBy(x: 0, y: view.bounds.height)
                        ctx.scaleBy(x: 1, y: -1)
                        layer.render(in: ctx)
                    }
                case .cacheDisplay, .windowServer:
                    if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                        view.cacheDisplay(in: view.bounds, to: rep)
                        if let cg = rep.cgImage { ctx.draw(cg, in: CGRect(origin: .zero, size: view.bounds.size)) }
                    }
                }
                ctx.restoreGState()
            }
        }

        draw(frameView, at: .zero)
        for child in window.sheets + (window.childWindows ?? []) where child.isVisible {
            guard let v = child.contentView?.superview else { continue }
            draw(v, at: CGPoint(x: child.frame.minX - window.frame.minX, y: child.frame.minY - window.frame.minY))
        }
        guard let cg = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }
}

func log(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}
