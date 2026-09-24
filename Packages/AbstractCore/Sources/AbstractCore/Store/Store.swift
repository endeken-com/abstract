import Foundation
import GRDB

/// SQLite persistence for everything Abstract remembers between launches.
///
/// Every call is synchronous and serialized by GRDB. Dates are stored in
/// GRDB's default format (`yyyy-MM-dd HH:mm:ss.SSS`, UTC), so they round-trip
/// at millisecond precision.
public final class Store: Sendable {
    private let writer: any DatabaseWriter

    /// Opens (or creates) the database at `path` in WAL mode and runs migrations.
    public convenience init(path: String) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // DatabasePool always uses WAL.
        try self.init(writer: DatabasePool(path: url.path, configuration: Self.configuration))
    }

    private init(writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    public static func inMemory() throws -> Store {
        try Store(writer: DatabaseQueue(configuration: configuration))
    }

    /// Test support: an in-memory database migrated only up to `migration`,
    /// with `sql` run against that older schema, then migrated the rest of
    /// the way the way an existing install would be.
    static func inMemory(migratedTo migration: String, thenRunning sql: String) throws -> Store {
        let queue = try DatabaseQueue(configuration: configuration)
        try migrator.migrate(queue, upTo: migration)
        try queue.write { db in try db.execute(sql: sql) }
        return try Store(writer: queue)
    }

    /// `~/Library/Application Support/Abstract/abstract.sqlite`, or
    /// `$ABSTRACT_DATA_DIR/abstract.sqlite` when that variable is set.
    public static func defaultPath() -> String {
        let fileName = "abstract.sqlite"
        if let dir = ProcessInfo.processInfo.environment["ABSTRACT_DATA_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)
                .appendingPathComponent(fileName).path
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("Abstract").appendingPathComponent(fileName).path
    }

    /// Abstract was called Backtick. The first launch after the rename moves
    /// the old data folder (database, chat logs, project icons) to its new
    /// home and points stored paths at it, so nothing is lost. Does nothing
    /// once moved, when there was nothing to move, or with a custom data dir.
    public static func migrateLegacyData(fileManager fm: FileManager = .default) {
        guard ProcessInfo.processInfo.environment["ABSTRACT_DATA_DIR"]?.isEmpty ?? true else { return }
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        migrateLegacyData(from: support.appendingPathComponent("Backtick"), to: support.appendingPathComponent("Abstract"), fileManager: fm)
    }

    /// The move itself, between any two folders (tests use temporary ones).
    public static func migrateLegacyData(from old: URL, to new: URL, fileManager fm: FileManager = .default) {
        let oldDB = old.appendingPathComponent("backtick.sqlite"), newDB = new.appendingPathComponent("abstract.sqlite")
        guard fm.fileExists(atPath: oldDB.path), !fm.fileExists(atPath: newDB.path) else { return }
        do {
            try fm.createDirectory(at: new, withIntermediateDirectories: true)
            for name in try fm.contentsOfDirectory(atPath: old.path) {
                // backtick.sqlite, -wal and -shm become abstract.sqlite…
                let target = name.hasPrefix("backtick.sqlite") ? "abstract" + name.dropFirst("backtick".count) : name
                let destination = new.appendingPathComponent(target)
                guard !fm.fileExists(atPath: destination.path) else { continue }
                try fm.moveItem(at: old.appendingPathComponent(name), to: destination)
            }
            if (try? fm.contentsOfDirectory(atPath: old.path))?.isEmpty == true { try? fm.removeItem(at: old) }
            // Uploaded project icons were stored by absolute path inside the old folder.
            let queue = try DatabaseQueue(path: newDB.path)
            try queue.write { db in
                guard try db.tableExists("projects"), try db.columns(in: "projects").contains(where: { $0.name == "icon_image_path" }) else { return }
                try db.execute(sql: "UPDATE projects SET icon_image_path = REPLACE(icon_image_path, ?, ?) WHERE icon_image_path IS NOT NULL",
                               arguments: [old.path + "/", new.path + "/"])
            }
        } catch {
            // Leave whatever didn't move where it is; the app starts fresh beside it.
        }
    }

    // MARK: - Settings

    public func setting<T: Codable>(_ key: String, as type: T.Type) -> T? {
        let text = try? writer.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM settings WHERE key = ?", arguments: [key])
        }
        guard let text else { return nil }
        return try? JSONDecoder().decode(T.self, from: Data(text.utf8))
    }

    /// Stores `value` as JSON text. `nil` deletes the key.
    public func setSetting<T: Codable>(_ key: String, _ value: T?) throws {
        guard let value else {
            try writer.write { db in
                try db.execute(sql: "DELETE FROM settings WHERE key = ?", arguments: [key])
            }
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let text = String(decoding: try encoder.encode(value), as: UTF8.self)
        try writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO settings (key, value) VALUES (?, ?)
                    ON CONFLICT(key) DO UPDATE SET value = excluded.value
                    """,
                arguments: [key, text])
        }
    }

    // MARK: - Projects

    public func projects() throws -> [Project] {
        try writer.read { db in
            try ProjectRow.fetchAll(db, sql: "SELECT * FROM projects ORDER BY sort_order, created_at").map(\.value)
        }
    }

    public func project(_ id: String) throws -> Project? {
        try writer.read { db in
            try ProjectRow.fetchOne(db, sql: "SELECT * FROM projects WHERE id = ?", arguments: [id])?.value
        }
    }

    public func save(_ project: Project) throws {
        try writer.write { db in try ProjectRow(project).save(db) }
    }

    /// Cascades to the project's sessions and automations (and their runs).
    public func deleteProject(_ id: String) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM projects WHERE id = ?", arguments: [id])
        }
    }

    // MARK: - Sessions

    public func sessions() throws -> [Session] {
        try writer.read { db in
            try SessionRow.fetchAll(
                db, sql: "SELECT * FROM sessions ORDER BY COALESCE(last_event_at, created_at) DESC, created_at DESC"
            ).map(\.value)
        }
    }

    public func session(_ id: String) throws -> Session? {
        try writer.read { db in
            try SessionRow.fetchOne(db, sql: "SELECT * FROM sessions WHERE id = ?", arguments: [id])?.value
        }
    }

    public func save(_ session: Session) throws {
        try writer.write { db in try SessionRow(session).save(db) }
    }

    /// Also bumps `lastEventAt`.
    public func updateSessionStatus(_ id: String, _ status: SessionStatus, detail: String?) throws {
        try writer.write { db in
            try db.execute(
                sql: "UPDATE sessions SET status = ?, status_detail = ?, last_event_at = ? WHERE id = ?",
                arguments: [status.rawValue, detail, Date(), id])
        }
    }

    public func touchSession(_ id: String) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE sessions SET last_event_at = ? WHERE id = ?", arguments: [Date(), id])
        }
    }

    public func deleteSession(_ id: String) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM sessions WHERE id = ?", arguments: [id])
        }
    }

    /// Sessions that were mid-turn when the app last quit get marked errored with
    /// detail "Interrupted when Abstract quit"; idle ones had finished their turn,
    /// so they become finished. `lastEventAt` is left alone so the list keeps
    /// its order. Returns how many sessions changed.
    public func reconcileInterruptedSessions() throws -> Int {
        let active = SessionStatus.allCases.filter { $0.isActive && $0 != .idle }.map(\.rawValue)
        let placeholders = active.map { _ in "?" }.joined(separator: ", ")
        return try writer.write { db in
            try db.execute(
                sql: "UPDATE sessions SET status = ?, status_detail = NULL WHERE status = ?",
                arguments: [SessionStatus.finished.rawValue, SessionStatus.idle.rawValue])
            var changed = db.changesCount
            try db.execute(
                sql: "UPDATE sessions SET status = ?, status_detail = ? WHERE status IN (\(placeholders))",
                arguments: StatementArguments([SessionStatus.errored.rawValue, "Interrupted when Abstract quit"] + active))
            changed += db.changesCount
            return changed
        }
    }

    // MARK: - Usage

    public func record(_ usage: UsageRecord) throws {
        try writer.write { db in try UsageRow(usage).insert(db) }
    }

    /// Totals grouped by provider, ordered by provider id.
    public func usageSummary(since: Date?, projectId: String?) throws -> [UsageSummary] {
        var clauses: [String] = []
        var arguments: [(any DatabaseValueConvertible)?] = []
        if let since { clauses.append("at >= ?"); arguments.append(since) }
        if let projectId { clauses.append("project_id = ?"); arguments.append(projectId) }
        let filter = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
        let sql = """
            SELECT provider_id,
                   COUNT(DISTINCT session_id) AS sessions,
                   SUM(turns) AS turns,
                   SUM(input_tokens) AS input_tokens,
                   SUM(output_tokens) AS output_tokens,
                   SUM(cache_read) AS cache_read,
                   SUM(cache_write) AS cache_write,
                   SUM(cost_usd) AS cost_usd,
                   SUM(duration_ms) AS duration_ms
            FROM usage_events \(filter)
            GROUP BY provider_id
            ORDER BY provider_id
            """
        return try writer.read { db in
            try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments)).map { row in
                UsageSummary(
                    providerId: try row.decode(forColumn: "provider_id"),
                    sessions: try row.decode(forColumn: "sessions"),
                    turns: try row.decode(forColumn: "turns"),
                    usage: UsageTotals(
                        inputTokens: try row.decode(forColumn: "input_tokens"),
                        outputTokens: try row.decode(forColumn: "output_tokens"),
                        cacheRead: try row.decode(forColumn: "cache_read"),
                        cacheWrite: try row.decode(forColumn: "cache_write")),
                    costUsd: try row.decode(forColumn: "cost_usd"),
                    durationMs: try row.decode(forColumn: "duration_ms"))
            }
        }
    }

    /// Output tokens and cost grouped by local calendar day and provider,
    /// ordered by day then provider.
    public func usageByDay(since: Date?) throws -> [UsageDay] {
        let filter = since == nil ? "" : "WHERE at >= ?"
        let arguments: StatementArguments = since.map { [$0] } ?? []
        let rows = try writer.read { db in
            try Row.fetchAll(
                db, sql: "SELECT at, provider_id, output_tokens, cost_usd FROM usage_events \(filter)",
                arguments: arguments
            ).map { row in
                (at: try row.decode(Date.self, forColumn: "at"),
                 providerId: try row.decode(String.self, forColumn: "provider_id"),
                 outputTokens: try row.decode(Int.self, forColumn: "output_tokens"),
                 costUsd: try row.decode(Double.self, forColumn: "cost_usd"))
            }
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        struct Key: Hashable { var day: String; var providerId: String }
        var totals: [Key: UsageDay] = [:]
        for row in rows {
            let c = calendar.dateComponents([.year, .month, .day], from: row.at)
            let day = String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
            let key = Key(day: day, providerId: row.providerId)
            var entry = totals[key] ?? UsageDay(day: day, providerId: row.providerId, outputTokens: 0, costUsd: 0)
            entry.outputTokens += row.outputTokens
            entry.costUsd += row.costUsd
            totals[key] = entry
        }
        return totals.values.sorted { ($0.day, $0.providerId) < ($1.day, $1.providerId) }
    }

    // MARK: - Automations

    public func automations() throws -> [Automation] {
        try writer.read { db in
            try AutomationRow.fetchAll(db, sql: "SELECT * FROM automations ORDER BY created_at").map(\.value)
        }
    }

    public func automation(_ id: String) throws -> Automation? {
        try writer.read { db in
            try AutomationRow.fetchOne(db, sql: "SELECT * FROM automations WHERE id = ?", arguments: [id])?.value
        }
    }

    public func save(_ automation: Automation) throws {
        try writer.write { db in try AutomationRow(automation).save(db) }
    }

    /// Test support: the single schedule kept in the pre-trigger columns.
    func legacySchedule(automationId id: String) throws -> (rrule: String, timezone: String, dtstart: Date)? {
        try writer.read { db in
            try Row.fetchOne(db, sql: "SELECT rrule, timezone, dtstart FROM automations WHERE id = ?", arguments: [id])
                .map { (try $0.decode(forColumn: "rrule"), try $0.decode(forColumn: "timezone"), try $0.decode(forColumn: "dtstart")) }
        }
    }

    /// Cascades to the automation's runs. Sessions it created are kept.
    public func deleteAutomation(_ id: String) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM automations WHERE id = ?", arguments: [id])
        }
    }

    /// Newest first.
    public func runs(automationId: String, limit: Int) throws -> [AutomationRun] {
        try writer.read { db in
            try RunRow.fetchAll(
                db,
                sql: "SELECT * FROM automation_runs WHERE automation_id = ? ORDER BY fired_at DESC, rowid DESC LIMIT ?",
                arguments: [automationId, limit]
            ).map(\.value)
        }
    }

    public func lastRun(automationId: String) throws -> AutomationRun? {
        try runs(automationId: automationId, limit: 1).first
    }

    public func save(_ run: AutomationRun) throws {
        try writer.write { db in try RunRow(run).save(db) }
    }

    // MARK: - Schema

    private static var configuration: Configuration {
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.busyMode = .timeout(5)
        config.label = "Abstract.Store"
        return config
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE settings (
                  key   TEXT PRIMARY KEY NOT NULL,
                  value TEXT NOT NULL
                );

                CREATE TABLE projects (
                  id                        TEXT PRIMARY KEY NOT NULL,
                  name                      TEXT NOT NULL,
                  root_path                 TEXT NOT NULL,
                  default_base_ref          TEXT NOT NULL DEFAULT 'HEAD',
                  default_provider_id       TEXT NOT NULL DEFAULT 'claude',
                  default_permission_policy TEXT NOT NULL DEFAULT 'ask',
                  nested_repos              TEXT NOT NULL DEFAULT '[]',
                  worktree_template         TEXT,
                  branch_prefix             TEXT,
                  sort_order                INTEGER NOT NULL DEFAULT 0,
                  created_at                DATETIME NOT NULL,
                  archived_at               DATETIME
                );

                CREATE TABLE sessions (
                  id                  TEXT PRIMARY KEY NOT NULL,
                  project_id          TEXT REFERENCES projects(id) ON DELETE CASCADE,
                  name                TEXT NOT NULL,
                  provider_id         TEXT NOT NULL,
                  provider_session_id TEXT,
                  worktree_path       TEXT,
                  branch              TEXT,
                  base_ref            TEXT,
                  status              TEXT NOT NULL DEFAULT 'created',
                  status_detail       TEXT,
                  permission_policy   TEXT NOT NULL DEFAULT 'ask',
                  prompt              TEXT,
                  automation_id       TEXT,
                  created_at          DATETIME NOT NULL,
                  last_event_at       DATETIME,
                  archived_at         DATETIME
                );
                CREATE INDEX sessions_project ON sessions(project_id);
                CREATE INDEX sessions_automation ON sessions(automation_id);

                CREATE TABLE usage_events (
                  id            INTEGER PRIMARY KEY AUTOINCREMENT,
                  session_id    TEXT NOT NULL,
                  project_id    TEXT,
                  provider_id   TEXT NOT NULL,
                  at            DATETIME NOT NULL,
                  input_tokens  INTEGER NOT NULL DEFAULT 0,
                  output_tokens INTEGER NOT NULL DEFAULT 0,
                  cache_read    INTEGER NOT NULL DEFAULT 0,
                  cache_write   INTEGER NOT NULL DEFAULT 0,
                  cost_usd      REAL NOT NULL DEFAULT 0,
                  duration_ms   INTEGER NOT NULL DEFAULT 0,
                  turns         INTEGER NOT NULL DEFAULT 0
                );
                CREATE INDEX usage_events_at ON usage_events(at);

                CREATE TABLE automations (
                  id                     TEXT PRIMARY KEY NOT NULL,
                  name                   TEXT NOT NULL,
                  prompt                 TEXT NOT NULL,
                  provider_id            TEXT NOT NULL,
                  project_id             TEXT REFERENCES projects(id) ON DELETE CASCADE,
                  rrule                  TEXT NOT NULL,
                  timezone               TEXT NOT NULL,
                  dtstart                DATETIME NOT NULL,
                  workspace_mode         TEXT NOT NULL DEFAULT 'new_worktree',
                  pinned_session_id      TEXT,
                  continue_agent_session BOOLEAN NOT NULL DEFAULT 0,
                  permission_policy      TEXT NOT NULL DEFAULT 'auto-edits',
                  catch_up               BOOLEAN NOT NULL DEFAULT 0,
                  enabled                BOOLEAN NOT NULL DEFAULT 1,
                  next_run_at            DATETIME,
                  created_at             DATETIME NOT NULL,
                  updated_at             DATETIME NOT NULL
                );
                CREATE INDEX automations_project ON automations(project_id);

                CREATE TABLE automation_runs (
                  id            TEXT PRIMARY KEY NOT NULL,
                  automation_id TEXT NOT NULL REFERENCES automations(id) ON DELETE CASCADE,
                  fired_at      DATETIME NOT NULL,
                  "trigger"     TEXT NOT NULL,
                  status        TEXT NOT NULL,
                  session_id    TEXT,
                  error         TEXT
                );
                CREATE INDEX automation_runs_automation ON automation_runs(automation_id, fired_at DESC);
                """)
        }
        migrator.registerMigration("v2-model") { db in
            try db.execute(sql: "ALTER TABLE sessions ADD COLUMN model TEXT")
            try db.execute(sql: "ALTER TABLE automations ADD COLUMN model TEXT")
        }
        migrator.registerMigration("v3-effort") { db in
            try db.execute(sql: "ALTER TABLE sessions ADD COLUMN effort TEXT")
            try db.execute(sql: "ALTER TABLE automations ADD COLUMN effort TEXT")
        }
        // Automations can have several triggers. They live in a JSON array;
        // the old rrule/timezone/dtstart columns stay and keep the first
        // trigger, so a build from before this still reads the database.
        migrator.registerMigration("v4-triggers") { db in
            try db.execute(sql: "ALTER TABLE automations ADD COLUMN triggers TEXT NOT NULL DEFAULT '[]'")
            for row in try Row.fetchAll(db, sql: "SELECT id, rrule, timezone, dtstart FROM automations") {
                guard let trigger = AutomationRow.legacyTrigger(row) else { continue }
                try db.execute(sql: "UPDATE automations SET triggers = ? WHERE id = ?",
                               arguments: [try TriggerJSON.encode([trigger]), row["id"] as String])
            }
        }
        // Project settings: icon, naming, sparse checkout and lifecycle
        // scripts. Every column is optional or defaulted, so existing
        // projects read exactly as before.
        migrator.registerMigration("v5-project-settings") { db in
            for column in ["icon_symbol TEXT", "icon_color TEXT", "icon_image_path TEXT", "naming_instructions TEXT",
                           "sparse_checkout TEXT NOT NULL DEFAULT '[]'", "setup_script TEXT", "teardown_script TEXT",
                           "run_script TEXT"] {
                try db.execute(sql: "ALTER TABLE projects ADD COLUMN \(column)")
            }
        }
        return migrator
    }
}

