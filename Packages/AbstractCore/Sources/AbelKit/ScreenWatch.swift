import AppKit
import CoreGraphics
import Darwin
import Foundation

/// Tells ABEL when the screen locks or is shared, so it stops listening
/// and acting (ABS-202 §5). There's no public API for "shared": ABEL sees
/// macOS Screen Sharing and Remote Management (their `screensharingd`
/// runs) and mirrored displays; for a video call sharing your screen,
/// there's Pause ABEL in its menu.
@MainActor
public final class ScreenWatch {
    public struct Reading: Sendable, Equatable {
        public var locked: Bool
        public var shared: Bool
        public init(locked: Bool, shared: Bool) { self.locked = locked; self.shared = shared }
    }

    /// Called whenever the reading changes.
    public var onChange: ((Reading) -> Void)?
    public private(set) var reading = Reading(locked: false, shared: false)
    private let read: @MainActor () -> Reading
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []

    /// `read` is how the screen is checked; the real one by default.
    public init(read: @escaping @MainActor () -> Reading = { ScreenWatch.current() }) {
        self.read = read
    }

    public func start() {
        let center = DistributedNotificationCenter.default()
        for name in ["com.apple.screenIsLocked", "com.apple.screenIsUnlocked"] {
            observers.append(center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.check() }
            })
        }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification,
                     NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.check() }
            })
        }
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        check()
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        for observer in observers {
            DistributedNotificationCenter.default().removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers = []
    }

    /// Reads the screen now and reports a change.
    public func check() {
        let now = read()
        guard now != reading else { return }
        reading = now
        onChange?(now)
    }

    // MARK: The real checks

    public static func current() -> Reading {
        Reading(locked: isLocked(), shared: isShared())
    }

    /// The session's own word: `CGSSessionScreenIsLocked` is there only while locked.
    public static func isLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        if session["CGSSessionScreenIsLocked"] as? Bool == true { return true }
        // Switched to another user: this one isn't on the console.
        if session["kCGSSessionOnConsoleKey"] as? Bool == false { return true }
        return false
    }

    public static func isShared() -> Bool {
        isRunning("screensharingd") || isMirrored()
    }

    /// Any display mirroring another (AirPlay or a projector showing this screen).
    static func isMirrored() -> Bool {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return false }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &displays, &count) == .success else { return false }
        return displays.contains { CGDisplayIsInMirrorSet($0) != 0 }
    }

    /// Whether a process of this name runs, from the kernel's process list.
    static func isRunning(_ name: String) -> Bool {
        var size = 0
        var mib = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return false }
        let count = size / MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count + 16)
        size = procs.count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 3, &procs, &size, nil, 0) == 0 else { return false }
        let found = size / MemoryLayout<kinfo_proc>.stride
        return procs.prefix(found).contains { proc in
            var comm = proc.kp_proc.p_comm
            let processName = withUnsafeBytes(of: &comm) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            return processName == name
        }
    }
}
