import AppKit
import Darwin
import Observation
@preconcurrency import SwiftTerm
import AbstractCore

/// One terminal pane's shell and the view that shows it.
///
/// Lives in `TerminalRegistry`, not in SwiftUI, so switching tabs or chats
/// (which tears the SwiftUI view down) never touches the shell. The view is
/// the same `LocalProcessTerminalView` for the pane's whole life; SwiftUI
/// only borrows it. When the shell exits the scrollback stays, and
/// `restart()` starts a fresh shell in the same view.
@MainActor
@Observable
final class TerminalHost {
    enum Phase: Equatable {
        /// Waiting for the login PATH and a real size before spawning.
        case starting
        case running
        case exited(code: Int32?)
        case failed(String)
    }

    let paneId: String
    private(set) var phase: Phase = .starting
    /// What its tab says: the program in front, else the shell's own title
    /// (OSC 0/2, e.g. "you@mac: ~/repo"), else the shell's name.
    private(set) var title = "Terminal"

    @ObservationIgnored let container: TerminalContainerView
    @ObservationIgnored var terminal: AbstractTerminalView { container.terminal }
    /// The mount (SwiftUI's view) currently showing `container`; newest wins.
    @ObservationIgnored weak var owner: NSView?
    /// Take first responder the next time the pane is shown: true for a new
    /// pane, then whether the terminal had focus when it was last hidden.
    @ObservationIgnored var focusOnShow = true

    @ObservationIgnored private let directory: String?
    @ObservationIgnored private var searchPath: String?
    @ObservationIgnored private var pid: pid_t = 0
    @ObservationIgnored private var exitWatch: DispatchSourceProcess?
    @ObservationIgnored private var shellTitle: String?
    @ObservationIgnored private var titleWatch: Task<Void, Never>?
    /// A fixed tab title ("Setup", "Run") in place of the program in front.
    @ObservationIgnored private(set) var label: String?
    /// Commands to type once the shell is at its prompt.
    @ObservationIgnored private var pending: [String] = []
    @ObservationIgnored private var typing: Task<Void, Never>?
    /// For a chat on another Mac: its shell runs there, this view shows it.
    @ObservationIgnored private weak var remote: RemoteLink?
    @ObservationIgnored private var remoteId: Int?
    @ObservationIgnored private var remoteStarted = Date.distantFuture
    var isRemote: Bool { remote != nil }

    init(paneId: String, directory: String?, remote: RemoteLink? = nil) {
        self.paneId = paneId
        self.directory = directory
        self.remote = remote
        container = TerminalContainerView()
        container.host = self
        terminal.host = self
        terminal.processDelegate = self
        Task { [weak self] in
            // A GUI app does not inherit the shell PATH; use the login one.
            let path = await LocalExecutor.shared.searchPath
            self?.searchPath = path
            self?.startIfReady()
        }
    }

    // MARK: Lifecycle

    /// Spawns the shell once the PATH is known and the view has its real
    /// size, so the shell draws its first prompt at the right width.
    func startIfReady() {
        if let remote {
            guard phase == .starting, container.hasUsableSize, let directory else { return }
            let size = terminal.getTerminal()
            remoteId = remote.openTerminal(cwd: directory, cols: size.cols, rows: size.rows, output: { [weak self] data in
                self?.terminal.feed(byteArray: ArraySlice(data))
            }, exit: { [weak self] code in
                self?.remoteEnded(code)
            })
            remoteStarted = Date()
            phase = .running
            typePending()
            return
        }
        guard phase == .starting, let searchPath, container.hasUsableSize else { return }
        let shell = TerminalShell.executable()
        let cwd = TerminalShell.workingDirectory(directory)
        let theme = TerminalTheme.resolve(for: container.effectiveAppearance)
        terminal.startProcess(
            executable: shell, args: [],
            environment: TerminalShell.environment(path: searchPath, shell: shell, cwd: cwd, darkBackground: theme.isDark),
            execName: "-" + (shell as NSString).lastPathComponent, // leading dash = login shell
            currentDirectory: cwd)
        let process = terminal.process!
        guard process.running, process.shellPid > 0 else {
            phase = .failed("Couldn't start \(shell)")
            return
        }
        pid = process.shellPid
        phase = .running
        watchExit(of: pid)
        watchTitle()
        typePending()
    }

    // MARK: Commands

