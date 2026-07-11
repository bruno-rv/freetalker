import CSQLite
import Testing
@testable import FreeTalker

@Suite struct DatabaseMigrationTests {
    @Test func migratesEmptyDatabaseToLatestSchema() throws {
        let db = try TemporaryDatabase()

        try DatabaseMigrator.migrate(db.handle)

        #expect(try db.tableNames() == [
            "transcription_jobs", "job_attempts", "speaker_segments",
            "speaker_names", "snippets", "schema_migrations"
        ])
        #expect(try db.indexNames() == [
            "idx_transcription_jobs_state_expires_at",
            "idx_job_attempts_job_id"
        ])
        #expect(try db.migrationVersions() == [DatabaseMigrator.latestVersion])
    }

    @Test func migratingLatestSchemaAgainMakesNoChanges() throws {
        let db = try TemporaryDatabase()
        try DatabaseMigrator.migrate(db.handle)
        let schema = try db.schema()

        try DatabaseMigrator.migrate(db.handle)

        #expect(try db.schema() == schema)
        #expect(try db.migrationVersions() == [DatabaseMigrator.latestVersion])
    }

    @Test func rollsBackEntireMigrationWhenSchemaCreationFails() throws {
        let db = try TemporaryDatabase()
        try db.execute("CREATE TABLE job_attempts (collision INTEGER);")

        #expect(throws: DatabaseError.self) {
            try DatabaseMigrator.migrate(db.handle)
        }

        #expect(try db.tableNames() == ["job_attempts"])
    }

    @Test func rejectsSchemaVersionNewerThanMigrator() throws {
        let db = try TemporaryDatabase()
        try db.createMigrationLedger(versions: [DatabaseMigrator.latestVersion + 1])

        #expect(throws: DatabaseError.self) {
            try DatabaseMigrator.migrate(db.handle)
        }

        #expect(try db.migrationVersions() == [DatabaseMigrator.latestVersion + 1])
    }

    @Test func rejectsDiscontinuousMigrationLedger() throws {
        let db = try TemporaryDatabase()
        try db.createMigrationLedger(versions: [0])

        #expect(throws: DatabaseError.self) {
            try DatabaseMigrator.migrate(db.handle)
        }

        #expect(try db.migrationVersions() == [0])
        #expect(try db.tableNames() == ["schema_migrations"])
    }
}

private final class TemporaryDatabase {
    let handle: OpaquePointer

    init() throws {
        var database: OpaquePointer?
        guard sqlite3_open(":memory:", &database) == SQLITE_OK, let database else {
            defer { sqlite3_close(database) }
            throw DatabaseError.openFailed("Could not open temporary database")
        }
        handle = database
    }

    deinit {
        sqlite3_close(handle)
    }

    func tableNames() throws -> Set<String> {
        try strings("""
        SELECT name FROM sqlite_master
        WHERE type = 'table' AND name NOT LIKE 'sqlite_%';
        """)
    }

    func indexNames() throws -> Set<String> {
        try strings("""
        SELECT name FROM sqlite_master
        WHERE type = 'index' AND name NOT LIKE 'sqlite_autoindex_%';
        """)
    }

    func migrationVersions() throws -> [Int] {
        try integers("SELECT version FROM schema_migrations ORDER BY version;")
    }

    func schema() throws -> Set<String> {
        try strings("SELECT type || ':' || name || ':' || sql FROM sqlite_master WHERE sql IS NOT NULL;")
    }

    func createMigrationLedger(versions: [Int]) throws {
        try execute("""
        CREATE TABLE schema_migrations (
            version INTEGER PRIMARY KEY,
            applied_at REAL NOT NULL DEFAULT (unixepoch())
        );
        """)
        for version in versions {
            try execute("INSERT INTO schema_migrations (version) VALUES (\(version));")
        }
    }

    func execute(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? lastError()
            sqlite3_free(errorMessage)
            throw DatabaseError.sqlFailed(message)
        }
    }

    private func strings(_ sql: String) throws -> Set<String> {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.sqlFailed(lastError())
        }
        defer { sqlite3_finalize(statement) }

        var values = Set<String>()
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 0) {
                values.insert(String(cString: text))
            }
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else {
            throw DatabaseError.sqlFailed(lastError())
        }
        return values
    }

    private func integers(_ sql: String) throws -> [Int] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.sqlFailed(lastError())
        }
        defer { sqlite3_finalize(statement) }

        var values: [Int] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            values.append(Int(sqlite3_column_int(statement, 0)))
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else {
            throw DatabaseError.sqlFailed(lastError())
        }
        return values
    }

    private func lastError() -> String {
        String(cString: sqlite3_errmsg(handle))
    }
}
