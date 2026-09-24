import Darwin
import Foundation

/// Who is driving a chat.
public enum SessionDriver: String, Codable, Sendable {
    /// Abstract's window: the chat is showing there, or the app runs its agent.
    case app
    /// `abstract`, the command line: the chat's agent runs outside the app.
    case cli
}

/// A chat's running agent, as its driver publishes it.
public struct AgentRecord: Codable, Sendable, Hashable {
    /// New for every agent started, so a message meant for one never reaches its replacement.
    public var id: String
    public var sessionId: String
    public var providerId: String
    public var startedAt: Date

    public init(id: String = UUID().uuidString, sessionId: String, providerId: String, startedAt: Date = Date()) {
        self.id = id; self.sessionId = sessionId; self.providerId = providerId; self.startedAt = startedAt
    }
}

/// What a lock's holder says about itself.
public struct SessionLockInfo: Codable, Sendable, Hashable {
    public var driver: SessionDriver
    public var pid: Int32
    /// When `pid` started, so a pid the system has since reused never passes for the holder.
    public var pidStartedAt: Double
    public var agent: AgentRecord?

    public init(driver: SessionDriver, pid: Int32, pidStartedAt: Double, agent: AgentRecord?) {
        self.driver = driver; self.pid = pid; self.pidStartedAt = pidStartedAt; self.agent = agent
    }
}

public enum SessionLockError: Error, Equatable {
    /// Someone else drives the chat; their info when they published it.
    case held(SessionLockInfo?)
}

/// One driver per chat at a time, across processes: the app, or `abstract`.
///
/// The lock is an `flock` on `<id>.lock`, so the kernel drops it when its
/// holder exits however it exits. Beside it, `<id>.json` says who holds it
/// and which agent runs; readers trust it only while that process lives, and
/// never touch the lock itself, so looking can't make a taker fail.
public final class SessionLock: @unchecked Sendable {
    public let sessionId: String
    public let driver: SessionDriver
    public let directory: URL
    private let mutex = NSLock()
    private var fd: Int32
    private var agent: AgentRecord?

    /// `locks/` beside the database.
    public static func defaultDirectory() -> URL {
        URL(fileURLWithPath: Store.defaultPath()).deletingLastPathComponent().appendingPathComponent("locks", isDirectory: true)
    }

    private init(fd: Int32, sessionId: String, driver: SessionDriver, directory: URL) {
        self.fd = fd; self.sessionId = sessionId; self.driver = driver; self.directory = directory
    }

    deinit { release() }

    /// Takes the chat's lock, or throws `SessionLockError.held`.
    public static func acquire(_ sessionId: String, as driver: SessionDriver, in directory: URL = defaultDirectory()) throws -> SessionLock {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("\(sessionId).lock").path
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw AbstractError.message("Could not open \(path): \(String(cString: strerror(errno)))") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw SessionLockError.held(holder(of: sessionId, in: directory))
        }
        let lock = SessionLock(fd: fd, sessionId: sessionId, driver: driver, directory: directory)
        try lock.publish()
        return lock
    }

    /// A lock taken by the process that started this one, passed down as
    /// `descriptor`. It must be this chat's lock file, and held through it
    /// (taking it again on the same open file succeeds; on any other, it fails).
    public static func inherited(_ descriptor: Int32, sessionId: String, driver: SessionDriver,
                                 in directory: URL = defaultDirectory()) throws -> SessionLock {
        var handed = stat(), file = stat()
        guard fstat(descriptor, &handed) == 0, stat(directory.appendingPathComponent("\(sessionId).lock").path, &file) == 0,
              handed.st_dev == file.st_dev, handed.st_ino == file.st_ino, flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw AbstractError.message("This process wasn't handed session \(sessionId)'s lock.")
        }
        let lock = SessionLock(fd: descriptor, sessionId: sessionId, driver: driver, directory: directory)
        do {
            try lock.publish()
        } catch {
            // The open file is shared with whoever handed it over: never unlock it from here.
            lock.handOff()
            throw error
        }
        return lock
    }

    /// The open lock file, to pass to a child that takes over (see `handOff`).
    public var descriptor: Int32 { mutex.withLock { fd } }

    /// Says which agent runs now (nil: none).
    public func setAgent(_ agent: AgentRecord?) throws {
        mutex.withLock { self.agent = agent }
        try publish()
    }

    /// Lets go: others may take the chat.
    public func release() {
        mutex.withLock {
            guard fd >= 0 else { return }
            try? FileManager.default.removeItem(at: infoURL)
            flock(fd, LOCK_UN)
            close(fd)
            fd = -1
        }
    }

    /// Lets go and removes the lock file, for a chat that never came to be.
    /// Only safe when no one else can know its id: another process holding
    /// the old file open would otherwise lock a different one than the next taker.
    public func discard() {
        mutex.withLock {
            guard fd >= 0 else { return }
            try? FileManager.default.removeItem(at: infoURL)
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(sessionId).lock"))
            flock(fd, LOCK_UN)
            close(fd)
            fd = -1
        }
    }

    /// Closes this process's hold without letting go: a child given
    /// `descriptor` keeps the lock (it's the same open file) and publishes itself.
    public func handOff() {
        mutex.withLock {
            guard fd >= 0 else { return }
            close(fd)
            fd = -1
        }
    }

    /// Who drives the chat, when anyone does.
    public static func holder(of sessionId: String, in directory: URL = defaultDirectory()) -> SessionLockInfo? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("\(sessionId).json")),
              let info = try? JSONDecoder().decode(SessionLockInfo.self, from: data),
              let started = processStartTime(info.pid), abs(started - info.pidStartedAt) < 0.001
        else { return nil }
        return info
    }

    private var infoURL: URL { directory.appendingPathComponent("\(sessionId).json") }

    private func publish() throws {
        let pid = getpid()
        let info = mutex.withLock { SessionLockInfo(driver: driver, pid: pid, pidStartedAt: Self.processStartTime(pid) ?? 0, agent: agent) }
        // Replaced whole, so a reader never sees half of it.
        try JSONEncoder().encode(info).write(to: infoURL, options: .atomic)
    }

    /// When a process started, in seconds since 1970; nil when there's no such process.
    static func processStartTime(_ pid: Int32) -> Double? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000
    }
}
