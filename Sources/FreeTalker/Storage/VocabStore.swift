import CSQLite
import Foundation
import os

/// One evidence sighting: a dictation whose refined output contained an anchored local
/// substitution correction of `normalizedTerm`, spelled `surfaceTerm` in that dictation. See
/// `VocabularyMiner`.
struct VocabEvidenceCandidate: Equatable, Sendable {
    let normalizedTerm: String
    let surfaceTerm: String
}

/// A term recurring in evidence with no explicit decision yet — what Settings shows in the
/// suggestions list. `surfaceTerm` is already tie-broken (highest frequency, then most recent —
/// PLAN.md PR B, item 2) across every evidence row sharing `normalizedTerm`.
struct VocabSuggestion: Equatable, Sendable {
    let normalizedTerm: String
    let surfaceTerm: String
    let recurrence: Int
    let mostRecentSeenAt: Date
}

enum VocabDecisionStatus: String, Sendable, Codable {
    case approved
    case dismissed
}

/// An explicit approve/dismiss decision — the only thing `vocab_decisions` ever stores. See
/// PLAN.md PR B, item 2 ("suggested" is never stored, it's derived from evidence). `Codable` for
/// Backup Bundle export/restore (PLAN.md PR B, item 2c) — same auto-synthesized `Date` encoding
/// `Template`/`Snippet` already use via `JSONEncoder`/`JSONDecoder` there.
struct VocabDecision: Equatable, Sendable, Codable {
    let normalizedTerm: String
    let status: VocabDecisionStatus
    /// Always non-nil when `status == .approved` (mirrors the table's own CHECK constraint); nil
    /// for `.dismissed`.
    let surfaceTerm: String?
    let decidedAt: Date
}

/// An approved term ready to feed `EffectiveVocabulary` — `surfaceTerm` is guaranteed non-nil
/// (unlike the general `VocabDecision`), and results are always ordered oldest-`decidedAt`-first,
/// matching the derivation order in PLAN.md PR B, item 2b/5.
struct ApprovedVocabularyTerm: Equatable, Sendable {
    let normalizedTerm: String
    let surfaceTerm: String
    let decidedAt: Date
}

enum VocabStoreError: Error, Equatable {
    case noEvidence(String)
}

