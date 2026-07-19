import CSQLite

enum DatabaseRole: Sendable {
    case jobs
    case library
}

enum DatabaseMigrator {
    static let latestVersion = 14

    static func migrate(_ db: OpaquePointer, role: DatabaseRole = .jobs) throws {
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
                if version == 10 {
                    try migrateLibraryV10(db)
                } else if version == 11 {
                    try migrateCaptureV11(db, role: role)
                } else if version == 12 {
                    try migrateLibraryStatsV12(db, role: role)
                } else if version == 13 {
                    try migrateVoiceCommandSnapshotV13(db, role: role)
                } else if version == 14 {
                    try migrateVocabV14(db, role: role)
                } else {
                    try execute(db, migration)
                }
                if version == 5 {
                    try migrateLegacySnippetRows(db)
                }
                if version == 9 {
                    try migrateAttemptTriggersV9(db)
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

    private static let migration7 = """
    ALTER TABLE transcription_jobs ADD COLUMN lease_owner TEXT;
    ALTER TABLE transcription_jobs ADD COLUMN lease_expires_at REAL;
    ALTER TABLE transcription_jobs ADD COLUMN deletion_claimed_at REAL;
    ALTER TABLE transcription_jobs ADD COLUMN deletion_owner TEXT;
    ALTER TABLE transcription_jobs ADD COLUMN deletion_error TEXT;
    CREATE INDEX idx_transcription_jobs_lease_expires_at ON transcription_jobs(lease_expires_at);
    CREATE INDEX idx_transcription_jobs_deletion_claimed_at ON transcription_jobs(deletion_claimed_at);
    """

    private static let migration8 = """
    ALTER TABLE transcription_jobs ADD COLUMN deletion_expires_at REAL;
    """

    private static let migration9 = """
    CREATE TABLE IF NOT EXISTS job_attempts (
        id INTEGER PRIMARY KEY AUTOINCREMENT, job_id TEXT NOT NULL, attempt_number INTEGER NOT NULL,
        started_at REAL NOT NULL, completed_at REAL, failure_stage TEXT, failure_message TEXT,
        language TEXT, speech_model TEXT, template TEXT, result TEXT
    );
    ALTER TABLE job_attempts RENAME TO legacy_job_attempts;
    CREATE TABLE job_attempts (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        job_id TEXT NOT NULL,
        attempt_number INTEGER NOT NULL,
        started_at REAL NOT NULL,
        completed_at REAL,
        failure_stage TEXT,
        failure_message TEXT,
        language TEXT,
        speech_model TEXT,
        template TEXT,
        result TEXT,
        FOREIGN KEY (job_id) REFERENCES transcription_jobs(id) ON DELETE CASCADE
    );
    INSERT INTO job_attempts
        (id, job_id, attempt_number, started_at, completed_at, failure_stage, failure_message,
         language, speech_model, template, result)
    SELECT id, job_id, attempt_number, started_at, completed_at, failure_stage, failure_message,
           language, speech_model, template, result
    FROM legacy_job_attempts AS attempt
    WHERE EXISTS (SELECT 1 FROM transcription_jobs AS job WHERE job.id = attempt.job_id);
    """

    private static let migration10 = ""
    private static let migration11 = ""
    private static let migration12 = ""
    private static let migration13 = ""
    private static let migration14 = ""

    private static let migrations = [migration1, migration2, migration3, migration4, migration5, migration6, migration7, migration8, migration9, migration10, migration11, migration12, migration13, migration14]

    /// Adds the Usage Statistics columns to an existing Library `dictations` table. Runs only for
    /// the Library database (the jobs database has no `dictations`). Guarded by `columnExists` so a
    /// fresh install — whose `createSchema()` baseline already declares both columns — converges to
    /// the identical schema without re-adding them. FTS triggers are untouched. See PLAN.md F4.1.
    private static func migrateLibraryStatsV12(_ db: OpaquePointer, role: DatabaseRole) throws {
        guard role == .library else { return }
        guard try tableExists("dictations", db: db) else { return }
        if try !columnExists("bundle_id", in: "dictations", db: db) {
            try execute(db, "ALTER TABLE dictations ADD COLUMN bundle_id TEXT;")
        }
        if try !columnExists("duration_secs", in: "dictations", db: db) {
            try execute(db, "ALTER TABLE dictations ADD COLUMN duration_secs REAL;")
        }
    }

    /// Adds the durable voice command snapshot columns (PLAN.md PR A, item 1b): nullable
    /// `voice_commands_enabled`/`command_keywords` on `capture_sessions`, `transcription_jobs`,
    /// and `job_attempts` (jobs database), and nullable `voice_commands_active` on `dictations`
    /// (library database). `command_keywords` is stored as a comma-joined string — validated
    /// keywords are letters-only (see `AppSettings.normalizeCommandKeywords`), so a comma can
    /// never collide with keyword content. NULL everywhere means "absent" (legacy/unknown), never
    /// "disabled" — see each column's call site for how that's resolved.
    private static func migrateVoiceCommandSnapshotV13(_ db: OpaquePointer, role: DatabaseRole) throws {
        switch role {
        case .jobs:
            if try tableExists("capture_sessions", db: db) {
                if try !columnExists("voice_commands_enabled", in: "capture_sessions", db: db) {
                    try execute(db, "ALTER TABLE capture_sessions ADD COLUMN voice_commands_enabled INTEGER;")
                }
                if try !columnExists("command_keywords", in: "capture_sessions", db: db) {
                    try execute(db, "ALTER TABLE capture_sessions ADD COLUMN command_keywords TEXT;")
                }
            }
            if try !columnExists("voice_commands_enabled", in: "transcription_jobs", db: db) {
                try execute(db, "ALTER TABLE transcription_jobs ADD COLUMN voice_commands_enabled INTEGER;")
            }
            if try !columnExists("command_keywords", in: "transcription_jobs", db: db) {
                try execute(db, "ALTER TABLE transcription_jobs ADD COLUMN command_keywords TEXT;")
            }
            if try !columnExists("voice_commands_enabled", in: "job_attempts", db: db) {
                try execute(db, "ALTER TABLE job_attempts ADD COLUMN voice_commands_enabled INTEGER;")
            }
            if try !columnExists("command_keywords", in: "job_attempts", db: db) {
                try execute(db, "ALTER TABLE job_attempts ADD COLUMN command_keywords TEXT;")
            }
        case .library:
            guard try tableExists("dictations", db: db) else { return }
            if try !columnExists("voice_commands_active", in: "dictations", db: db) {
                try execute(db, "ALTER TABLE dictations ADD COLUMN voice_commands_active INTEGER;")
            }
        }
    }

    /// Adds the self-learning vocabulary tables (PLAN.md PR B, item 2): `vocab_evidence` — one row
    /// per (dictation, normalized term) recurrence, FK'd to `dictations` `ON DELETE CASCADE` so
    /// deleting a dictation automatically retracts its evidence — and `vocab_decisions` — one row
    /// per term ever explicitly approved or dismissed, independent of evidence, so Delete All
    /// (which clears `dictations` and therefore all evidence via cascade) never touches a user's
    /// approve/dismiss decisions. Library database only; unconditional (not guarded on `dictations`
    /// already existing) because SQLite does not require a `FOREIGN KEY` target table to exist at
    /// `CREATE TABLE` time — see the sibling V13 doc comment for why a `tableExists` guard here
    /// would instead risk PERMANENTLY skipping table creation if this migration ever ran before
    /// `dictations` existed (ledger already at v14, guard forever false on every later run).
    private static func migrateVocabV14(_ db: OpaquePointer, role: DatabaseRole) throws {
        guard role == .library else { return }
        try execute(db, """
        CREATE TABLE IF NOT EXISTS vocab_evidence (
            dictation_id INTEGER NOT NULL,
            normalized_term TEXT NOT NULL,
            surface_term TEXT NOT NULL,
            first_seen REAL NOT NULL,
            PRIMARY KEY (dictation_id, normalized_term),
            FOREIGN KEY (dictation_id) REFERENCES dictations(id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS idx_vocab_evidence_normalized_term
            ON vocab_evidence(normalized_term, dictation_id);
        CREATE TABLE IF NOT EXISTS vocab_decisions (
            normalized_term TEXT PRIMARY KEY,
            status TEXT NOT NULL CHECK(status IN ('approved', 'dismissed')),
            surface_term TEXT,
            decided_at REAL NOT NULL,
            CHECK (status != 'approved' OR surface_term IS NOT NULL)
        );
        """)
    }

    private static func migrateCaptureV11(_ db: OpaquePointer, role: DatabaseRole) throws {
        switch role {
        case .jobs:
            try execute(db, """
            CREATE TABLE IF NOT EXISTS capture_sessions (
                id TEXT PRIMARY KEY,
                state TEXT NOT NULL,
                directory TEXT NOT NULL,
                captured_at REAL NOT NULL,
                sample_rate REAL NOT NULL,
                channel_count INTEGER NOT NULL,
                input_device_uid TEXT,
                destination TEXT NOT NULL,
                recovery_job_id TEXT,
                library_dictation_id INTEGER,
                asset_kind TEXT NOT NULL,
                failure_message TEXT,
                content_hash TEXT
            );
            CREATE TABLE IF NOT EXISTS capture_segments (
                capture_id TEXT NOT NULL,
                ordinal INTEGER NOT NULL,
                path TEXT NOT NULL,
                sample_count INTEGER NOT NULL,
                content_hash TEXT NOT NULL,
                PRIMARY KEY (capture_id, ordinal),
                FOREIGN KEY (capture_id) REFERENCES capture_sessions(id) ON DELETE CASCADE
            );
            CREATE INDEX IF NOT EXISTS idx_capture_sessions_state_captured_at
                ON capture_sessions(state, captured_at);
            """)
        case .library:
            guard try tableExists("dictations", db: db) else { return }
            if try !columnExists("capture_id", in: "dictations", db: db) {
                try execute(db, "ALTER TABLE dictations ADD COLUMN capture_id TEXT;")
            }
            try execute(db, """
            CREATE UNIQUE INDEX IF NOT EXISTS idx_dictations_capture_id
            ON dictations(capture_id)
            WHERE capture_id IS NOT NULL;
            """)
        }
    }

    private static func migrateLibraryV10(_ db: OpaquePointer) throws {
        guard try tableExists("dictations", db: db) else { return }
        let hasRequestedOutput: Bool
        do {
            hasRequestedOutput = try columnExists("requested_output_language", in: "dictations", db: db)
        } catch {
            throw DatabaseError.sqlFailed("Migration 10 column inspection failed: \(error)")
        }
        let hasLegacyForeignKey: Bool
        do {
            hasLegacyForeignKey = try hasSourceIDForeignKey(db)
        } catch {
            throw DatabaseError.sqlFailed("Migration 10 foreign-key inspection failed: \(error)")
        }
        if hasLegacyForeignKey {
            do {
                try rebuildLegacyDictationsV10(
                    db, hasRequestedOutput: hasRequestedOutput,
                    hasFTS: try tableExists("dictations_fts", db: db)
                )
            } catch {
                throw DatabaseError.sqlFailed("Migration 10 Library rebuild failed: \(error)")
            }
        } else if !hasRequestedOutput {
            do {
                try execute(db, "ALTER TABLE dictations ADD COLUMN requested_output_language TEXT NOT NULL DEFAULT 'same';")
            } catch {
                throw DatabaseError.sqlFailed("Migration 10 metadata column failed: \(error)")
            }
        }
        do {
            try execute(db, """
        CREATE TABLE dictation_translation_variants (
          parent_id TEXT NOT NULL,
          target_language TEXT NOT NULL,
          text TEXT NOT NULL,
          created_at REAL NOT NULL,
          updated_at REAL NOT NULL,
          PRIMARY KEY (parent_id, target_language),
          FOREIGN KEY (parent_id) REFERENCES dictations(id) ON DELETE CASCADE
        );
        """)
        } catch {
            throw DatabaseError.sqlFailed("Migration 10 variant table failed: \(error)")
        }
    }

    private static func rebuildLegacyDictationsV10(
        _ db: OpaquePointer, hasRequestedOutput: Bool, hasFTS: Bool
    ) throws {
        let requestedOutputExpression = hasRequestedOutput ? "requested_output_language" : "'same'"
        let rebuildSQL = """
        PRAGMA defer_foreign_keys=ON;
        DROP TRIGGER IF EXISTS dictations_ai;
        DROP TRIGGER IF EXISTS dictations_ad;
        DROP TRIGGER IF EXISTS dictations_au;
        ALTER TABLE dictations RENAME TO legacy_dictations_v9;
        CREATE TABLE dictations (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            ts REAL NOT NULL,
            language TEXT NOT NULL,
            template TEXT NOT NULL,
            transcript TEXT NOT NULL,
            refined TEXT NOT NULL,
            engine TEXT NOT NULL,
            source_id INTEGER,
            requested_output_language TEXT NOT NULL DEFAULT 'same'
        );
        INSERT INTO dictations
            (id, ts, language, template, transcript, refined, engine, source_id, requested_output_language)
        SELECT id, ts, language, template, transcript, refined, engine, source_id,
        """ + requestedOutputExpression + """

        FROM legacy_dictations_v9;
        DROP TABLE legacy_dictations_v9;
        """
        try execute(db, rebuildSQL)
        guard hasFTS else { return }
        try execute(db, """
        CREATE TRIGGER dictations_ai AFTER INSERT ON dictations BEGIN
            INSERT INTO dictations_fts(rowid, transcript, refined) VALUES (new.id, new.transcript, new.refined);
        END;
        CREATE TRIGGER dictations_ad AFTER DELETE ON dictations BEGIN
            INSERT INTO dictations_fts(dictations_fts, rowid, transcript, refined) VALUES('delete', old.id, old.transcript, old.refined);
        END;
        CREATE TRIGGER dictations_au AFTER UPDATE ON dictations BEGIN
            INSERT INTO dictations_fts(dictations_fts, rowid, transcript, refined) VALUES('delete', old.id, old.transcript, old.refined);
            INSERT INTO dictations_fts(rowid, transcript, refined) VALUES (new.id, new.transcript, new.refined);
        END;
        """)
    }

    private static func hasSourceIDForeignKey(_ db: OpaquePointer) throws -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "SELECT 1 FROM pragma_foreign_key_list('dictations') WHERE \"from\" = 'source_id' LIMIT 1;",
            -1, &statement, nil
        ) == SQLITE_OK, let statement else { throw DatabaseError.sqlFailed(lastError(db)) }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private static func columnExists(_ column: String, in table: String, db: OpaquePointer) throws -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            db, "PRAGMA table_info('\(table)');",
            -1, &statement, nil
        ) == SQLITE_OK, let statement else { throw DatabaseError.sqlFailed(lastError(db)) }
        defer { sqlite3_finalize(statement) }
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            if let name = sqlite3_column_text(statement, 1), String(cString: name) == column {
                return true
            }
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw DatabaseError.sqlFailed(lastError(db)) }
        return false
    }

    private static func migrateAttemptTriggersV9(_ db: OpaquePointer) throws {
        if try tableExists("job_attempt_triggers", db: db) {
            try execute(db, """
        ALTER TABLE job_attempt_triggers RENAME TO legacy_job_attempt_triggers;
        CREATE TABLE job_attempt_triggers (
            attempt_id INTEGER NOT NULL,
            trigger TEXT NOT NULL,
            PRIMARY KEY (attempt_id, trigger),
            FOREIGN KEY (attempt_id) REFERENCES job_attempts(id) ON DELETE CASCADE
        );
        INSERT INTO job_attempt_triggers (attempt_id, trigger)
        SELECT legacy.attempt_id, legacy.trigger
        FROM legacy_job_attempt_triggers AS legacy
        JOIN job_attempts AS attempt ON attempt.id = legacy.attempt_id;
        DROP TABLE legacy_job_attempt_triggers;
        CREATE INDEX idx_job_attempt_triggers_attempt_id ON job_attempt_triggers(attempt_id);
        """)
        }
        try execute(db, """
        DROP TABLE legacy_job_attempts;
        CREATE INDEX idx_job_attempts_job_id ON job_attempts(job_id);
        """)
    }

    private static func tableExists(_ name: String, db: OpaquePointer) throws -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?;", -1, &statement, nil) == SQLITE_OK,
              let statement else { throw DatabaseError.sqlFailed(lastError(db)) }
        defer { sqlite3_finalize(statement) }
        bind(name, at: 1, to: statement)
        return sqlite3_step(statement) == SQLITE_ROW
    }

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
