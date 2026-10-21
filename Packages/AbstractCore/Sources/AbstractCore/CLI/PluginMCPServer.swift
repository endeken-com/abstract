import Darwin
import Foundation
import Synchronization

/// Where a chat's plugin tools come from: the running app, which holds
/// the plugins' background scripts and the project's settings.
public protocol PluginToolSource: Sendable {
    /// The tools' `tools/list` entries; nil when the app can't be reached.
    func list() async -> [JSONValue]?
    /// Runs one call and returns what the agent reads.
    func call(_ name: String, arguments: JSONValue) async -> (text: String, isError: Bool)
}

/// `abstract mcp --chat <id> --plugins`: the stdio MCP server that gives
/// one chat's agent the tools its plugins offer (ABS-97). It knows only
/// the chat; the app decides which tools that chat's project gets and
/// runs each call. When that changes, it tells the agent the list
/// changed, so a tool switched Off is gone by the next turn. Requests
/// are answered concurrently: a call waiting for your answer doesn't
/// hold up the rest.
public final class PluginMCPServer: Sendable {
    let source: any PluginToolSource
    let pollInterval: Duration
    /// The tools last given to the agent; nil until it asked.
    private let listed = Mutex<[JSONValue]?>(nil)
    private let output = Mutex<Void>(())

    public init(source: any PluginToolSource, pollInterval: Duration = .seconds(2)) {
        self.source = source; self.pollInterval = pollInterval
    }

    public static let listChangedNotification =
        #"{"jsonrpc":"2.0","method":"notifications/tools/list_changed"}"#

    /// Answers requests from stdin until it closes, and watches the list.
    public func run() async {
        let watcher = Task { [self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: pollInterval)
                if await listChanged() { write(Self.listChangedNotification) }
            }
        }
        await withTaskGroup(of: Void.self) { group in
            do {
                for try await line in FileHandle.standardInput.bytes.lines {
                    group.addTask { [self] in
                        if let reply = await handle(line) { write(reply) }
                    }
                }
            } catch {}
        }
        watcher.cancel()
    }

    private func write(_ line: String) {
        output.withLock { _ in
            print(line)
            fflush(stdout)
        }
    }

    /// Whether the tools differ from what the agent last listed. Only
    /// after it has listed them once; the new list counts as told.
    public func listChanged() async -> Bool {
        guard listed.withLock({ $0 }) != nil, let now = await source.list() else { return false }
        return listed.withLock { last in
            guard last != now else { return false }
            last = now
            return true
        }
    }

    /// One request line → its reply line; nil for a notification, or for
    /// input that isn't a request at all.
    public func handle(_ line: String) async -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let request = try? JSONDecoder().decode(JSONValue.self, from: Data(trimmed.utf8)),
              let method = request["method"]?.string else { return nil }
        guard let id = request["id"], id != .null else { return nil }
        let params = request["params"] ?? .object([:])
        switch method {
        case "initialize":
            return reply(id, result: .object([
                "protocolVersion": params["protocolVersion"] ?? .string("2024-11-05"),
                "capabilities": .object(["tools": .object(["listChanged": .bool(true)])]),
                "serverInfo": .object(["name": .string(PluginTools.serverName), "version": .string("1")]),
            ]))
        case "ping":
            return reply(id, result: .object([:]))
        case "tools/list":
            let tools = await source.list() ?? []
            listed.withLock { $0 = tools }
            return reply(id, result: .object(["tools": .array(tools)]))
        case "tools/call":
            guard let name = params["name"]?.string, !name.isEmpty else {
                return reply(id, result: text("Name the tool to call.", isError: true))
            }
            let outcome = await source.call(name, arguments: params["arguments"] ?? .object([:]))
            return reply(id, result: text(outcome.text, isError: outcome.isError))
        default:
            return JSONValue.object([
                "jsonrpc": .string("2.0"), "id": id,
                "error": .object(["code": .number(-32601), "message": .string("Unknown method “\(method)”.")]),
            ]).compact()
        }
    }

    private func reply(_ id: JSONValue, result: JSONValue) -> String {
        JSONValue.object(["jsonrpc": .string("2.0"), "id": id, "result": result]).compact()
    }

    private func text(_ body: String, isError: Bool) -> JSONValue {
        .object(["content": .array([.object(["type": .string("text"), "text": .string(body)])]),
                 "isError": .bool(isError)])
    }
}