    /// Type `command` and Return into the shell, as if at the keyboard, once
    /// it is at its prompt: now, or when it starts. `interrupt` first sends
    /// ⌃C, stopping whatever runs in front (a previous run) or clearing a
    /// half-typed line. A tab with a `label` keeps that title.
    func run(_ command: String, label: String? = nil, interrupt: Bool = false) {
        if let label {
            self.label = label
            title = label
        }
        if interrupt, phase == .running { sendToShell([3]) }
        pending.append(command.hasSuffix("\n") ? command : command + "\n")
        typePending()
    }

    /// Waits (up to 10 s) for the shell to be in front with its line editor
    /// up, so the text lands on a prompt and never in another program. Gives
    /// up rather than typing into something that ignored ⌃C.
    private func typePending() {
        guard phase == .running, !pending.isEmpty, typing == nil else { return }
        typing = Task { [weak self] in
            var ready = false
            for attempt in 0..<200 {
                guard let self, self.phase == .running else { break }
                if self.atPrompt(waited: attempt) { ready = true; break }
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard let self else { return }
            self.typing = nil
            guard ready, self.phase == .running else { self.pending = []; return }
            let text = self.pending.joined()
            self.pending = []
            self.sendToShell(Array(text.utf8))
        }
    }

    /// Keys to the shell, here or on the other Mac.
    func sendToShell(_ bytes: [UInt8]) {
        if let remote, let remoteId {
            remote.terminalInput(remoteId, Data(bytes))
        } else {
            terminal.process.send(data: ArraySlice(bytes))
        }
    }

    fileprivate func remoteResized(cols: Int, rows: Int) {
        guard let remote, let remoteId else { return }
        remote.resizeTerminal(remoteId, cols: cols, rows: rows)
    }

    private func remoteEnded(_ code: Int32?) {
        guard phase == .running else { return }
        remoteId = nil
        phase = .exited(code: code)
        terminal.feed(text: "\u{1b}[?25l")
    }

    /// The shell, not a program it started, owns the terminal, and its line
    /// editor has the tty out of canonical mode. Shells without a line
    /// editor stay canonical, so after a while the first test is enough.
    private func atPrompt(waited attempt: Int) -> Bool {
        // A shell on another Mac can't be asked; its prompt is up in a moment.
        if isRemote { return Date().timeIntervalSince(remoteStarted) > 1.2 }
        let fd = terminal.process.childfd
        guard fd >= 0, pid > 0, tcgetpgrp(fd) == pid else { return false }
        var mode = termios()
        guard tcgetattr(fd, &mode) == 0 else { return attempt > 30 }
        return mode.c_lflag & tcflag_t(ICANON) == 0 || attempt > 30
    }

    /// A fresh shell in the same view, below the old scrollback.
    func restart() {
        switch phase {
        case .exited, .failed: break
        case .starting, .running: return
        }
        // Normally already stopped; covers an exit SwiftTerm has not seen yet.
        if let remoteId { remote?.closeTerminal(remoteId); self.remoteId = nil }
        if !isRemote, terminal.process.running { terminal.terminate() }
        resetModes()
        phase = .starting
        startIfReady()
        if let window = terminal.window { window.makeFirstResponder(terminal) }
    }

    /// Hang up the shell, like closing a terminal window, and let it go.
    func shutdown() {
        titleWatch?.cancel()
        exitWatch?.cancel()
        exitWatch = nil
        if isRemote {
            if let remoteId { remote?.closeTerminal(remoteId) }
            remoteId = nil
            phase = .exited(code: nil)
            container.removeFromSuperview()
            owner = nil
            return
        }
        if phase == .running, pid > 0 {
            let fd = terminal.process.childfd
            if fd >= 0 {
                let foreground = tcgetpgrp(fd)
                if foreground > 0, foreground != pid { kill(-foreground, SIGHUP) }
            }
            kill(-pid, SIGHUP)
            kill(pid, SIGHUP)
        }
        // Closes the pty and stops SwiftTerm's own watcher.
        if terminal.process.running { terminal.terminate() }
        if phase == .running, pid > 0 { TerminalShell.reapInBackground(pid) }
        phase = .exited(code: nil)
        container.removeFromSuperview()
        owner = nil
    }

    // MARK: Title

    /// The foreground program changes without telling anyone, so look once a
    /// second: two cheap syscalls.
    private func watchTitle() {
        titleWatch?.cancel()
        titleWatch = Task { [weak self] in
            while !Task.isCancelled {
                self?.refreshTitle()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    fileprivate func refreshTitle() {
        if isRemote {
            let next = label ?? shellTitle ?? "Terminal"
            if next != title { title = next }
            return
        }
        guard phase == .running, pid > 0 else { return }
        let fd = terminal.process.childfd
        var running: String?
        if fd >= 0 {
            let foreground = tcgetpgrp(fd)
            if foreground > 0, foreground != pid { running = Self.processName(foreground) }
        }
        let next = label ?? running ?? shellTitle ?? Self.processName(pid) ?? "Terminal"
        if next != title { title = next }
    }

    fileprivate func setShellTitle(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        shellTitle = trimmed.isEmpty ? nil : trimmed
        refreshTitle()
    }

    private static func processName(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        return length > 0 ? String(cString: buffer) : nil
    }

    // MARK: Exit

    /// SwiftTerm's watcher can be cancelled by the pty's EOF arriving first,
    /// and then it never reports the exit; watch the pid ourselves as well.
    private func watchExit(of pid: pid_t) {
        exitWatch?.cancel()
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.shellEnded(pid: pid, rawStatus: nil) }
        }
        exitWatch = source
        source.activate()
    }

    /// Called by our watcher and by SwiftTerm's (with the wait status it
    /// reaped). Whichever reaps first wins; the other finds nothing to do.
    func shellEnded(pid: pid_t, rawStatus: Int32?) {
        guard pid == self.pid, phase == .running else { return }
        var status: Int32 = 0
        let reaped = waitpid(pid, &status, WNOHANG)
        if reaped == 0 { return } // not exited after all
        let code: Int32? = reaped == pid ? TerminalShell.exitCode(status) : rawStatus.map(TerminalShell.exitCode)
        exitWatch?.cancel()
        exitWatch = nil
        phase = .exited(code: code)
        terminal.feed(text: "\u{1b}[?25l") // no live-looking cursor in a dead shell
    }

    /// Leave full-screen apps' modes behind so the new prompt lands on the
    /// normal screen with a visible cursor and plain keys.
    private func resetModes() {
        let t = terminal.getTerminal()
        var reset = "\u{1b}[0m"
        if t.isCurrentBufferAlternate { reset += "\u{1b}[?1049l" }
        reset += "\u{1b}[?25h\u{1b}[?1l\u{1b}[?1000l\u{1b}[?1002l\u{1b}[?1003l\u{1b}[?1006l\u{1b}[?2004l"
        if t.buffer.x > 0 { reset += "\r\n" }
        reset += "\r\n"
        terminal.feed(text: reset)
    }

    // MARK: Showing

    /// The pane just appeared in a window: repaint output that arrived while
    /// hidden and take focus, unless the user is typing somewhere else.
    func didShow(in window: NSWindow) {
        terminal.needsDisplay = true
        let wanted = focusOnShow
        DispatchQueue.main.async { [weak self] in
            guard let self, let current = self.terminal.window, current === window else { return }
            if wanted || !Self.isTyping(in: window) { window.makeFirstResponder(self.terminal) }
        }
    }

    /// The pane is about to leave its window.
    func willHide(from window: NSWindow) {
        focusOnShow = window.firstResponder === terminal
    }

    private static func isTyping(in window: NSWindow) -> Bool {
        guard let responder = window.firstResponder as? NSView, responder.window === window, !responder.isHiddenOrHasHiddenAncestor
        else { return false }
        return responder is NSTextView || responder is TerminalView
    }
}

/// `LocalProcessTerminalView` with Abstract's exit handling and caret.
final class AbstractTerminalView: LocalProcessTerminalView {
    weak var host: TerminalHost?
    weak var container: TerminalContainerView?

    /// The caret is always a bar: accent while typing goes here, faded when
    /// focus is elsewhere (SwiftTerm's unfocused caret is a hollow box).
    var caretAccent: NSColor = .controlAccentColor {
        didSet { updateCaret() }
    }
    private var isFocused = false

    override var hasFocus: Bool {
        get { super.hasFocus }
        set {
            super.hasFocus = newValue
            isFocused = newValue
            updateCaret()
        }
    }

    private func updateCaret() {
        caretColor = isFocused ? caretAccent : caretAccent.withAlphaComponent(0.35)
    }

    override func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        host?.shellEnded(pid: source.shellPid, rawStatus: exitCode)
    }

    override func scrolled(source: TerminalView, position: Double) {
        container?.scrollChanged() // once per output line: keep it trivial
    }

    /// Return in an exited terminal starts a new shell.
    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        // Typing goes to the shell on the other Mac for a chat there.
        if let host, host.isRemote {
            if case .running = host.phase { host.sendToShell(Array(data)) } else if data.elementsEqual([13]) { host.restart() }
            return
        }
        guard process.running else {
            if data.elementsEqual([13]) { host?.restart() }
            return
        }
        super.send(source: source, data: data)
    }