// MARK: - Row mapping

private extension Row {
    func rawEnum<E: RawRepresentable>(_ column: String, as type: E.Type = E.self) throws -> E
    where E.RawValue == String {
        let raw: String = try decode(forColumn: column)
        guard let value = E(rawValue: raw) else {
            throw AbstractError.message("Unknown \(column) value \"\(raw)\" in the database")
        }
        return value
    }

    func stringList(_ column: String) throws -> [String] {
        let text: String = try decode(forColumn: column)
        return (try? JSONDecoder().decode([String].self, from: Data(text.utf8))) ?? []
    }
}

private func jsonText(_ list: [String]) throws -> String {
    String(decoding: try JSONEncoder().encode(list), as: UTF8.self)
}

private struct ProjectRow: FetchableRecord, PersistableRecord {
    static let databaseTableName = "projects"
    let value: Project

    init(_ value: Project) { self.value = value }

    init(row: Row) throws {
        value = Project(
            id: try row.decode(forColumn: "id"),
            name: try row.decode(forColumn: "name"),
            rootPath: try row.decode(forColumn: "root_path"),
            defaultBaseRef: try row.decode(forColumn: "default_base_ref"),
            defaultProviderId: try row.decode(forColumn: "default_provider_id"),
            defaultPermissionPolicy: try row.rawEnum("default_permission_policy"),
            nestedRepos: try row.stringList("nested_repos"),
            worktreeTemplate: try row.decode(forColumn: "worktree_template"),
            branchPrefix: try row.decode(forColumn: "branch_prefix"),
            sortOrder: try row.decode(forColumn: "sort_order"),
            createdAt: try row.decode(forColumn: "created_at"),
            archivedAt: try row.decode(forColumn: "archived_at"),
            iconSymbol: try row.decode(forColumn: "icon_symbol"),
            iconColor: try row.decode(forColumn: "icon_color"),
            iconImagePath: try row.decode(forColumn: "icon_image_path"),
            namingInstructions: try row.decode(forColumn: "naming_instructions"),
            sparseCheckout: try row.stringList("sparse_checkout"),
            setupScript: try row.decode(forColumn: "setup_script"),
            teardownScript: try row.decode(forColumn: "teardown_script"),
            runScript: try row.decode(forColumn: "run_script"))
    }

