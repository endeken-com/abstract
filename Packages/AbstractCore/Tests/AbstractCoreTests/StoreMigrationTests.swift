import Foundation
import GRDB
import Testing
@testable import AbstractCore

@Suite struct StoreMigrationTests {
    @Test(arguments: ["v11-default-device", "v12-automation-device"])
    func upgradesCodeHistoryFromEarlierNightlies(migratedTo migration: String) throws {
        // These builds applied code history as v12, before it was renamed
        // to v13 when the automation-device migration was merged.
        let store = try Store.inMemory(migratedTo: migration, thenRunning: """
            ALTER TABLE turn_records ADD COLUMN decision TEXT;
            ALTER TABLE projects ADD COLUMN agent_history INTEGER;
            INSERT INTO grdb_migrations (identifier) VALUES ('v12-code-history');
            INSERT INTO projects (id, name, root_path, created_at, agent_history)
            VALUES ('p1', 'Project', '/repos/project', '2026-09-01 12:00:00.000', 0);
            INSERT INTO sessions (id, project_id, name, provider_id, created_at)
            VALUES ('s1', 'p1', 'Chat', 'claude', '2026-09-01 12:00:00.000');
            INSERT INTO turn_records (id, project_id, session_id, chat_name, provider_id, number, decision)
            VALUES ('t1', 'p1', 's1', 'Chat', 'claude', 1, 'Keep the existing history');
            """)

        #expect(try store.project("p1")?.agentHistory == false)
        #expect(try store.session("s1")?.name == "Chat")
        #expect(try store.turnRecords(sessionId: "s1").first?.decision == "Keep the existing history")
        // Migrations after code history still run and the store stays writable.
        #expect(try store.profiles().isEmpty)
        var project = try #require(try store.project("p1"))
        project.agentHistory = true
        project.defaultDeviceId = "mac-1"
        try store.save(project)
        #expect(try store.project("p1") == project)
        let migrations = try store.writer.read { try String.fetchAll($0, sql: "SELECT identifier FROM grdb_migrations") }
        #expect(migrations.contains("v12-code-history"))
        #expect(migrations.contains("v13-code-history"))
        #expect(migrations.contains("v16-automation-scheduling"))
    }

    @Test(arguments: [false, true])
    func reopeningKeepsDataWithEitherCodeHistoryName(legacyName: Bool) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("store-migration-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("abstract.sqlite").path
        let project = Project(id: "p1", name: "Project", rootPath: "/repos/project",
                              createdAt: Date(timeIntervalSince1970: 1_790_000_000), agentHistory: false)
        do {
            let store = try Store(path: path)
            try store.save(project)
            if legacyName {
                try store.writer.write { db in
                    try db.execute(sql: "UPDATE grdb_migrations SET identifier = 'v12-code-history' WHERE identifier = 'v13-code-history'")
                }
            }
        }
        // The first reopen upgrades the legacy name; the next must be a no-op.
        for _ in 0..<2 {
            let store = try Store(path: path)
            #expect(try store.projects() == [project])
            #expect(try store.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM grdb_migrations WHERE identifier = 'v13-code-history'") } == 1)
        }
    }
}
