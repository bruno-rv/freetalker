import CSQLite
import Foundation
import Testing
@testable import FreeTalker

@Suite struct VocabStoreTests {
    @Test func recordEvidenceIsIdempotentAcrossRepeatedScans() async throws {
        let url = temporaryDatabaseURL()
        let library = try Database(path: url)
        let id = try library.insertDictation(makeInsertRequest(transcript: "hello joao", refined: "hello João"))
        let store = try VocabStore(databaseURL: url)

        let candidate = VocabEvidenceCandidate(normalizedTerm: "joão", surfaceTerm: "João")
        try await store.recordEvidence(dictationID: id, candidates: [candidate])
        try await store.recordEvidence(dictationID: id, candidates: [candidate]) // re-scan, same row

        let suggestions = try await store.suggestions(minimumRecurrence: 1, limit: 25)
        #expect(suggestions.count == 1)
        #expect(suggestions.first?.recurrence == 1)
    }

    /// PLAN.md PR B, item 2: deleting a dictation retracts its evidence (and, once no other
    /// evidence meets the recurrence threshold, the derived suggestion) — but Delete All (every
    /// `dictations` row gone) leaves `vocab_decisions` completely untouched.
    @Test func cascadeDeleteRetractsSuggestionsWhileDecisionsSurviveDeleteAll() async throws {
        let url = temporaryDatabaseURL()
        let library = try Database(path: url)
        let id1 = try library.insertDictation(makeInsertRequest(transcript: "hello joao", refined: "hello João"))
        let id2 = try library.insertDictation(makeInsertRequest(transcript: "bye joao", refined: "bye João"))
        let store = try VocabStore(databaseURL: url)
        let candidate = VocabEvidenceCandidate(normalizedTerm: "joão", surfaceTerm: "João")
        try await store.recordEvidence(dictationID: id1, candidates: [candidate])
        try await store.recordEvidence(dictationID: id2, candidates: [candidate])
        #expect(try await store.suggestions(minimumRecurrence: 2, limit: 25).count == 1)

        try await store.approve(normalizedTerm: "joão")
        #expect(try await store.approvedTerms().map(\.normalizedTerm) == ["joão"])

        try library.deleteAllRows()

        #expect(try await store.suggestions(minimumRecurrence: 1, limit: 25).isEmpty)
        #expect(try await store.approvedTerms().map(\.normalizedTerm) == ["joão"])
    }

    /// PLAN.md PR B, item 2: a scan racing a concurrent deletion of the dictation it's mining is a
    /// BENIGN SKIP — `recordEvidence` must not throw, and must not record the orphaned evidence.
    @Test func scanVersusDeleteRaceIsABenignSkip() async throws {
        let url = temporaryDatabaseURL()
        let library = try Database(path: url)
        let id = try library.insertDictation(makeInsertRequest(transcript: "hello joao", refined: "hello João"))
        let store = try VocabStore(databaseURL: url)

        try library.deleteRow(id: id) // simulates the row vanishing between the scan's read and this write

        try await store.recordEvidence(dictationID: id, candidates: [VocabEvidenceCandidate(normalizedTerm: "joão", surfaceTerm: "João")])

        #expect(try await store.suggestions(minimumRecurrence: 1, limit: 25).isEmpty)
    }

