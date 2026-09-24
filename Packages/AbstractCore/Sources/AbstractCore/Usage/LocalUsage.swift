import Foundation
import Synchronization

/// Token use read from the agents' own session logs: every Claude profile
/// (`~/.claude` and any `~/.claude-*` a `CLAUDE_CONFIG_DIR` points at,
/// subagent transcripts included) and Codex (`~/.codex/sessions`). Nothing
/// is sent anywhere; costs are estimates at API list prices.
public enum LocalUsage {
    public struct Tokens: Codable, Sendable, Hashable {
        /// Input not served from the cache.
        public var input = 0
        public var cacheWrite5m = 0
        public var cacheWrite1h = 0
        public var cacheRead = 0
        public var output = 0

        public init(input: Int = 0, cacheWrite5m: Int = 0, cacheWrite1h: Int = 0, cacheRead: Int = 0, output: Int = 0) {
            self.input = input; self.cacheWrite5m = cacheWrite5m; self.cacheWrite1h = cacheWrite1h
            self.cacheRead = cacheRead; self.output = output
        }

        public var cacheWrite: Int { cacheWrite5m + cacheWrite1h }
        public var total: Int { input + cacheWrite + cacheRead + output }

        public static func + (a: Tokens, b: Tokens) -> Tokens {
            Tokens(input: a.input + b.input, cacheWrite5m: a.cacheWrite5m + b.cacheWrite5m, cacheWrite1h: a.cacheWrite1h + b.cacheWrite1h,
                   cacheRead: a.cacheRead + b.cacheRead, output: a.output + b.output)
        }
    }

    public enum Provider: String, Codable, Sendable, Hashable, CaseIterable { case claude, codex }

    /// One model response.
    public struct Record: Codable, Sendable, Hashable {
        /// Message and request id, for responses a resumed session copied into a new transcript.
        public var key: String?
        public var date: Date
        public var provider: Provider
        public var model: String
        public var cwd: String
        public var tokens: Tokens

        public init(key: String?, date: Date, provider: Provider, model: String, cwd: String, tokens: Tokens) {
            self.key = key; self.date = date; self.provider = provider; self.model = model; self.cwd = cwd; self.tokens = tokens
        }
    }

    // MARK: Where logs live

    /// Claude's config directories: `~/.claude` and every `~/.claude-*` folder holding transcripts.
    public static func claudeHomes(home: String, fileManager fm: FileManager = .default) -> [String] {
        let names = (try? fm.contentsOfDirectory(atPath: home)) ?? []
        let homes = names.filter { $0 == ".claude" || $0.hasPrefix(".claude-") }.sorted().map { home + "/" + $0 }
        return homes.filter { path in
            var isDirectory: ObjCBool = false
            return fm.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
                && fm.fileExists(atPath: path + "/projects")
        }
    }

