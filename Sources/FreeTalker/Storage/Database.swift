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

    static let defaultURL: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("FreeTalker", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("library.db")
    }()

    init(path: URL = Database.defaultURL) throws {
        if sqlite3_open(path.path, &handle) != SQLITE_OK {
            let message = String(cString: sqlite3_errmsg(handle))
            throw DatabaseError.openFailed(message)
        }
        sqlite3_busy_timeout(handle, 5_000)
        try exec("PRAGMA journal_mode=WAL;")
        try exec("PRAGMA secure_delete=ON;")
        try exec("PRAGMA foreign_keys=ON;")
        try createSchema()
        try DatabaseMigrator.migrate(try requireHandle())
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
            requested_output_language TEXT NOT NULL DEFAULT 'same'
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
        let sql = "INSERT INTO dictations (ts, language, requested_output_language, template, transcript, refined, engine, source_id) VALUES (?, ?, ?, ?, ?, ?, ?, ?);"
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
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.sqlFailed(lastError())
        }
        return sqlite3_last_insert_rowid(handle)
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

    /// All dictations, reverse-chronological. `id DESC` breaks ties when two rows share a `ts`
    /// (e.g. inserted within the same clock tick) — id is the monotonic tiebreaker.
    func allDictations() throws -> [Dictation] {
        let sql = "SELECT id, ts, language, requested_output_language, template, transcript, refined, engine, source_id FROM dictations ORDER BY ts DESC, id DESC;"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        return try readAll(stmt)
    }

    func latestDictation() throws -> Dictation? {
        let sql = "SELECT id, ts, language, requested_output_language, template, transcript, refined, engine, source_id FROM dictations ORDER BY id DESC LIMIT 1;"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        return try readAll(stmt).first
    }

    /// Full-text search over transcript + refined output, falling back to a LIKE scan if the
    /// FTS query syntax is rejected (e.g. bare punctuation in the query).
    func searchDictations(query: String) throws -> [Dictation] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return try allDictations() }

        let ftsSQL = """
        SELECT d.id, d.ts, d.language, d.requested_output_language, d.template, d.transcript, d.refined, d.engine, d.source_id
        FROM dictations d
        JOIN dictations_fts f ON f.rowid = d.id
        WHERE dictations_fts MATCH ?
        ORDER BY d.ts DESC, d.id DESC;
        """
        if let stmt = try? prepare(ftsSQL) {
            bindText(stmt, 1, ftsMatchExpression(for: trimmed))
            if let results = try? readAll(stmt) {
                sqlite3_finalize(stmt)
                return results
            }
            sqlite3_finalize(stmt)
        }

        // Fallback: plain LIKE scan.
        let likeSQL = """
        SELECT id, ts, language, requested_output_language, template, transcript, refined, engine, source_id FROM dictations
        WHERE transcript LIKE ? OR refined LIKE ?
        ORDER BY ts DESC, id DESC;
        """
        let stmt = try prepare(likeSQL)
        defer { sqlite3_finalize(stmt) }
        let pattern = "%\(trimmed)%"
        bindText(stmt, 1, pattern)
        bindText(stmt, 2, pattern)
        return try readAll(stmt)
    }

    private func ftsMatchExpression(for query: String) -> String {
        // Quote each token so punctuation/prefixes in free text don't break FTS5 query syntax.
        let tokens = query.split(separator: " ").map { "\"\($0)\"*" }
        return tokens.joined(separator: " ")
    }

    /// Scans every row via `sqlite3_step`, throwing unless the loop ends at a clean `SQLITE_DONE`
    /// EOF — a `SQLITE_BUSY`/`SQLITE_ERROR`/etc. mid-scan (`.other`, see `classifyStep`) is a
    /// failure, not "no more rows", so callers (notably `latestDictation()`, which
    /// `AppCoordinator.redoLast()` depends on to distinguish "empty Library" from "Library
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
            results.append(Dictation(
                id: id,
                timestamp: Date(timeIntervalSince1970: ts),
                sourceLanguage: sourceLanguage,
                requestedOutputLanguage: requestedOutputLanguage,
                templateName: template,
                transcript: transcript,
                refined: refined,
                engine: engine,
                sourceID: sourceID
            ))
            stepResult = sqlite3_step(stmt)
        }
        guard Self.classifyStep(stepResult) == .done else {
            throw DatabaseError.sqlFailed(lastError())
        }
        return results
    }

    func dictation(id: Int64) throws -> Dictation? {
        let stmt = try prepare("SELECT id, ts, language, requested_output_language, template, transcript, refined, engine, source_id FROM dictations WHERE id = ?;")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, id)
        return try readAll(stmt).first
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

    private func lastError() -> String {
        String(cString: sqlite3_errmsg(handle))
    }
}
