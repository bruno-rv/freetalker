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

            let appliedVersions = try appliedVersions(db)
            try validate(appliedVersions)

            for (offset, migration) in migrations.enumerated() {
                let version = offset + 1
                guard version > appliedVersions.count else { continue }
                try execute(db, migration)
                try execute(db, "INSERT INTO schema_migrations (version) VALUES (\(version));")
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

    private static let migrations = [migration1]

    private static func appliedVersions(_ db: OpaquePointer) throws -> [Int] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "SELECT version FROM schema_migrations ORDER BY version;",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else {
            throw DatabaseError.sqlFailed(lastError(db))
        }
        defer { sqlite3_finalize(statement) }

        var versions: [Int] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            versions.append(Int(sqlite3_column_int(statement, 0)))
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else {
            throw DatabaseError.sqlFailed(lastError(db))
        }
        return versions
    }

    private static func validate(_ versions: [Int]) throws {
        if let newest = versions.last, newest > latestVersion {
            throw DatabaseError.sqlFailed(
                "Database schema version \(newest) is newer than supported version \(latestVersion)"
            )
        }
        if !versions.isEmpty && versions != Array(1...versions.count) {
            throw DatabaseError.sqlFailed("Database migration ledger is not contiguous from version 1")
        }
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