    static func transcripts(under root: String, fileManager fm: FileManager = .default) -> [URL] {
        guard let walker = fm.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.isRegularFileKey],
                                         options: [.skipsHiddenFiles]) else { return [] }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "jsonl" }
    }

    // MARK: Reading everything

    private struct CachedFile: Codable {
        var modified: Date
        var size: Int
        var records: [Record]
    }

    /// Every record from every log, reusing `cache` for files that haven't
    /// changed since, then writing it back. Slow the first time; run it off
    /// the main thread.
    public static func load(home: String, cache: URL?, fileManager fm: FileManager = .default) -> [Record] {
        let stored = cache.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode([String: CachedFile].self, from: $0) } ?? [:]
        var fresh: [String: CachedFile] = [:]
        let sources = claudeHomes(home: home, fileManager: fm).flatMap { transcripts(under: $0 + "/projects", fileManager: fm).map { ($0, Provider.claude) } }
            + transcripts(under: home + "/.codex/sessions", fileManager: fm).map { ($0, Provider.codex) }
        var changed: [(url: URL, provider: Provider, modified: Date, size: Int)] = []
        for (url, provider) in sources {
            guard let attributes = try? fm.attributesOfItem(atPath: url.path),
                  let modified = attributes[.modificationDate] as? Date, let size = (attributes[.size] as? NSNumber)?.intValue else { continue }
            if let known = stored[url.path], known.modified == modified, known.size == size {
                fresh[url.path] = known
            } else {
                changed.append((url, provider, modified, size))
            }
        }
        // Files parse independently, so new ones spread across the cores.
        let parsed = Mutex<[String: CachedFile]>([:])
        DispatchQueue.concurrentPerform(iterations: changed.count) { i in
            let file = changed[i]
            guard let data = try? Data(contentsOf: file.url, options: .alwaysMapped) else { return }
            let records = file.provider == .claude ? claudeRecords(data) : codexRecords(data)
            parsed.withLock { $0[file.url.path] = CachedFile(modified: file.modified, size: file.size, records: records) }
        }
        fresh.merge(parsed.withLock { $0 }) { _, new in new }
        if let cache, let data = try? JSONEncoder().encode(fresh) {
            try? fm.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: cache, options: .atomic)
        }
        var seen = Set<String>()
        return fresh.values.flatMap(\.records).sorted { $0.date < $1.date }.filter { record in
            guard let key = record.key else { return true }
            return seen.insert(key).inserted
        }
    }

    // MARK: Claude transcripts

    /// Assistant responses with usage. A response logged once per content
    /// block counts once.
    public static func claudeRecords(_ data: Data) -> [Record] {
        var byKey: [String: Record] = [:]
        var order: [String] = []
        for line in lines(data, containing: #""output_tokens""#) {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  object["type"] as? String == "assistant",
                  let message = object["message"] as? [String: Any], let usage = message["usage"] as? [String: Any],
                  let model = message["model"] as? String, model != "<synthetic>",
                  let date = (object["timestamp"] as? String).flatMap(parseDate) else { continue }
            let creation = usage["cache_creation"] as? [String: Any]
            let written = int(usage["cache_creation_input_tokens"])
            let oneHour = int(creation?["ephemeral_1h_input_tokens"])
            let fiveMinutes = creation == nil ? written : int(creation?["ephemeral_5m_input_tokens"])
            let tokens = Tokens(input: int(usage["input_tokens"]), cacheWrite5m: fiveMinutes, cacheWrite1h: oneHour,
                                cacheRead: int(usage["cache_read_input_tokens"]), output: int(usage["output_tokens"]))
            let key = [message["id"] as? String, object["requestId"] as? String].compactMap { $0 }.joined(separator: ":")
            let record = Record(key: key.isEmpty ? nil : key, date: date, provider: .claude, model: model,
                                cwd: object["cwd"] as? String ?? "", tokens: tokens)
            let slot = key.isEmpty ? UUID().uuidString : key
            if byKey[slot] == nil { order.append(slot) }
            byKey[slot] = record
        }
        return order.compactMap { byKey[$0] }
    }

    // MARK: Codex sessions

    /// Each turn's `token_count`, under the model and folder that turn used.
    public static func codexRecords(_ data: Data) -> [Record] {
        var records: [Record] = []
        var model = "codex"
        var cwd = ""
        var lastTotal = -1
        for line in lines(data, containing: nil) {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let payload = object["payload"] as? [String: Any] else { continue }
            switch object["type"] as? String {
            case "session_meta":
                cwd = payload["cwd"] as? String ?? cwd
            case "turn_context":
                cwd = payload["cwd"] as? String ?? cwd
                model = payload["model"] as? String ?? model
            case "event_msg":
                if payload["type"] as? String == "thread_settings_applied",
                   let settings = payload["thread_settings"] as? [String: Any], let chosen = settings["model"] as? String {
                    model = chosen
                }
                guard payload["type"] as? String == "token_count", let info = payload["info"] as? [String: Any],
                      let last = info["last_token_usage"] as? [String: Any],
                      let date = (object["timestamp"] as? String).flatMap(parseDate) else { continue }
                // The same count can be reported twice; only a new total is a new turn.
                let total = int((info["total_token_usage"] as? [String: Any])?["total_tokens"])
                guard total != lastTotal else { continue }
                lastTotal = total
                let cached = int(last["cached_input_tokens"])
                records.append(Record(key: nil, date: date, provider: .codex, model: model, cwd: cwd,
                                      tokens: Tokens(input: max(0, int(last["input_tokens"]) - cached), cacheWrite5m: int(last["cache_write_input_tokens"]),
                                                     cacheRead: cached, output: int(last["output_tokens"]))))
            default:
                continue
            }
        }
        return records
    }

    // MARK: Helpers

    /// Lines of a JSONL file, skipping any without `needle` before parsing them.
    static func lines(_ data: Data, containing needle: String?) -> [Data] {
        let marker = needle.map { Data($0.utf8) }
        return data.split(separator: UInt8(ascii: "\n")).compactMap { slice in
            let line = Data(slice)
            if let marker, line.range(of: marker) == nil { return nil }
            return line
        }
    }

    private static func int(_ value: Any?) -> Int { (value as? NSNumber)?.intValue ?? 0 }

    private static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let plain = Date.ISO8601FormatStyle()

    static func parseDate(_ text: String) -> Date? { (try? fractional.parse(text)) ?? (try? plain.parse(text)) }
}

