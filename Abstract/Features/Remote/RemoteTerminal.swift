import Darwin
import Foundation
@preconcurrency import SwiftTerm
import AbstractCore

/// A shell on this Mac for a terminal on another: a pty in one of this Mac's
/// worktrees, its output sent over the pairing link.
final class HostTerminal {
    private var process: LocalProcess!
    private var size: winsize
    private let output: (Data) -> Void
    private let ended: (Int32?) -> Void

    init(cwd: String, cols: Int, rows: Int, searchPath: String, output: @escaping (Data) -> Void, ended: @escaping (Int32?) -> Void) {
        size = winsize(ws_row: UInt16(max(rows, 2)), ws_col: UInt16(max(cols, 10)), ws_xpixel: 0, ws_ypixel: 0)
        self.output = output
        self.ended = ended
        process = LocalProcess(delegate: self, dispatchQueue: .main)
        let shell = TerminalShell.executable()
        process.startProcess(executable: shell, args: [],
                             environment: TerminalShell.environment(path: searchPath, shell: shell, cwd: cwd, darkBackground: true),
                             execName: "-" + (shell as NSString).lastPathComponent, currentDirectory: cwd)
    }

    func send(_ data: Data) { process.send(data: ArraySlice(data)) }

    func resize(cols: Int, rows: Int) {
        size = winsize(ws_row: UInt16(max(rows, 2)), ws_col: UInt16(max(cols, 10)), ws_xpixel: 0, ws_ypixel: 0)
        guard process.childfd >= 0 else { return }
        _ = ioctl(process.childfd, TIOCSWINSZ, &size)
    }

    func close() {
        let pid = process.shellPid
        if pid > 0 {
            kill(-pid, SIGHUP)
            kill(pid, SIGHUP)
        }
        if process.running { process.terminate() }
        if pid > 0 { TerminalShell.reapInBackground(pid) }
    }
}

extension HostTerminal: @preconcurrency LocalProcessDelegate {
    func processTerminated(_ source: LocalProcess, exitCode: Int32?) { ended(exitCode) }
    func dataReceived(slice: ArraySlice<UInt8>) { output(Data(slice)) }
    func getWindowSize() -> winsize { size }
}

extension HostedPeer {
    func openTerminal(_ id: Int, cwd: String, cols: Int, rows: Int) -> RemoteResponse {
        guard allowed(cwd) else { return .failed("That folder isn't one of this Mac's projects.") }
        Task {
            // A GUI app has no shell PATH of its own; the login one.
            let path = await LocalExecutor.shared.searchPath
            terminals[id] = HostTerminal(cwd: cwd, cols: cols, rows: rows, searchPath: path, output: { [weak self] data in
                self?.post(.event(.terminalOutput(id: id, data)))
            }, ended: { [weak self] code in
                self?.terminals[id] = nil
                self?.post(.event(.terminalExit(id: id, code: code)))
            })
        }
        return .ok
    }
}

extension RemoteLink {
    /// A shell on that Mac in `cwd`; its output and exit come back through the closures.
    func openTerminal(cwd: String, cols: Int, rows: Int, output: @escaping (Data) -> Void, exit: @escaping (Int32?) -> Void) -> Int {
        let id = nextRequestId()
        terminals[id] = (output, exit)
        send(.request(id: id, .openTerminal(id: id, cwd: cwd, cols: cols, rows: rows)))
        return id
    }

    func terminalInput(_ id: Int, _ data: Data) { fire(.terminalInput(id: id, data: data)) }
    func resizeTerminal(_ id: Int, cols: Int, rows: Int) { fire(.resizeTerminal(id: id, cols: cols, rows: rows)) }

    func closeTerminal(_ id: Int) {
        guard terminals.removeValue(forKey: id) != nil else { return }
        fire(.closeTerminal(id: id))
    }
}
