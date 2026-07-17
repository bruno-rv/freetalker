import CSQLite
import Foundation

enum DatabaseError: Error, Equatable {
    case openFailed(String)
    case sqlFailed(String)
    case translationParentMissing(Int64)
}

/// Thin wrapper over the system libsqlite3 C API. No ORM — a handful of hand-written
/// statements is simpler than pulling in a wrapper dependency (ponytail rung 4).
final class Database {
    private var handle: OpaquePointer?

    static let defaultURL: URL = FreeTalkerPaths.libraryDatabase

    init(path: URL = Database.defaultURL) throws {
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        if sqlite3_open(path.path, &handle) != SQLITE_OK {
            let message = String(cString: sqlite3_errmsg(handle))
            throw DatabaseError.openFailed(message)
        }
        sqlite3_busy_timeout(handle, 5_000)
        try exec("PRAGMA journal_mode=WAL;")
        try exec("PRAGMA secure_delete=ON;")
        try exec("PRAGMA foreign_keys=ON;")
        try createSchema()
        try DatabaseMigrator.migrate(try requireHandle(), role: .library)
        try createCaptureIdentitySchema()
        try createTranslationSchema()
    }

    deinit {
        sqlite3_close(handle)
    }

    private func createSchema() throws {
        try exec("""
        CREATE TABLE IF NOT EXISTS dictations (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            ts REAL NOT NULL,
            language TEXT NOT NULL,
            template TEXT NOT NULL,
            transcript TEXT NOT NULL,
            refined TEXT NOT NULL,
            engine TEXT NOT NULL,
            source_id INTEGER,
            requested_output_language TEXT NOT NULL DEFAULT 'same',
            capture_id TEXT,
            bundle_id TEXT,
            duration_secs REAL
        );
        """)
        try exec("""
        CREATE VIRTUAL TABLE IF NOT EXISTS dictations_fts USING fts5(
            transcript, refined, content='dictations', content_rowid='id'
        );
        """)
        try exec("""
        CREATE TRIGGER IF NOT EXISTS dictations_ai AFTER INSERT ON dictations BEGIN
            INSERT INTO dictations_fts(rowid, transcript, refined) VALUES (new.id, new.transcript, new.refined);
        END;
        """)
        try exec("""
        CREATE TRIGGER IF NOT EXISTS dictations_ad AFTER DELETE ON dictations BEGIN
            INSERT INTO dictations_fts(dictations_fts, rowid, transcript, refined) VALUES('delete', old.id, old.transcript, old.refined);
        END;
        """)
        try exec("""
        CREATE TRIGGER IF NOT EXISTS dictations_au AFTER UPDATE ON dictations BEGIN
            INSERT INTO dictations_fts(dictations_fts, rowid, transcript, refined) VALUES('delete', old.id, old.transcript, old.refined);
            INSERT INTO dictations_fts(rowid, transcript, refined) VALUES (new.id, new.transcript, new.refined);
        END;
        """)
    }

    private func createCaptureIdentitySchema() throws {
        try exec("""
        CREATE UNIQUE INDEX IF NOT EXISTS idx_dictations_capture_id
        ON dictations(capture_id)
        WHERE capture_id IS NOT NULL;
        """)
    }

    private func createTranslationSchema() throws {
        try exec("""
        CREATE TABLE IF NOT EXISTS dictation_translation_variants (
          parent_id TEXT NOT NULL,
          target_language TEXT NOT NULL,
          text TEXT NOT NULL,
          created_at REAL NOT NULL,
          updated_at REAL NOT NULL,
          PRIMARY KEY (parent_id, target_language),
          FOREIGN KEY (parent_id) REFERENCES dictations(id) ON DELETE CASCADE
        );
        """)
    }

    // MARK: - Writes

    @discardableResult
    func insertDictation(_ request: DictationInsertRequest) throws -> Int64 {
        try insertDictation(request, captureID: nil).id
    }