    /// SwiftTerm logs every action it does not know; answer quietly instead.
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)), #selector(paste(_:)), #selector(selectAll(_:)),
             #selector(performFindPanelAction(_:)), #selector(performTextFinderAction(_:)):
            return super.validateUserInterfaceItem(item)
        default:
            return false
        }
    }
}

/// How the shell is launched.
enum TerminalShell {
    /// `$SHELL`, else the account's shell, else zsh. Must exist: SwiftTerm
    /// forks before exec, and a failed exec would leave a copy of the app.
    static func executable() -> String {
        let fm = FileManager.default
        if let shell = ProcessInfo.processInfo.environment["SHELL"], !shell.isEmpty, fm.isExecutableFile(atPath: shell) {
            return shell
        }
        if let entry = getpwuid(getuid()), let raw = entry.pointee.pw_shell {
            let shell = String(cString: raw)
            if fm.isExecutableFile(atPath: shell) { return shell }
        }
        return "/bin/zsh"
    }

    static func workingDirectory(_ preferred: String?) -> String {
        var isDirectory: ObjCBool = false
        if let preferred, FileManager.default.fileExists(atPath: preferred, isDirectory: &isDirectory), isDirectory.boolValue {
            return preferred
        }
        return LocalExecutor.shared.homeDirectory
    }