/// Dedicated store actor for the self-learning vocabulary feature (PLAN.md PR B, item 2) — the
/// ONE owner of all `vocab_evidence`/`vocab_decisions` reads and writes, on its own serialized
/// connection to the Library database (same file as `Database`/`LibraryStore`, a separate
/// connection — WAL mode makes concurrent connections to one file safe, same pattern as
/// `SnippetStore`/`TranscriptionJobStore` sharing the jobs database with a dedicated read actor).
/// Every write here is a single self-contained SQL statement/transaction; nothing here ever
/// blocks on another store's connection, so a scan racing a `LibraryStore` deletion resolves via
/// SQLite's own foreign-key enforcement (see `recordEvidence`), not cross-store coordination.
actor VocabStore {
    /// Non-content logging only (PLAN.md PR B, item 8) — dictation ids and outcome counts, never
    /// transcript text or mined terms.
    private static let logger = Logger(subsystem: "org.freetalker.app", category: "vocabulary-suggestions")

    private let connection: SQLiteVocabConnection
    private var handle: OpaquePointer { connection.handle }

    /// Anchored local substitutions require at least this many DISTINCT dictations before a term
    /// is surfaced as a suggestion — a single occurrence is too weak a signal to distinguish a
    /// genuine recurring correction from a one-off rewrite. Tunable (PLAN.md "Risks"); the
    /// approval gate is the real safety net either way.
    static let minimumRecurrence = 2
    /// Matches the Settings UI's visible cap (PLAN.md PR B, item 6).
    static let maxVisibleSuggestions = 25
    /// Mirrors the miner's own per-dictation cap (PLAN.md PR B, item 1) — belt-and-suspenders so
    /// a caller bypassing the miner can't write an unbounded batch in one call.
    static let maxCandidatesPerDictation = 10

    /// The `vocab_evidence` surface-spelling tie-break — highest frequency, then most recent, then
    /// surface spelling ascending (full determinism, never SQLite's unspecified row order among
    /// ties) — shared, textually, by `suggestions()`'s correlated subquery and
    /// `canonicalSurfaceTerm(normalizedTerm:)`'s standalone query, so this really is the one place
    /// it lives, not two copies kept in sync by hand. See PLAN.md PR B, item 2/6, Codex round 1
    /// minor finding (`VocabStore.swift:149`).
    private static let surfaceTermTieBreakOrder = "GROUP BY surface_term ORDER BY COUNT(*) DESC, MAX(first_seen) DESC, surface_term ASC LIMIT 1"

    init(databaseURL: URL = FreeTalkerPaths.libraryDatabase) throws {
        try DatabasePrivacy.prepare(url: databaseURL)
        var database: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "Could not open database"
            sqlite3_close(database)
            throw DatabaseError.openFailed(message)
        }
        sqlite3_busy_timeout(database, 5_000)
        do {
            try DatabasePrivacy.secureOpenedDatabase(database, url: databaseURL)
            try Self.execute(database, "PRAGMA foreign_keys=ON;")
            try DatabaseMigrator.migrate(database, role: .library)
        } catch {
            sqlite3_close(database)
            throw error
        }
        connection = SQLiteVocabConnection(handle: database)
    }

    // MARK: - Evidence (mining writes)

    /// Idempotent PK upsert (`ON CONFLICT DO NOTHING`) — re-mining the same dictation never
    /// changes `first_seen` or duplicates a row. A dictation deleted concurrently with a scan (the
    /// row this evidence would FK to no longer exists) fails the `FOREIGN KEY` check inside this
    /// transaction; that failure is a BENIGN SKIP — caught here and swallowed, never surfaced as
    /// an error — since the row's own deletion already retracted any evidence that used to exist
    /// for it. See PLAN.md PR B, item 2.
    func recordEvidence(dictationID: Int64, candidates: [VocabEvidenceCandidate], now: Date = Date()) throws {
        let bounded = Array(candidates.prefix(Self.maxCandidatesPerDictation))
        guard !bounded.isEmpty else { return }
        do {
            try transaction {
                for candidate in bounded {
                    try execute(
                        """
                        INSERT INTO vocab_evidence (dictation_id, normalized_term, surface_term, first_seen)
                        VALUES (?, ?, ?, ?)
                        ON CONFLICT(dictation_id, normalized_term) DO NOTHING;
                        """,
                        bindings: [.int64(dictationID), .text(candidate.normalizedTerm),
                                   .text(candidate.surfaceTerm), .double(now.timeIntervalSince1970)]
                    )
                }
            }
        } catch let error as DatabaseError {
            guard Self.isForeignKeyFailure(error) else { throw error }
            Self.logger.notice("vocabulary evidence skipped (dictation \(dictationID, privacy: .public) no longer exists — benign scan/delete race)")
        }
    }

    private static func isForeignKeyFailure(_ error: DatabaseError) -> Bool {
        guard case .sqlFailed(let message) = error else { return false }
        return message.localizedCaseInsensitiveContains("FOREIGN KEY constraint failed")
    }

    // MARK: - Suggestions (derived, never stored)

    /// Terms recurring in evidence with no decision row yet, ranked by recurrence then recency,
    /// capped at `maxVisibleSuggestions`. `surfaceTerm` is tie-broken per normalized term by
    /// highest per-spelling frequency, then most recent `first_seen`, then — when frequency AND
    /// recency are BOTH equal — the surface spelling itself ascending, so the choice is fully
    /// deterministic rather than falling back to SQLite's unspecified row order among ties.
    /// Computed in SQL so the tie-break logic lives in exactly one place. See PLAN.md PR B, item
    /// 2/6, Codex round 1 minor finding (`VocabStore.swift:149`).
    func suggestions(minimumRecurrence: Int = VocabStore.minimumRecurrence, limit: Int = VocabStore.maxVisibleSuggestions) throws -> [VocabSuggestion] {
        let statement = try prepare("""
        SELECT ve.normalized_term,
               (SELECT surface_term FROM vocab_evidence
                WHERE normalized_term = ve.normalized_term
                \(Self.surfaceTermTieBreakOrder)) AS canonical_surface_term,
               COUNT(DISTINCT ve.dictation_id) AS recurrence,
               MAX(ve.first_seen) AS most_recent
        FROM vocab_evidence ve
        WHERE NOT EXISTS (SELECT 1 FROM vocab_decisions vd WHERE vd.normalized_term = ve.normalized_term)
        GROUP BY ve.normalized_term
        HAVING COUNT(DISTINCT ve.dictation_id) >= ?
        ORDER BY recurrence DESC, most_recent DESC
        LIMIT ?;
        """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(minimumRecurrence))
        sqlite3_bind_int(statement, 2, Int32(limit))
        var results: [VocabSuggestion] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            results.append(VocabSuggestion(
                normalizedTerm: text(statement, 0),
                surfaceTerm: text(statement, 1),
                recurrence: Int(sqlite3_column_int64(statement, 2)),
                mostRecentSeenAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
            ))
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw sqlError() }
        return results
    }

    /// The evidence-derived canonical surface spelling for `normalizedTerm` (see `suggestions`'
    /// tie-break, including the final `surface_term ASC` determinism tie-break), or nil when no
    /// evidence exists — used by `approve` to fix the spelling at approval time from whatever
    /// evidence currently exists, per PLAN.md PR B, item 2.
    private func canonicalSurfaceTerm(normalizedTerm: String) throws -> String? {
        let statement = try prepare("""
        SELECT surface_term FROM vocab_evidence
        WHERE normalized_term = ?
        \(Self.surfaceTermTieBreakOrder);
        """)
        defer { sqlite3_finalize(statement) }
        bind([.text(normalizedTerm)], to: statement)
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW else {
            guard result == SQLITE_DONE else { throw sqlError() }
            return nil
        }
        return text(statement, 0)
    }

    // MARK: - Decisions (explicit approve/dismiss)

    /// Fixes the canonical surface spelling from current evidence (see `canonicalSurfaceTerm`) and
    /// records an explicit `approved` decision — direct user action, always wins over whatever was
    /// there before (unlike `mergeDecisions`, which is timestamp-gated for restore). Throws
    /// `VocabStoreError.noEvidence` if the term has no evidence rows (e.g. a race with a
    /// concurrent Delete All) rather than approving a spelling that doesn't exist. The
    /// evidence-presence check and the decision upsert run in ONE `BEGIN IMMEDIATE` transaction —
    /// two separate autocommit statements would let `LibraryStore`'s Delete All (a different
    /// connection) delete the evidence this read just saw BETWEEN the read and the write, leaving
    /// a ghost `approved` decision for a term with no evidence backing it, contrary to the
    /// documented `noEvidence` race behavior. `BEGIN IMMEDIATE` takes the write lock up front, so
    /// the whole read+write is atomic with respect to any concurrent writer. See Codex round 1
    /// finding 9.
    @discardableResult
    func approve(normalizedTerm: String, now: Date = Date()) throws -> VocabDecision {
        try transaction {
            guard let surfaceTerm = try canonicalSurfaceTerm(normalizedTerm: normalizedTerm) else {
                throw VocabStoreError.noEvidence(normalizedTerm)
            }
            let decidedAt = try upsertDecision(normalizedTerm: normalizedTerm, status: .approved, surfaceTerm: surfaceTerm, decidedAt: now)
            return VocabDecision(normalizedTerm: normalizedTerm, status: .approved, surfaceTerm: surfaceTerm, decidedAt: decidedAt)
        }
    }

    /// Records an explicit `dismissed` decision — also the "evict a displaced approved term"
    /// action (PLAN.md PR B, item 2e): dismissing an already-approved term removes it from
    /// `approvedTerms()` the same way as dismissing a fresh suggestion.
    @discardableResult
    func dismiss(normalizedTerm: String, now: Date = Date()) throws -> VocabDecision {
        let decidedAt = try upsertDecision(normalizedTerm: normalizedTerm, status: .dismissed, surfaceTerm: nil, decidedAt: now)
        return VocabDecision(normalizedTerm: normalizedTerm, status: .dismissed, surfaceTerm: nil, decidedAt: decidedAt)
    }

    /// Direct user action (approve/dismiss) — unlike `mergeDecisions` (restore), which already
    /// correctly compares timestamps (`WHERE excluded.decided_at > vocab_decisions.decided_at`),
    /// this path previously overwrote `decided_at` unconditionally with whatever `now` the caller
    /// supplied, even if it was OLDER than what was already stored (system clock rolled back, or
    /// a prior restore landed a future-dated decision). That could move a term's effective
    /// timestamp backward, letting a LATER restore merge (which trusts `decided_at` as the
    /// ordering authority) accept a genuinely-superseded incoming decision as "newer" and
    /// resurrect it. `now` is always guaranteed to advance strictly past whatever is currently
    /// stored, so direct action always wins the ordering it's entitled to. See Codex round 1
    /// finding 10.
    @discardableResult
    private func upsertDecision(normalizedTerm: String, status: VocabDecisionStatus, surfaceTerm: String?, decidedAt: Date) throws -> Date {
        let resolved = Self.monotonicDecidedAt(requested: decidedAt, stored: try currentDecidedAt(normalizedTerm: normalizedTerm))
        try execute(
            """
            INSERT INTO vocab_decisions (normalized_term, status, surface_term, decided_at)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(normalized_term) DO UPDATE SET
                status = excluded.status, surface_term = excluded.surface_term, decided_at = excluded.decided_at;
            """,
            bindings: [.text(normalizedTerm), .text(status.rawValue),
                       surfaceTerm.map(SQLiteVocabValue.text) ?? .null, .double(resolved.timeIntervalSince1970)]
        )
        return resolved
    }

    /// `stored + epsilon`, or `requested` if that's already later — the simplest monotonic
    /// guard: a direct action's effective timestamp is always `max(requested, stored + epsilon)`,
    /// never merely `requested`. `epsilon` (1 microsecond) is far below any real clock-rollback or
    /// restore-skew scenario while keeping the resolved value indistinguishable from `requested`
    /// under normal (forward-moving clock) operation.
    nonisolated static func monotonicDecidedAt(requested: Date, stored: Date?) -> Date {
        guard let stored else { return requested }
        return max(requested, stored.addingTimeInterval(0.000_001))
    }

    private func currentDecidedAt(normalizedTerm: String) throws -> Date? {
        let statement = try prepare("SELECT decided_at FROM vocab_decisions WHERE normalized_term = ?;")
        defer { sqlite3_finalize(statement) }
        bind([.text(normalizedTerm)], to: statement)
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW else {
            guard result == SQLITE_DONE else { throw sqlError() }
            return nil
        }
        return Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
    }

    /// Every decision, unfiltered — used by Backup Bundle export. See PLAN.md PR B, item 2c.
    func decisions() throws -> [VocabDecision] {
        let statement = try prepare("SELECT normalized_term, status, surface_term, decided_at FROM vocab_decisions ORDER BY normalized_term;")
        defer { sqlite3_finalize(statement) }
        var results: [VocabDecision] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            guard let status = VocabDecisionStatus(rawValue: text(statement, 1)) else {
                throw DatabaseError.sqlFailed("Invalid vocab_decisions.status in Library database")
            }
            results.append(VocabDecision(
                normalizedTerm: text(statement, 0), status: status,
                surfaceTerm: optionalText(statement, 2),
                decidedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
            ))
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw sqlError() }
        return results
    }

    /// Approved terms only, oldest-`decidedAt`-first — the exact order `EffectiveVocabulary`
    /// appends after user-entered terms (PLAN.md PR B, item 2b/5): once a term is approved, it
    /// already provably fit the budget at that point in time, so an approval made earlier keeps
    /// priority over one made later if a subsequent manual edit tightens the budget.
    func approvedTerms() throws -> [ApprovedVocabularyTerm] {
        let statement = try prepare("""
        SELECT normalized_term, surface_term, decided_at FROM vocab_decisions
        WHERE status = 'approved'
        ORDER BY decided_at ASC, normalized_term ASC;
        """)
        defer { sqlite3_finalize(statement) }
        var results: [ApprovedVocabularyTerm] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            results.append(ApprovedVocabularyTerm(
                normalizedTerm: text(statement, 0),
                // CHECK(status != 'approved' OR surface_term IS NOT NULL) guarantees this.
                surfaceTerm: optionalText(statement, 1) ?? "",
                decidedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
            ))
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw sqlError() }
        return results
    }

    struct MergeResult: Equatable, Sendable {
        var merged = 0
        var skipped = 0
    }

    /// Backup Bundle restore (PLAN.md PR B, item 2c): merge-by-newer-`decidedAt` — an incoming
    /// decision replaces the stored one only if it's strictly newer; ties/older incoming rows are
    /// skipped, existing wins. No duplicates possible (PK upsert on `normalized_term`).
    func mergeDecisions(_ incoming: [VocabDecision]) throws -> MergeResult {
        var outcome = MergeResult()
        try transaction {
            for decision in incoming {
                try execute(
                    """
                    INSERT INTO vocab_decisions (normalized_term, status, surface_term, decided_at)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(normalized_term) DO UPDATE SET
                        status = excluded.status, surface_term = excluded.surface_term, decided_at = excluded.decided_at
                    WHERE excluded.decided_at > vocab_decisions.decided_at;
                    """,
                    bindings: [.text(decision.normalizedTerm), .text(decision.status.rawValue),
                               decision.surfaceTerm.map(SQLiteVocabValue.text) ?? .null,
                               .double(decision.decidedAt.timeIntervalSince1970)]
                )
                if sqlite3_changes(handle) == 1 {
                    outcome.merged += 1
                } else {
                    outcome.skipped += 1
                }
            }
        }
        return outcome
    }

    // MARK: - SQL plumbing (mirrors SnippetStore)

    private static func execute(_ database: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw DatabaseError.sqlFailed(String(cString: sqlite3_errmsg(database)))
        }
    }

    @discardableResult
    private func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE;")
        do {
            let result = try body()
            try execute("COMMIT;")
            return result
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    private func execute(_ sql: String, bindings: [SQLiteVocabValue] = []) throws {
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

    private func bind(_ values: [SQLiteVocabValue], to statement: OpaquePointer) {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .text(let text): sqlite3_bind_text(statement, index, text, -1, Self.sqliteTransient)
            case .int64(let int64): sqlite3_bind_int64(statement, index, int64)
            case .double(let double): sqlite3_bind_double(statement, index, double)
            case .null: sqlite3_bind_null(statement, index)
            }
        }
    }

    private func text(_ statement: OpaquePointer, _ index: Int32) -> String {
        guard let value = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: value)
    }

    private func optionalText(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return text(statement, index)
    }

    private func sqlError() -> DatabaseError {
        .sqlFailed(String(cString: sqlite3_errmsg(handle)))
    }

    fileprivate static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}

private enum SQLiteVocabValue {
    case text(String)
    case int64(Int64)
    case double(Double)
    case null
}

private final class SQLiteVocabConnection: @unchecked Sendable {
    let handle: OpaquePointer
    init(handle: OpaquePointer) { self.handle = handle }
    deinit { sqlite3_close(handle) }
}
