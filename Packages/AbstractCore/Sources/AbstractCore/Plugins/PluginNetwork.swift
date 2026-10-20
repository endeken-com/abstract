import Foundation

/// A plugin's network request, as the plugin asks for it (ABS-94). It is
/// carried over the bridge and never sent as-is: `PluginFetchService`
/// checks it, puts secret values into headers, and only then sends it.
public struct PluginFetchRequest: Sendable, Equatable {
    public var url: String
    public var method: String
    public var headers: [String: String]
    /// Header name → a header the host fills from a named secret. The
    /// plugin names the secret; it never sees the value.
    public var secretHeaders: [String: SecretHeader]
    public var body: String?

    public struct SecretHeader: Sendable, Equatable {
        public var secret: String
        /// Text before the value, like "Bearer ".
        public var prefix: String
        public init(secret: String, prefix: String = "") { self.secret = secret; self.prefix = prefix }
    }

    public init(url: String, method: String = "GET", headers: [String: String] = [:],
                secretHeaders: [String: SecretHeader] = [:], body: String? = nil) {
        self.url = url; self.method = method; self.headers = headers
        self.secretHeaders = secretHeaders; self.body = body
    }

    /// From a bridge payload. Nil when the shape is wrong.
    public init?(payload: JSONValue?) {
        guard let url = payload?["url"]?.string else { return nil }
        var headers: [String: String] = [:]
        for (name, value) in payload?["headers"]?.object ?? [:] {
            guard let value = value.string else { return nil }
            headers[name] = value
        }
        var secretHeaders: [String: SecretHeader] = [:]
        for (name, value) in payload?["secretHeaders"]?.object ?? [:] {
            guard let secret = value["secret"]?.string else { return nil }
            if let prefix = value["prefix"], prefix.string == nil { return nil }
            secretHeaders[name] = SecretHeader(secret: secret, prefix: value["prefix"]?.string ?? "")
        }
        if let method = payload?["method"], method.string == nil { return nil }
        if let body = payload?["body"], body != .null, body.string == nil { return nil }
        self.init(url: url, method: payload?["method"]?.string ?? "GET", headers: headers,
                  secretHeaders: secretHeaders, body: payload?["body"]?.string)
    }
}

/// What the plugin gets back: status, headers (never cookies) and the body
/// as text, or base64 when it isn't text. Secret values are never in it.
public struct PluginFetchResponse: Sendable, Equatable {
    public var status: Int
    public var headers: [String: String]
    public var body: String
    public var bodyIsBase64: Bool

    public func jsonValue() -> JSONValue {
        .object(["status": .number(Double(status)),
                 "headers": .object(headers.mapValues(JSONValue.string)),
                 "body": .string(body), "bodyIsBase64": .bool(bodyIsBase64)])
    }
}

/// Why a request wasn't sent (or wasn't finished), in a plain sentence.
public enum PluginFetchError: Error, Sendable, Equatable, CustomStringConvertible {
    case refused(String)
    case failed(String)

    public var description: String {
        switch self {
        case .refused(let why), .failed(let why): why
        }
    }
}

/// Resolves a plugin's named secret to its value, host-side only. The app
/// backs this with the Keychain; tests use a dictionary.
public protocol PluginSecretResolving: Sendable {
    func secretValue(pluginId: String, name: String) -> String?
}

public struct DictionaryPluginSecrets: PluginSecretResolving {
    public var values: [String: String]
    public init(_ values: [String: String] = [:]) { self.values = values }
    public func secretValue(pluginId: String, name: String) -> String? { values[name] }
}

/// One actual send. The live one uses `URLSession` and does not follow
/// redirects (the service checks and follows them itself); tests supply
/// their own.
public protocol PluginNetworkTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Every request a plugin made, for Settings → Plugins (ABS-94): time,
/// host and status only — never the URL path, headers, body or a secret.
public struct PluginNetworkLog: Sendable {
    public static let entryLimit = 100

    public struct Entry: Sendable, Hashable, Codable, Identifiable {
        public var at: Date
        public var host: String
        /// The HTTP status, or 0 when the request was refused or failed.
        public var status: Int
        public var id: Date { at }
        public init(at: Date, host: String, status: Int) { self.at = at; self.host = host; self.status = status }
    }

    public var fileURL: URL

    public init(fileURL: URL) { self.fileURL = fileURL }

    public init(directory: URL, pluginId: String) {
        self.init(fileURL: directory.appendingPathComponent("\(pluginId).network-log.json"))
    }

    /// Newest first. An unreadable log reads as empty, never fatal.
    public func entries() -> [Entry] {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return decoded
    }

    public func append(_ entry: Entry) {
        var all = [entry] + entries()
        all.sort { $0.at > $1.at }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(Array(all.prefix(Self.entryLimit))) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: [.atomic])
    }

    public func removeAll() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}

/// Sends plugin requests under ABS-94's rules: https to an exact listed
/// host, no cookies, bodies up to 1 MB, redirects only to a listed host,
/// secrets put in by the host and never handed back, and every attempt
/// logged. The page's own network stays closed; this is the only way out.
public struct PluginFetchService: Sendable {
    public static let bodyByteLimit = 1_024 * 1_024
    public static let redirectLimit = 5
    static let methods: Set<String> = ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE"]

    public var pluginId: String
    /// The granted hosts (from the record, not just the manifest).
    public var allowedHosts: Set<String>
    /// The granted secret names.
    public var secretNames: Set<String>
    public var secrets: any PluginSecretResolving
    public var transport: any PluginNetworkTransport
    public var log: PluginNetworkLog?

