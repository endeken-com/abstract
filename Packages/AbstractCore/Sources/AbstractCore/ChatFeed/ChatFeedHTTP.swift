import CryptoKit
import Foundation
import Security
import Synchronization

/// One HTTP/1.1 request, as far as the chat feed reads one.
public struct FeedHTTPRequest: Sendable {
    public var method: String
    /// Without its query string.
    public var path: String
    /// Names lowercased.
    public var headers: [String: String]
    public var body: Data
    /// It declared a body over `FeedHTTPParser.maxBody`; the body wasn't read.
    public var bodyTooLarge = false

    public init(method: String, path: String, headers: [String: String] = [:], body: Data = Data(), bodyTooLarge: Bool = false) {
        self.method = method
        self.path = path
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { _, last in last })
        self.body = body
        self.bodyTooLarge = bodyTooLarge
    }
}

public struct FeedHTTPResponse: Sendable, Equatable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status; self.headers = headers; self.body = body
    }

    static let reasons = [200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden",
                          404: "Not Found", 405: "Method Not Allowed", 413: "Content Too Large",
                          415: "Unsupported Media Type", 429: "Too Many Requests", 431: "Request Header Fields Too Large",
                          500: "Internal Server Error", 503: "Service Unavailable"]

    /// The response on the wire. Every connection is closed after one answer.
    public func serialized() -> Data {
        var head = "HTTP/1.1 \(status) \(Self.reasons[status] ?? "Error")\r\n"
        var all = headers
        all["Content-Length"] = String(body.count)
        all["Connection"] = "close"
        all["Cache-Control"] = "no-store"
        for (name, value) in all.sorted(by: { $0.key < $1.key }) { head += "\(name): \(value)\r\n" }
        head += "\r\n"
        return Data(head.utf8) + body
    }
}

/// Reads one request out of the bytes a connection has sent so far.
public enum FeedHTTPParser {
    public static let maxHead = 16 << 10
    public static let maxBody = 64 << 10

    public enum Outcome: Sendable {
        case incomplete
        case request(FeedHTTPRequest)
        case invalid(status: Int)
    }

    public static func parse(_ data: Data) -> Outcome {
        guard let end = data.firstRange(of: Data("\r\n\r\n".utf8)) else {
            return data.count > maxHead ? .invalid(status: 431) : .incomplete
        }
        guard end.lowerBound <= maxHead, let head = String(data: data[data.startIndex..<end.lowerBound], encoding: .utf8) else {
            return .invalid(status: 431)
        }
        var lines = head.components(separatedBy: "\r\n")
        let parts = lines.removeFirst().split(separator: " ")
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1.") else { return .invalid(status: 400) }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { return .invalid(status: 400) }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let target = String(parts[1])
        let path = String(target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        var request = FeedHTTPRequest(method: String(parts[0]), path: path, headers: headers)
        let rest = data[end.upperBound...]
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            switch dechunk(rest) {
            case .incomplete: return .incomplete
            case .tooLarge: request.bodyTooLarge = true
            case .invalid: return .invalid(status: 400)
            case .body(let body): request.body = body
            }
            return .request(request)
        }
        let length = headers["content-length"].map { Int($0) } ?? 0
        guard let length, length >= 0 else { return .invalid(status: 400) }
        if length > maxBody {
            request.bodyTooLarge = true
            return .request(request)
        }
        guard rest.count >= length else { return .incomplete }
        request.body = Data(rest.prefix(length))
        return .request(request)
    }

    private enum Chunked { case incomplete, tooLarge, invalid, body(Data) }