    /// The app's environment, minus what belongs to whoever launched it (the
    /// terminal Abstract was started from, Xcode's dyld overrides), plus a
    /// terminal's own variables and the login PATH.
    static func environment(path: String, shell: String, cwd: String, darkBackground: Bool) -> [String] {
        var env = ProcessInfo.processInfo.environment
        let inherited = ["TERM_SESSION_ID", "ITERM_SESSION_ID", "ITERM_PROFILE", "LC_TERMINAL", "LC_TERMINAL_VERSION",
                         "COLUMNS", "LINES", "OLDPWD", "SHLVL", "_"]
        for key in inherited { env[key] = nil }
        for key in env.keys where key.hasPrefix("DYLD_") || key.hasPrefix("__XPC_DYLD_") { env[key] = nil }
        env["PATH"] = path
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "Abstract"
        env["TERM_PROGRAM_VERSION"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        // Lets vim and friends pick a matching background.
        env["COLORFGBG"] = darkBackground ? "15;0" : "0;15"
        env["SHELL"] = shell
        env["PWD"] = cwd
        env["HOME"] = env["HOME"] ?? LocalExecutor.shared.homeDirectory
        if env["LANG"] == nil, env["LC_ALL"] == nil, env["LC_CTYPE"] == nil { env["LANG"] = "en_US.UTF-8" }
        return env.map { "\($0.key)=\($0.value)" }
    }

    /// The exit code from a wait status; 128 + signal when killed.
    static func exitCode(_ status: Int32) -> Int32 {
        let signal = status & 0x7F
        return signal == 0 ? (status >> 8) & 0xFF : 128 + signal
    }

    /// Wait for a hung-up shell off the main thread, killing it if it
    /// ignores the hangup, so it never lingers as a zombie.
    nonisolated static func reapInBackground(_ pid: pid_t) {
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            for _ in 0..<40 {
                let reaped = waitpid(pid, &status, WNOHANG)
                if reaped == pid || (reaped == -1 && errno != EINTR) { return }
                usleep(50_000)
            }
            kill(-pid, SIGKILL)
            kill(pid, SIGKILL)
            while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
        }
    }
}

/// SwiftTerm reports titles the shell sets (OSC 0/2) through this delegate;
/// exits are handled by `AbstractTerminalView`.
extension TerminalHost: @preconcurrency LocalProcessTerminalViewDelegate {
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) { remoteResized(cols: newCols, rows: newRows) }
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) { setShellTitle(title) }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) {}
}
