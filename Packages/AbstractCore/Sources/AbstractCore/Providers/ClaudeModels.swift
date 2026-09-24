import Foundation

/// Claude Code's model catalogue.
///
/// The CLI has no `models` command. Its stream-json `initialize` control
/// request answers with the account's models, and running no turn costs no
/// usage. Shapes verified against claude 2.1.274:
///
///     → {"type":"control_request","request_id":"<id>","request":{"subtype":"initialize"}}
///     ← {"type":"control_response","response":{"subtype":"success","request_id":"<id>",
///        "response":{"models":[{"value":"sonnet","resolvedModel":"claude-sonnet-5",
///        "displayName":"Sonnet","description":"Sonnet 5 · Efficient for routine tasks",
///        "supportsEffort":true,"supportedEffortLevels":["low",…]}, …], …}}}
///
/// The `default` entry is the account's default, not the one in
/// ~/.claude/settings.json, which still wins when set.
extension ClaudeProvider {
    /// Offered under "Specific versions" alongside whatever the account's
    /// aliases resolve to today.
    static let pinnedVersions = [
        "claude-fable-5-1", "claude-opus-5-5", "claude-opus-5-5[1m]", "claude-sonnet-5", "claude-haiku-4-5-20251001",
    ]

    /// The levels claude 2.1.274 reports for every model that takes an effort.
    static let effortLevels = ["low", "medium", "high", "xhigh", "max"]

    static let discoveryTimeout: Duration = .seconds(15)

    public var fallbackModels: ModelCatalog {
        let efforts = { (id: String) in Self.family(id) == "haiku" ? [] : Self.effortLevels }
        return ModelCatalog(
            models: ["fable", "opus", "sonnet", "haiku"].map { ModelOption(id: $0, label: Self.displayName($0), efforts: efforts($0)) },
            versions: Self.pinnedVersions.map { ModelOption(id: $0, label: Self.displayName($0), detail: $0, efforts: efforts($0)) })
    }

    public func discoverModels(executor: any Executor, binary: String?) async -> ModelCatalog? {
        await discoverModels(executor: executor, binary: binary, timeout: Self.discoveryTimeout)
    }

    func discoverModels(executor: any Executor, binary: String?, timeout: Duration) async -> ModelCatalog? {
        let override = binary.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        // Resolved up front so a missing CLI bails out without spawning.
        let found = override == nil ? await executor.which(self.binary) : nil
        guard let command = override ?? found else { return nil }
        let requestId = "abstract-models-" + UUID().uuidString
        let spec = LaunchSpec(
            command: command,
            args: ["-p", "--output-format", "stream-json", "--input-format", "stream-json", "--verbose"],
            cwd: executor.homeDirectory,
            stdinInitial: Self.initializeRequest(id: requestId),
            keepStdinOpen: true)
        let line = await ModelDiscovery.firstLine(executor, spec, timeout: timeout) { line in
            line.contains(requestId) && line.contains(#""control_response""#)
        }
        return line.flatMap { Self.modelCatalog(initializeResponse: $0, requestId: requestId) }
    }

    /// `id` is Abstract's own and never needs escaping.
    static func initializeRequest(id: String) -> String {
        #"{"type":"control_request","request_id":""# + id + #"","request":{"subtype":"initialize"}}"# + "\n"
    }

    /// The initialize `control_response` line → catalogue. nil for any other
    /// line, another request's response, an error response or no models.
    static func modelCatalog(initializeResponse line: String, requestId: String? = nil) -> ModelCatalog? {
        guard let obj = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)),
              obj["type"]?.string == "control_response",
              let response = obj["response"],
              requestId == nil || response["request_id"]?.string == requestId,
              let entries = response["response"]?["models"]?.array
        else { return nil }
        return modelCatalog(entries: entries)
    }

    static func modelCatalog(entries: [JSONValue]) -> ModelCatalog? {
        let parsed = entries.compactMap(option(entry:))
        guard !parsed.isEmpty else { return nil }
        let models = parsed.filter { $0.id != "default" }
        // Specific versions: the pinned list plus what the aliases resolve to
        // today, minus models an entry already pins (Fable's entry is a full id).
        let pinnedByEntries = Set(models.filter { $0.id.hasPrefix("claude-") }.flatMap { [$0.id, $0.resolvedId].compactMap { $0 } })
        let versionIds = (pinnedVersions + parsed.compactMap(\.resolvedId))
            .reduce(into: [String]()) { ids, id in if !ids.contains(id) { ids.append(id) } }
            .filter { !pinnedByEntries.contains($0) }
        return ModelCatalog(
            accountDefault: parsed.first { $0.id == "default" },
            models: models,
            versions: versionIds.map { ModelOption(id: $0, label: displayName($0), detail: $0, efforts: efforts(for: $0, in: parsed)) })
    }

    private static func option(entry: JSONValue) -> ModelOption? {
        guard let value = entry["value"]?.string, !value.isEmpty else { return nil }
        let resolved = entry["resolvedModel"]?.string
        let efforts = entry["supportsEffort"]?.bool == true ? (entry["supportedEffortLevels"]?.array?.compactMap(\.string) ?? []) : []
        // "Default (recommended)" says nothing once it sits under our own
        // "Default" row; name the model it runs instead.
        let label = value == "default" ? displayName(resolved ?? value) : entry["displayName"]?.string ?? displayName(value)
        return ModelOption(id: value, label: label, detail: entry["description"]?.string, efforts: efforts, resolvedId: resolved)
    }

    /// A pinned version takes the efforts of the entry that runs it, then of
    /// the same model without 1M context, then of its family.
    private static func efforts(for id: String, in entries: [ModelOption]) -> [String] {
        let base = withoutLongContext(id)
        return (entries.first { $0.resolvedId == id || $0.id == id }
            ?? entries.first { withoutLongContext($0.resolvedId ?? $0.id) == base }
            ?? entries.first { family($0.resolvedId ?? $0.id) == family(id) })?.efforts ?? []
    }

    /// "claude-opus-5-5[1m]" → "Opus 5.5 · 1M context", "claude-haiku-4-5-20251001"
    /// → "Haiku 4.5", "sonnet" → "Sonnet". Anything else is returned as is.
    static func displayName(_ id: String) -> String {
        let longContext = id.hasSuffix("[1m]")
        let base = withoutLongContext(id)
        let parts = base.split(separator: "-").map(String.init)
        guard parts.first == "claude" || parts.count == 1 else { return id }
        let words = parts.first == "claude" ? Array(parts.dropFirst()) : parts
        guard let family = words.first(where: { Int($0) == nil }) else { return id }
        // Short numbers are the version; the 8-digit one is a snapshot date.
        let version = words.filter { Int($0) != nil && $0.count <= 2 }.joined(separator: ".")
        let name = family.prefix(1).uppercased() + family.dropFirst() + (version.isEmpty ? "" : " " + version)
        return longContext ? name + " · 1M context" : name
    }

    private static func withoutLongContext(_ id: String) -> String {
        id.hasSuffix("[1m]") ? String(id.dropLast(4)) : id
    }

    /// "claude-haiku-4-5-20251001" → "haiku", "opus[1m]" → "opus".
    private static func family(_ id: String) -> String? {
        withoutLongContext(id).split(separator: "-").map(String.init).first { $0 != "claude" && Int($0) == nil }
    }
}
