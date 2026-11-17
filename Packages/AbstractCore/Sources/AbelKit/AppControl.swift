import AbstractCore
import AppKit
import ApplicationServices
import Foundation

/// One control in another app's window, as Accessibility reports it.
public struct AbelUIElement: Sendable, Equatable {
    public var role: String
    public var title: String
    /// A password field: ABEL never types into one.
    public var isSecure: Bool

    public init(role: String, title: String, isSecure: Bool = false) {
        self.role = role; self.title = title; self.isSecure = isSecure
    }
}

/// How ABEL acts on other apps (ABS-205). The real one uses NSWorkspace,
/// the `shortcuts` command, AppleScript and Accessibility, each holding
/// ABEL's own permission; tests use a fake.
@MainActor
public protocol AppControlling: AnyObject {
    func installedApps() -> [AbelAppInfo]
    func open(app: AbelAppInfo) async throws
    func open(url: URL) async throws
    func shortcuts() async -> [String]
    func runShortcut(_ name: String, input: String?) async throws -> String
    func runAppleScript(_ source: String) async throws -> String
    var accessibilityAllowed: Bool { get }
    func uiRead(app: AbelAppInfo) throws -> [AbelUIElement]
    func uiPress(app: AbelAppInfo, element: String) throws
    /// Types into the app's focused field; throws for a password field.
    func uiType(app: AbelAppInfo, text: String) throws
}

/// The Mac's own ways to act on apps.
@MainActor
public final class MacAppControl: AppControlling {
    /// The `shortcuts` command; a stand-in in demos and checks.
    public var shortcutsTool: String
    private var apps: [AbelAppInfo]?
    private var shortcutNames: (names: [String], read: Date)?

    public init(shortcutsTool: String = "/usr/bin/shortcuts") {
        self.shortcutsTool = shortcutsTool
    }

    // MARK: Opening

