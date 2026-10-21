import Foundation
import Synchronization

/// Asks an MCP server which tools it offers, so Project Settings can set
/// each one's access (ABS-123). Abstract only lists: the agents call them.
public enum MCPToolList {
    public enum Failure: LocalizedError, Equatable {
        /// The server wants a sign-in (HTTP 401 or 403).
        case signIn
        case timedOut
        /// The server answered something else; the words say what.
        case server(String)

        public var errorDescription: String? {
            switch self {
            case .signIn:
                "The server asks you to sign in. The agents do that themselves where they can, but Abstract can't list its tools until you add a header with a key, if the server takes one. Until then each agent uses all of its tools under its own rules."
            case .timedOut: "The server didn't answer within 20 seconds."
            case let .server(text): text
            }
        }
    }

    public static func list(_ connection: ProjectToolServer.Connection,
                            timeout: Duration = .seconds(20)) async throws -> [ProjectToolServer.Tool] {
        switch connection {
        case let .url(url, headers):
            guard let endpoint = URL(string: url), endpoint.scheme == "https" || endpoint.scheme == "http" else {
                throw Failure.server("That isn't a web address.")
            }
            return try await HTTPClient(endpoint: endpoint, headers: headers, timeout: timeout).listTools()
        case let .command(argv, env):
            guard !argv.isEmpty else { throw Failure.server("There's no command to run.") }
            return try await StdioClient.listTools(argv: argv, env: env, timeout: timeout)
        }
    }

    // MARK: - The protocol

    static let protocolVersion = "2025-06-18"

    static func request(id: Int, method: String, params: JSONValue = .object([:])) -> String {
        JSONValue.object(["jsonrpc": .string("2.0"), "id": .number(Double(id)), "method": .string(method),
                          "params": params]).compact()
    }

    static func notification(_ method: String) -> String {
        JSONValue.object(["jsonrpc": .string("2.0"), "method": .string(method)]).compact()
    }

    static var initializeParams: JSONValue {
        .object(["protocolVersion": .string(protocolVersion), "capabilities": .object([:]),
                 "clientInfo": .object(["name": .string("abstract"), "version": .string("0.0.0")])])
    }

    /// The tools of one `tools/list` result, and the cursor of the next page.
    static func tools(in result: JSONValue) -> (tools: [ProjectToolServer.Tool], next: String?) {
        let tools = (result["tools"]?.array ?? []).compactMap { tool -> ProjectToolServer.Tool? in
            guard let name = tool["name"]?.string, ProjectToolServer.Tool.isValidName(name) else { return nil }
            let detail = tool["description"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
            return ProjectToolServer.Tool(name: name, detail: detail?.isEmpty == false ? detail : nil,
                                          readOnly: tool["annotations"]?["readOnlyHint"]?.bool ?? false)
        }
        return (tools, result["nextCursor"]?.string.flatMap { $0.isEmpty ? nil : $0 })
    }

    /// The `result` of the message answering `id`, or its error as a failure.
    static func result(of message: JSONValue, id: Int) throws -> JSONValue? {
        guard message["id"]?.int == id else { return nil }
        if let error = message["error"] {
            throw Failure.server(error["message"]?.string ?? "The server refused the request.")
        }
        return message["result"] ?? .object([:])
    }

    /// The JSON-RPC messages in a body sent as JSON or as server-sent events.
    static func messages(inBody body: String, eventStream: Bool) -> [JSONValue] {
        let decode = { (text: String) in try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) }
        guard eventStream else {
            guard let value = decode(body) else { return [] }
            return value.array ?? [value]
        }
        var messages: [JSONValue] = []
        var data: [String] = []
        for line in (body + "\n\n").components(separatedBy: "\n").map({ $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }) {
            if line.isEmpty {
                if !data.isEmpty, let value = decode(data.joined(separator: "\n")) { messages.append(value) }
                data = []
            } else if line.hasPrefix("data:") {
                data.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
            }
        }
        return messages
    }

    static func allPages(_ fetch: (String?) async throws -> JSONValue) async throws -> [ProjectToolServer.Tool] {
        var all: [ProjectToolServer.Tool] = []
        var cursor: String?
        repeat {
            let page = tools(in: try await fetch(cursor))
            all += page.tools
            cursor = page.next
        } while cursor != nil && all.count < 2_000
        return all
    }

    static func pageParams(_ cursor: String?) -> JSONValue {
        .object(cursor.map { ["cursor": .string($0)] } ?? [:])
    }

    // MARK: - Streamable HTTP

    private struct HTTPClient {
        let endpoint: URL
        let headers: [String: String]
        let timeout: Duration

