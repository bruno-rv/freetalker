import CSQLite
import Foundation

enum DatabaseError: Error {
    case openFailed(String)
    case sqlFailed(String)
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
        try exec("PRAGMA journal_mode=WAL;")
        // Deletion is a privacy feature, not just a row removal: secure_delete zeroes deleted
        // page content instead of leaving it recoverable in free pages. See PLAN.md step 1.
        try exec("PRAGMA secure_delete=ON;")
        try createSchema()
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
            -- SQLite foreign keys stay OFF permanently in this app (never
            -- `PRAGMA foreign_keys=ON`) — a dangling source_id after the source row is deleted
            -- is intended provenance behavior, not corruption. See PLAN.md step 1, CONTEXT.md
            -- "Re-process".
            source_id INTEGER REFERENCES dictations(id)
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

    // MARK: - Writes

    @discardableResult
    func insertDictation(timestamp: Date, language: String, template: String, transcript: String, refined: String, engine: String, sourceID: Int64? = nil) throws -> Int64 {
        let sql = "INSERT INTO dictations (ts, language, template, transcript, refined, engine, source_id) VALUES (?, ?, ?, ?, ?, ?, ?);"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, timestamp.timeIntervalSince1970)
        bindText(stmt, 2, language)
        bindText(stmt, 3, template)
        bindText(stmt, 4, transcript)
        bindText(stmt, 5, refined)
        bindText(stmt, 6, engine)
        if let sourceID {
            sqlite3_bind_int64(stmt, 7, sourceID)
        } else {
            sqlite3_bind_null(stmt, 7)
        }
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.sqlFailed(lastError())
        }
        return sqlite3_last_insert_rowid(handle)
    }

    // MARK: - Deletes

    /// Deletes one Dictation row. The `dictations_ad` AFTER DELETE trigger keeps
    /// `dictations_fts` in sync — no FTS code needed here. Followed by a verified WAL truncate:
    /// with `secure_delete` on, per-row deletion is only privacy-grade if the deleted page image
    /// doesn't linger in the WAL. See PLAN.md step 1.
    func deleteDictation(id: Int64) throws {
        let stmt = try prepare("DELETE FROM dictations WHERE id = ?;")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, id)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.sqlFailed(lastError())
        }
        try walCheckpointTruncate()
    }

    /// Clears the entire Library. `VACUUM` reclaims (and overwrites) freed pages so cleared text
    /// doesn't linger there, then a verified WAL truncate clears the write-ahead log. See
    /// PLAN.md step 1.
    func deleteAllDictations() throws {
        try exec("DELETE FROM dictations;")
        try exec("VACUUM;")
        try walCheckpointTruncate()
    }

    /// Whether a Dictation row with this id still exists — used by `AppCoordinator.reprocess` to
    /// detect a source row deleted mid-flight (e.g. by Delete All while an LLM call was in
    /// flight). See PLAN.md step 5.
    func dictationExists(id: Int64) throws -> Bool {
        let stmt = try prepare("SELECT 1 FROM dictations WHERE id = ? LIMIT 1;")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, id)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    /// Runs `PRAGMA wal_checkpoint(TRUNCATE)` as a prepared statement and checks the result
    /// row's busy column (first column) — SQLite reports checkpoint-busy via the result row, not
    /// an exec error, so a plain `exec(...)` would silently ignore a failed truncate. See
    /// PLAN.md step 1.
    private func walCheckpointTruncate() throws {
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

    /// Reads back `PRAGMA secure_delete` (0/1) — exercised by SelfCheck to confirm the on-open
    /// pragma in `init` actually took effect.
    func secureDeleteStatus() throws -> Int32 {
        let stmt = try prepare("PRAGMA secure_delete;")
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            throw DatabaseError.sqlFailed(lastError())
        }
        return sqlite3_column_int(stmt, 0)
    }

    // MARK: - Reads

    /// All dictations, reverse-chronological. `id DESC` breaks ties when two rows share a `ts`
    /// (e.g. inserted within the same clock tick) — id is the monotonic tiebreaker.
    func allDictations() throws -> [Dictation] {
        let sql = "SELECT id, ts, language, template, transcript, refined, engine, source_id FROM dictations ORDER BY ts DESC, id DESC;"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        return try readAll(stmt)
    }

    /// The most recently inserted Dictation, or nil if the Library is empty. `id` (not `ts`) is
    /// the monotonic tiebreaker on equal timestamps — shared reasoning with `allDictations()`'s
    /// ordering. Used by the Redo Last hotkey (`AppCoordinator.redoLast()` via `LibraryStore`) to
    /// fetch straight from the DB, immune to the Library window's search-text filter. See
    /// CONTEXT.md "Redo Last".
    func latestDictation() throws -> Dictation? {
        let sql = "SELECT id, ts, language, template, transcript, refined, engine, source_id FROM dictations ORDER BY id DESC LIMIT 1;"
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
        SELECT d.id, d.ts, d.language, d.template, d.transcript, d.refined, d.engine, d.source_id
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
        SELECT id, ts, language, template, transcript, refined, engine, source_id FROM dictations
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

    private func readAll(_ stmt: OpaquePointer?) throws -> [Dictation] {
        var results: [Dictation] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let ts = sqlite3_column_double(stmt, 1)
            let language = columnText(stmt, 2)
            let template = columnText(stmt, 3)
            let transcript = columnText(stmt, 4)
            let refined = columnText(stmt, 5)
            let engine = columnText(stmt, 6)
            let sourceID: Int64? = sqlite3_column_type(stmt, 7) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 7)
            results.append(Dictation(
                id: id,
                timestamp: Date(timeIntervalSince1970: ts),
                language: language,
                templateName: template,
                transcript: transcript,
                refined: refined,
                engine: engine,
                sourceID: sourceID
            ))
        }
        return results
    }

    // MARK: - Helpers

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.sqlFailed(lastError())
        }
        return stmt
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