    /// PLAN.md PR B, item 2: canonical surface spelling is tie-broken by highest frequency across
    /// evidence, then most recent `first_seen` — computed the same way `suggestions()` and
    /// `approve()` both use.
    @Test func surfaceTermTieBreaksByFrequencyThenRecency() async throws {
        let url = temporaryDatabaseURL()
        let library = try Database(path: url)
        let ids = try (0..<3).map { _ in try library.insertDictation(makeInsertRequest(transcript: "x", refined: "x")) }
        let store = try VocabStore(databaseURL: url)

        // "joao" spelled twice, "João" spelled once — higher frequency wins despite being older.
        try await store.recordEvidence(dictationID: ids[0], candidates: [.init(normalizedTerm: "joao", surfaceTerm: "joao")], now: Date(timeIntervalSince1970: 100))
        try await store.recordEvidence(dictationID: ids[1], candidates: [.init(normalizedTerm: "joao", surfaceTerm: "joao")], now: Date(timeIntervalSince1970: 200))
        try await store.recordEvidence(dictationID: ids[2], candidates: [.init(normalizedTerm: "joao", surfaceTerm: "João")], now: Date(timeIntervalSince1970: 300))

        let suggestion = try #require(try await store.suggestions(minimumRecurrence: 1, limit: 25).first)
        #expect(suggestion.surfaceTerm == "joao")

        let decision = try await store.approve(normalizedTerm: "joao")
        #expect(decision.surfaceTerm == "joao")
    }

    @Test func surfaceTermTieBreaksByRecencyWhenFrequencyIsEqual() async throws {
        let url = temporaryDatabaseURL()
        let library = try Database(path: url)
        let ids = try (0..<2).map { _ in try library.insertDictation(makeInsertRequest(transcript: "x", refined: "x")) }
        let store = try VocabStore(databaseURL: url)

        try await store.recordEvidence(dictationID: ids[0], candidates: [.init(normalizedTerm: "joao", surfaceTerm: "joao")], now: Date(timeIntervalSince1970: 100))
        try await store.recordEvidence(dictationID: ids[1], candidates: [.init(normalizedTerm: "joao", surfaceTerm: "João")], now: Date(timeIntervalSince1970: 300))

        let suggestion = try #require(try await store.suggestions(minimumRecurrence: 1, limit: 25).first)
        #expect(suggestion.surfaceTerm == "João")
    }

    /// When BOTH frequency and recency tie, the final tie-break is the surface spelling itself,
    /// ascending — deterministic rather than SQLite's unspecified order among equal rows. See
    /// Codex round 1 minor finding (`VocabStore.swift:149`).
    @Test func surfaceTermTieBreaksBySpellingWhenFrequencyAndRecencyAreBothEqual() async throws {
        let url = temporaryDatabaseURL()
        let library = try Database(path: url)
        let ids = try (0..<2).map { _ in try library.insertDictation(makeInsertRequest(transcript: "x", refined: "x")) }
        let store = try VocabStore(databaseURL: url)

        let sameInstant = Date(timeIntervalSince1970: 100)
        try await store.recordEvidence(dictationID: ids[0], candidates: [.init(normalizedTerm: "joao", surfaceTerm: "joão")], now: sameInstant)
        try await store.recordEvidence(dictationID: ids[1], candidates: [.init(normalizedTerm: "joao", surfaceTerm: "João")], now: sameInstant)

        let suggestion = try #require(try await store.suggestions(minimumRecurrence: 1, limit: 25).first)
        // "João" < "joão" under ordinary ASCII/codepoint ordering (uppercase sorts before lower).
        #expect(suggestion.surfaceTerm == "João")

        let decision = try await store.approve(normalizedTerm: "joao")
        #expect(decision.surfaceTerm == "João")
    }

    @Test func belowRecurrenceThresholdIsNotSuggested() async throws {
        let url = temporaryDatabaseURL()
        let library = try Database(path: url)
        let id = try library.insertDictation(makeInsertRequest(transcript: "x", refined: "x"))
        let store = try VocabStore(databaseURL: url)
        try await store.recordEvidence(dictationID: id, candidates: [.init(normalizedTerm: "joao", surfaceTerm: "João")])

        #expect(try await store.suggestions(minimumRecurrence: VocabStore.minimumRecurrence, limit: 25).isEmpty)
    }

