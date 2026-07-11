import CSQLite
import Foundation
import Testing
@testable import FreeTalker

@Suite struct SnippetStoreTests {
    @Test func normalizesUnicodePunctuationAndWhitespace() {
        #expect(SnippetStore.normalizeTrigger("  …STRA\u{00DF}E\n\tBitte!!! ") == "strasse bitte")
        #expect(SnippetStore.normalizeTrigger("¿Qué tal?") == "qué tal")
        #expect(SnippetStore.normalizeTrigger("CAF\u{00C9}") == SnippetStore.normalizeTrigger("CAFE\u{0301}"))
    }

    @Test func composedAndDecomposedTriggersConflictAndMatchBothDirections() async throws {
        let store = try SnippetStore(databaseURL: temporaryDatabaseURL())
        let snippet = try await store.create(name: "Coffee", triggers: ["caf\u{00E9}"], expansion: "coffee")
        #expect(try await store.match("cafe\u{0301}") == .match(snippet))
        await #expect(throws: SnippetStoreError.duplicateTrigger("caf\u{00E9}")) {
            try await store.create(name: "Other", triggers: ["cafe\u{0301}"], expansion: "other")
        }
    }

    @Test func deletingMissingSnippetThrowsNotFound() async throws {
        let store = try SnippetStore(databaseURL: temporaryDatabaseURL())
        await #expect(throws: SnippetStoreError.notFound) { try await store.delete(id: "missing") }
    }

    @Test func createsReadsUpdatesAndDeletesSnippet() async throws {
        let url = temporaryDatabaseURL()
        let store = try SnippetStore(databaseURL: url)
        let created = try await store.create(
            name: "Reply", triggers: ["BRB", "be right back"], expansion: "Back soon"
        )

        let loaded = try await store.snippet(id: created.id)
        #expect(loaded == created)
        #expect(try await store.match("… brb!") == .match(created))

        let updated = try await store.update(
            id: created.id, name: "Reply later", triggers: ["later"], expansion: "I will reply later"
        )
        #expect(try await store.match("brb") == .none)
        #expect(try await store.match("LATER.") == .match(updated))

        try await store.delete(id: created.id)
        #expect(try await store.snippets().isEmpty)
    }

    @Test func rejectsEmptyAndDuplicateNormalizedTriggersWithoutPartialWrite() async throws {
        let store = try SnippetStore(databaseURL: temporaryDatabaseURL())
        _ = try await store.create(name: "First", triggers: ["Hello!"], expansion: "one")

        await #expect(throws: SnippetStoreError.emptyTrigger) {
            try await store.create(name: "Empty", triggers: ["..."], expansion: "no")
        }
        await #expect(throws: SnippetStoreError.emptyTrigger) {
            try await store.create(name: "Missing", triggers: [], expansion: "no")
        }
        await #expect(throws: SnippetStoreError.duplicateTrigger("hello")) {
            try await store.create(name: "Second", triggers: ["  HELLO  "], expansion: "two")
        }
        #expect(try await store.snippets().count == 1)
    }

    @Test func reportsAmbiguousNormalizedLegacyTriggers() async throws {
        let url = temporaryDatabaseURL()
        try createLegacyDatabase(at: url, triggers: ["Hello", "HELLO!"])
        let store = try SnippetStore(databaseURL: url)

        guard case .ambiguous(let snippets) = try await store.match(" hello ") else {
            Issue.record("Expected ambiguous legacy match")
            return
        }
        #expect(Set(snippets.map(\.name)) == ["Hello", "HELLO!"])
    }

    @Test func twoConnectionsCannotCommitSameNormalizedTrigger() async throws {
        let url = temporaryDatabaseURL()
        let first = try SnippetStore(databaseURL: url)
        let second = try SnippetStore(databaseURL: url)

        async let a = attemptCreate(first, name: "A", trigger: "Ship it!")
        async let b = attemptCreate(second, name: "B", trigger: " SHIP IT ")
        let results = await [a, b]

        #expect(results.filter { if case .success = $0 { true } else { false } }.count == 1)
        #expect(try await first.snippets().count == 1)
    }

    @Test func concurrentDeleteWinsBeforeUpdateWithoutLeavingOrphanTriggers() async throws {
        let url = temporaryDatabaseURL()
        let seed = try SnippetStore(databaseURL: url)
        let snippet = try await seed.create(name: "Race", triggers: ["race"], expansion: "old")
        let gate = TransactionGate()
        let deleting = try SnippetStore(databaseURL: url) {
            gate.notifyAndWait()
        }
        let updating = try SnippetStore(databaseURL: url)

        async let deleteResult = attemptDelete(deleting, id: snippet.id)
        await gate.waitUntilBegan()
        async let updateResult = attemptUpdate(updating, id: snippet.id)
        gate.release()
        let results = await (deleteResult, updateResult)

        #expect(results.0 == nil)
        #expect(results.1 == .notFound)
        #expect(try sqliteCount(url, "SELECT COUNT(*) FROM snippet_triggers;") == 0)
    }
}