    func encode(to container: inout PersistenceContainer) throws {
        container["id"] = value.id
        container["name"] = value.name
        container["root_path"] = value.rootPath
        container["default_base_ref"] = value.defaultBaseRef
        container["default_provider_id"] = value.defaultProviderId
        container["default_permission_policy"] = value.defaultPermissionPolicy.rawValue
        container["nested_repos"] = try jsonText(value.nestedRepos)
        container["worktree_template"] = value.worktreeTemplate
        container["branch_prefix"] = value.branchPrefix
        container["sort_order"] = value.sortOrder
        container["created_at"] = value.createdAt
        container["archived_at"] = value.archivedAt
        container["icon_symbol"] = value.iconSymbol
        container["icon_color"] = value.iconColor
        container["icon_image_path"] = value.iconImagePath
        container["naming_instructions"] = value.namingInstructions
        container["sparse_checkout"] = try jsonText(value.sparseCheckout)
        container["setup_script"] = value.setupScript
        container["teardown_script"] = value.teardownScript
        container["run_script"] = value.runScript
    }
}

private struct SessionRow: FetchableRecord, PersistableRecord {
    static let databaseTableName = "sessions"
    let value: Session

    init(_ value: Session) { self.value = value }

    init(row: Row) throws {
        value = Session(
            id: try row.decode(forColumn: "id"),
            projectId: try row.decode(forColumn: "project_id"),
            name: try row.decode(forColumn: "name"),
            providerId: try row.decode(forColumn: "provider_id"),
            providerSessionId: try row.decode(forColumn: "provider_session_id"),
            worktreePath: try row.decode(forColumn: "worktree_path"),
            branch: try row.decode(forColumn: "branch"),
            baseRef: try row.decode(forColumn: "base_ref"),
            status: try row.rawEnum("status"),
            statusDetail: try row.decode(forColumn: "status_detail"),
            permissionPolicy: try row.rawEnum("permission_policy"),
            prompt: try row.decode(forColumn: "prompt"),
            automationId: try row.decode(forColumn: "automation_id"),
            createdAt: try row.decode(forColumn: "created_at"),
            lastEventAt: try row.decode(forColumn: "last_event_at"),
            archivedAt: try row.decode(forColumn: "archived_at"),
            model: try row.decode(forColumn: "model"),
            effort: try row.decode(forColumn: "effort"))
    }