    /// PLAN.md PR B, item 2 / Codex round 1 finding 9: the evidence-presence read and the
    /// decision insert must run in ONE `BEGIN IMMEDIATE` transaction — two separate autocommit
    /// statements would let a concurrent `LibraryStore` Delete All (a different connection)
    /// commit its delete of the evidence BETWEEN the read and the write, leaving a ghost
    /// `approved` decision for a term with no evidence. Deterministically reproduced by holding a
    /// competing write transaction open on a second raw connection to the SAME database file: it
    /// starts the delete but does not commit until AFTER `approve()` has already been asked to
    /// run. Without the fix, `approve()`'s SELECT (no write lock needed under WAL) would read the
    /// evidence BEFORE the held transaction's delete commits, then its separate INSERT would
    /// block on the write lock and land the ghost decision once the delete finally commits. With
    /// the fix, `approve()`'s own `BEGIN IMMEDIATE` cannot even start until the held transaction
    /// releases the lock — so by the time it runs, the delete has already committed, and its
    /// read correctly sees no evidence.
    @Test func approveAndAConcurrentEvidenceDeleteNeverRaceIntoAGhostDecision() async throws {
        let url = temporaryDatabaseURL()
        let library = try Database(path: url)
        let id = try library.insertDictation(makeInsertRequest(transcript: "hello joao", refined: "hello João"))
        let store = try VocabStore(databaseURL: url)
        try await store.recordEvidence(dictationID: id, candidates: [VocabEvidenceCandidate(normalizedTerm: "joão", surfaceTerm: "João")])

        let holder = try RawSQLiteHolder(path: url)
        try holder.beginImmediateAndDelete(dictationID: id) // delete started, NOT yet committed

        async let outcome: Result<VocabDecision, Error> = {
            do { return .success(try await store.approve(normalizedTerm: "joão")) }
            catch { return .failure(error) }
        }()

        // Give `approve()` a moment to actually attempt (and block on) its own transaction before
        // the held one commits — otherwise this test would pass trivially by accident of
        // scheduling rather than by exercising the lock.
        try await Task.sleep(nanoseconds: 150_000_000)
        holder.commit()

        let result = await outcome
        switch result {
        case .success:
            Issue.record("approve() must not succeed once the concurrent delete has committed")
        case .failure(let error):
            #expect(error as? VocabStoreError == .noEvidence("joão"))
        }
        #expect(try await store.decisions().isEmpty)
    }