    private static func dechunk(_ data: Data) -> Chunked {
        var body = Data()
        var i = data.startIndex
        let crlf = Data("\r\n".utf8)
        while true {
            guard let lineEnd = data[i...].firstRange(of: crlf) else { return .incomplete }
            guard let sizeText = String(data: data[i..<lineEnd.lowerBound], encoding: .ascii)?
                    .split(separator: ";").first.map({ $0.trimmingCharacters(in: .whitespaces) }),
                  let size = Int(sizeText, radix: 16), size >= 0 else { return .invalid }
            if size == 0 { return .body(body) }
            if body.count + size > maxBody { return .tooLarge }
            let start = lineEnd.upperBound
            guard data.distance(from: start, to: data.endIndex) >= size + 2 else { return .incomplete }
            let stop = data.index(start, offsetBy: size)
            body.append(data[start..<stop])
            i = data.index(stop, offsetBy: 2)
        }
    }
}

/// Fixed-window-free rate limit: at most `limit` requests in any `window`.
struct FeedRateLimiter: Sendable {
    var limit: Int
    var window: TimeInterval
    private var calls: [String: [Date]] = [:]

    init(limit: Int, window: TimeInterval) { self.limit = limit; self.window = window }

    /// nil when allowed (and counted); otherwise the seconds until it would be.
    mutating func take(_ key: String, at now: Date) -> Int? {
        var list = (calls[key] ?? []).filter { now.timeIntervalSince($0) < window }
        defer { calls[key] = list }
        guard list.count < limit else {
            return max(1, Int((window - now.timeIntervalSince(list[0])).rounded(.up)))
        }
        list.append(now)
        return nil
    }

    mutating func reset() { calls.removeAll() }
}

/// The chat feed's HTTP endpoint (ABS-217), apart from the socket: the
/// token, the Origin check, the rate limit, the one path and verb, the
/// size caps and the log, in front of `ChatFeedMCPServer`. Nothing reaches
/// the server, and no method answers, without the token.
public final class ChatFeedEndpoint: Sendable {
    public static let path = "/mcp"
    public static let maxResponse = 1 << 20
    public static let requestsPerMinute = 60

    public struct Configuration: Sendable, Equatable {
        /// nil: no token yet, so every request is refused.
        public var token: String?
        public var filter: ChatFeedFilter
        /// Exact `Origin` values allowed; a request with any other Origin is refused.
        public var allowedOrigins: [String]

        public init(token: String?, filter: ChatFeedFilter = ChatFeedFilter(), allowedOrigins: [String] = []) {
            self.token = token; self.filter = filter; self.allowedOrigins = allowedOrigins
        }
    }

    let reader: any ChatFeedReader
    let log: ChatFeedLog?
    let clock: @Sendable () -> Date
    private let state: Mutex<(config: Configuration, limiter: FeedRateLimiter)>

    public init(reader: any ChatFeedReader, configuration: Configuration, log: ChatFeedLog?,
                clock: @escaping @Sendable () -> Date = { Date() }) {
        self.reader = reader
        self.log = log
        self.clock = clock
        state = Mutex((configuration, FeedRateLimiter(limit: Self.requestsPerMinute, window: 60)))
    }

    /// Takes effect from the next request: a rotated or revoked token is
    /// refused at once.
    public var configuration: Configuration {
        get { state.withLock { $0.config } }
        set {
            state.withLock {
                if $0.config.token != newValue.token { $0.limiter.reset() }
                $0.config = newValue
            }
        }
    }

    public func respond(to request: FeedHTTPRequest) -> FeedHTTPResponse {
        let started = clock()
        var entry = ChatFeedLog.Entry(time: started, code: 0, ms: 0)
        let response = answer(request, entry: &entry)
        entry.code = response.status
        entry.ms = max(0, Int(clock().timeIntervalSince(started) * 1000))
        log?.append(entry)
        return response
    }

    /// For an unreadable request, so the log still has one line for it.
    public func reject(status: Int) -> FeedHTTPResponse {
        log?.append(ChatFeedLog.Entry(time: clock(), code: status, ms: 0))
        return FeedHTTPResponse(status: status)
    }

