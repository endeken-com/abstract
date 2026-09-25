import Darwin
import Foundation

/// What `abstract agent send` asks the host running a chat's agent.
struct HostRequest: Codable {
    var op: String
    /// The agent the caller means: a respawned chat's new agent never takes its predecessor's messages.
    var agentId: String
    var text: String?
}

struct HostReply: Codable {
    var ok: Bool
    var code: CLIError.Code?
    var message: String?

    static let ok = HostReply(ok: true, code: nil, message: nil)
    static func failed(_ error: CLIError) -> HostReply { HostReply(ok: false, code: error.code, message: error.message) }
}

/// The Unix socket a host listens on: `<session id>.sock` beside the chat's
/// lock. A socket's path is limited to 104 bytes and the data folder can be
/// long, so both ends reach it by name from inside that folder (which makes
/// each change its working directory; neither uses relative paths otherwise).
enum HostSocket {
    static func name(_ sessionId: String) -> String { "\(sessionId).sock" }

    static func listen(sessionId: String, in directory: URL) throws -> Int32 {
        guard chdir(directory.path) == 0 else { throw posixError("chdir \(directory.path)") }
        let name = name(sessionId)
        unlink(name)
        return try listen(path: name)
    }

    /// A listening socket at `path`, which must fit a socket address.
    static func listen(path: String) throws -> Int32 {
        guard fits(path) else { throw AbstractError.message("\(path) is too long for a socket") }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw posixError("socket") }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var address = Self.address(path)
        guard withSockaddr(&address, { bind(fd, $0, $1) }) == 0, Darwin.listen(fd, 8) == 0 else {
            let error = posixError("listen on \(path)")
            close(fd)
            throw error
        }
        chmod(path, 0o600)
        return fd
    }

    /// Connected to the socket at `path`; nil when nothing listens there.
    static func connect(path: String) -> Int32? {
        guard fits(path) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var address = Self.address(path)
        guard withSockaddr(&address, { Darwin.connect(fd, $0, $1) }) == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    /// Whether `path` fits a socket address (104 bytes, with its terminator).
    static func fits(_ path: String) -> Bool {
        path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path)
    }

    /// The host's answer; nil when no host listens (or it went away mid-request).
    static func request(_ request: HostRequest, sessionId: String, in directory: URL,
                        timeoutMs: Int32 = 15_000) throws -> HostReply? {
        guard chdir(directory.path) == 0 else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw posixError("socket") }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var address = Self.address(name(sessionId))
        guard withSockaddr(&address, { Darwin.connect(fd, $0, $1) }) == 0 else { return nil }
        guard writeLine(fd, try JSONEncoder().encode(request)), let line = readLine(fd, timeoutMs: timeoutMs) else { return nil }
        return try? JSONDecoder().decode(HostReply.self, from: line)
    }

    /// One `\n`-terminated line (without it), or what came before EOF; nil on timeout or error.
    static func readLine(_ fd: Int32, timeoutMs: Int32) -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        while true {
            if let newline = data.firstIndex(of: 0x0A) { return data[data.startIndex..<newline] }
            let remaining = Int32(max(0, deadline.timeIntervalSinceNow * 1000))
            guard remaining > 0 else { return nil }
            var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&poller, 1, remaining)
            if ready < 0, errno == EINTR { continue }
            guard ready > 0 else { return nil }
            let n = read(fd, &buffer, buffer.count)
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { return data.isEmpty ? nil : data }
            data.append(contentsOf: buffer[0..<n])
        }
    }

    /// `data` and a newline, all of it; false when the other end is gone.
    @discardableResult
    static func writeLine(_ fd: Int32, _ data: Data) -> Bool {
        let bytes = [UInt8](data) + [0x0A]
        var offset = 0
        while offset < bytes.count {
            let n = bytes.withUnsafeBytes { write(fd, $0.baseAddress! + offset, bytes.count - offset) }
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { return false }
            offset += n
        }
        return true
    }

    private static func address(_ path: String) -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes.prefix(raw.count - 1))
        }
        return address
    }

    private static func withSockaddr<T>(_ address: inout sockaddr_un, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
        withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }

    private static func posixError(_ what: String) -> AbstractError {
        AbstractError.message("\(what): \(String(cString: strerror(errno)))")
    }
}