    func insertDictation(_ request: DictationInsertRequest, captureID: UUID?) throws -> Dictation {
        let sql = """
        INSERT INTO dictations
            (ts, language, requested_output_language, template, transcript, refined, engine, source_id, capture_id, bundle_id, duration_secs)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(capture_id) WHERE capture_id IS NOT NULL DO NOTHING;
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, request.timestamp.timeIntervalSince1970)
        bindText(stmt, 2, request.sourceLanguage.rawValue)
        bindText(stmt, 3, request.requestedOutputLanguage.rawValue)
        bindText(stmt, 4, request.template)
        bindText(stmt, 5, request.transcript)
        bindText(stmt, 6, request.refined)
        bindText(stmt, 7, request.engine)
        if let sourceID = request.sourceID {
            sqlite3_bind_int64(stmt, 8, sourceID)
        } else {
            sqlite3_bind_null(stmt, 8)
        }
        if let captureID {
            bindText(stmt, 9, captureID.uuidString)
        } else {
            sqlite3_bind_null(stmt, 9)
        }
        if let bundleID = request.bundleID {
            bindText(stmt, 10, bundleID)
        } else {
            sqlite3_bind_null(stmt, 10)
        }
        if let durationSecs = request.durationSecs {
            sqlite3_bind_double(stmt, 11, durationSecs)
        } else {
            sqlite3_bind_null(stmt, 11)
        }
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.sqlFailed(lastError())
        }
        if sqlite3_changes(handle) == 1 {
            guard let inserted = try dictation(id: sqlite3_last_insert_rowid(handle)) else {
                throw DatabaseError.sqlFailed("Inserted Library dictation could not be read")
            }
            if captureID != nil { SmokeCheckpoint.hit(.postLibraryInsert) }
            return inserted
        }
        guard let captureID, let existing = try dictations(captureID: captureID).first else {
            throw DatabaseError.sqlFailed("Library dictation insert made no change")
        }
        return existing
    }

    func deleteRow(id: Int64) throws {
        let stmt = try prepare("DELETE FROM dictations WHERE id = ?;")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, id)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.sqlFailed(lastError())
        }
    }

    func deleteAllRows() throws {
        try exec("DELETE FROM dictations;")
    }

    func vacuumAndCheckpoint() throws {
        try exec("VACUUM;")
        try checkpointTruncate()
    }

    func dictationExists(id: Int64) throws -> Bool {
        let stmt = try prepare("SELECT 1 FROM dictations WHERE id = ? LIMIT 1;")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, id)
        switch Self.classifyStep(sqlite3_step(stmt)) {
        case .row: return true
        case .done: return false
        case .other: throw DatabaseError.sqlFailed(lastError())
        }
    }

    enum StepOutcome: Equatable { case row, done, other }

    static func classifyStep(_ result: Int32) -> StepOutcome {
        switch result {
        case SQLITE_ROW: return .row
        case SQLITE_DONE: return .done
        default: return .other
        }
    }

    func checkpointTruncate() throws {
        let stmt = try prepare("PRAGMA wal_checkpoint(TRUNCATE);")
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            throw DatabaseError.sqlFailed(lastError())
        }
        let busy = sqlite3_column_int(stmt, 0)
        guard busy == 0 else {
            throw DatabaseError.sqlFailed("wal_checkpoint(TRUNCATE) busy — checkpoint incomplete")
        }
    }

    /// Total (unfiltered) Library row count — the source of truth for
    /// `LibraryStore.totalCount()` (the Delete All confirmation dialog), immune to an active
    /// Library search filter. See Round 1 Codex finding 1.
    func totalCount() throws -> Int {
        let stmt = try prepare("SELECT COUNT(*) FROM dictations;")
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            throw DatabaseError.sqlFailed(lastError())
        }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    func secureDeleteStatus() throws -> Int32 {
        let stmt = try prepare("PRAGMA secure_delete;")
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            throw DatabaseError.sqlFailed(lastError())
        }
        return sqlite3_column_int(stmt, 0)
    }

    func foreignKeysEnabled() throws -> Bool {
        let stmt = try prepare("PRAGMA foreign_keys;")
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw DatabaseError.sqlFailed(lastError()) }
        return sqlite3_column_int(stmt, 0) == 1
    }

    func migrationVersions() throws -> [Int] {
        let stmt = try prepare("SELECT version FROM schema_migrations ORDER BY version;")
        defer { sqlite3_finalize(stmt) }
        var versions: [Int] = []
        var result = sqlite3_step(stmt)
        while result == SQLITE_ROW {
            versions.append(Int(sqlite3_column_int(stmt, 0)))
            result = sqlite3_step(stmt)
        }
        guard result == SQLITE_DONE else { throw DatabaseError.sqlFailed(lastError()) }
        return versions
    }

    // MARK: - Reads

    /// The single source-of-truth column list, in the exact order `readAll` reads positionally.
    /// Every dictation SELECT interpolates this so the projection and the reader can never drift.
    private static let dictationColumns =
        "id, ts, language, requested_output_language, template, transcript, refined, engine, source_id, capture_id, bundle_id, duration_secs"
    private static let dictationColumnsPrefixedD =
        "d.id, d.ts, d.language, d.requested_output_language, d.template, d.transcript, d.refined, d.engine, d.source_id, d.capture_id, d.bundle_id, d.duration_secs"

    /// All dictations, reverse-chronological. `id DESC` breaks ties when two rows share a `ts`
    /// (e.g. inserted within the same clock tick) — id is the monotonic tiebreaker.
    func allDictations() throws -> [Dictation] {
        let sql = "SELECT \(Self.dictationColumns) FROM dictations ORDER BY ts DESC, id DESC;"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        return try readAll(stmt)
    }

    func latestDictation() throws -> Dictation? {
        let sql = "SELECT \(Self.dictationColumns) FROM dictations ORDER BY id DESC LIMIT 1;"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        return try readAll(stmt).first
    }

    /// Full-text search over transcript + refined output, falling back to a LIKE scan if the
    /// FTS query syntax is rejected. Unlimited — the Library view's live as-you-type search.
    /// Delegates to `search(query:limit:)`, the ONE search path also used by the Dictation
    /// History Quick Panel (F3.3) from its own dedicated actor connection.
    func searchDictations(query: String) throws -> [Dictation] {
        try search(query: query, limit: nil)
    }

    /// The ONE search path shared by every caller (`searchDictations` above, and the Dictation
    /// History Quick Panel's dedicated `LibraryReadActor`, which opens its own connection to this
    /// same database file — see PLAN.md F3.3). `limit`, when non-nil, is bound as a SQL `LIMIT`
    /// parameter (never string-interpolated) so a bounded caller can never accidentally scan/
    /// return an unbounded result set. `query` is bounded and trimmed by
    /// `DictationSearchQuery.bounded` before it ever reaches SQLite.
    func search(query: String, limit: Int?) throws -> [Dictation] {
        let bounded = DictationSearchQuery.bounded(query)
        let limitValue = Int32(limit ?? -1) // SQLite: LIMIT -1 means unlimited.

        guard !bounded.isEmpty else {
            let stmt = try prepare("SELECT \(Self.dictationColumns) FROM dictations ORDER BY ts DESC, id DESC LIMIT ?;")
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, limitValue)
            return try readAll(stmt)
        }

        let ftsSQL = """
        SELECT \(Self.dictationColumnsPrefixedD)
        FROM dictations d
        JOIN dictations_fts f ON f.rowid = d.id
        WHERE dictations_fts MATCH ?
        ORDER BY d.ts DESC, d.id DESC
        LIMIT ?;
        """
        if let stmt = try? prepare(ftsSQL) {
            bindText(stmt, 1, DictationSearchQuery.ftsMatchExpression(for: bounded))
            sqlite3_bind_int(stmt, 2, limitValue)
            if let results = try? readAll(stmt) {
                sqlite3_finalize(stmt)
                return results
            }
            sqlite3_finalize(stmt)
        }

        // Fallback: plain LIKE scan, explicit ESCAPE clause (see `DictationSearchQuery`).
        let likeSQL = """
        SELECT \(Self.dictationColumns) FROM dictations
        WHERE transcript LIKE ? ESCAPE '\(DictationSearchQuery.likeEscapeCharacter)'
           OR refined LIKE ? ESCAPE '\(DictationSearchQuery.likeEscapeCharacter)'
        ORDER BY ts DESC, id DESC
        LIMIT ?;
        """
        let stmt = try prepare(likeSQL)
        defer { sqlite3_finalize(stmt) }
        let pattern = DictationSearchQuery.likePattern(for: bounded)
        bindText(stmt, 1, pattern)
        bindText(stmt, 2, pattern)
        sqlite3_bind_int(stmt, 3, limitValue)
        return try readAll(stmt)
    }

    /// Scans every row via `sqlite3_step`, throwing unless the loop ends at a clean `SQLITE_DONE`
    /// EOF — a `SQLITE_BUSY`/`SQLITE_ERROR`/etc. mid-scan (`.other`, see `classifyStep`) is a
    /// failure, not "no more rows", so callers (notably `latestDictation()`, which
    /// `AppCoordinator.insertLastDictation()` depends on to distinguish "empty Library" from "Library
    /// unavailable") never silently see a truncated result as a normal empty/short one. See
    /// Round 1 Codex finding 2.
    private func readAll(_ stmt: OpaquePointer?) throws -> [Dictation] {
        var results: [Dictation] = []
        var stepResult = sqlite3_step(stmt)
        while Self.classifyStep(stepResult) == .row {
            let id = sqlite3_column_int64(stmt, 0)
            let ts = sqlite3_column_double(stmt, 1)
            let sourceLanguage = SourceLanguage(columnText(stmt, 2))
            let requestedOutputLanguage = OutputLanguage.persisted(rawValue: columnText(stmt, 3))
            let template = columnText(stmt, 4)
            let transcript = columnText(stmt, 5)
            let refined = columnText(stmt, 6)
            let engine = columnText(stmt, 7)
            let sourceID: Int64? = sqlite3_column_type(stmt, 8) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 8)
            let captureID = optionalColumnText(stmt, 9).flatMap(UUID.init(uuidString:))
            let bundleID = optionalColumnText(stmt, 10)
            let durationSecs: Double? = sqlite3_column_type(stmt, 11) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 11)
            results.append(Dictation(
                id: id,
                timestamp: Date(timeIntervalSince1970: ts),
                sourceLanguage: sourceLanguage,
                requestedOutputLanguage: requestedOutputLanguage,
                templateName: template,
                transcript: transcript,
                refined: refined,
                engine: engine,
                sourceID: sourceID,
                captureID: captureID,
                bundleID: bundleID,
                durationSecs: durationSecs
            ))
            stepResult = sqlite3_step(stmt)
        }
        guard Self.classifyStep(stepResult) == .done else {
            throw DatabaseError.sqlFailed(lastError())
        }
        return results
    }

    func dictation(id: Int64) throws -> Dictation? {
        let stmt = try prepare("SELECT \(Self.dictationColumns) FROM dictations WHERE id = ?;")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, id)
        return try readAll(stmt).first
    }

    func dictations(captureID: UUID) throws -> [Dictation] {
        let stmt = try prepare("SELECT \(Self.dictationColumns) FROM dictations WHERE capture_id = ? ORDER BY id;")
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, captureID.uuidString)
        return try readAll(stmt)
    }

    /// Minimal projection for Usage Statistics — just the columns the aggregation needs, so a large
    /// history streams through with no `Dictation` allocation overhead. Word counts are computed in
    /// Swift from `refined`, never in SQL. See PLAN.md F4.4.
    func statRows() throws -> [DictationStatRow] {
        let stmt = try prepare("SELECT ts, language, template, engine, bundle_id, duration_secs, refined, transcript FROM dictations;")
        defer { sqlite3_finalize(stmt) }
        var rows: [DictationStatRow] = []
        var result = sqlite3_step(stmt)
        while Self.classifyStep(result) == .row {
            rows.append(DictationStatRow(
                timestamp: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0)),
                language: columnText(stmt, 1),
                template: columnText(stmt, 2),
                engine: columnText(stmt, 3),
                bundleID: optionalColumnText(stmt, 4),
                durationSecs: sqlite3_column_type(stmt, 5) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 5),
                refined: columnText(stmt, 6),
                transcript: columnText(stmt, 7)
            ))
            result = sqlite3_step(stmt)
        }
        guard Self.classifyStep(result) == .done else { throw DatabaseError.sqlFailed(lastError()) }
        return rows
    }

    func translationVariants(parentID: Int64) throws -> [DictationTranslationVariant] {
        let stmt = try prepare("SELECT parent_id, target_language, text, created_at, updated_at FROM dictation_translation_variants WHERE parent_id = ? ORDER BY target_language;")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, parentID)
        var variants: [DictationTranslationVariant] = []
        var result = sqlite3_step(stmt)
        while result == SQLITE_ROW {
            guard let target = TranslationTarget(rawValue: columnText(stmt, 1)) else {
                throw DatabaseError.sqlFailed("Invalid translation target in Library database")
            }
            variants.append(.init(
                parentID: sqlite3_column_int64(stmt, 0),
                target: target,
                text: columnText(stmt, 2),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3)),
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4))
            ))
            result = sqlite3_step(stmt)
        }
        guard result == SQLITE_DONE else { throw DatabaseError.sqlFailed(lastError()) }
        return variants
    }

    func upsertTranslation(parentID: Int64, target: TranslationTarget, text: String) throws {
        try transaction {
            guard try dictationExists(id: parentID) else {
                throw DatabaseError.translationParentMissing(parentID)
            }
            let stmt = try prepare("""
            INSERT INTO dictation_translation_variants
                (parent_id, target_language, text, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(parent_id, target_language) DO UPDATE SET
                text = excluded.text, updated_at = excluded.updated_at;
            """)
            defer { sqlite3_finalize(stmt) }
            let now = Date().timeIntervalSince1970
            sqlite3_bind_int64(stmt, 1, parentID)
            bindText(stmt, 2, target.rawValue)
            bindText(stmt, 3, text)
            sqlite3_bind_double(stmt, 4, now)
            sqlite3_bind_double(stmt, 5, now)
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw DatabaseError.sqlFailed(lastError()) }
        }
    }

    func conditionalUpsertTranslation(
        parentID: Int64,
        target: TranslationTarget,
        text: String,
        expected: TranslationVariantExpectation
    ) throws -> TranslationVariantWriteResult {
        var outcome: TranslationVariantWriteResult?
        try transaction {
            guard try dictationExists(id: parentID) else {
                throw DatabaseError.translationParentMissing(parentID)
            }
            let current = try translationVariant(parentID: parentID, target: target)
            let matches: Bool
            switch (expected, current) {
            case (.absent, nil): matches = true
            case (.version(let version), .some(let variant)):
                matches = abs(variant.updatedAt.timeIntervalSince1970 - version.timeIntervalSince1970) < 0.000_001
            default: matches = false
            }
            guard matches else {
                if let current { outcome = .replacementConfirmationRequired(current) }
                else { outcome = .replacementStateChangedToAbsent }
                return
            }

            let wallClock = Date().timeIntervalSince1970
            let now = Date(timeIntervalSince1970: max(wallClock, (current?.updatedAt.timeIntervalSince1970 ?? 0) + 0.001))
            let createdAt = current?.createdAt ?? now
            let stmt = try prepare("""
            INSERT INTO dictation_translation_variants
                (parent_id, target_language, text, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(parent_id, target_language) DO UPDATE SET
                text = excluded.text, updated_at = excluded.updated_at;
            """)
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, parentID)
            bindText(stmt, 2, target.rawValue)
            bindText(stmt, 3, text)
            sqlite3_bind_double(stmt, 4, createdAt.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 5, now.timeIntervalSince1970)
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw DatabaseError.sqlFailed(lastError()) }
            outcome = .committed(.init(
                parentID: parentID, target: target, text: text,
                createdAt: createdAt, updatedAt: now
            ))
        }
        guard let outcome else { throw DatabaseError.sqlFailed("Translation write produced no result") }
        return outcome
    }

    private func translationVariant(parentID: Int64, target: TranslationTarget) throws -> DictationTranslationVariant? {
        let stmt = try prepare("SELECT parent_id, text, created_at, updated_at FROM dictation_translation_variants WHERE parent_id = ? AND target_language = ?;")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, parentID)
        bindText(stmt, 2, target.rawValue)
        let result = sqlite3_step(stmt)
        guard result == SQLITE_ROW else {
            guard result == SQLITE_DONE else { throw DatabaseError.sqlFailed(lastError()) }
            return nil
        }
        return .init(
            parentID: sqlite3_column_int64(stmt, 0), target: target, text: columnText(stmt, 1),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2)),
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))
        )
    }

    func deleteTranslation(parentID: Int64, target: TranslationTarget) throws {
        try transaction {
            let stmt = try prepare("DELETE FROM dictation_translation_variants WHERE parent_id = ? AND target_language = ?;")
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, parentID)
            bindText(stmt, 2, target.rawValue)
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw DatabaseError.sqlFailed(lastError()) }
        }
    }

    // MARK: - Helpers

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.sqlFailed(lastError())
        }
        return stmt
    }

    private func transaction(_ body: () throws -> Void) throws {
        try exec("BEGIN IMMEDIATE;")
        do {
            try body()
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    private func requireHandle() throws -> OpaquePointer {
        guard let handle else { throw DatabaseError.openFailed("Database handle is unavailable") }
        return handle
    }

    private func exec(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<Int8>?
        if sqlite3_exec(handle, sql, nil, nil, &errorMessage) != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? "unknown sqlite error"
            sqlite3_free(errorMessage)
            throw DatabaseError.sqlFailed(message)
        }
    }

    private func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }

    private func columnText(_ stmt: OpaquePointer?, _ index: Int32) -> String {
        guard let cString = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: cString)
    }

    private func optionalColumnText(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        return columnText(stmt, index)
    }

    private func lastError() -> String {
        String(cString: sqlite3_errmsg(handle))
    }
}