    private func answer(_ request: FeedHTTPRequest, entry: inout ChatFeedLog.Entry) -> FeedHTTPResponse {
        let config = configuration
        guard let token = config.token, !token.isEmpty, let given = Self.bearer(request.headers["authorization"]),
              Self.constantTimeEqual(given, token) else {
            return FeedHTTPResponse(status: 401, headers: ["WWW-Authenticate": "Bearer"])
        }
        if let origin = request.headers["origin"], !config.allowedOrigins.contains(origin) {
            return FeedHTTPResponse(status: 403)
        }
        let key = Data(SHA256.hash(data: Data(token.utf8))).base64EncodedString()
        if let wait = state.withLock({ $0.limiter.take(key, at: clock()) }) {
            return FeedHTTPResponse(status: 429, headers: ["Retry-After": String(wait)])
        }
        guard request.path == Self.path else { return FeedHTTPResponse(status: 404) }
        guard request.method == "POST" else { return FeedHTTPResponse(status: 405, headers: ["Allow": "POST"]) }
        guard !request.bodyTooLarge else { return FeedHTTPResponse(status: 413) }
        guard request.headers["content-type"]?.lowercased().hasPrefix("application/json") == true else {
            return FeedHTTPResponse(status: 415)
        }
        if let version = request.headers["mcp-protocol-version"], !ChatFeedMCPServer.protocolVersions.contains(version) {
            return json(400, Self.rpcError(-32600, "Unsupported protocol version."))
        }
        guard let message = try? JSONDecoder().decode(JSONValue.self, from: request.body) else {
            return json(400, Self.rpcError(-32700, "Parse error."))
        }
        guard case .object = message else {
            // One JSON-RPC message per POST: batches aren't part of the transport.
            return json(400, Self.rpcError(-32600, "Send one JSON-RPC message per request."))
        }
        let server = ChatFeedMCPServer(reader: reader, filter: config.filter, now: clock)
        let reply = server.handle(message)
        entry.method = reply.method
        entry.tool = reply.tool
        entry.chatId = reply.chatId.flatMap(Self.loggableId)
        if reply.tool != nil { entry.toolError = reply.isError }
        guard let body = reply.body else { return FeedHTTPResponse(status: 202) }
        var data = Data(body.compact().utf8)
        if data.count > Self.maxResponse {
            entry.toolError = true
            let tooBig = JSONValue.object([
                "jsonrpc": .string("2.0"), "id": message["id"] ?? .null,
                "result": .object(["content": .array([.object(["type": .string("text"), "text": .string(
                    "A resposta passou de 1 MB. Peça menos de uma vez: um limite menor ou um intervalo mais curto.")])]),
                                   "isError": .bool(true)]),
            ])
            data = Data(tooBig.compact().utf8)
        }
        return FeedHTTPResponse(status: 200, headers: ["Content-Type": "application/json"], body: data)
    }

    private func json(_ status: Int, _ value: JSONValue) -> FeedHTTPResponse {
        FeedHTTPResponse(status: status, headers: ["Content-Type": "application/json"], body: Data(value.compact().utf8))
    }

    private static func rpcError(_ code: Int, _ message: String) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": .null,
                 "error": .object(["code": .number(Double(code)), "message": .string(message)])])
    }

    static func bearer(_ header: String?) -> String? {
        guard let header else { return nil }
        let parts = header.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else { return nil }
        let token = parts[1].trimmingCharacters(in: .whitespaces)
        return token.isEmpty ? nil : token
    }

    /// Compares digests, so the time taken says nothing about how much of the token matched.
    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(SHA256.hash(data: Data(a.utf8))), y = Array(SHA256.hash(data: Data(b.utf8)))
        var diff: UInt8 = 0
        for i in 0..<x.count { diff |= x[i] ^ y[i] }
        return diff == 0
    }

    /// A chat id is logged only when it looks like one, so a client can't
    /// write its own text into the log through it.
    static func loggableId(_ id: String) -> String? {
        id.count <= 64 && id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) ? id : nil
    }

    /// A new token: 32 random bytes, base64url.
    public static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "No random bytes for the chat feed's token.")
        return "abs_" + Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