    @Test func approveWithoutAnyEvidenceThrows() async throws {
        let store = try VocabStore(databaseURL: temporaryDatabaseURL())
        await #expect(throws: VocabStoreError.self) {
            try await store.approve(normalizedTerm: "ghost")
        }
    }

    /// PLAN.md PR B, item 2 / Codex round 1 finding 10: a direct dismiss/approve with an OLDER
    /// `now` than what's already stored (clock rollback, or a prior restore landed a future-dated
    /// decision) must not move `decided_at` backward — the resolved value is always strictly
    /// after the stored one, so a later restore merge's newer-wins comparison can never
    /// mistake this direct action for something that happened before it actually did.
    @Test func directDismissNeverMovesDecidedAtBackward() async throws {
        let store = try VocabStore(databaseURL: temporaryDatabaseURL())
        _ = try await store.mergeDecisions([
            VocabDecision(normalizedTerm: "joao", status: .approved, surfaceTerm: "João", decidedAt: Date(timeIntervalSince1970: 1_000))
        ])

        // Direct dismiss with a `now` OLDER than the stored decided_at (1_000).
        let decision = try await store.dismiss(normalizedTerm: "joao", now: Date(timeIntervalSince1970: 500))

        #expect(decision.decidedAt.timeIntervalSince1970 > 1_000)
        let stored = try await store.decisions().first
        #expect(stored?.status == .dismissed)
        #expect(stored?.decidedAt.timeIntervalSince1970 ?? 0 > 1_000)

        // A restore merge trying to apply an incoming decision timestamped BETWEEN the original
        // 1_000 and the direct dismiss's now-monotonic timestamp must NOT resurrect it — proves
        // the monotonic guard actually protects merge ordering, not just the stored value.
        let mergeResult = try await store.mergeDecisions([
            VocabDecision(normalizedTerm: "joao", status: .approved, surfaceTerm: "João", decidedAt: Date(timeIntervalSince1970: 750))
        ])
        #expect(mergeResult == VocabStore.MergeResult(merged: 0, skipped: 1))
        #expect(try await store.decisions().first?.status == .dismissed)
    }

    /// Pure decision function: no existing row → `requested` passes through unchanged.
    @Test func monotonicDecidedAtPassesThroughWhenNothingIsStored() {
        let requested = Date(timeIntervalSince1970: 42)
        #expect(VocabStore.monotonicDecidedAt(requested: requested, stored: nil) == requested)
    }

    /// Pure decision function: `requested` already newer than stored → unchanged (no needless
    /// forward-skew under normal, forward-moving-clock operation).
    @Test func monotonicDecidedAtPassesThroughWhenRequestedIsAlreadyNewer() {
        let requested = Date(timeIntervalSince1970: 200)
        let stored = Date(timeIntervalSince1970: 100)
        #expect(VocabStore.monotonicDecidedAt(requested: requested, stored: stored) == requested)
    }

    /// Pure decision function: `requested` older than or equal to stored → bumped strictly past
    /// `stored`, never merely equal to it (equal would still let a same-timestamp incoming merge
    /// be ambiguous under `mergeDecisions`' strict `>` comparison).
    @Test func monotonicDecidedAtAdvancesStrictlyPastStoredWhenRequestedIsOlderOrEqual() {
        let stored = Date(timeIntervalSince1970: 100)
        #expect(VocabStore.monotonicDecidedAt(requested: Date(timeIntervalSince1970: 50), stored: stored) > stored)
        #expect(VocabStore.monotonicDecidedAt(requested: stored, stored: stored) > stored)
    }

    @Test func dismissEvictsAnApprovedTerm() async throws {
        let url = temporaryDatabaseURL()
        let library = try Database(path: url)
        let id = try library.insertDictation(makeInsertRequest(transcript: "x", refined: "x"))
        let store = try VocabStore(databaseURL: url)
        try await store.recordEvidence(dictationID: id, candidates: [.init(normalizedTerm: "joao", surfaceTerm: "João")])
        try await store.approve(normalizedTerm: "joao")
        #expect(try await store.approvedTerms().count == 1)

        try await store.dismiss(normalizedTerm: "joao")

        #expect(try await store.approvedTerms().isEmpty)
        #expect(try await store.decisions().first?.status == .dismissed)
    }

    @Test func approvedTermsAreOrderedOldestDecidedAtFirst() async throws {
        let url = temporaryDatabaseURL()
        let library = try Database(path: url)
        let ids = try (0..<2).map { _ in try library.insertDictation(makeInsertRequest(transcript: "x", refined: "x")) }
        let store = try VocabStore(databaseURL: url)
        try await store.recordEvidence(dictationID: ids[0], candidates: [.init(normalizedTerm: "second", surfaceTerm: "second")])
        try await store.recordEvidence(dictationID: ids[1], candidates: [.init(normalizedTerm: "first", surfaceTerm: "first")])
        try await store.approve(normalizedTerm: "second", now: Date(timeIntervalSince1970: 200))
        try await store.approve(normalizedTerm: "first", now: Date(timeIntervalSince1970: 100))

        #expect(try await store.approvedTerms().map(\.normalizedTerm) == ["first", "second"])
    }

    // MARK: - Backup Bundle merge-by-newer (PLAN.md PR B, item 2c)

    @Test func mergeDecisionsKeepsExistingWhenIncomingIsOlder() async throws {
        let store = try VocabStore(databaseURL: temporaryDatabaseURL())
        _ = try await recordAndApprove(store, term: "joao", surfaceTerm: "João", at: 200)

        let result = try await store.mergeDecisions([
            VocabDecision(normalizedTerm: "joao", status: .dismissed, surfaceTerm: nil, decidedAt: Date(timeIntervalSince1970: 100))
        ])

        #expect(result == VocabStore.MergeResult(merged: 0, skipped: 1))
        #expect(try await store.decisions().first?.status == .approved)
    }

    @Test func mergeDecisionsReplacesExistingWhenIncomingIsNewer() async throws {
        let store = try VocabStore(databaseURL: temporaryDatabaseURL())
        _ = try await recordAndApprove(store, term: "joao", surfaceTerm: "João", at: 100)

        let result = try await store.mergeDecisions([
            VocabDecision(normalizedTerm: "joao", status: .dismissed, surfaceTerm: nil, decidedAt: Date(timeIntervalSince1970: 200))
        ])

        #expect(result == VocabStore.MergeResult(merged: 1, skipped: 0))
        #expect(try await store.decisions().first?.status == .dismissed)
    }

    @Test func mergeDecisionsInsertsABrandNewTerm() async throws {
        let store = try VocabStore(databaseURL: temporaryDatabaseURL())
        let result = try await store.mergeDecisions([
            VocabDecision(normalizedTerm: "brand-new", status: .approved, surfaceTerm: "Brand New", decidedAt: Date(timeIntervalSince1970: 1))
        ])
        #expect(result == VocabStore.MergeResult(merged: 1, skipped: 0))
        #expect(try await store.approvedTerms().map(\.surfaceTerm) == ["Brand New"])
    }

    // MARK: - Helpers

    /// Seeds an `approved` decision directly (via the same PK-upsert `mergeDecisions` write path
    /// as Backup Bundle restore) — these merge tests exercise `vocab_decisions` conflict
    /// resolution only, independent of evidence/`approve`'s surface-term derivation.
    private func recordAndApprove(_ store: VocabStore, term: String, surfaceTerm: String, at epoch: TimeInterval) async throws {
        _ = try await store.mergeDecisions([
            VocabDecision(normalizedTerm: term, status: .approved, surfaceTerm: surfaceTerm, decidedAt: Date(timeIntervalSince1970: epoch))
        ])
    }
}

