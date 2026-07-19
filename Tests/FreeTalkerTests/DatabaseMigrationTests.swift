import CSQLite
import Foundation
import Testing
@testable import FreeTalker

@Suite struct DatabaseMigrationTests {
    @Test func migratesEmptyDatabaseToLatestSchema() throws {
        let db = try TemporaryDatabase()

        try DatabaseMigrator.migrate(db.handle, role: .jobs)

        #expect(try db.tableNames() == [
            "transcription_jobs", "job_attempts", "speaker_segments",
            "speaker_names", "snippets", "snippet_triggers", "schema_migrations",
            "media_job_stages", "transcript_segments", "speaker_turns", "media_derived_files",
            "capture_sessions", "capture_segments"
        ])
        #expect(try db.indexNames() == [
            "idx_transcription_jobs_state_expires_at",
            "idx_transcription_jobs_purge_claimed_at",
            "idx_transcription_jobs_needs_source_cleanup",
            "idx_job_attempts_job_id", "idx_snippet_triggers_normalized_unique",
            "idx_transcript_segments_job_id", "idx_speaker_turns_job_id",
            "idx_transcription_jobs_lease_expires_at", "idx_transcription_jobs_deletion_claimed_at",
            "idx_capture_sessions_state_captured_at"
        ])
        #expect(try db.integer("SELECT COUNT(*) FROM pragma_foreign_key_list('snippet_triggers') WHERE \"table\" = 'snippets' AND \"from\" = 'snippet_id' AND on_delete = 'CASCADE';") == 1)
        #expect(try db.integer("SELECT COUNT(*) FROM pragma_foreign_key_list('job_attempts') WHERE \"table\" = 'transcription_jobs' AND \"from\" = 'job_id' AND on_delete = 'CASCADE';") == 1)
        #expect(try db.migrationVersions() == Array(1...DatabaseMigrator.latestVersion))
    }

    @Test func versionTenJobsUpgradePreservesRowsAndIsIdempotent() throws {
        let db = try TemporaryDatabase()
        try DatabaseMigrator.migrate(db.handle, role: .jobs)
        try db.execute("""
        DROP INDEX idx_capture_sessions_state_captured_at;
        DROP TABLE capture_segments;
        DROP TABLE capture_sessions;
        DELETE FROM schema_migrations WHERE version >= 11;
        CREATE TABLE dictations (
          id INTEGER PRIMARY KEY, ts REAL NOT NULL, language TEXT NOT NULL,
          template TEXT NOT NULL, transcript TEXT NOT NULL, refined TEXT NOT NULL,
          engine TEXT NOT NULL, source_id INTEGER,
          requested_output_language TEXT NOT NULL DEFAULT 'same'
        );
        INSERT INTO transcription_jobs
            (id, kind, source_reference, state, created_at, updated_at)
        VALUES ('kept-job', 'recovery', '/kept.wav', 'failed', 100, 101);
        """)
        #expect(try db.integer("SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name IN ('capture_sessions', 'capture_segments');") == 0)
        #expect(try db.integer("SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND name = 'idx_capture_sessions_state_captured_at';") == 0)

        try DatabaseMigrator.migrate(db.handle, role: .jobs)
        let schema = try db.schema()
        try DatabaseMigrator.migrate(db.handle, role: .jobs)

        #expect(try db.integer("SELECT COUNT(*) FROM transcription_jobs WHERE id = 'kept-job';") == 1)
        #expect(try db.schema() == schema)
        #expect(try db.integer("SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name IN ('capture_sessions', 'capture_segments');") == 2)
        #expect(try db.integer("SELECT COUNT(*) FROM pragma_table_info('capture_segments') WHERE (name = 'capture_id' AND pk = 1) OR (name = 'ordinal' AND pk = 2);") == 2)
        #expect(try db.integer("SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND name = 'idx_capture_sessions_state_captured_at';") == 1)
        #expect(try db.integer("SELECT COUNT(*) FROM pragma_foreign_key_list('capture_segments') WHERE \"table\" = 'capture_sessions' AND \"from\" = 'capture_id' AND on_delete = 'CASCADE';") == 1)
        #expect(try db.integer("SELECT COUNT(*) FROM pragma_table_info('dictations') WHERE name = 'capture_id';") == 0)
        #expect(try db.integer("SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND name = 'idx_dictations_capture_id';") == 0)
        #expect(try db.migrationVersions() == Array(1...DatabaseMigrator.latestVersion))
    }

    @Test func versionTenLibraryUpgradePreservesRowsAndIsIdempotent() throws {
        let db = try TemporaryDatabase()
        try DatabaseMigrator.migrate(db.handle)
        try db.execute("""
        DROP INDEX idx_capture_sessions_state_captured_at;
        DROP TABLE capture_segments;
        DROP TABLE capture_sessions;
        CREATE TABLE dictations (
          id INTEGER PRIMARY KEY, ts REAL NOT NULL, language TEXT NOT NULL,
          template TEXT NOT NULL, transcript TEXT NOT NULL, refined TEXT NOT NULL,
          engine TEXT NOT NULL, source_id INTEGER,
          requested_output_language TEXT NOT NULL DEFAULT 'same'
        );
        DELETE FROM schema_migrations WHERE version >= 11;
        INSERT INTO dictations
          (id, ts, language, template, transcript, refined, engine, source_id, requested_output_language)
        VALUES (7, 123, 'pt', 'Clean', 'raw', 'kept', 'local', NULL, 'same');
        """)
        #expect(try db.integer("SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name IN ('capture_sessions', 'capture_segments');") == 0)
        #expect(try db.integer("SELECT COUNT(*) FROM pragma_table_info('dictations') WHERE name = 'capture_id';") == 0)

        try DatabaseMigrator.migrate(db.handle, role: .library)
        let schema = try db.schema()
        try DatabaseMigrator.migrate(db.handle, role: .library)

        #expect(try db.string("SELECT language || '|' || requested_output_language || '|' || refined FROM dictations WHERE id = 7;") == "pt|same|kept")
        #expect(try db.integer("SELECT COUNT(*) FROM pragma_table_info('dictations') WHERE name = 'capture_id' AND type = 'TEXT';") == 1)
        #expect(try db.integer("SELECT COUNT(*) FROM pragma_index_list('dictations') WHERE name = 'idx_dictations_capture_id' AND \"unique\" = 1;") == 1)
        #expect(try db.integer("SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name IN ('capture_sessions', 'capture_segments');") == 0)
        #expect(try db.integer("SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND name = 'idx_capture_sessions_state_captured_at';") == 0)
        #expect(try db.schema() == schema)
        #expect(try db.migrationVersions() == Array(1...DatabaseMigrator.latestVersion))
    }

    @Test func versionElevenLibraryUpgradeAddsStatsColumnsAndIsIdempotent() throws {
        let db = try TemporaryDatabase()
        try DatabaseMigrator.migrate(db.handle)
        try db.execute("""
        DROP INDEX idx_capture_sessions_state_captured_at;
        DROP TABLE capture_segments;
        DROP TABLE capture_sessions;
        DELETE FROM schema_migrations WHERE version >= 12;
        CREATE TABLE dictations (
          id INTEGER PRIMARY KEY, ts REAL NOT NULL, language TEXT NOT NULL,
          template TEXT NOT NULL, transcript TEXT NOT NULL, refined TEXT NOT NULL,
          engine TEXT NOT NULL, source_id INTEGER,
          requested_output_language TEXT NOT NULL DEFAULT 'same',
          capture_id TEXT
        );
        INSERT INTO dictations
          (id, ts, language, template, transcript, refined, engine, source_id,
           requested_output_language, capture_id)
        VALUES (7, 123, 'pt', 'Clean', 'raw', 'kept', 'local', NULL, 'same', NULL);
        """)
        #expect(try db.integer("SELECT COUNT(*) FROM pragma_table_info('dictations') WHERE name IN ('bundle_id', 'duration_secs');") == 0)

        try DatabaseMigrator.migrate(db.handle, role: .library)
        let schema = try db.schema()
        try DatabaseMigrator.migrate(db.handle, role: .library)

        #expect(try db.string("SELECT language || '|' || requested_output_language || '|' || refined FROM dictations WHERE id = 7;") == "pt|same|kept")
        #expect(try db.integer("SELECT COUNT(*) FROM pragma_table_info('dictations') WHERE name = 'bundle_id' AND type = 'TEXT';") == 1)
        #expect(try db.integer("SELECT COUNT(*) FROM pragma_table_info('dictations') WHERE name = 'duration_secs' AND type = 'REAL';") == 1)
        #expect(try db.integer("SELECT bundle_id IS NULL AND duration_secs IS NULL FROM dictations WHERE id = 7;") == 1)
        // The "normal" migration ordering (Codex round-4 finding 1): `dictations` already exists
        // when the ledger reaches v13, so the idempotent `ALTER TABLE ... ADD COLUMN` adds it.
        #expect(try db.integer("SELECT COUNT(*) FROM pragma_table_info('dictations') WHERE name = 'voice_commands_active' AND type = 'INTEGER';") == 1)
        // Codex round-5 finding 8: the v13 `ALTER TABLE ... ADD COLUMN` has no DEFAULT clause, so
        // it must leave this pre-existing (v11) row's new column NULL, never backfill it.
        #expect(try db.integer("SELECT voice_commands_active IS NULL FROM dictations WHERE id = 7;") == 1)
        #expect(try db.schema() == schema)
        #expect(try db.migrationVersions() == Array(1...DatabaseMigrator.latestVersion))
    }

    /// Codex round-5 finding 8: the library-side test above covers `dictations.voice_commands_active`
    /// — this covers the jobs-database side of the same v13 migration (`capture_sessions`,
    /// `transcription_jobs`, `job_attempts`), proving a populated PRE-v13 row in each table stays
    /// NULL for the new `voice_commands_enabled`/`command_keywords` columns rather than being
    /// backfilled to some non-NULL default.
    @Test func versionThirteenJobsUpgradeLeavesPopulatedRowsNullForVoiceCommandColumns() throws {
        let db = try TemporaryDatabase()
        try DatabaseMigrator.migrate(db.handle, role: .jobs)
        // Simulate a genuinely PRE-v13 schema by dropping the columns the v13 migration adds,
        // then re-running only that step — mirrors the drop+recreate trick the library-side test
        // above uses for `dictations`, just via DROP COLUMN since these tables have foreign-key
        // dependents that make a full drop+recreate impractical.
        try db.execute("""
        ALTER TABLE transcription_jobs DROP COLUMN voice_commands_enabled;
        ALTER TABLE transcription_jobs DROP COLUMN command_keywords;
        ALTER TABLE job_attempts DROP COLUMN voice_commands_enabled;
        ALTER TABLE job_attempts DROP COLUMN command_keywords;
        ALTER TABLE capture_sessions DROP COLUMN voice_commands_enabled;
        ALTER TABLE capture_sessions DROP COLUMN command_keywords;
        DELETE FROM schema_migrations WHERE version >= 13;
        INSERT INTO transcription_jobs
            (id, kind, source_reference, state, created_at, updated_at)
        VALUES ('kept-job', 'recovery', '/kept.wav', 'failed', 100, 101);
        INSERT INTO job_attempts (job_id, attempt_number, started_at)
        VALUES ('kept-job', 1, 100);
        INSERT INTO capture_sessions
            (id, state, directory, captured_at, sample_rate, channel_count, destination, asset_kind)
        VALUES ('kept-capture', 'staged', '/dir', 100, 16000, 1, 'external', 'audio');
        """)
        #expect(try db.integer("SELECT COUNT(*) FROM pragma_table_info('transcription_jobs') WHERE name = 'voice_commands_enabled';") == 0)

        try DatabaseMigrator.migrate(db.handle, role: .jobs)
        let schema = try db.schema()
        try DatabaseMigrator.migrate(db.handle, role: .jobs)

        #expect(try db.integer("SELECT voice_commands_enabled IS NULL AND command_keywords IS NULL FROM transcription_jobs WHERE id = 'kept-job';") == 1)
        #expect(try db.integer("SELECT voice_commands_enabled IS NULL AND command_keywords IS NULL FROM job_attempts WHERE job_id = 'kept-job';") == 1)
        #expect(try db.integer("SELECT voice_commands_enabled IS NULL AND command_keywords IS NULL FROM capture_sessions WHERE id = 'kept-capture';") == 1)
        #expect(try db.schema() == schema)
        #expect(try db.migrationVersions() == Array(1...DatabaseMigrator.latestVersion))
    }

    /// PLAN.md PR B, item 2: `vocab_evidence`/`vocab_decisions` are library-only, created
    /// unconditionally (no `dictations`-exists guard — see the migration's doc comment), and the
    /// migration is idempotent (re-running produces no schema diff).
    @Test func versionFourteenLibraryUpgradeAddsVocabTablesAndIsIdempotent() throws {
        let db = try TemporaryDatabase()
        try DatabaseMigrator.migrate(db.handle, role: .library)
        let schema = try db.schema()
        try DatabaseMigrator.migrate(db.handle, role: .library)

        #expect(try db.tableNames().isSuperset(of: ["vocab_evidence", "vocab_decisions"]))
        #expect(try db.integer("SELECT COUNT(*) FROM pragma_table_info('vocab_evidence') WHERE name = 'dictation_id' AND type = 'INTEGER';") == 1)
        #expect(try db.integer("SELECT COUNT(*) FROM pragma_table_info('vocab_evidence') WHERE name = 'normalized_term' AND type = 'TEXT';") == 1)
        #expect(try db.integer("SELECT COUNT(*) FROM pragma_table_info('vocab_evidence') WHERE name = 'surface_term' AND type = 'TEXT';") == 1)
        #expect(try db.integer("SELECT COUNT(*) FROM pragma_table_info('vocab_evidence') WHERE name = 'first_seen' AND type = 'REAL';") == 1)
        #expect(try db.integer("""
        SELECT COUNT(*) FROM pragma_table_info('vocab_evidence')
        WHERE name IN ('dictation_id', 'normalized_term') AND pk > 0;
        """) == 2)
        #expect(try db.integer("SELECT COUNT(*) FROM pragma_foreign_key_list('vocab_evidence') WHERE \"table\" = 'dictations' AND \"from\" = 'dictation_id' AND on_delete = 'CASCADE';") == 1)
        #expect(try db.integer("SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND name = 'idx_vocab_evidence_normalized_term' AND tbl_name = 'vocab_evidence';") == 1)

        #expect(try db.integer("SELECT COUNT(*) FROM pragma_table_info('vocab_decisions') WHERE name = 'normalized_term' AND pk = 1;") == 1)
        #expect(try db.integer("SELECT COUNT(*) FROM pragma_table_info('vocab_decisions') WHERE name = 'status' AND \"notnull\" = 1;") == 1)
        #expect(try db.integer("SELECT COUNT(*) FROM pragma_table_info('vocab_decisions') WHERE name = 'surface_term' AND \"notnull\" = 0;") == 1)
        #expect(try db.integer("SELECT COUNT(*) FROM pragma_table_info('vocab_decisions') WHERE name = 'decided_at' AND type = 'REAL' AND \"notnull\" = 1;") == 1)

        #expect(try db.schema() == schema)
        #expect(try db.migrationVersions() == Array(1...DatabaseMigrator.latestVersion))
    }

    /// Jobs database never gets the vocab tables (they FK to `dictations`, a Library-only table) —
    /// mirrors the role separation `migrateVoiceCommandSnapshotV13`/`migrateCaptureV11` already
    /// establish for their own library-vs-jobs branches.
    @Test func versionFourteenJobsUpgradeCreatesNoVocabTables() throws {
        let db = try TemporaryDatabase()
        try DatabaseMigrator.migrate(db.handle, role: .jobs)
        #expect(try db.integer("SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name IN ('vocab_evidence', 'vocab_decisions');") == 0)
        #expect(try db.migrationVersions() == Array(1...DatabaseMigrator.latestVersion))
    }

    /// Deleting a dictation retracts its mined evidence (cascade) but a term's explicit
    /// approve/dismiss decision is a separate, unrelated table — Delete All (which clears every
    /// `dictations` row) must therefore leave `vocab_decisions` untouched. See PLAN.md PR B, item 2.
    @Test func vocabEvidenceCascadesOnDictationDeleteWhileDecisionsSurvive() throws {
        let db = try TemporaryDatabase()
        try DatabaseMigrator.migrate(db.handle, role: .library)
        // `dictations` isn't created by the migrator itself (only `Database.createSchema()` does,
        // for a fresh install) — declare it here matching that baseline shape, same as the other
        // library-role tests above (e.g. `versionElevenLibraryUpgrade...`).
        try db.execute("""
        CREATE TABLE dictations (
          id INTEGER PRIMARY KEY, ts REAL NOT NULL, language TEXT NOT NULL,
          template TEXT NOT NULL, transcript TEXT NOT NULL, refined TEXT NOT NULL,
          engine TEXT NOT NULL, source_id INTEGER
        );
        INSERT INTO dictations (id, ts, language, template, transcript, refined, engine, source_id)
        VALUES (7, 1, 'en', 'Clean', 'hello joao', 'hello João', 'local', NULL);
        INSERT INTO vocab_evidence (dictation_id, normalized_term, surface_term, first_seen)
        VALUES (7, 'joao', 'João', 1);
        INSERT INTO vocab_decisions (normalized_term, status, surface_term, decided_at)
        VALUES ('joao', 'approved', 'João', 1);
        """)
        try db.execute("PRAGMA foreign_keys = ON;")

        try db.execute("DELETE FROM dictations WHERE id = 7;")

        #expect(try db.integer("SELECT COUNT(*) FROM vocab_evidence;") == 0)
        #expect(try db.integer("SELECT COUNT(*) FROM vocab_decisions;") == 1)
        #expect(try db.string("SELECT status || '|' || surface_term FROM vocab_decisions WHERE normalized_term = 'joao';") == "approved|João")
    }

    @Test func vocabDecisionsCheckConstraintRejectsApprovedWithoutSurfaceTerm() throws {
        let db = try TemporaryDatabase()
        try DatabaseMigrator.migrate(db.handle, role: .library)

        #expect(throws: DatabaseError.self) {
            try db.execute("""
            INSERT INTO vocab_decisions (normalized_term, status, surface_term, decided_at)
            VALUES ('joao', 'approved', NULL, 1);
            """)
        }
        #expect(throws: DatabaseError.self) {
            try db.execute("""
            INSERT INTO vocab_decisions (normalized_term, status, surface_term, decided_at)
            VALUES ('joao', 'unknown-status', 'João', 1);
            """)
        }
        try db.execute("""
        INSERT INTO vocab_decisions (normalized_term, status, surface_term, decided_at)
        VALUES ('joao', 'dismissed', NULL, 1);
        """)
        #expect(try db.integer("SELECT COUNT(*) FROM vocab_decisions;") == 1)
    }

    @Test func deletingJobCascadesRecoveryAttempts() throws {
        let db = try TemporaryDatabase()
        try DatabaseMigrator.migrate(db.handle)
        try db.execute("PRAGMA foreign_keys = ON;")
        try db.execute("""
        INSERT INTO transcription_jobs (id, kind, source_reference, state, created_at, updated_at) VALUES ('recovery', 'recovery', '/audio', 'failed', 1, 1);
        INSERT INTO job_attempts (id, job_id, attempt_number, started_at, language, speech_model, template) VALUES (77, 'recovery', 1, 1, 'pt', 'small', 'clean');
        DELETE FROM transcription_jobs WHERE id = 'recovery';
        """)
        #expect(try db.integer("SELECT COUNT(*) FROM job_attempts WHERE id = 77;") == 0)
    }

    @Test func versionEightUpgradeDiscardsOrphanAttemptsAndPreservesValidAttemptsAndTriggers() throws {
        let db = try TemporaryDatabase()
        try DatabaseMigrator.migrate(db.handle)
        try db.execute("""
        PRAGMA foreign_keys = OFF;
        CREATE TABLE attempts_v8 AS SELECT * FROM job_attempts;
        DROP TABLE job_attempts;
        ALTER TABLE attempts_v8 RENAME TO job_attempts;
        CREATE INDEX idx_job_attempts_job_id ON job_attempts(job_id);
        CREATE TABLE job_attempt_triggers (attempt_id INTEGER NOT NULL, trigger TEXT NOT NULL, PRIMARY KEY(attempt_id, trigger));
        DELETE FROM schema_migrations WHERE version >= 9;
        INSERT INTO transcription_jobs (id, kind, source_reference, state, created_at, updated_at) VALUES ('valid-job', 'recovery', '/audio', 'failed', 1, 2);
        INSERT INTO job_attempts (id, job_id, attempt_number, started_at, completed_at, failure_stage, failure_message, language, speech_model, template, result)
          VALUES (41, 'valid-job', 3, 10, 20, 'transcribing', 'kept failure', 'pt', 'small', 'clean', 'failed');
        INSERT INTO job_attempts (id, job_id, attempt_number, started_at, language, speech_model, template, result)
          VALUES (42, 'missing-job', 1, 30, 'en', 'large', 'raw', 'failed');
        INSERT INTO job_attempt_triggers VALUES (41, 'valid-trigger'), (42, 'orphan-trigger');
        """)

        try DatabaseMigrator.migrate(db.handle)

        #expect(try db.string("SELECT id || '|' || job_id || '|' || attempt_number || '|' || started_at || '|' || completed_at || '|' || failure_stage || '|' || failure_message || '|' || language || '|' || speech_model || '|' || template || '|' || result FROM job_attempts WHERE id = 41;") == "41|valid-job|3|10.0|20.0|transcribing|kept failure|pt|small|clean|failed")
        #expect(try db.integer("SELECT COUNT(*) FROM job_attempts WHERE id = 42;") == 0)
        #expect(try db.integer("SELECT COUNT(*) FROM job_attempt_triggers WHERE attempt_id = 41 AND trigger = 'valid-trigger';") == 1)
        #expect(try db.integer("SELECT COUNT(*) FROM job_attempt_triggers WHERE attempt_id = 42;") == 0)
        try db.execute("PRAGMA foreign_keys = ON; DELETE FROM transcription_jobs WHERE id = 'valid-job';")
        #expect(try db.integer("SELECT COUNT(*) FROM job_attempts WHERE id = 41;") == 0)
        #expect(try db.integer("SELECT COUNT(*) FROM job_attempt_triggers WHERE attempt_id = 41;") == 0)
    }

    @Test func versionNineFailureRollsBackAttemptsTriggersAndLedger() throws {
        let db = try TemporaryDatabase()
        try DatabaseMigrator.migrate(db.handle)
        try db.execute("""
        PRAGMA foreign_keys = OFF;
        CREATE TABLE attempts_v8 AS SELECT * FROM job_attempts;
        DROP TABLE job_attempts;
        ALTER TABLE attempts_v8 RENAME TO job_attempts;
        CREATE INDEX idx_job_attempts_job_id ON job_attempts(job_id);
        CREATE TABLE job_attempt_triggers (attempt_id INTEGER NOT NULL, trigger TEXT NOT NULL, PRIMARY KEY(attempt_id, trigger));
        CREATE TABLE legacy_job_attempts (collision INTEGER);
        DELETE FROM schema_migrations WHERE version >= 9;
        INSERT INTO job_attempts (id, job_id, attempt_number, started_at) VALUES (88, 'orphan', 1, 1);
        INSERT INTO job_attempt_triggers VALUES (88, 'kept-on-rollback');
        """)

        #expect(throws: DatabaseError.self) { try DatabaseMigrator.migrate(db.handle) }

        #expect(try db.migrationVersions() == Array(1...8))
        #expect(try db.integer("SELECT COUNT(*) FROM job_attempts WHERE id = 88;") == 1)
        #expect(try db.integer("SELECT COUNT(*) FROM job_attempt_triggers WHERE attempt_id = 88 AND trigger = 'kept-on-rollback';") == 1)
        #expect(try db.integer("SELECT COUNT(*) FROM pragma_table_info('legacy_job_attempts') WHERE name = 'collision';") == 1)
    }

    @Test func migratingLatestSchemaAgainMakesNoChanges() throws {
        let db = try TemporaryDatabase()
        try DatabaseMigrator.migrate(db.handle)
        let schema = try db.schema()

        try DatabaseMigrator.migrate(db.handle)

        #expect(try db.schema() == schema)
        #expect(try db.migrationVersions() == Array(1...DatabaseMigrator.latestVersion))
    }

    @Test func versionNineLibraryUpgradePreservesRowsAndAddsOutputMetadata() throws {
        let db = try TemporaryDatabase()
        try DatabaseMigrator.migrate(db.handle, role: .library)
        try db.execute("""
        DELETE FROM schema_migrations WHERE version >= 10;
        CREATE TABLE dictations (
          id INTEGER PRIMARY KEY, ts REAL NOT NULL, language TEXT NOT NULL,
          template TEXT NOT NULL, transcript TEXT NOT NULL, refined TEXT NOT NULL,
          engine TEXT NOT NULL, source_id INTEGER
        );
        INSERT INTO dictations VALUES (7, 123, 'pt', 'Clean', 'raw', 'kept', 'local', NULL);
        """)

        try DatabaseMigrator.migrate(db.handle, role: .library)

        #expect(try db.string("SELECT language || '|' || requested_output_language || '|' || refined FROM dictations WHERE id = 7;") == "pt|same|kept")
        #expect(try db.migrationVersions() == Array(1...DatabaseMigrator.latestVersion))
        #expect(try db.integer("SELECT COUNT(*) FROM pragma_table_info('dictation_translation_variants') WHERE name = 'parent_id' AND type = 'TEXT';") == 1)
        #expect(try db.integer("SELECT COUNT(*) FROM pragma_foreign_key_list('dictation_translation_variants') WHERE \"table\" = 'dictations' AND \"from\" = 'parent_id' AND on_delete = 'CASCADE';") == 1)
    }

    @Test func versionTenRebuildsLegacySourceForeignKeyWithoutLosingHistoryOrSearch() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("freetalker-legacy-v9-\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(atPath: url.path + "-wal")
            try? FileManager.default.removeItem(atPath: url.path + "-shm")
        }
        do {
            let legacy = try TemporaryDatabase(path: url.path)
            try DatabaseMigrator.migrate(legacy.handle, role: .library)
            try legacy.execute("""
            DELETE FROM schema_migrations WHERE version >= 10;
            CREATE TABLE dictations (
              id INTEGER PRIMARY KEY AUTOINCREMENT, ts REAL NOT NULL, language TEXT NOT NULL,
              template TEXT NOT NULL, transcript TEXT NOT NULL, refined TEXT NOT NULL,
              engine TEXT NOT NULL, source_id INTEGER REFERENCES dictations(id)
            );
            CREATE VIRTUAL TABLE dictations_fts USING fts5(
              transcript, refined, content='dictations', content_rowid='id'
            );
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
            INSERT INTO dictations VALUES (41, 1, 'en', 'Clean', 'source words', 'source result', 'local', NULL);
            INSERT INTO dictations VALUES (99, 2, 'pt', 'Clean', 'child words', 'searchable child', 'local', 41);
            """)
            try DatabaseMigrator.migrate(legacy.handle, role: .library)
            #expect(try legacy.integer("SELECT COUNT(*) FROM pragma_foreign_key_list('dictations') WHERE \"from\" = 'source_id';") == 0)
        }

        let library = try Database(path: url)
        #expect(try library.searchDictations(query: "searchable").map(\.id) == [99])
        #expect(try library.searchDictations(query: "source result").map(\.id) == [41])
        try library.deleteRow(id: 41)
        let fetchedChild = try library.dictation(id: 99)
        let child = try #require(fetchedChild)
        #expect(child.sourceID == 41)
        #expect(child.sourceLanguage == SourceLanguage("pt"))
        #expect(child.requestedOutputLanguage == .sameAsSpoken)
        #expect(child.templateName == "Clean")
        #expect(child.transcript == "child words")
        #expect(child.refined == "searchable child")
        #expect(child.engine == "local")
        #expect(try library.searchDictations(query: "searchable").map(\.id) == [99])
        #expect(try library.searchDictations(query: "source result").isEmpty)

        let insertedID = try library.insertDictation(.init(
            timestamp: Date(), sourceLanguage: SourceLanguage("de"),
            requestedOutputLanguage: .sameAsSpoken, template: "Clean",
            transcript: "new trigger words", refined: "new searchable result", engine: "local"
        ))
        #expect(try library.searchDictations(query: "new searchable").map(\.id) == [insertedID])
        try library.deleteRow(id: insertedID)
        #expect(try library.searchDictations(query: "new searchable").isEmpty)
    }

    @Test func migratorBeforeLibraryCreationDoesNotPoisonVersionTen() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("freetalker-migrator-first-\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(atPath: url.path + "-wal")
            try? FileManager.default.removeItem(atPath: url.path + "-shm")
        }
        do {
            let shared = try TemporaryDatabase(path: url.path)
            try DatabaseMigrator.migrate(shared.handle, role: .library)
            #expect(try shared.migrationVersions() == Array(1...DatabaseMigrator.latestVersion))
            // The ledger ordering this test exercises (Codex round-4 finding 1): the migrator
            // reaches v13 before `createSchema()` has ever created `dictations`, so v13 is a no-op
            // here — the baseline `CREATE TABLE dictations` (below, via `Database(path:)`) must
            // declare the column itself, or a ledger already at v13 permanently skips the ALTER.
            #expect(try shared.integer("SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'dictations';") == 0)
        }

        let library = try Database(path: url)
        // `insertDictation` binds `voice_commands_active` unconditionally (Database.swift); if the
        // baseline `CREATE TABLE dictations` omitted the column (the poisoned-ledger bug), this
        // insert throws `DatabaseError.sqlFailed` instead of silently succeeding.
        let id = try library.insertDictation(.init(
            timestamp: Date(), sourceLanguage: SourceLanguage("en"),
            requestedOutputLanguage: .spanish, template: "Clean",
            transcript: "hello", refined: "hello", engine: "local",
            voiceCommandsActive: true
        ))
        try library.upsertTranslation(parentID: id, target: .spanish, text: "hola")
        #expect(try library.translationVariants(parentID: id).map(\.text) == ["hola"])
        #expect(try library.dictation(id: id)?.voiceCommandsActive == true)
    }

    @Test func versionTenFailureRollsBackLibrarySchemaAndLedger() throws {
        let db = try TemporaryDatabase()
        try db.execute("""
        CREATE TABLE dictations (
          id INTEGER PRIMARY KEY, ts REAL NOT NULL, language TEXT NOT NULL,
          template TEXT NOT NULL, transcript TEXT NOT NULL, refined TEXT NOT NULL,
          engine TEXT NOT NULL, source_id INTEGER
        );
        """)
        try DatabaseMigrator.migrate(db.handle, role: .library)
        try db.execute("""
        DROP TABLE dictation_translation_variants;
        ALTER TABLE dictations DROP COLUMN requested_output_language;
        DELETE FROM schema_migrations WHERE version >= 10;
        CREATE TABLE dictation_translation_variants (collision INTEGER);
        INSERT INTO dictations
          (id, ts, language, template, transcript, refined, engine, source_id)
        VALUES (7, 1, 'en', 'Clean', 'raw', 'kept', 'local', NULL);
        """)

        #expect(throws: DatabaseError.self) {
            try DatabaseMigrator.migrate(db.handle, role: .library)
        }

        #expect(try db.migrationVersions() == Array(1...9))
        #expect(try db.integer("SELECT COUNT(*) FROM pragma_table_info('dictations') WHERE name = 'requested_output_language';") == 0)
        #expect(try db.integer("SELECT COUNT(*) FROM dictations WHERE id = 7 AND refined = 'kept';") == 1)
        #expect(try db.integer("SELECT COUNT(*) FROM pragma_table_info('dictation_translation_variants') WHERE name = 'collision';") == 1)
    }

    @Test func mediaForeignKeysRejectOrphansAndCascadeFromJobs() throws {
        let db = try TemporaryDatabase()
        try DatabaseMigrator.migrate(db.handle)
        try db.execute("PRAGMA foreign_keys = ON;")
        #expect(throws: DatabaseError.self) {
            try db.execute("INSERT INTO transcript_segments (job_id, ordinal, start_time, end_time, transcript) VALUES ('missing', 0, 0, 1, 'x');")
        }
        try db.execute("""
        INSERT INTO transcription_jobs (id, kind, source_reference, state, created_at, updated_at) VALUES ('media', 'media_import', '/source', 'ready', 1, 1);
        INSERT INTO transcript_segments (job_id, ordinal, start_time, end_time, transcript) VALUES ('media', 0, 0, 1, 'x');
        DELETE FROM transcription_jobs WHERE id = 'media';
        """)
        #expect(try db.integer("SELECT COUNT(*) FROM transcript_segments WHERE job_id = 'media';") == 0)
    }

    @Test func upgradesPopulatedVersionSixMediaSchemaWithoutDataLoss() throws {
        let db = try TemporaryDatabase()
        try DatabaseMigrator.migrate(db.handle)
        try db.execute("""
        DROP INDEX idx_transcription_jobs_lease_expires_at;
        DROP INDEX idx_transcription_jobs_deletion_claimed_at;
        ALTER TABLE transcription_jobs DROP COLUMN deletion_expires_at;
        ALTER TABLE transcription_jobs DROP COLUMN deletion_error;
        ALTER TABLE transcription_jobs DROP COLUMN deletion_owner;
        ALTER TABLE transcription_jobs DROP COLUMN deletion_claimed_at;
        ALTER TABLE transcription_jobs DROP COLUMN lease_expires_at;
        ALTER TABLE transcription_jobs DROP COLUMN lease_owner;
        DELETE FROM schema_migrations WHERE version >= 7;
        INSERT INTO transcription_jobs (id, kind, source_reference, state, created_at, updated_at) VALUES ('media-v6', 'media_import', '/source', 'queued', 1, 1);
        INSERT INTO transcript_segments (job_id, ordinal, start_time, end_time, transcript) VALUES ('media-v6', 0, 0, 1, 'kept');
        """)
        try DatabaseMigrator.migrate(db.handle)
        #expect(try db.migrationVersions() == Array(1...DatabaseMigrator.latestVersion))
        #expect(try db.integer("SELECT COUNT(*) FROM transcript_segments WHERE job_id = 'media-v6' AND transcript = 'kept';") == 1)
        #expect(try db.integer("SELECT COUNT(*) FROM pragma_table_info('transcription_jobs') WHERE name IN ('lease_owner','lease_expires_at','deletion_claimed_at','deletion_owner','deletion_error','deletion_expires_at');") == 6)
    }

    @Test func migratesPopulatedVersionOneDatabaseWithoutDataLoss() throws {
        let db = try TemporaryDatabase()
        try db.createVersionOneSchema()
        try db.execute("""
        INSERT INTO transcription_jobs
            (id, kind, source_reference, state, created_at, updated_at)
        VALUES ('job-1', 'recovery', '/tmp/audio.wav', 'failed', 100, 101);
        INSERT INTO job_attempts
            (id, job_id, attempt_number, started_at, completed_at, failure_stage, failure_message)
        VALUES (7, 'job-1', 1, 100, 101, 'transcribing', 'old failure');
        INSERT INTO speaker_segments
            (id, job_id, speaker_id, start_time, end_time, transcript)
        VALUES (8, 'job-1', 'speaker-1', 0, 1.5, 'hello');
        INSERT INTO speaker_names (job_id, speaker_id, name)
        VALUES ('job-1', 'speaker-1', 'Alice');
        INSERT INTO snippets (id, trigger, replacement, created_at, updated_at)
        VALUES ('snippet-1', 'brb', 'be right back', 100, 101);
        """)

        try DatabaseMigrator.migrate(db.handle)

        #expect(try db.migrationVersions() == Array(1...DatabaseMigrator.latestVersion))
        #expect(try db.integer("SELECT COUNT(*) FROM transcription_jobs WHERE id = 'job-1';") == 1)
        #expect(try db.integer("SELECT COUNT(*) FROM job_attempts WHERE id = 7 AND failure_message = 'old failure';") == 1)
        #expect(try db.integer("SELECT COUNT(*) FROM speaker_segments WHERE id = 8 AND transcript = 'hello';") == 1)
        #expect(try db.integer("SELECT COUNT(*) FROM speaker_names WHERE name = 'Alice';") == 1)
        #expect(try db.integer("SELECT COUNT(*) FROM snippets WHERE replacement = 'be right back';") == 1)
        #expect(try db.integer("SELECT COUNT(*) FROM snippet_triggers WHERE trigger = 'brb';") == 1)
        #expect(try db.integer("SELECT is_legacy FROM snippet_triggers WHERE trigger = 'brb';") == 1)

        try db.execute("""
        UPDATE job_attempts
        SET language = 'pt', speech_model = 'small', template = 'clean', result = 'failed'
        WHERE id = 7;
        """)
        #expect(try db.string("""
        SELECT language || '|' || speech_model || '|' || template || '|' || result
        FROM job_attempts WHERE id = 7;
        """) == "pt|small|clean|failed")
        #expect(try db.integer("SELECT COUNT(*) FROM pragma_table_info('transcription_jobs') WHERE name IN ('purge_claimed_at', 'purge_error');") == 2)
        #expect(try db.integer("SELECT COUNT(*) FROM pragma_table_info('transcription_jobs') WHERE name IN ('needs_source_cleanup', 'source_cleanup_error');") == 2)
    }

    @Test func upgradesVersionThreeCleanupMetadataWithoutChangingRows() throws {
        let db = try TemporaryDatabase()
        try db.createVersionThreeSchema()
        try db.execute("""
        INSERT INTO transcription_jobs
            (id, kind, source_reference, state, created_at, updated_at)
        VALUES ('ready-recovery', 'recovery', '/tmp/audio.wav', 'ready', 100, 101);
        """)

        try DatabaseMigrator.migrate(db.handle)

        #expect(try db.migrationVersions() == Array(1...DatabaseMigrator.latestVersion))
        #expect(try db.integer("SELECT COUNT(*) FROM transcription_jobs WHERE id = 'ready-recovery';") == 1)
        #expect(try db.integer("SELECT needs_source_cleanup FROM transcription_jobs WHERE id = 'ready-recovery';") == 0)
        #expect(try db.integer("SELECT source_cleanup_error IS NULL FROM transcription_jobs WHERE id = 'ready-recovery';") == 1)
    }

    @Test func rollsBackEntireMigrationWhenSchemaCreationFails() throws {
        let db = try TemporaryDatabase()
        try db.execute("CREATE TABLE job_attempts (collision INTEGER);")

        #expect(throws: DatabaseError.self) {
            try DatabaseMigrator.migrate(db.handle)
        }

        #expect(try db.tableNames() == ["job_attempts"])
    }

    @Test func rollsBackVersionFiveUpgradeAndLedgerWhenTriggerTableCreationFails() throws {
        let db = try TemporaryDatabase()
        try db.createVersionFourSchema()
        try db.execute("CREATE TABLE snippet_triggers (collision INTEGER);")

        #expect(throws: DatabaseError.self) { try DatabaseMigrator.migrate(db.handle) }

        #expect(try db.migrationVersions() == [1, 2, 3, 4])
        #expect(try db.integer("SELECT COUNT(*) FROM pragma_table_info('snippets') WHERE name = 'trigger';") == 1)
        #expect(try db.integer("SELECT COUNT(*) FROM pragma_table_info('snippets') WHERE name = 'name';") == 0)
    }

    @Test func rollsBackVersionSixMediaUpgradeAndLedgerWhenTableCreationFails() throws {
        let db = try TemporaryDatabase()
        try DatabaseMigrator.migrate(db.handle)
        try db.execute("""
        DROP INDEX idx_transcript_segments_job_id;
        DROP INDEX idx_speaker_turns_job_id;
        DROP TABLE media_job_stages;
        DROP TABLE transcript_segments;
        DROP TABLE speaker_turns;
        DROP TABLE media_derived_files;
        DELETE FROM schema_migrations WHERE version >= 6;
        CREATE TABLE transcript_segments (collision INTEGER);
        """)

        #expect(throws: DatabaseError.self) { try DatabaseMigrator.migrate(db.handle) }

        #expect(try db.migrationVersions() == [1, 2, 3, 4, 5])
        #expect(try db.tableNames().contains("media_job_stages") == false)
        #expect(try db.integer("SELECT COUNT(*) FROM pragma_table_info('transcript_segments') WHERE name = 'collision';") == 1)
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

    init(path: String = ":memory:") throws {
        var database: OpaquePointer?
        guard sqlite3_open(path, &database) == SQLITE_OK, let database else {
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

    func createVersionOneSchema() throws {
        try execute("""
        CREATE TABLE schema_migrations (
            version INTEGER PRIMARY KEY,
            applied_at REAL NOT NULL DEFAULT (unixepoch())
        );
        INSERT INTO schema_migrations (version) VALUES (1);
        CREATE TABLE transcription_jobs (
            id TEXT PRIMARY KEY, kind TEXT NOT NULL, source_reference TEXT NOT NULL,
            source_bookmark BLOB, state TEXT NOT NULL, progress REAL NOT NULL DEFAULT 0,
            created_at REAL NOT NULL, updated_at REAL NOT NULL, started_at REAL,
            completed_at REAL, expires_at REAL, language TEXT, speech_model TEXT,
            template TEXT, failure_stage TEXT, failure_message TEXT, result TEXT
        );
        CREATE TABLE job_attempts (
            id INTEGER PRIMARY KEY AUTOINCREMENT, job_id TEXT NOT NULL,
            attempt_number INTEGER NOT NULL, started_at REAL NOT NULL, completed_at REAL,
            failure_stage TEXT, failure_message TEXT
        );
        CREATE TABLE speaker_segments (
            id INTEGER PRIMARY KEY AUTOINCREMENT, job_id TEXT NOT NULL,
            speaker_id TEXT NOT NULL, start_time REAL NOT NULL, end_time REAL NOT NULL,
            transcript TEXT NOT NULL
        );
        CREATE TABLE speaker_names (
            job_id TEXT NOT NULL, speaker_id TEXT NOT NULL, name TEXT NOT NULL,
            PRIMARY KEY (job_id, speaker_id)
        );
        CREATE TABLE snippets (
            id TEXT PRIMARY KEY, trigger TEXT NOT NULL UNIQUE, replacement TEXT NOT NULL,
            created_at REAL NOT NULL, updated_at REAL NOT NULL
        );
        CREATE INDEX idx_transcription_jobs_state_expires_at
            ON transcription_jobs (state, expires_at);
        CREATE INDEX idx_job_attempts_job_id ON job_attempts (job_id);
        """)
    }

    func createVersionThreeSchema() throws {
        try createVersionOneSchema()
        try execute("""
        ALTER TABLE job_attempts ADD COLUMN language TEXT;
        ALTER TABLE job_attempts ADD COLUMN speech_model TEXT;
        ALTER TABLE job_attempts ADD COLUMN template TEXT;
        ALTER TABLE job_attempts ADD COLUMN result TEXT;
        INSERT INTO schema_migrations (version) VALUES (2);
        ALTER TABLE transcription_jobs ADD COLUMN purge_claimed_at REAL;
        ALTER TABLE transcription_jobs ADD COLUMN purge_error TEXT;
        CREATE INDEX idx_transcription_jobs_purge_claimed_at
            ON transcription_jobs (purge_claimed_at);
        INSERT INTO schema_migrations (version) VALUES (3);
        """)
    }

    func createVersionFourSchema() throws {
        try createVersionThreeSchema()
        try execute("""
        ALTER TABLE transcription_jobs ADD COLUMN needs_source_cleanup INTEGER NOT NULL DEFAULT 0;
        ALTER TABLE transcription_jobs ADD COLUMN source_cleanup_error TEXT;
        CREATE INDEX idx_transcription_jobs_needs_source_cleanup ON transcription_jobs (needs_source_cleanup);
        INSERT INTO schema_migrations (version) VALUES (4);
        """)
    }

    func execute(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? lastError()
            sqlite3_free(errorMessage)
            throw DatabaseError.sqlFailed(message)
        }
    }

    func integer(_ sql: String) throws -> Int {
        try integers(sql).first ?? 0
    }

    func string(_ sql: String) throws -> String? {
        try strings(sql).first
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
