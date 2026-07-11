import CSQLite

enum DatabaseMigrator {
    static let latestVersion = 6

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
                if version == 5 {
                    try migrateLegacySnippetRows(db)
                }
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

    private static let migration2 = """
    ALTER TABLE job_attempts ADD COLUMN language TEXT;
    ALTER TABLE job_attempts ADD COLUMN speech_model TEXT;
    ALTER TABLE job_attempts ADD COLUMN template TEXT;
    ALTER TABLE job_attempts ADD COLUMN result TEXT;
    """

    private static let migration3 = """
    ALTER TABLE transcription_jobs ADD COLUMN purge_claimed_at REAL;
    ALTER TABLE transcription_jobs ADD COLUMN purge_error TEXT;
    CREATE INDEX idx_transcription_jobs_purge_claimed_at
        ON transcription_jobs (purge_claimed_at);
    """

    private static let migration4 = """
    ALTER TABLE transcription_jobs ADD COLUMN needs_source_cleanup INTEGER NOT NULL DEFAULT 0;
    ALTER TABLE transcription_jobs ADD COLUMN source_cleanup_error TEXT;
    CREATE INDEX idx_transcription_jobs_needs_source_cleanup
        ON transcription_jobs (needs_source_cleanup);
    """

    private static let migration5 = """
    ALTER TABLE snippets RENAME TO legacy_snippets;
    CREATE TABLE snippets (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL UNIQUE,
        replacement TEXT NOT NULL,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL
    );
    CREATE TABLE snippet_triggers (
        snippet_id TEXT NOT NULL,
        trigger TEXT NOT NULL,
        normalized_trigger TEXT NOT NULL,
        is_legacy INTEGER NOT NULL DEFAULT 0,
        FOREIGN KEY (snippet_id) REFERENCES snippets(id) ON DELETE CASCADE,
        PRIMARY KEY (snippet_id, trigger)
    );
    INSERT INTO snippets (id, name, replacement, created_at, updated_at)
        SELECT id, trigger, replacement, created_at, updated_at FROM legacy_snippets;
    """

    private static let migration6 = """
    CREATE TABLE media_job_stages (
        job_id TEXT NOT NULL,
        stage TEXT NOT NULL,
        completed_at REAL NOT NULL,
        PRIMARY KEY (job_id, stage),
        FOREIGN KEY (job_id) REFERENCES transcription_jobs(id) ON DELETE CASCADE
    );
    CREATE TABLE transcript_segments (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        job_id TEXT NOT NULL,
        ordinal INTEGER NOT NULL,
        start_time REAL NOT NULL,
        end_time REAL NOT NULL,
        transcript TEXT NOT NULL,
        FOREIGN KEY (job_id) REFERENCES transcription_jobs(id) ON DELETE CASCADE,
        UNIQUE (job_id, ordinal)
    );
    CREATE TABLE speaker_turns (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        job_id TEXT NOT NULL,
        ordinal INTEGER NOT NULL,
        speaker_id TEXT NOT NULL,
        start_time REAL NOT NULL,
        end_time REAL NOT NULL,
        FOREIGN KEY (job_id) REFERENCES transcription_jobs(id) ON DELETE CASCADE,
        UNIQUE (job_id, ordinal)
    );
    CREATE TABLE media_derived_files (
        job_id TEXT NOT NULL,
        path TEXT NOT NULL,
        PRIMARY KEY (job_id, path),
        FOREIGN KEY (job_id) REFERENCES transcription_jobs(id) ON DELETE CASCADE
    );
    CREATE INDEX idx_transcript_segments_job_id ON transcript_segments(job_id, ordinal);
    CREATE INDEX idx_speaker_turns_job_id ON speaker_turns(job_id, ordinal);
    """

    private static let migrations = [migration1, migration2, migration3, migration4, migration5, migration6]

    private static func migrateLegacySnippetRows(_ db: OpaquePointer) throws {
        var select: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id, trigger FROM legacy_snippets;", -1, &select, nil) == SQLITE_OK,
              let select else { throw DatabaseError.sqlFailed(lastError(db)) }
        defer { sqlite3_finalize(select) }

        var insert: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "INSERT INTO snippet_triggers (snippet_id, trigger, normalized_trigger, is_legacy) VALUES (?, ?, ?, 1);",
            -1, &insert, nil
        ) == SQLITE_OK, let insert else { throw DatabaseError.sqlFailed(lastError(db)) }
        defer { sqlite3_finalize(insert) }

        var result = sqlite3_step(select)
        while result == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(select, 0))
            let trigger = String(cString: sqlite3_column_text(select, 1))
            bind(id, at: 1, to: insert)
            bind(trigger, at: 2, to: insert)
            bind(TriggerNormalizer.normalize(trigger), at: 3, to: insert)
            guard sqlite3_step(insert) == SQLITE_DONE else { throw DatabaseError.sqlFailed(lastError(db)) }
            sqlite3_reset(insert)
            sqlite3_clear_bindings(insert)
            result = sqlite3_step(select)
        }
        guard result == SQLITE_DONE else { throw DatabaseError.sqlFailed(lastError(db)) }
        try execute(db, "DROP TABLE legacy_snippets;")
        try execute(db, "CREATE UNIQUE INDEX idx_snippet_triggers_normalized_unique ON snippet_triggers(normalized_trigger) WHERE is_legacy = 0;")
    }

    private static func bind(_ value: String, at index: Int32, to statement: OpaquePointer) {
        sqlite3_bind_text(statement, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }

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