    func encode(to container: inout PersistenceContainer) throws {
        container["id"] = value.id
        container["project_id"] = value.projectId
        container["name"] = value.name
        container["provider_id"] = value.providerId
        container["provider_session_id"] = value.providerSessionId
        container["worktree_path"] = value.worktreePath
        container["branch"] = value.branch
        container["base_ref"] = value.baseRef
        container["status"] = value.status.rawValue
        container["status_detail"] = value.statusDetail
        container["permission_policy"] = value.permissionPolicy.rawValue
        container["prompt"] = value.prompt
        container["automation_id"] = value.automationId
        container["model"] = value.model
        container["effort"] = value.effort
        container["created_at"] = value.createdAt
        container["last_event_at"] = value.lastEventAt
        container["archived_at"] = value.archivedAt
    }
}

private struct AutomationRow: FetchableRecord, PersistableRecord {
    static let databaseTableName = "automations"
    let value: Automation

    init(_ value: Automation) { self.value = value }

    init(row: Row) throws {
        value = Automation(
            id: try row.decode(forColumn: "id"),
            name: try row.decode(forColumn: "name"),
            prompt: try row.decode(forColumn: "prompt"),
            providerId: try row.decode(forColumn: "provider_id"),
            projectId: try row.decode(forColumn: "project_id"),
            triggers: try Self.triggers(row),
            workspaceMode: try row.rawEnum("workspace_mode"),
            pinnedSessionId: try row.decode(forColumn: "pinned_session_id"),
            continueAgentSession: try row.decode(forColumn: "continue_agent_session"),
            permissionPolicy: try row.rawEnum("permission_policy"),
            catchUp: try row.decode(forColumn: "catch_up"),
            enabled: try row.decode(forColumn: "enabled"),
            nextRunAt: try row.decode(forColumn: "next_run_at"),
            createdAt: try row.decode(forColumn: "created_at"),
            updatedAt: try row.decode(forColumn: "updated_at"),
            model: try row.decode(forColumn: "model"),
            effort: try row.decode(forColumn: "effort"))
    }

