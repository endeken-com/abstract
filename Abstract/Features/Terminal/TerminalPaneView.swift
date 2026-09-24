import AppKit
import SwiftUI
import AbstractCore

/// A shell in the chat's worktree. The shell belongs to `TerminalRegistry`
/// and outlives this view: hiding the tab or switching chats keeps it (and
/// anything running in it) alive; closing the pane ends it.
struct TerminalPaneView: View {
    @Environment(AppModel.self) private var model
    let session: Session
    let paneId: String

    var body: some View {
        TerminalPaneBody(host: TerminalRegistry.shared.host(for: paneId, directory: session.worktreePath,
                                                            remote: model.remoteLink(for: session.id)))
    }
}

private struct TerminalPaneBody: View {
    let host: TerminalHost

    var body: some View {
        VStack(spacing: 0) {
            TerminalSurface(host: host)
            if let message = statusMessage {
                TerminalStatusBar(message: message) { host.restart() }
            }
        }
        .background(Color.btCanvas)
    }

    private var statusMessage: String? {
        switch host.phase {
        case .starting, .running: nil
        case .exited(let code): code.map { "Process exited (code \($0))" } ?? "Process exited"
        case .failed(let message): message
        }
    }
}

/// Quiet line under a finished shell's scrollback.
private struct TerminalStatusBar: View {
    let message: String
    let restart: () -> Void

    var body: some View {
        HStack(spacing: Space.sm) {
            Text(message)
                .font(.btCaption)
                .foregroundStyle(Color.btTextSecondary)
            Spacer(minLength: Space.sm)
            Button(action: restart) {
                Label("Restart", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bt(.ghost, size: .small))
            .help("Start a new shell (Return)")
        }
        .padding(.leading, TerminalContainerView.insets.left)
        .padding(.trailing, Space.sm)
        .frame(height: 32)
    }
}

/// Hands SwiftUI the pane's long-lived terminal instead of a new one.
private struct TerminalSurface: NSViewRepresentable {
    let host: TerminalHost

    func makeNSView(context: Context) -> TerminalMountView {
        let view = TerminalMountView()
        view.mount(host, claim: true)
        return view
    }

    func updateNSView(_ view: TerminalMountView, context: Context) {
        view.mount(host, claim: false)
    }

    static func dismantleNSView(_ view: TerminalMountView, coordinator: ()) {
        view.unmount()
    }
}

/// SwiftUI's view for a terminal pane: a throwaway frame that borrows the
/// host's container. If two mounts exist at once (SwiftUI can build the new
/// one before dismantling the old), the newest owns the terminal, and an old
/// mount's teardown never pulls the terminal out from under it.
final class TerminalMountView: NSView {
    private weak var host: TerminalHost?

    func mount(_ host: TerminalHost, claim: Bool) {
        if let current = self.host, current !== host { release(current) }
        self.host = host
        if claim || host.owner == nil || host.owner?.window == nil { host.owner = self }
        guard host.owner === self, host.container.superview !== self else { return }
        host.container.frame = bounds
        host.container.autoresizingMask = [.width, .height]
        addSubview(host.container)
    }

    func unmount() {
        if let host { release(host) }
        host = nil
    }

    private func release(_ host: TerminalHost) {
        guard host.owner === self else { return }
        host.owner = nil
        if host.container.superview === self { host.container.removeFromSuperview() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Reclaim a terminal whose newer mount went away first.
        if window != nil, let host { mount(host, claim: false) }
    }
}
