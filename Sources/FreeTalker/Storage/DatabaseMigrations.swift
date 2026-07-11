import CSQLite

enum DatabaseMigrator {
    static let latestVersion = 1

    static func migrate(_ db: OpaquePointer) throws {
        try execute(db, "BEGIN IMMEDIATE;")
        do {
            try execute(db, """
            CREATE TABLE IF NOT EXISTS schema_migrations (
                version INTEGER PRIMARY KEY,
                applied_at REAL NOT NULL DEFAULT (unixepoch())
            );
            """)

            if try currentVersion(db) < 1 {
                try execute(db, migration1)
                try execute(db, "INSERT INTO schema_migrations (version) VALUES (1);")
            }

            try execute(db, "COMMIT;")
        } catch {
            try? execute(db, "ROLLBACK;")
            throw error
        }
    }

    private static let migration1 = """
    CREATE TABLE transcription_jobs (
        id TEXT PRIMARY KEY,
        kind TEXT NOT NULL,
        source_reference TEXT NOT NULL,
        source_bookmark BLOB,
        state TEXT NOT NULL,
        progress REAL NOT NULL DEFAULT 0,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL,
        started_at REAL,
        completed_at REAL,
        expires_at REAL,
        language TEXT,
        speech_model TEXT,
        template TEXT,
        failure_stage TEXT,
        failure_message TEXT,
        result TEXT
    );

    CREATE TABLE job_attempts (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        job_id TEXT NOT NULL,
        attempt_number INTEGER NOT NULL,
        started_at REAL NOT NULL,
        completed_at REAL,
        failure_stage TEXT,
        failure_message TEXT
    );

    CREATE TABLE speaker_segments (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        job_id TEXT NOT NULL,
        speaker_id TEXT NOT NULL,
        start_time REAL NOT NULL,
        end_time REAL NOT NULL,
        transcript TEXT NOT NULL
    );

    CREATE TABLE speaker_names (
        job_id TEXT NOT NULL,
        speaker_id TEXT NOT NULL,
        name TEXT NOT NULL,
        PRIMARY KEY (job_id, speaker_id)
    );

    CREATE TABLE snippets (
        id TEXT PRIMARY KEY,
        trigger TEXT NOT NULL UNIQUE,
        replacement TEXT NOT NULL,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL
    );

    CREATE INDEX idx_transcription_jobs_state_expires_at
        ON transcription_jobs (state, expires_at);
    CREATE INDEX idx_job_attempts_job_id
        ON job_attempts (job_id);
    """

    private static func currentVersion(_ db: OpaquePointer) throws -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "SELECT COALESCE(MAX(version), 0) FROM schema_migrations;",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else {
            throw DatabaseError.sqlFailed(lastError(db))
        }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw DatabaseError.sqlFailed(lastError(db))
        }
        return Int(sqlite3_column_int(statement, 0))
    }

    private static func execute(_ db: OpaquePointer, _ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? lastError(db)
            sqlite3_free(errorMessage)
            throw DatabaseError.sqlFailed(message)
        }
    }

    private static func lastError(_ db: OpaquePointer) -> String {
        String(cString: sqlite3_errmsg(db))
    }
}
