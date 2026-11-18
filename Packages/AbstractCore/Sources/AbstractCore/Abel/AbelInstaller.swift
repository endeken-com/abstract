import Foundation
import ServiceManagement

/// A login item as `SMAppService` sees it.
public enum LoginItemStatus: Sendable, Equatable {
    case notRegistered, enabled, requiresApproval, notFound
}

/// What turns a bundled helper on and off at login: `SMAppService` for
/// real, a fake in tests.
public protocol LoginItemService: Sendable {
    var status: LoginItemStatus { get }
    func register() throws
    func unregister() throws
}

/// `SMAppService.loginItem` for a helper in the app's `Contents/Library/LoginItems`.
public struct SystemLoginItem: LoginItemService {
    public let identifier: String
    public init(identifier: String = AbelLink.bundleIdentifier) { self.identifier = identifier }

    private var service: SMAppService { SMAppService.loginItem(identifier: identifier) }

    public var status: LoginItemStatus {
        switch service.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        default: .notRegistered
        }
    }

    public func register() throws { try service.register() }
    public func unregister() throws { try service.unregister() }
}

/// Installs and removes ABEL from Settings › ABEL (ABS-203).
///
/// Abel.app ships inside Abstract.app, but it runs from its own copy in
/// `~/Applications`. macOS judges a helper bundled inside another app as
/// that app: from inside Abstract, ABEL's microphone request was Abstract's,
/// which has no microphone entitlement, so macOS refused to ask and ABEL
/// never appeared in Privacy & Security. Its own copy is its own app,
/// asked for and listed as ABEL. It starts itself at login
/// (`SMAppService.mainApp`), and Abstract keeps the copy in step with its
/// own version. Abstract itself still never asks for the microphone.
public struct AbelInstaller: Sendable {
    public enum State: Sendable, Equatable {
        /// ABEL can't run here, and why.
        case unavailable(String)
        case notInstalled
        case installed
    }

    /// ABEL needs macOS 26: its recognizer (`SpeechAnalyzer`) is there,
    /// on the Mac, in English and Portuguese.
    public static let minimumMacOS = OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)

    /// The login item ABEL used to be, from inside Abstract.app: turned off.
    public let legacy: any LoginItemService
    /// Abel.app inside Abstract.app, copied from; nil when this Abstract
    /// was built without it.
    public let appURL: URL?
    /// Where ABEL's own copy lives.
    public let installURL: URL
    public let systemVersion: OperatingSystemVersion
    /// Starts ABEL from `URL`.
    public let launch: @Sendable (URL) -> Void
    /// Asks a running ABEL to stop starting at login and quit, then waits for it.
    public let quit: @Sendable (_ forget: Bool) -> Void

    public init(legacy: any LoginItemService = SystemLoginItem(), appURL: URL?,
                installURL: URL = Self.defaultInstallURL,
                systemVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
                launch: @escaping @Sendable (URL) -> Void, quit: @escaping @Sendable (_ forget: Bool) -> Void) {
        self.legacy = legacy; self.appURL = appURL; self.installURL = installURL; self.systemVersion = systemVersion
        self.launch = launch; self.quit = quit
    }

    /// `~/Applications/Abel.app`: the user's own Applications folder, no administrator needed.
    public static var defaultInstallURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/\(AbelLink.appName)")
    }

    /// Abel.app inside the Abstract.app at `bundleURL`, when it's there.
    public static func bundledApp(in bundleURL: URL, fileManager: FileManager = .default) -> URL? {
        let url = bundleURL.appendingPathComponent(AbelLink.bundledPath)
        return fileManager.fileExists(atPath: url.appendingPathComponent("Contents/Info.plist").path) ? url : nil
    }

    public var state: State {
        guard Self.supports(systemVersion) else {
            return .unavailable("ABEL needs macOS 26 or later. This Mac has macOS \(systemVersion.majorVersion).")
        }
        guard appURL != nil else { return .unavailable("This copy of Abstract was built without ABEL.") }
        return FileManager.default.fileExists(atPath: installURL.appendingPathComponent("Contents/Info.plist").path)
            ? .installed : .notInstalled
    }

    public static func supports(_ version: OperatingSystemVersion) -> Bool {
        (version.majorVersion, version.minorVersion) >= (minimumMacOS.majorVersion, minimumMacOS.minorVersion)
    }

    /// The version a copy of Abel.app says it is.
    public static func version(of app: URL) -> String? {
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        guard let short = info?["CFBundleShortVersionString"] as? String else { return nil }
        return "\(short) (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }

    /// Whether ABEL's copy is a different version from the one Abstract ships.
    public var needsUpdate: Bool {
        guard state == .installed, let appURL else { return false }
        return Self.version(of: appURL) != Self.version(of: installURL)
    }

    /// Copies ABEL to its own place and starts it; it then starts itself at login.
    public func install() throws {
        if case let .unavailable(reason) = state { throw AbstractError.message(reason) }
        guard let appURL else { return }
        // The old login item, from inside Abstract.app, never starts again.
        if legacy.status == .enabled || legacy.status == .requiresApproval { try? legacy.unregister() }
        quit(false)
        try replaceCopy(from: appURL)
        launch(installURL)
    }

    /// Brings ABEL's copy up to Abstract's version, when it's installed and differs.
    @discardableResult
    public func updateIfNeeded() throws -> Bool {
        guard needsUpdate, let appURL else { return false }
        quit(false)
        try replaceCopy(from: appURL)
        launch(installURL)
        return true
    }

    /// Stops ABEL starting at login, quits it and deletes its copy.
    public func remove() throws {
        if legacy.status == .enabled || legacy.status == .requiresApproval { try? legacy.unregister() }
        quit(true)
        let fm = FileManager.default
        if fm.fileExists(atPath: installURL.path) { try fm.removeItem(at: installURL) }
    }

    func replaceCopy(from source: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: installURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staging = installURL.deletingLastPathComponent().appendingPathComponent(".\(AbelLink.appName).new")
        if fm.fileExists(atPath: staging.path) { try fm.removeItem(at: staging) }
        try fm.copyItem(at: source, to: staging)
        if fm.fileExists(atPath: installURL.path) {
            _ = try fm.replaceItemAt(installURL, withItemAt: staging)
        } else {
            try fm.moveItem(at: staging, to: installURL)
        }
    }
}