private final class TransactionGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var began = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    func notifyAndWait() {
        condition.lock()
        began = true
        continuation?.resume()
        continuation = nil
        while !released { condition.wait() }
        condition.unlock()
    }

    func waitUntilBegan() async {
        await withCheckedContinuation { continuation in
            condition.lock()
            if began { continuation.resume() } else { self.continuation = continuation }
            condition.unlock()
        }
    }

    func release() {
        condition.lock()
        released = true
        condition.signal()
        condition.unlock()
    }
}

private func attemptDelete(_ store: SnippetStore, id: String) async -> SnippetStoreError? {
    do { try await store.delete(id: id); return nil }
    catch { return error as? SnippetStoreError }
}

private func attemptUpdate(_ store: SnippetStore, id: String) async -> SnippetStoreError? {
    do {
        _ = try await store.update(id: id, name: "Updated", triggers: ["updated"], expansion: "new")
        return nil
    } catch { return error as? SnippetStoreError }
}

private func sqliteCount(_ url: URL, _ sql: String) throws -> Int {
    var handle: OpaquePointer?
    guard sqlite3_open(url.path, &handle) == SQLITE_OK, let handle else { throw DatabaseError.openFailed("test") }
    defer { sqlite3_close(handle) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw DatabaseError.sqlFailed("test") }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { throw DatabaseError.sqlFailed("test") }
    return Int(sqlite3_column_int(statement, 0))
}

private func attemptCreate(_ store: SnippetStore, name: String, trigger: String) async -> Result<Snippet, Error> {
    do {
        return .success(try await store.create(name: name, triggers: [trigger], expansion: name))
    } catch {
        return .failure(error)
    }
}

private func temporaryDatabaseURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("sqlite")
}

private func createLegacyDatabase(at url: URL, triggers: [String]) throws {
    var handle: OpaquePointer?
    guard sqlite3_open(url.path, &handle) == SQLITE_OK, let handle else {
        throw DatabaseError.openFailed("legacy test database")
    }
    defer { sqlite3_close(handle) }
    var error: UnsafeMutablePointer<CChar>?
    let sql = """
    CREATE TABLE schema_migrations (version INTEGER PRIMARY KEY, applied_at REAL NOT NULL DEFAULT (unixepoch()));
    INSERT INTO schema_migrations(version) VALUES (1),(2),(3),(4);
    CREATE TABLE transcription_jobs (id TEXT PRIMARY KEY);
    CREATE TABLE snippets (id TEXT PRIMARY KEY, trigger TEXT NOT NULL UNIQUE, replacement TEXT NOT NULL, created_at REAL NOT NULL, updated_at REAL NOT NULL);
    """ + triggers.enumerated().map {
        "INSERT INTO snippets VALUES ('\($0.offset)', '\($0.element)', 'value \($0.offset)', 100, 100);"
    }.joined()
    guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
        let message = error.map { String(cString: $0) } ?? "legacy setup failed"
        sqlite3_free(error)
        throw DatabaseError.sqlFailed(message)
    }
}
