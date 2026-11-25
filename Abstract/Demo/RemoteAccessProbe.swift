import AppKit
import SwiftUI
import AbstractCore

/// Demo mode's remote access check (ABS-219), against a local gateway:
/// `ABSTRACT_REMOTE_ACCESS_URL=http://localhost:8787 ABSTRACT_DEMO_REMOTE_ACCESS=1`.
///
/// It turns remote access on, allows any assistant that asks (the consent
/// sheet is ABS-220) for the projects named in
/// `ABSTRACT_DEMO_REMOTE_ACCESS_PROJECTS` (comma-separated; all when unset),
/// and writes a fresh connection code to `<demo root>/remote-code`. Then it
/// watches the demo root: `remote-revoke` revokes every grant,
/// `remote-code-again` makes a new code, `remote-off` turns remote access
/// off. `ABSTRACT_DEMO_REMOTE_ACCESS_SHOT=<png>` saves Settings › Devices.
enum RemoteAccessProbe {
    static func runIfRequested(_ model: AppModel, root: URL) {
        guard ProcessInfo.processInfo.environment["ABSTRACT_DEMO_REMOTE_ACCESS"] != nil else { return }
        Task { await run(model, root: root) }
    }

    private static func run(_ model: AppModel, root: URL) async {
        let access = model.remoteAccess
        let wanted = ProcessInfo.processInfo.environment["ABSTRACT_DEMO_REMOTE_ACCESS_PROJECTS"]?
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let projects: RemoteProjects = wanted.map { names in
            .only(Set(model.projects.filter { names.contains($0.name) }.map(\.id)))
        } ?? .all
        access.consentHandler = { request in
            let kind = request.loopback ? "local app" : "remote"
            await MainActor.run { log("remote access: consent asked by a client (\(kind))") }
            return RemoteGrant(clientName: request.clientName, clientDomain: request.clientDomain, projects: projects)
        }
        access.setEnabled(true)
        guard await wait(30, { access.status == .connected }) else {
            log("remote access: FAIL not connected: \(access.status)")
            return
        }
        log("remote access: connected")
        await writeCode(access, to: root)
        if let shot = ProcessInfo.processInfo.environment["ABSTRACT_DEMO_REMOTE_ACCESS_SHOT"] {
            await shoot(model, to: shot)
        }
        while true {
            try? await Task.sleep(for: .milliseconds(300))
            if take(root, "remote-code-again") { await writeCode(access, to: root) }
            if take(root, "remote-revoke") {
                for grant in access.grants where grant.isActive { access.revoke(grant.id) }
                log("remote access: revoked \(access.grants.count) grant(s)")
            }
            if take(root, "remote-off") {
                access.setEnabled(false)
                _ = await wait(15, { access.status == .off })
                log("remote access: off (\(access.status))")
                return
            }
            if take(root, "remote-status") {
                log("remote access: status \(access.status); grants \(access.grants.map { "\($0.clientName)=\($0.isActive ? "active" : "revoked")" })")
            }
        }
    }

    private static func writeCode(_ access: RemoteAccessService, to root: URL) async {
        do {
            let (code, _) = try await access.connectionCode()
            let url = root.appendingPathComponent("remote-code")
            FileManager.default.createFile(atPath: url.path, contents: Data(code.utf8), attributes: [.posixPermissions: 0o600])
            log("remote access: code written")
        } catch {
            log("remote access: FAIL code: \(error.localizedDescription)")
        }
    }

    private static func take(_ root: URL, _ name: String) -> Bool {
        let url = root.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        try? FileManager.default.removeItem(at: url)
        return true
    }

    private static func wait(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return condition()
    }

    /// Settings › Devices, scrolled down to Remote access.
    private static func shoot(_ model: AppModel, to path: String) async {
        let tab = UserDefaults.standard.string(forKey: "settingsTab")
        defer {
            if let tab { UserDefaults.standard.set(tab, forKey: "settingsTab") } else { UserDefaults.standard.removeObject(forKey: "settingsTab") }
        }
        UserDefaults.standard.set(SettingsTab.devices.rawValue, forKey: "settingsTab")
        model.isSettingsOpen = true
        try? await Task.sleep(for: .seconds(Double(ProcessInfo.processInfo.environment["ABSTRACT_DEMO_REMOTE_ACCESS_WAIT"] ?? "") ?? 3))
        for fraction in [0.6, 0.8, 1.0] {
            scroll(to: fraction)
            try? await Task.sleep(for: .seconds(1.2))
            guard let image = WindowCapture.image() ?? WindowCapture.image(method: .cacheDisplay) else { log("remote access: no shot"); continue }
            let base = URL(fileURLWithPath: path)
            let out = URL(fileURLWithPath: base.deletingPathExtension().path + "-\(Int(fraction * 100))." + base.pathExtension)
            try? image.write(to: out)
            log("remote access: shot \(out.path)")
        }
    }

    private static var mainWindow: NSWindow? { NSApp.windows.first { $0.canBecomeMain && $0.isVisible } }

    private static func scroll(to fraction: CGFloat) {
        guard let scroll = scrollViews(mainWindow?.contentView)
            .max(by: { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }),
              let document = scroll.documentView else { return }
        let inset = scroll.contentView.contentInsets.top
        let target = max(0, document.frame.height - scroll.contentView.bounds.height + inset) * fraction - inset
        scroll.contentView.scroll(to: NSPoint(x: 0, y: document.isFlipped ? target : document.frame.height - scroll.contentView.bounds.height - target))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private static func scrollViews(_ view: NSView?) -> [NSScrollView] {
        guard let view else { return [] }
        return ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollViews)
    }
}