    func encode(to container: inout PersistenceContainer) throws {
        container["id"] = value.id
        container["name"] = value.name
        container["prompt"] = value.prompt
        container["provider_id"] = value.providerId
        container["project_id"] = value.projectId
        container["triggers"] = try TriggerJSON.encode(value.triggers)
        // The first trigger, for builds that predate `triggers`. No
        // triggers writes an empty rule, which those builds never fire.
        let first = value.triggers.first
        container["rrule"] = first?.rrule ?? ""
        container["timezone"] = first?.timezone ?? ""
        container["dtstart"] = first?.dtstart ?? value.createdAt
        container["workspace_mode"] = value.workspaceMode.rawValue
        container["pinned_session_id"] = value.pinnedSessionId
        container["continue_agent_session"] = value.continueAgentSession
        container["permission_policy"] = value.permissionPolicy.rawValue
        container["model"] = value.model
        container["effort"] = value.effort
        container["catch_up"] = value.catchUp
        container["enabled"] = value.enabled
        container["next_run_at"] = value.nextRunAt
        container["created_at"] = value.createdAt
        container["updated_at"] = value.updatedAt
    }

    /// The `triggers` array. A row with none there but a rule in the old
    /// columns was written by a build from before triggers: use that rule.
    static func triggers(_ row: Row) throws -> [AutomationTrigger] {
        let text: String = try row.decode(forColumn: "triggers")
        let triggers = (try? TriggerJSON.decode(text)) ?? []
        if triggers.isEmpty, var legacy = legacyTrigger(row) {
            // Stable, so the same row reads as the same trigger every time.
            legacy.id = "\(try row.decode(String.self, forColumn: "id"))-legacy"
            return [legacy]
        }
        return triggers
    }