        func listTools() async throws -> [ProjectToolServer.Tool] {
            var session: String?
            _ = try await send(request(id: 1, method: "initialize", params: initializeParams), id: 1, session: &session)
            _ = try? await send(notification("notifications/initialized"), id: nil, session: &session)
            var next = 2
            return try await allPages { cursor in
                defer { next += 1 }
                return try await send(request(id: next, method: "tools/list", params: pageParams(cursor)), id: next,
                                      session: &session) ?? .object([:])
            }
        }

        func send(_ body: String, id: Int?, session: inout String?) async throws -> JSONValue? {
            var request = URLRequest(url: endpoint, timeoutInterval: Double(timeout.components.seconds))
            request.httpMethod = "POST"
            request.httpBody = Data(body.utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
            request.setValue(MCPToolList.protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
            if let session { request.setValue(session, forHTTPHeaderField: "Mcp-Session-Id") }
            for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
            let (data, response): (Data, URLResponse)
            do { (data, response) = try await URLSession.shared.data(for: request) } catch let error as URLError {
                throw error.code == .timedOut ? Failure.timedOut : Failure.server(error.localizedDescription)
            }
            guard let http = response as? HTTPURLResponse else { throw Failure.server("The server didn't answer over HTTP.") }
            if http.statusCode == 401 || http.statusCode == 403 { throw Failure.signIn }
            guard (200..<300).contains(http.statusCode) else {
                throw Failure.server("The server answered \(http.statusCode) \(HTTPURLResponse.localizedString(forStatusCode: http.statusCode)).")
            }
            if let id = http.value(forHTTPHeaderField: "Mcp-Session-Id") { session = id }
            guard let id else { return nil }
            let stream = http.value(forHTTPHeaderField: "Content-Type")?.contains("text/event-stream") == true
            for message in messages(inBody: String(decoding: data, as: UTF8.self), eventStream: stream) {
                if let result = try result(of: message, id: id) { return result }
            }
            throw Failure.server("The server's answer wasn't MCP.")
        }
    }

    // MARK: - stdio

    private enum StdioClient {
        static func listTools(argv: [String], env: [String: String], timeout: Duration) async throws -> [ProjectToolServer.Tool] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = argv
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = await LoginShell.path()
            for (key, value) in env { environment[key] = value }
            process.environment = environment
            process.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())
            let input = Pipe(), output = Pipe(), errors = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = errors
            let stderr = Mutex(Data())
            errors.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                stderr.withLock { if $0.count < 64_000 { $0.append(chunk) } }
            }
            // A server that has already ended must fail the write, not
            // end Abstract with SIGPIPE.
            _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            do { try process.run() } catch { throw Failure.server("The command couldn't start: \(error.localizedDescription)") }
            defer {
                errors.fileHandleForReading.readabilityHandler = nil
                if process.isRunning { process.terminate() }
                try? input.fileHandleForWriting.close()
            }
            let lines = output.fileHandleForReading.bytes.lines
            let send = { (line: String) in try? input.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8)) }
            let exchange = Task { () throws -> [ProjectToolServer.Tool] in
                var iterator = lines.makeAsyncIterator()
                func answer(_ id: Int) async throws -> JSONValue {
                    while let line = try await iterator.next() {
                        guard let message = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)) else { continue }
                        if let result = try result(of: message, id: id) { return result }
                    }
                    // Its last words: once it has exited, the rest of stderr.
                    for _ in 0..<50 where process.isRunning { try await Task.sleep(for: .milliseconds(20)) }
                    if !process.isRunning {
                        errors.fileHandleForReading.readabilityHandler = nil
                        let rest = (try? errors.fileHandleForReading.readToEnd()) ?? Data()
                        stderr.withLock { $0.append(rest) }
                    }
                    let said = String(decoding: stderr.withLock { $0 }, as: UTF8.self)
                        .split(whereSeparator: \.isNewline).suffix(3).joined(separator: "\n")
                    throw Failure.server(said.isEmpty ? "The command ended without listing its tools." : said)
                }
                send(request(id: 1, method: "initialize", params: initializeParams))
                _ = try await answer(1)
                send(notification("notifications/initialized"))
                var next = 2
                return try await allPages { cursor in
                    defer { next += 1 }
                    send(request(id: next, method: "tools/list", params: pageParams(cursor)))
                    return try await answer(next)
                }
            }
            // On time, or the process is ended, which ends the read.
            let expired = Mutex(false)
            let watchdog = Task {
                try await Task.sleep(for: timeout)
                expired.withLock { $0 = true }
                if process.isRunning { process.terminate() }
            }
            defer { watchdog.cancel() }
            do {
                return try await exchange.value
            } catch {
                throw expired.withLock { $0 } ? Failure.timedOut : error
            }
        }
    }
}
