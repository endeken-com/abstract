import Darwin
import Foundation

/// `abstract` asking the running app to start a chat's agent, so the chat is
/// the app's from its first second: you can reply to it, approve its tools or
/// stop it there, as with any chat. Over a Unix socket the app listens on
/// while it runs. No app (or a dead socket), and `abstract` runs the agent itself.
public enum AppLink {
    public struct StartRequest: Codable, Sendable {
        public var sessionId: String
        public var prompt: String
        /// The chat's agent before a respawn switched agents: the log marks the change.
        public var replacing: String?
        /// A new chat, not a respawned one: its transcript starts empty.
        public var fresh: Bool
    }

    /// The agent the app started, or why it didn't.
    public struct StartReply: Codable, Sendable {
        public var agent: AgentRecord?
        public var message: String?

        public init(agent: AgentRecord?, message: String?) {
            self.agent = agent; self.message = message
        }
    }

    /// In this user's temporary folder, whose path is short enough for a
    /// socket; one per data folder, so a demo or a test never reaches the real app.
    public static func socketPath(storePath: String = Store.defaultPath()) -> String {
        (NSTemporaryDirectory() as NSString).appendingPathComponent("abstract-\(WorktreeNaming.shortHash(storePath)).sock")
    }

    /// What the app runs while it's open: answers each request with `handler`.
    public final class Server: @unchecked Sendable {
        private let fd: Int32
        private let path: String
        private let source: any DispatchSourceRead

        /// Listens for the data folder at `storePath`; nil when another app
        /// already does, or the socket can't be made.
        public init?(storePath: String, handler: @escaping @Sendable (StartRequest) async -> StartReply) {
            let path = AppLink.socketPath(storePath: storePath)
            if let other = HostSocket.connect(path: path) {
                close(other)
                return nil
            }
            unlink(path)
            guard let fd = try? HostSocket.listen(path: path) else { return nil }
            self.fd = fd
            self.path = path
            source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue(label: "sh.abstract.app-link"))
            source.setEventHandler {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { return }
                var on: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                guard let line = HostSocket.readLine(client, timeoutMs: 5_000),
                      let request = try? JSONDecoder().decode(StartRequest.self, from: line) else {
                    close(client)
                    return
                }
                Task {
                    let reply = await handler(request)
                    HostSocket.writeLine(client, (try? JSONEncoder().encode(reply)) ?? Data())
                    close(client)
                }
            }
            source.resume()
        }

        public func stop() {
            source.cancel()
            close(fd)
            unlink(path)
        }
    }

    /// Asks the running app to start `request`'s agent and waits for it to
    /// be up. nil when no app listens.
    static func start(_ request: StartRequest, storePath: String) throws -> StartReply? {
        guard let fd = HostSocket.connect(path: socketPath(storePath: storePath)) else { return nil }
        defer { close(fd) }
        guard HostSocket.writeLine(fd, try JSONEncoder().encode(request)) else { return nil }
        guard let line = HostSocket.readLine(fd, timeoutMs: Int32((AgentStart.timeout + 60) * 1000)),
              let reply = try? JSONDecoder().decode(StartReply.self, from: line) else {
            throw CLIError(.agentStartFailed, "Abstract stopped answering before the agent started.")
        }
        return reply
    }
}