    public func installedApps() -> [AbelAppInfo] {
        if let apps { return apps }
        let fm = FileManager.default
        let folders = ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
                       (NSHomeDirectory() as NSString).appendingPathComponent("Applications")]
        var seen = Set<String>()
        let found = folders.flatMap { folder -> [AbelAppInfo] in
            ((try? fm.contentsOfDirectory(atPath: folder)) ?? []).filter { $0.hasSuffix(".app") }.compactMap { item in
                let path = (folder as NSString).appendingPathComponent(item)
                let bundle = Bundle(path: path)
                let name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (item as NSString).deletingPathExtension
                guard seen.insert(name.lowercased()).inserted else { return nil }
                return AbelAppInfo(name: name, bundleId: bundle?.bundleIdentifier, path: path)
            }
        }
        apps = found
        return found
    }

    public func open(app: AbelAppInfo) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try await NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: app.path), configuration: configuration)
    }

    /// Apps a file never opens in for ABEL: each would run it.
    static let runners: Set<String> = ["com.apple.Terminal", "com.googlecode.iterm2", "com.apple.ScriptEditor2",
                                       "com.apple.Automator", "com.apple.installer", "com.apple.archiveutility",
                                       "com.apple.shortcuts", "dev.warp.Warp-Stable", "com.mitchellh.ghostty"]

    public func open(url: URL) async throws {
        if url.isFileURL, let app = NSWorkspace.shared.urlForApplication(toOpen: url),
           let id = Bundle(url: app)?.bundleIdentifier, Self.runners.contains(id) {
            throw AbelError("That file would open in \(FileManager.default.displayName(atPath: app.path)), which runs it. Open it yourself.")
        }
        guard NSWorkspace.shared.open(url) else { throw AbelError("Nothing on this Mac opens \(url.absoluteString).") }
    }

    // MARK: Shortcuts

    public func shortcuts() async -> [String] {
        if let cached = shortcutNames, Date().timeIntervalSince(cached.read) < 60 { return cached.names }
        let output = (try? await run(shortcutsTool, ["list"], timeout: 15)) ?? ""
        let names = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        shortcutNames = (names, Date())
        return names
    }

    public func runShortcut(_ name: String, input: String?) async throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("abel-shortcut-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("output.txt")
        var arguments = ["run", name, "--output-path", out.path, "--output-type", "public.plain-text"]
        if let input {
            let file = dir.appendingPathComponent("input.txt")
            try input.write(to: file, atomically: true, encoding: .utf8)
            arguments += ["--input-path", file.path]
        }
        let printed = try await run(shortcutsTool, arguments, timeout: 120)
        let written = (try? String(contentsOf: out, encoding: .utf8)) ?? ""
        return (written.isEmpty ? printed : written).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Runs a command off the main thread and returns what it printed.
    private func run(_ tool: String, _ arguments: [String], timeout: TimeInterval) async throws -> String {
        try await AbelLink.offThePool {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            let pipe = Pipe(), errors = Pipe()
            process.standardOutput = pipe
            process.standardError = errors
            process.standardInput = FileHandle.nullDevice
            do { try process.run() } catch { return Result<String, AbelError>.failure(AbelError(error.localizedDescription)) }
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
            if process.isRunning { process.terminate(); return .failure(AbelError("That took too long, so ABEL stopped it.")) }
            let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let err = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            guard process.terminationStatus == 0 else {
                return .failure(AbelError(err.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "That didn't work." : err))
            }
            return .success(out)
        }.get()
    }

    // MARK: AppleScript

    public func runAppleScript(_ source: String) async throws -> String {
        guard let script = NSAppleScript(source: source) else { throw AbelError("That AppleScript can't be read.") }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            throw AbelError((error[NSAppleScript.errorMessage] as? String) ?? "The AppleScript failed.")
        }
        return result.stringValue ?? ""
    }

    // MARK: Accessibility

    public var accessibilityAllowed: Bool { AXIsProcessTrusted() }

    private func window(of app: AbelAppInfo) throws -> AXUIElement {
        guard accessibilityAllowed else {
            throw AbelError("ABEL needs Accessibility: allow it for Abel in System Settings › Privacy & Security.")
        }
        guard let bundleId = app.bundleId,
              let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first else {
            throw AbelError("\(app.name) isn't open.")
        }
        let element = AXUIElementCreateApplication(running.processIdentifier)
        var window: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window else { throw AbelError("\(app.name) has no window open.") }
        return window as! AXUIElement
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private func walk(_ root: AXUIElement, depth: Int = 0, into found: inout [(AXUIElement, AbelUIElement)]) {
        guard depth < 8, found.count < 300 else { return }
        for child in Self.children(root) {
            let role = Self.string(child, kAXRoleAttribute) ?? ""
            let title = Self.string(child, kAXTitleAttribute) ?? Self.string(child, kAXDescriptionAttribute) ?? ""
            let secure = Self.string(child, kAXSubroleAttribute) == (kAXSecureTextFieldSubrole as String)
            if !title.isEmpty || secure { found.append((child, AbelUIElement(role: role, title: title, isSecure: secure))) }
            walk(child, depth: depth + 1, into: &found)
        }
    }

    public func uiRead(app: AbelAppInfo) throws -> [AbelUIElement] {
        var found: [(AXUIElement, AbelUIElement)] = []
        walk(try window(of: app), into: &found)
        return found.map(\.1)
    }

    public func uiPress(app: AbelAppInfo, element title: String) throws {
        var found: [(AXUIElement, AbelUIElement)] = []
        walk(try window(of: app), into: &found)
        guard case let .one(index, _) = AbelNames.match(title, among: found.enumerated().map { (id: $0.offset, name: $0.element.1.title) })
        else { throw AbelError("\(app.name) has no “\(title)” to press.") }
        guard AXUIElementPerformAction(found[index].0, kAXPressAction as CFString) == .success else {
            throw AbelError("“\(found[index].1.title)” can't be pressed.")
        }
    }

    public func uiType(app: AbelAppInfo, text: String) throws {
        _ = try window(of: app)
        guard let bundleId = app.bundleId,
              let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first else {
            throw AbelError("\(app.name) isn't open.")
        }
        var focused: AnyObject?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(running.processIdentifier),
                                            kAXFocusedUIElementAttribute as CFString, &focused) == .success, let focused else {
            throw AbelError("Nothing in \(app.name) is ready for typing.")
        }
        let field = focused as! AXUIElement
        let subrole = Self.string(field, kAXSubroleAttribute)
        try AbelSecureField.check(role: Self.string(field, kAXRoleAttribute), subrole: subrole)
        guard AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, text as CFString) == .success else {
            throw AbelError("ABEL couldn't type there.")
        }
    }
}

/// ABEL never types into a password field (ABS-202 §5).
public enum AbelSecureField {
    public static func check(role: String?, subrole: String?) throws {
        if subrole == (kAXSecureTextFieldSubrole as String) || role == "AXSecureTextField" {
            throw AbelError("That's a password field. ABEL never types into one.")
        }
    }
}