/// The plugin-tool server's line to the running app: a Unix socket the
/// app listens on while it's open, one request and one reply per
/// connection, as `AppLink` does for starting agents.
public enum PluginToolLink {
    public struct Request: Codable, Sendable, Equatable {
        /// `list` or `call`.
        public var op: String
        public var chatId: String
        /// The token the chat's agent was launched with.
        public var token: String
        public var name: String?
        public var arguments: JSONValue?

        public init(op: String, chatId: String, token: String, name: String? = nil, arguments: JSONValue? = nil) {
            self.op = op; self.chatId = chatId; self.token = token; self.name = name; self.arguments = arguments
        }
    }

    public struct Reply: Codable, Sendable, Equatable {
        public var tools: [JSONValue]?
        public var text: String?
        public var isError: Bool?

        public init(tools: [JSONValue]? = nil, text: String? = nil, isError: Bool? = nil) {
            self.tools = tools; self.text = text; self.isError = isError
        }
    }

    /// Beside `AppLink`'s socket, one per data folder.
    public static func socketPath(storePath: String = Store.defaultPath()) -> String {
        (NSTemporaryDirectory() as NSString).appendingPathComponent("abstract-\(WorktreeNaming.shortHash(storePath))-tools.sock")
    }

    /// What the app runs while it's open: answers each request with `handler`.
    public final class Server: @unchecked Sendable {
        private let fd: Int32
        private let path: String
        private let source: any DispatchSourceRead

        /// Listens at `path`; nil when another app already does, or the
        /// socket can't be made.
        public init?(path: String, handler: @escaping @Sendable (Request) async -> Reply) {
            if let other = HostSocket.connect(path: path) {
                close(other)
                return nil
            }
            unlink(path)
            guard let fd = try? HostSocket.listen(path: path) else { return nil }
            self.fd = fd
            self.path = path
            source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue(label: "sh.abstract.plugin-tools"))
            source.setEventHandler {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { return }
                var on: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                guard let line = HostSocket.readLine(client, timeoutMs: 5_000),
                      let request = try? JSONDecoder().decode(Request.self, from: line) else {
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

    /// The app's reply, off the caller's thread; nil when no app listens
    /// or it didn't answer in time.
    public static func send(_ request: Request, path: String, timeout: TimeInterval) async -> Reply? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                guard let fd = HostSocket.connect(path: path) else { return continuation.resume(returning: nil) }
                defer { close(fd) }
                guard let data = try? JSONEncoder().encode(request), HostSocket.writeLine(fd, data),
                      let line = HostSocket.readLine(fd, timeoutMs: Int32(timeout * 1000)) else {
                    return continuation.resume(returning: nil)
                }
                continuation.resume(returning: try? JSONDecoder().decode(Reply.self, from: line))
            }
        }
    }
}

/// A chat's plugin tools, asked of the running app.
public struct LinkedPluginTools: PluginToolSource {
    public let chatId: String
    public let token: String
    public let path: String

    public init(chatId: String, token: String, path: String = PluginToolLink.socketPath()) {
        self.chatId = chatId; self.token = token; self.path = path
    }

    public func list() async -> [JSONValue]? {
        await PluginToolLink.send(.init(op: "list", chatId: chatId, token: token), path: path, timeout: 5)?.tools
    }

    public func call(_ name: String, arguments: JSONValue) async -> (text: String, isError: Bool) {
        // Long enough for you to answer an Ask first card, then the script.
        let reply = await PluginToolLink.send(.init(op: "call", chatId: chatId, token: token, name: name, arguments: arguments),
                                              path: path, timeout: PluginTools.askTimeout + PluginTools.timeout + 30)
        guard let reply else { return ("Abstract isn't open, so plugin tools can't run.", true) }
        return (reply.text ?? "", reply.isError ?? false)
    }
}
