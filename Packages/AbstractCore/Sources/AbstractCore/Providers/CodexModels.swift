import Foundation

/// Codex's model catalogue.
///
/// The CLI keeps the account's models in ~/.codex/models_cache.json and
/// refreshes it itself. Shape verified against codex-cli 0.153.4:
///
///     {"fetched_at":…,"models":[{"slug":"gpt-6-astra","display_name":"GPT-6-Astra",
///       "description":…,"default_reasoning_level":"low",
///       "supported_reasoning_levels":[{"effort":"low","description":…},…],
///       "visibility":"list","priority":1,"upgrade":null},…]}
///
/// `visibility` "hide" marks internal models; a non-null `upgrade` marks one
/// being retired (`{model, migration_markdown, retirement_at}`).
extension CodexProvider {
    /// Nothing to suggest without the cache: the picker offers the configured
    /// default and accepts any typed name.
    public var fallbackModels: ModelCatalog { .empty }

    public func discoverModels(executor: any Executor, binary: String?) async -> ModelCatalog? {
        guard let text = try? executor.readFile(executor.homeDirectory + "/.codex/models_cache.json") else { return nil }
        return Self.modelCatalog(modelsCache: text)
    }

    /// models_cache.json → catalogue: listed models by ascending priority.
    /// nil when the file isn't a cache or lists nothing.
    static func modelCatalog(modelsCache text: String, now: Date = Date(), timeZone: TimeZone = .current) -> ModelCatalog? {
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)),
              let entries = root["models"]?.array
        else { return nil }
        let models = entries.enumerated()
            .filter { ($0.element["visibility"]?.string ?? "list") == "list" }
            .sorted { (priority($0.element), $0.offset) < (priority($1.element), $1.offset) }
            .compactMap { option(entry: $0.element, now: now, timeZone: timeZone) }
        return models.isEmpty ? nil : ModelCatalog(models: models)
    }

    private static func priority(_ entry: JSONValue) -> Double {
        entry["priority"]?.double ?? .infinity
    }

    private static func option(entry: JSONValue, now: Date, timeZone: TimeZone) -> ModelOption? {
        guard let slug = entry["slug"]?.string, !slug.isEmpty else { return nil }
        return ModelOption(
            id: slug,
            label: entry["display_name"]?.string ?? slug,
            detail: entry["description"]?.string,
            efforts: entry["supported_reasoning_levels"]?.array?.compactMap { $0["effort"]?.string } ?? [],
            defaultEffort: entry["default_reasoning_level"]?.string,
            note: entry["upgrade"]?.object.map { _ in retirementNote(entry["upgrade"], now: now, timeZone: timeZone) })
    }

    /// "Retires Oct 14", "Retired Oct 14", or "Being retired" without a date.
    private static func retirementNote(_ upgrade: JSONValue?, now: Date, timeZone: TimeZone) -> String {
        guard let text = upgrade?["retirement_at"]?.string, let date = ISO8601DateFormatter().date(from: text) else {
            return "Being retired"
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "MMM d"
        return (date > now ? "Retires " : "Retired ") + formatter.string(from: date)
    }
}