    /// The single schedule stored in the pre-trigger columns, if there is one.
    static func legacyTrigger(_ row: Row) -> AutomationTrigger? {
        guard let rrule: String = row["rrule"], !rrule.isEmpty,
              let timezone: String = row["timezone"], let dtstart: Date = row["dtstart"] else { return nil }
        return AutomationTrigger(rrule: rrule, timezone: timezone, dtstart: dtstart)
    }
}

/// Triggers as JSON text, dates as ISO 8601 at millisecond precision (the
/// same precision the store keeps every other date at).
private enum TriggerJSON {
    private static let dateStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    static func encode(_ triggers: [AutomationTrigger]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(dateStyle))
        }
        return String(decoding: try encoder.encode(triggers), as: UTF8.self)
    }

    static func decode(_ text: String) throws -> [AutomationTrigger] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            return try dateStyle.parse(text)
        }
        return try decoder.decode([AutomationTrigger].self, from: Data(text.utf8))
    }
}

private struct RunRow: FetchableRecord, PersistableRecord {
    static let databaseTableName = "automation_runs"
    let value: AutomationRun

    init(_ value: AutomationRun) { self.value = value }

    init(row: Row) throws {
        value = AutomationRun(
            id: try row.decode(forColumn: "id"),
            automationId: try row.decode(forColumn: "automation_id"),
            firedAt: try row.decode(forColumn: "fired_at"),
            trigger: try row.rawEnum("trigger"),
            status: try row.rawEnum("status"),
            sessionId: try row.decode(forColumn: "session_id"),
            error: try row.decode(forColumn: "error"))
    }

    func encode(to container: inout PersistenceContainer) throws {
        container["id"] = value.id
        container["automation_id"] = value.automationId
        container["fired_at"] = value.firedAt
        container["trigger"] = value.trigger.rawValue
        container["status"] = value.status.rawValue
        container["session_id"] = value.sessionId
        container["error"] = value.error
    }
}

private struct UsageRow: PersistableRecord {
    static let databaseTableName = "usage_events"
    let value: UsageRecord

    init(_ value: UsageRecord) { self.value = value }

    func encode(to container: inout PersistenceContainer) throws {
        container["session_id"] = value.sessionId
        container["project_id"] = value.projectId
        container["provider_id"] = value.providerId
        container["at"] = value.at
        container["input_tokens"] = value.usage.inputTokens
        container["output_tokens"] = value.usage.outputTokens
        container["cache_read"] = value.usage.cacheRead
        container["cache_write"] = value.usage.cacheWrite
        container["cost_usd"] = value.costUsd
        container["duration_ms"] = value.durationMs
        container["turns"] = value.turns
    }
}
