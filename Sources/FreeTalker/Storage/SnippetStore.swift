import CSQLite
import Foundation

actor SnippetStore {
    private let connection: SQLiteSnippetConnection
    private var handle: OpaquePointer { connection.handle }
    private let transactionDidBegin: @Sendable () -> Void

    init(databaseURL: URL, transactionDidBegin: @escaping @Sendable () -> Void = {}) throws {
        var database: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "Could not open database"
            sqlite3_close(database)
            throw DatabaseError.openFailed(message)
        }
        sqlite3_busy_timeout(database, 5_000)
        do {
            try Self.execute(database, "PRAGMA foreign_keys=ON;")
            try DatabaseMigrator.migrate(database)
            guard try Self.foreignKeysEnabled(database) else {
                throw DatabaseError.sqlFailed("SQLite foreign key enforcement could not be enabled")
            }
        } catch {
            sqlite3_close(database)
            throw error
        }
        connection = SQLiteSnippetConnection(handle: database)
        self.transactionDidBegin = transactionDidBegin
    }

    nonisolated static func normalizeTrigger(_ trigger: String) -> String {
        TriggerNormalizer.normalize(trigger)
    }

    private static func execute(_ database: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw DatabaseError.sqlFailed(String(cString: sqlite3_errmsg(database)))
        }
    }

    private static func foreignKeysEnabled(_ database: OpaquePointer) throws -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA foreign_keys;", -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.sqlFailed(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw DatabaseError.sqlFailed(String(cString: sqlite3_errmsg(database)))
        }
        return sqlite3_column_int(statement, 0) == 1
    }

    func create(name: String, triggers: [String], expansion: String, now: Date = Date()) throws -> Snippet {
        let snippet = Snippet(
            id: UUID().uuidString, name: name, triggers: triggers, expansion: expansion,
            createdAt: now, updatedAt: now
        )
        try write(snippet, replacing: nil)
        guard let stored = try self.snippet(id: snippet.id) else { throw SnippetStoreError.notFound }
        return stored
    }

    func update(
        id: String, name: String, triggers: [String], expansion: String, now: Date = Date()
    ) throws -> Snippet {
        let normalized = try validatedTriggers(triggers)
        try transaction {
            guard let existing = try snippet(id: id) else { throw SnippetStoreError.notFound }
            let snippet = Snippet(
                id: id, name: name, triggers: triggers, expansion: expansion,
                createdAt: existing.createdAt, updatedAt: now
            )
            try writeBody(snippet, replacing: id, normalized: normalized)
        }
        guard let stored = try self.snippet(id: id) else { throw SnippetStoreError.notFound }
        return stored
    }

    func delete(id: String) throws {
        try transaction {
            try execute("DELETE FROM snippets WHERE id = ?;", bindings: [.text(id)])
            guard sqlite3_changes(handle) == 1 else { throw SnippetStoreError.notFound }
        }
    }

    func snippet(id: String) throws -> Snippet? {
        try snippets(whereClause: "WHERE s.id = ?", bindings: [.text(id)]).first
    }

    func snippets() throws -> [Snippet] {
        try snippets(whereClause: "", bindings: [])
    }

    func match(_ trigger: String) throws -> SnippetMatch {
        let normalized = Self.normalizeTrigger(trigger)
        guard !normalized.isEmpty else { return .none }
        let matches = try snippets(
            whereClause: "WHERE s.id IN (SELECT snippet_id FROM snippet_triggers WHERE normalized_trigger = ?)",
            bindings: [.text(normalized)]
        )
        switch matches.count {
        case 0: return .none
        case 1: return .match(matches[0])
        default: return .ambiguous(matches)
        }
    }

    private func write(_ snippet: Snippet, replacing id: String?) throws {
        let normalized = try validatedTriggers(snippet.triggers)
        try transaction {
            try writeBody(snippet, replacing: id, normalized: normalized)
        }
    }

    private func writeBody(_ snippet: Snippet, replacing id: String?, normalized: [String]) throws {
        for value in normalized {
            if try scalarInt(
                "SELECT COUNT(*) FROM snippet_triggers WHERE normalized_trigger = ? AND snippet_id != ?;",
                bindings: [.text(value), .text(id ?? snippet.id)]
            ) > 0 {
                throw SnippetStoreError.duplicateTrigger(value)
            }
        }
        if try scalarInt(
            "SELECT COUNT(*) FROM snippets WHERE name = ? AND id != ?;",
            bindings: [.text(snippet.name), .text(id ?? snippet.id)]
        ) > 0 {
            throw SnippetStoreError.duplicateName
        }

        if id == nil {
            try execute(
                "INSERT INTO snippets (id, name, replacement, created_at, updated_at) VALUES (?, ?, ?, ?, ?);",
                bindings: [.text(snippet.id), .text(snippet.name), .text(snippet.expansion),
                           .double(snippet.createdAt.timeIntervalSince1970), .double(snippet.updatedAt.timeIntervalSince1970)]
            )
        } else {
            try execute(
                "UPDATE snippets SET name = ?, replacement = ?, updated_at = ? WHERE id = ?;",
                bindings: [.text(snippet.name), .text(snippet.expansion),
                           .double(snippet.updatedAt.timeIntervalSince1970), .text(snippet.id)]
            )
            guard sqlite3_changes(handle) == 1 else { throw SnippetStoreError.notFound }
            try execute("DELETE FROM snippet_triggers WHERE snippet_id = ?;", bindings: [.text(snippet.id)])
        }
        for (trigger, normalizedTrigger) in zip(snippet.triggers, normalized) {
            try execute(
                "INSERT INTO snippet_triggers (snippet_id, trigger, normalized_trigger, is_legacy) VALUES (?, ?, ?, 0);",
                bindings: [.text(snippet.id), .text(trigger), .text(normalizedTrigger)]
            )
        }
    }

    private func validatedTriggers(_ triggers: [String]) throws -> [String] {
        guard !triggers.isEmpty else { throw SnippetStoreError.emptyTrigger }
        var seen = Set<String>()
        return try triggers.map {
            let normalized = Self.normalizeTrigger($0)
            guard !normalized.isEmpty else { throw SnippetStoreError.emptyTrigger }
            guard seen.insert(normalized).inserted else {
                throw SnippetStoreError.duplicateTrigger(normalized)
            }
            return normalized
        }
    }

    private func snippets(whereClause: String, bindings: [SQLiteSnippetValue]) throws -> [Snippet] {
        let statement = try prepare("""
        SELECT s.id, s.name, s.replacement, s.created_at, s.updated_at,
               t.trigger
        FROM snippets s LEFT JOIN snippet_triggers t ON t.snippet_id = s.id
        \(whereClause)
        ORDER BY s.created_at, s.id, t.rowid;
        """)
        defer { sqlite3_finalize(statement) }
        bind(bindings, to: statement)
        var snippets: [Snippet] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            let id = text(statement, 0)
            let trigger = text(statement, 5)
            if snippets.last?.id == id {
                snippets[snippets.count - 1].triggers.append(trigger)
            } else {
                snippets.append(Snippet(
                    id: id, name: text(statement, 1), triggers: [trigger], expansion: text(statement, 2),
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                    updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))
                ))
            }
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw sqlError() }
        return snippets
    }

    private func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE;")
        transactionDidBegin()
        do {
            try body()
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    private func scalarInt(_ sql: String, bindings: [SQLiteSnippetValue]) throws -> Int {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        bind(bindings, to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { throw sqlError() }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func execute(_ sql: String, bindings: [SQLiteSnippetValue] = []) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        bind(bindings, to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw sqlError() }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw sqlError()
        }
        return statement
    }

    private func bind(_ values: [SQLiteSnippetValue], to statement: OpaquePointer) {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .text(let text): sqlite3_bind_text(statement, index, text, -1, Self.sqliteTransient)
            case .double(let double): sqlite3_bind_double(statement, index, double)
            }
        }
    }

    private func text(_ statement: OpaquePointer, _ index: Int32) -> String {
        guard let value = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: value)
    }

    private func sqlError() -> DatabaseError {
        .sqlFailed(String(cString: sqlite3_errmsg(handle)))
    }

    fileprivate static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}

private enum SQLiteSnippetValue {
    case text(String)
    case double(Double)
}

private final class SQLiteSnippetConnection: @unchecked Sendable {
    let handle: OpaquePointer
    init(handle: OpaquePointer) { self.handle = handle }
    deinit { sqlite3_close(handle) }
}