private func makeInsertRequest(transcript: String, refined: String) -> DictationInsertRequest {
    .init(
        timestamp: Date(), sourceLanguage: SourceLanguage("en"),
        requestedOutputLanguage: .sameAsSpoken, template: "Clean",
        transcript: transcript, refined: refined, engine: "local",
        voiceCommandsActive: false
    )
}

private func temporaryDatabaseURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("sqlite")
}

/// A second, independent raw connection to a `VocabStore`'s database file — deliberately bypasses
/// `Database`/`VocabStore` to hold an uncommitted write transaction open across an `await`
/// boundary, simulating another connection (e.g. `LibraryStore`'s Delete All) mid-write. Test-only.
private final class RawSQLiteHolder: @unchecked Sendable {
    private var handle: OpaquePointer?

    init(path: URL) throws {
        guard sqlite3_open(path.path, &handle) == SQLITE_OK else {
            throw DatabaseError.sqlFailed("could not open raw test connection")
        }
        sqlite3_busy_timeout(handle, 5_000)
        // Must be set before BEGIN (SQLite forbids changing it mid-transaction) — without this,
        // this connection's own DELETE would NOT cascade into `vocab_evidence` (FK enforcement/
        // cascade actions are per-connection, not a schema-wide default), defeating the whole
        // point of this holder.
        sqlite3_exec(handle, "PRAGMA foreign_keys=ON;", nil, nil, nil)
    }

    func beginImmediateAndDelete(dictationID: Int64) throws {
        guard sqlite3_exec(handle, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK else {
            throw DatabaseError.sqlFailed("could not begin held transaction")
        }
        guard sqlite3_exec(handle, "DELETE FROM dictations WHERE id = \(dictationID);", nil, nil, nil) == SQLITE_OK else {
            throw DatabaseError.sqlFailed("could not delete within held transaction")
        }
    }

    func commit() {
        sqlite3_exec(handle, "COMMIT;", nil, nil, nil)
    }

    deinit {
        sqlite3_close(handle)
    }
}