    public init(pluginId: String, allowedHosts: Set<String>, secretNames: Set<String> = [],
                secrets: any PluginSecretResolving, transport: any PluginNetworkTransport,
                log: PluginNetworkLog? = nil) {
        self.pluginId = pluginId
        self.allowedHosts = Set(allowedHosts.map { $0.lowercased() })
        self.secretNames = secretNames
        self.secrets = secrets
        self.transport = transport
        self.log = log
    }

    public func perform(_ fetch: PluginFetchRequest, now: Date = Date()) async throws -> PluginFetchResponse {
        do {
            let response = try await send(fetch, redirectsLeft: Self.redirectLimit)
            log?.append(.init(at: now, host: host(of: fetch.url) ?? "", status: response.status))
            return response
        } catch let error as PluginFetchError {
            log?.append(.init(at: now, host: host(of: fetch.url) ?? "", status: 0))
            throw error
        }
    }

    private func send(_ fetch: PluginFetchRequest, redirectsLeft: Int) async throws -> PluginFetchResponse {
        let request = try urlRequest(for: fetch)
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch let error as PluginFetchError {
            throw error
        } catch {
            throw PluginFetchError.failed("That request couldn't be sent.")
        }
        guard data.count <= Self.bodyByteLimit else {
            throw PluginFetchError.refused("That reply was larger than 1 MB, so it wasn't passed on.")
        }
        if (300..<400).contains(response.statusCode),
           let location = response.value(forHTTPHeaderField: "Location"),
           let next = URL(string: location, relativeTo: request.url)?.absoluteURL {
            guard redirectsLeft > 0 else {
                throw PluginFetchError.refused("That request redirected too many times, so it was stopped.")
            }
            // A redirect is a new request: checked like the first, and
            // secret headers never carry over to it.
            let follow = PluginFetchRequest(
                url: next.absoluteString,
                method: [301, 302, 303].contains(response.statusCode) ? "GET" : fetch.method,
                headers: fetch.headers,
                body: [301, 302, 303].contains(response.statusCode) ? nil : fetch.body)
            return try await send(follow, redirectsLeft: redirectsLeft - 1)
        }
        var headers: [String: String] = [:]
        for (name, value) in response.allHeaderFields {
            let name = String(describing: name)
            if name.lowercased() == "set-cookie" { continue }
            headers[name] = String(describing: value)
        }
        if let text = String(data: data, encoding: .utf8) {
            return PluginFetchResponse(status: response.statusCode, headers: headers, body: text, bodyIsBase64: false)
        }
        return PluginFetchResponse(status: response.statusCode, headers: headers,
                                   body: data.base64EncodedString(), bodyIsBase64: true)
    }

    /// The request that would be sent, secrets in. Throws a plain refusal
    /// for anything outside the grant; nothing is sent in that case.
    public func urlRequest(for fetch: PluginFetchRequest) throws -> URLRequest {
        let method = fetch.method.uppercased()
        guard Self.methods.contains(method) else {
            throw PluginFetchError.refused("Abstract doesn't send \(method) requests for plugins.")
        }
        guard let url = URL(string: fetch.url), let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw PluginFetchError.refused("That web address couldn't be read.")
        }
        guard parts.scheme?.lowercased() == "https" else {
            throw PluginFetchError.refused("Plugins can only reach secure (https) addresses.")
        }
        guard parts.user == nil, parts.password == nil else {
            throw PluginFetchError.refused("That web address has a name or password in it, so it was refused.")
        }
        guard let host = parts.host?.lowercased(), PluginManifest.isExactHost(host), allowedHosts.contains(host) else {
            throw PluginFetchError.refused("This plugin hasn't been granted reaching \(parts.host ?? "that address").")
        }
        guard parts.port == nil || parts.port == 443 else {
            throw PluginFetchError.refused("This plugin hasn't been granted reaching \(host) on that port.")
        }
        let body = fetch.body.map { Data($0.utf8) }
        guard (body?.count ?? 0) <= Self.bodyByteLimit else {
            throw PluginFetchError.refused("That request was larger than 1 MB, so it wasn't sent.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpShouldHandleCookies = false
        request.httpBody = body
        for (name, value) in fetch.headers {
            guard Self.isHeaderName(name) else {
                throw PluginFetchError.refused("That request had a header Abstract can't send.")
            }
            // The host owns these; a plugin never sends cookies.
            if ["cookie", "host", "content-length"].contains(name.lowercased()) { continue }
            request.setValue(value, forHTTPHeaderField: name)
        }
        for (name, header) in fetch.secretHeaders {
            guard Self.isHeaderName(name), !["cookie", "host", "content-length"].contains(name.lowercased()) else {
                throw PluginFetchError.refused("That request had a header Abstract can't send.")
            }
            guard secretNames.contains(header.secret) else {
                throw PluginFetchError.refused("This plugin hasn't been granted that secret.")
            }
            guard let value = secrets.secretValue(pluginId: pluginId, name: header.secret), !value.isEmpty else {
                throw PluginFetchError.refused("That secret hasn't been entered in Settings → Plugins yet.")
            }
            request.setValue(header.prefix + value, forHTTPHeaderField: name)
        }
        return request
    }

    private func host(of url: String) -> String? {
        URLComponents(string: url)?.host?.lowercased()
    }

    static func isHeaderName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 80
            && name.allSatisfy { $0.isLetter || $0.isNumber || "!#$%&'*+-.^_`|~".contains($0) }
    }
}

/// The live transport: an ephemeral session (no stored cookies) that
/// sends no cookies and never follows a redirect on its own — the
/// service checks each redirect against the granted hosts first.
public final class URLSessionPluginTransport: NSObject, PluginNetworkTransport, URLSessionTaskDelegate {
    public override init() { super.init() }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PluginFetchError.failed("That request couldn't be sent.")
        }
        return (data, http)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest,
                           completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
