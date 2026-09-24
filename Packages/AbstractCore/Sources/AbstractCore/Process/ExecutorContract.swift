import Foundation

public struct ExecResult: Sendable, Hashable, Codable {
    public var code: Int32
    public var stdout: String
    public var stderr: String
    public var ok: Bool { code == 0 }
    public init(code: Int32, stdout: String, stderr: String) { self.code = code; self.stdout = stdout; self.stderr = stderr }
}

public struct OutputLine: Sendable, Hashable, Codable {
    public var stream: OutputStreamKind
    public var line: String
    public init(stream: OutputStreamKind, line: String) { self.stream = stream; self.line = line }
}

public enum AbstractError: Error, LocalizedError, Sendable, Equatable {
    case message(String)
    case command(code: Int32, stderr: String)
    case notFound(String)

    public var errorDescription: String? {
        switch self {
        case .message(let m): m
        case .command(let code, let stderr): stderr.isEmpty ? "Command failed with exit code \(code)" : stderr
        case .notFound(let what): "Not found: \(what)"
        }
    }
}

/// A live agent process.
public protocol RunningProcess: AnyObject, Sendable {
    var pid: Int32 { get }
    /// Write to stdin. Throws when stdin is closed.
    func write(_ text: String) throws
    func closeStdin()
    /// SIGTERM, then SIGKILL after a grace period.
    func terminate()
}

/// Where commands run. `LocalExecutor` today; an SSH executor slots in behind
/// the same protocol so git and session code never change.
public protocol Executor: Sendable {
    var homeDirectory: String { get }
    func run(_ command: String, _ args: [String], cwd: String?) async throws -> ExecResult
    /// Spawn with line-buffered output. Callbacks arrive on a background queue.
    func spawn(
        _ spec: LaunchSpec,
        onLine: @escaping @Sendable (OutputLine) -> Void,
        onExit: @escaping @Sendable (Int32?) -> Void
    ) throws -> RunningProcess
    func fileExists(_ path: String) -> Bool
    func readFile(_ path: String) throws -> String
    func createDirectory(_ path: String) throws
    func removeItem(_ path: String) throws
    /// Absolute path of a binary on this host's login-shell PATH.
    func which(_ binary: String) async -> String?
    /// A file's bytes, read on the executor's host.
    func readData(_ path: String) async throws -> Data
    func writeData(_ data: Data, to path: String) async throws
    /// What's at `path`; nil when nothing is.
    func fileInfo(_ path: String) async -> FileInfo?
}

/// A file's size, when it last changed, and whether it's a folder.
public struct FileInfo: Sendable, Hashable, Codable {
    public var size: Int64
    public var modified: Date?
    public var isDirectory: Bool

    public init(size: Int64, modified: Date?, isDirectory: Bool) {
        self.size = size; self.modified = modified; self.isDirectory = isDirectory
    }

    /// From this Mac's file system.
    public static func local(_ path: String) -> FileInfo? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        return FileInfo(size: (a[.size] as? NSNumber)?.int64Value ?? 0, modified: a[.modificationDate] as? Date,
                        isDirectory: a[.type] as? FileAttributeType == .typeDirectory)
    }
}

/// Files on this Mac, for executors that run here.
public extension Executor {
    func readData(_ path: String) async throws -> Data { try Data(contentsOf: URL(fileURLWithPath: path)) }
    /// In place, so the file keeps its permissions.
    func writeData(_ data: Data, to path: String) async throws { try data.write(to: URL(fileURLWithPath: path)) }
    func fileInfo(_ path: String) async -> FileInfo? { FileInfo.local(path) }
}
