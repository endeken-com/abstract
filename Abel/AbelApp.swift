import AbelKit
import AbstractCore
import AppKit
import ServiceManagement
import SwiftUI

/// ABEL, Abstract's Built-in Expert Listener (ABS-203): its own app, inside
/// Abstract.app at `Contents/Library/LoginItems`, started at login once you
/// install it from Settings › ABEL. It floats over every app, holds the
/// microphone under its own name, and talks to Abstract over `AppLink`.
///
/// Debug builds also take:
///
///     Abel --simulate "<what you said>" [--simulate "<next>"…] [--wake] [--language pt-BR] [--speech-out <dir>]
///     Abel --simulate-audio <file>… [--wake] [--language pt-BR]
///     Abel --snapshot <dir> [--resources <Abstract.app/Contents/Resources>]
///
/// Each runs against the Abstract of `ABSTRACT_DATA_DIR` (a demo's, say),
/// prints a JSON report and exits; none uses the microphone.
@main
enum AbelMain {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        #if DEBUG
        if let run = DebugRun(arguments) {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            Task { @MainActor in
                let code = await run.perform()
                exit(code)
            }
            app.run()
            return
        }
        #endif
        let app = NSApplication.shared
        let delegate = AbelDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

/// The running assistant: engine, panel, menu bar item, push-to-talk and
/// the screen watch.
@MainActor
final class AbelDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var engine: AbelEngine!
    private var panel: PanelController!
    private var server: AbelLink.LineServer<AbelLink.HelperRequest, AbelLink.HelperReply>?
    private let hotKey = HotKey(.optionSpace)
    private let escapeKey = HotKey(.escape)
    private let screen = ScreenWatch()
    private var statusItem: NSStatusItem?
    private var pausedByYou = false
    private let kept = KeptSettings()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The copy inside Abstract.app can't hold the microphone (macOS
        // judges it as Abstract): when ABEL's own copy exists, that one runs.
        if Bundle.main.bundlePath.contains("/Contents/Library/LoginItems/") {
            let own = AbelInstaller.defaultInstallURL
            if FileManager.default.fileExists(atPath: own.appendingPathComponent("Contents/Info.plist").path) {
                NSWorkspace.shared.openApplication(at: own, configuration: NSWorkspace.OpenConfiguration())
                NSApp.terminate(nil)
                return
            }
        } else if SMAppService.mainApp.status != .enabled {
            // ABEL's own copy starts itself at login.
            try? SMAppService.mainApp.register()
        }
        let storePath = Store.defaultPath()
        guard ProcessInfo.processInfo.isOperatingSystemAtLeast(AbelInstaller.minimumMacOS) else {
            NSApp.terminate(nil)
            return
        }
        let voice = SystemVoice()
        voice.warmUp()
        var speaker: any AbelVoice = voice
        #if DEBUG
        // Demos and checks at night: what ABEL says goes to sound files, not the speakers.
        if let dir = ProcessInfo.processInfo.environment["ABEL_VOICE_OUT"] {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            speaker = RecordingVoice(renderTo: URL(fileURLWithPath: dir))
        }
        #endif
        engine = AbelEngine(ears: DeviceEars(source: MicrophoneSource()), voice: speaker, abstract: LinkedAbstract(storePath: storePath))
        if let settings = kept.settings { engine.use(settings) }
        let apps = MacAppControl()
        #if DEBUG
        // Demos and checks: a stand-in for `shortcuts`, so no real shortcut runs.
        if let tool = ProcessInfo.processInfo.environment["ABEL_SHORTCUTS_TOOL"] { apps.shortcutsTool = tool }
        #endif
        engine.appControl = apps
        engine.onQuit = { forget in
            if forget { try? SMAppService.mainApp.unregister() }
            NSApp.terminate(nil)
        }
        engine.sounds = ChipChimes()
        engine.onSettings = { [weak self] settings in
            self?.kept.settings = settings
            voice.voiceIdentifier = settings.voice
        }
        voice.voiceIdentifier = engine.settings.voice
        let helperPath = AbelLink.helperSocketPath(storePath: storePath)
        let engine = engine!
        server = AbelLink.LineServer(path: helperPath) { request in
            await engine.receive(request)
        }
        // Another ABEL already answers for this data folder.
        guard server != nil else { NSApp.terminate(nil); return }
        panel = PanelController(engine: engine)
        panel.model.onOpen = { [weak self] in self?.openAbstract() }
        panel.model.onTalk = { [weak self] in self?.engine.toggleListening() }
        panel.model.onNewChat = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if await !self.engine.openNewChat() { self.openAbstract() }
            }
        }
        panel.model.onNeedsYou = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if await !self.engine.openWhatNeedsYou() { self.openAbstract() }
            }
        }
        hotKey.onPress = { [weak self] in self?.engine.pushDown() }
        hotKey.onRelease = { [weak self] in self?.engine.pushUp() }
        hotKey.register()
        escapeKey.onPress = { [weak self] in self?.engine.escape() }
        screen.onChange = { [weak self] reading in
            self?.engine.screen(locked: reading.locked, shared: reading.shared)
            self?.updateMenu()
        }
        screen.start()
        makeStatusItem()
        observeListening()
        engine.microphoneAllowed = { MicrophoneSource.isAuthorized }
        Task {
            await engine.start()
            panel.refreshTheme()
            updateMenu()
            // Asked once, right after ABEL is installed, so it shows in
            // Privacy & Security › Microphone before you first talk to it.
            // A moment first, so a launch at login has a session to show the prompt in.
            try? await Task.sleep(for: .seconds(3))
            if MicrophoneSource.canAsk {
                NSApp.activate()
                _ = await MicrophoneSource.requestAccess()
                updateMenu()
            }
        }
        // Settings and names change while ABEL runs: look again now and then.
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.engine.refreshContext(); self.panel.refreshTheme() }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        server?.stop()
        hotKey.unregister()
        escapeKey.unregister()
    }

    /// Escape ends listening while ABEL listens or speaks, and is left
    /// alone otherwise.
    private func observeListening() {
        withObservationTracking { _ = engine.display.mode } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                switch self.engine.display.mode {
                case .listening, .answering: self.escapeKey.register()
                default: self.escapeKey.unregister()
                }
                self.updateMenu()
                self.observeListening()
            }
        }
    }

    // MARK: Menu bar

    private func makeStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // Abstract's mark: ABEL is part of Abstract.
        item.button?.image = AbelMark.image(height: 15)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        updateMenu()
    }

    private func updateMenu() {
        guard let menu = statusItem?.menu, let engine else { return }
        menu.removeAllItems()
        let state = NSMenuItem(title: engine.stateSentence, action: nil, keyEquivalent: "")
        state.isEnabled = false
        menu.addItem(state)
        menu.addItem(.separator())
        let microphone = NSMenuItem(title: MicrophoneSource.stateTitle, action: nil, keyEquivalent: "")
        microphone.isEnabled = false
        menu.addItem(microphone)
        if !MicrophoneSource.isAuthorized {
            menu.addItem(item("Allow the Microphone…", #selector(allowMicrophone)))
        }
        menu.addItem(.separator())
        menu.addItem(item(panel.isHidden ? "Show ABEL" : "Hide ABEL", #selector(toggleOrb)))
        menu.addItem(item(pausedByYou ? "Resume ABEL" : "Pause ABEL", #selector(togglePause)))
        menu.addItem(.separator())
        menu.addItem(item("Open Abstract", #selector(openAbstract)))
        menu.addItem(item("Quit ABEL", #selector(quit)))
        statusItem?.button?.appearsDisabled = engine.machine.isPaused
    }

    /// Read fresh each time it opens: the microphone may have been allowed since.
    func menuNeedsUpdate(_ menu: NSMenu) { updateMenu() }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    /// Asks macOS, with ABEL in front so the prompt can't hide behind
    /// another app. When macOS has an answer stored already and won't ask,
    /// ABEL offers to forget it and ask again, or to open the settings.
    @objc private func allowMicrophone() {
        Task { @MainActor in
            NSApp.activate()
            if MicrophoneSource.canAsk, await MicrophoneSource.requestAccess() { updateMenu(); return }
            guard !MicrophoneSource.isAuthorized else { updateMenu(); return }
            let alert = NSAlert()
            alert.messageText = "ABEL's microphone is turned off"
            alert.informativeText = "macOS has turned the microphone off for ABEL, so it can't ask again by itself. "
                + "Reset and Ask Again forgets that answer and shows the prompt; choose Allow. "
                + "What ABEL hears is understood on this Mac and never sent anywhere or saved."
            alert.addButton(withTitle: "Reset and Ask Again")
            alert.addButton(withTitle: "Open Microphone Settings")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                MicrophoneSource.resetDecision()
                // The permission service restarts after a reset: ask once it's back.
                try? await Task.sleep(for: .milliseconds(1500))
                NSApp.activate()
                _ = await MicrophoneSource.requestAccess()
            case .alertSecondButtonReturn:
                NSWorkspace.shared.open(MicrophoneSource.settingsURL)
            default:
                break
            }
            updateMenu()
        }
    }

    @objc private func toggleOrb() { panel.isHidden.toggle(); updateMenu() }

    @objc private func togglePause() {
        pausedByYou.toggle()
        engine.pause(pausedByYou)
        updateMenu()
    }

    @objc func openAbstract() {
        // Abel.app sits in Abstract.app's Contents/Library/LoginItems.
        let app = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let configuration = NSWorkspace.OpenConfiguration()
        if app.pathExtension == "app" {
            NSWorkspace.shared.openApplication(at: app, configuration: configuration)
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "sh.abstract.app") {
            NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

/// The settings Abstract last handed over, kept for when it's closed.
@MainActor
final class KeptSettings {
    private let key = "settings"

    var settings: AbelSettings? {
        get { UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(AbelSettings.self, from: $0) } }
        set { UserDefaults.standard.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: key) }
    }
}

/// Keeps the floating widget in step with the engine: what ABEL shows,
/// how big the widget is, whether it shows, and Abstract's theme.
@MainActor
final class PanelController {
    private let engine: AbelEngine
    private let window = AbelPanel()
    let model: AbelWidgetModel
    private let host: AbelWidgetHost
    private let themes = AbelPalette.themes(in: AbelPalette.containingAppResources())
    var isKey: Bool { window.isKeyWindow }
    /// Hidden from the menu bar item; it still shows while ABEL listens or answers.
    var isHidden = false { didSet { update() } }

    init(engine: AbelEngine) {
        self.engine = engine
        model = AbelWidgetModel(palette: AbelPalette(theme: themes.standard(.dark)))
        host = AbelWidgetHost(model: model)
        host.sizingOptions = [.intrinsicContentSize]
        window.contentView = host
        window.setContentSize(host.fittingSize)
        window.restoreOrigin()
        update()
        observe()
    }

    func refreshTheme() {
        let theme = engine.context?.themeId.map { themes.theme($0) } ?? themes.standard(.dark)
        model.palette = AbelPalette(theme: theme)
        update()
    }

    private func observe() {
        withObservationTracking {
            _ = engine.display
            _ = engine.settings.showOrb
            _ = engine.context
            _ = model.hovered
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.update()
                self?.observe()
            }
        }
    }

    private func update() {
        if model.display != engine.display { model.display = engine.display }
        if model.needsYou != engine.needsYouCount { model.needsYou = engine.needsYouCount }
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        if window.frame.size != size { window.resize(to: size) }
        let shows = engine.display.isExpanded || (engine.settings.showOrb && !isHidden)
        if shows { window.orderFrontRegardless() } else { window.orderOut(nil) }
    }
}
