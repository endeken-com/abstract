import Foundation

/// OpenCode's HTTP server, as far as compacting one session needs it. Shapes
/// checked against OpenCode 1.18.18: `serve --port 0` binds 4096, or any
/// free port when that's taken, and prints the one it bound;
/// `POST /session/{id}/summarize` blocks until it's done and answers `true`.
enum OpenCodeServer {
    /// "opencode server listening on http://127.0.0.1:4096" → 4096.
    static func port(fromLine line: String) -> Int? {
        guard let range = line.range(of: "listening on http://") else { return nil }
        let address = line[range.upperBound...]
        guard let colon = address.lastIndex(of: ":") else { return nil }
        return Int(address[address.index(after: colon)...].prefix { $0.isNumber })
    }

    /// "openrouter/anthropic/x" → ("openrouter", "anthropic/x").
    static func model(_ id: String) -> (provider: String, model: String)? {
        guard let slash = id.firstIndex(of: "/"), slash != id.startIndex, id.index(after: slash) != id.endIndex else { return nil }
        return (String(id[..<slash]), String(id[id.index(after: slash)...]))
    }

    private static func replies(_ messages: JSONValue) -> [JSONValue] {
        (messages.array ?? []).filter { $0["info"]?["role"]?.string == "assistant" }
    }

    /// The context's size: the last reply's tokens, not counting a compaction's.
    static func contextTokens(messages: JSONValue) -> Int? {
        replies(messages).last { $0["info"]?["mode"]?.string != "compaction" }?["info"]?["tokens"]?["total"]?.int
    }

    /// What the compaction wrote: its reply's text, without the reasoning.
    static func summary(messages: JSONValue) -> String? {
        guard let reply = replies(messages).last(where: { $0["info"]?["mode"]?.string == "compaction" }) else { return nil }
        let text = (reply["parts"]?.array ?? []).filter { $0["type"]?.string == "text" }.compactMap { $0["text"]?.string }
            .joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// `{"name":…,"data":{"message":…}}` → its message.
    static func errorMessage(_ body: String) -> String? {
        (try? JSONDecoder().decode(JSONValue.self, from: Data(body.utf8)))?["data"]?["message"]?.string
    }

    /// curl's output with `-w "\n%{http_code}"` → the body and the status.
    static func split(_ output: String) -> (body: String, status: Int) {
        guard let newline = output.lastIndex(of: "\n") else { return (output, 0) }
        return (String(output[..<newline]), Int(output[output.index(after: newline)...].trimmingCharacters(in: .whitespaces)) ?? 0)
    }

    /// `base + path`, with `directory` as its query value, percent-encoded by
    /// hand: `URLComponents.queryItems` leaves `+` unescaped, and OpenCode's
    /// query parser reads a literal `+` as a space. Space and `&`/`#` stay
    /// encoded too, since a directory can contain any of them.
    static func url(base: String, path: String, directory: String) -> String? {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=#")
        guard let encoded = directory.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return base + path + "?directory=" + encoded
    }

    /// `curl --max-time`'s value: whole seconds left until `deadline`, at
    /// least 1; nil once `now` is at or past it. The compaction's one
    /// timeout bounds every call together, not each on its own.
    static func maxTime(until deadline: Date, from now: Date) -> String? {
        let remaining = deadline.timeIntervalSince(now)
        guard remaining > 0 else { return nil }
        return String(max(1, Int(remaining)))
    }
}

/// Starts `opencode serve` on the chat's host, asks it to compact the
/// session, reads the summary back, and stops it. The server takes a
/// one-time password, so nothing else on the Mac can use it meanwhile.
public struct OpenCodeCompactor: Compactor {
    static let timeout: Duration = .seconds(300)
    static let startTimeout: Duration = .seconds(30)

    public init() {}

    public func compact(_ request: CompactionRequest, executor: any Executor) async throws -> CompactionResult {
        guard let id = request.model ?? OpenCodeProvider().configuredDefaultModel(home: executor.homeDirectory),
              let model = OpenCodeServer.model(id)
        else { throw AbstractError.message("OpenCode needs a model to compact with; choose one for this chat.") }
        // One deadline for the whole compaction, not a fresh 300s per call.
        let seconds = Double(Self.timeout.components.seconds) + Double(Self.timeout.components.attoseconds) / 1e18
        let deadline = Date().addingTimeInterval(seconds)
        let password = UUID().uuidString
        let spec = LaunchSpec(command: request.binaryOverride ?? OpenCodeProvider().binary,
                              args: ["serve", "--hostname", "127.0.0.1", "--port", "0"], cwd: request.cwd,
                              env: ["OPENCODE_SERVER_PASSWORD": password], keepStdinOpen: false)
        let (line, server) = try await SideProcess.start(executor, spec, timeout: Self.startTimeout) { OpenCodeServer.port(fromLine: $0) != nil }
        defer { server.terminate() }
        guard let port = OpenCodeServer.port(fromLine: line) else { throw AbstractError.message("OpenCode's server didn't say where it listens.") }
        let http = HTTP(executor: executor, base: "http://127.0.0.1:\(port)", password: password, directory: request.cwd, deadline: deadline)
        let messages = "/session/\(request.sessionId)/message"
        let before = OpenCodeServer.contextTokens(messages: try await http.json(messages))
        try Task.checkCancellation()
        let body = try JSONEncoder().encode(["providerID": model.provider, "modelID": model.model])
        let answer = try await http.call("/session/\(request.sessionId)/summarize",
                                         extra: ["-X", "POST", "-H", "content-type: application/json",
                                                 "--data-binary", String(decoding: body, as: UTF8.self)])
        guard answer.trimmingCharacters(in: .whitespacesAndNewlines) == "true" else {
            throw AbstractError.message("OpenCode didn't compact: \(answer.prefix(200))")
        }
        let summary = OpenCodeServer.summary(messages: try await http.json(messages))
        return CompactionResult(tokensBefore: before, summary: summary)
    }

    /// Requests through `curl` on the executor's host, like everything else there.
    private struct HTTP: Sendable {
        let executor: any Executor
        let base: String
        let password: String
        let directory: String
        let deadline: Date

        func json(_ path: String) async throws -> JSONValue {
            let body = try await call(path, extra: [])
            return (try? JSONDecoder().decode(JSONValue.self, from: Data(body.utf8))) ?? .null
        }

        func call(_ path: String, extra: [String]) async throws -> String {
            guard let maxTime = OpenCodeServer.maxTime(until: deadline, from: Date()) else {
                throw AbstractError.message("opencode didn't answer in time.")
            }
            guard let address = OpenCodeServer.url(base: base, path: path, directory: directory) else {
                throw AbstractError.message("Bad OpenCode address: \(path)")
            }
            let result = try await executor.run("curl", ["-sS", "--max-time", maxTime, "-u", "opencode:" + password,
                                                         "-w", "\n%{http_code}"] + extra + [address], cwd: nil)
            guard result.ok else {
                throw AbstractError.message("Couldn't reach OpenCode's server: " + result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            let (body, status) = OpenCodeServer.split(result.stdout)
            guard (200..<300).contains(status) else {
                throw AbstractError.message("OpenCode: " + (OpenCodeServer.errorMessage(body) ?? "HTTP \(status)"))
            }
            return body
        }
    }
}
