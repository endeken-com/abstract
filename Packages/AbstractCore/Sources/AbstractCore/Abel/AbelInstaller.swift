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

/// Installs and removes ABEL from Settings › ABEL (ABS-203). Abel.app ships
/// inside Abstract.app, signed with it (ABS-202 §6): installing turns its
/// login item on and starts it; removing turns it off and quits it.
/// Nothing is downloaded, and Abstract itself never asks for the
/// microphone: ABEL does, under its own name.
public struct AbelInstaller: Sendable {
    public enum State: Sendable, Equatable {
        /// ABEL can't run here, and why.
        case unavailable(String)
        case notInstalled
        case installed
        /// macOS wants you to allow it in System Settings › General › Login Items.
        case needsApproval
    }

    /// ABEL needs macOS 26: its recognizer (`SpeechAnalyzer`) is there,
    /// on the Mac, in English and Portuguese.
    public static let minimumMacOS = OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)

    public let service: any LoginItemService
    /// Where Abel.app is; nil when this Abstract was built without it.
    public let appURL: URL?
    public let systemVersion: OperatingSystemVersion
    public let launch: @Sendable (URL) -> Void
    public let quit: @Sendable () -> Void

    public init(service: any LoginItemService = SystemLoginItem(), appURL: URL?,
                systemVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
                launch: @escaping @Sendable (URL) -> Void, quit: @escaping @Sendable () -> Void) {
        self.service = service; self.appURL = appURL; self.systemVersion = systemVersion
        self.launch = launch; self.quit = quit
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
        switch service.status {
        case .enabled: return .installed
        case .requiresApproval: return .needsApproval
        case .notRegistered, .notFound: return .notInstalled
        }
    }

    public static func supports(_ version: OperatingSystemVersion) -> Bool {
        (version.majorVersion, version.minorVersion) >= (minimumMacOS.majorVersion, minimumMacOS.minorVersion)
    }

    /// Turns ABEL on at login and starts it now.
    public func install() throws {
        if case let .unavailable(reason) = state { throw AbstractError.message(reason) }
        guard let appURL else { return }
        if service.status != .enabled { try service.register() }
        launch(appURL)
    }

    /// Turns ABEL off at login and quits it.
    public func remove() throws {
        if service.status != .notRegistered, service.status != .notFound { try service.unregister() }
        quit()
    }
}