/// API list prices per million tokens, to put a figure on subscription use.
public enum ModelPricing {
    public struct Rates: Sendable, Hashable {
        public var input: Double
        public var output: Double
        public var cacheRead: Double
        public var cacheWrite5m: Double
        public var cacheWrite1h: Double

        init(input: Double, output: Double, cacheRead: Double? = nil) {
            self.input = input; self.output = output
            self.cacheRead = cacheRead ?? input * 0.1
            cacheWrite5m = input * 1.25
            cacheWrite1h = input * 2
        }
    }

    /// Longest matching prefix wins, so dated and suffixed ids resolve.
    static let table: [(prefix: String, rates: Rates)] = [
        ("claude-fable-5-1", Rates(input: 10, output: 50, cacheRead: 0.25)),
        ("claude-mythos-5-1", Rates(input: 10, output: 50, cacheRead: 0.25)),
        ("claude-fable-5", Rates(input: 10, output: 50, cacheRead: 1)),
        ("claude-mythos-5", Rates(input: 10, output: 50, cacheRead: 1)),
        ("claude-opus-5-5", Rates(input: 4, output: 20, cacheRead: 0.2)),
        ("claude-opus-5", Rates(input: 5, output: 25)),
        ("claude-opus-4-8", Rates(input: 5, output: 25)),
        ("claude-opus-4-7", Rates(input: 5, output: 25)),
        ("claude-opus-4-6", Rates(input: 5, output: 25)),
        ("claude-opus-4-5", Rates(input: 5, output: 25)),
        ("claude-opus-4", Rates(input: 15, output: 75)),
        ("claude-sonnet-5", Rates(input: 2, output: 10)),
        ("claude-sonnet-4", Rates(input: 3, output: 15)),
        ("claude-3-7-sonnet", Rates(input: 3, output: 15)),
        ("claude-3-5-sonnet", Rates(input: 3, output: 15)),
        ("claude-haiku-4", Rates(input: 1, output: 5)),
        ("claude-3-5-haiku", Rates(input: 0.8, output: 4)),
        ("gpt-5-nano", Rates(input: 0.05, output: 0.4)),
        ("gpt-5-mini", Rates(input: 0.25, output: 2)),
        ("gpt-5", Rates(input: 1.25, output: 10)),
    ]

    /// OpenAI models this table doesn't know are priced as GPT-5.
    static let codexFallback = Rates(input: 1.25, output: 10)

    public static func rates(provider: LocalUsage.Provider, model: String) -> (rates: Rates, known: Bool)? {
        let id = model.lowercased()
        if let match = table.filter({ id.hasPrefix($0.prefix) }).max(by: { $0.prefix.count < $1.prefix.count }) {
            return (match.rates, true)
        }
        // Codex also runs local models (Ollama, LM Studio): those cost nothing to price.
        let openAI = ["gpt-", "o1", "o3", "o4", "codex"].contains { id.hasPrefix($0) }
        return provider == .codex && openAI ? (codexFallback, false) : nil
    }

    /// What the tokens would cost at API rates; nil for a model with no known price.
    public static func cost(provider: LocalUsage.Provider, model: String, tokens t: LocalUsage.Tokens) -> Double? {
        guard let r = rates(provider: provider, model: model)?.rates else { return nil }
        let millions = Double(t.input) * r.input + Double(t.output) * r.output + Double(t.cacheRead) * r.cacheRead
            + Double(t.cacheWrite5m) * r.cacheWrite5m + Double(t.cacheWrite1h) * r.cacheWrite1h
        return millions / 1_000_000
    }

    /// What reading from the cache saved, against paying full input price.
    public static func cacheSavings(provider: LocalUsage.Provider, model: String, tokens t: LocalUsage.Tokens) -> Double {
        guard let r = rates(provider: provider, model: model)?.rates else { return 0 }
        return Double(t.cacheRead) * (r.input - r.cacheRead) / 1_000_000
    }
}
