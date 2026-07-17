import AppKit
import Foundation
import Testing
@testable import FreeTalker

/// Dictation History Quick Panel (PLAN.md F3) coverage: FTS/LIKE escaping, SQL LIMIT, the
/// stale-result generation token, and the recording gate. Four-way hotkey validation is covered
/// alongside the rest of the hotkey suite in `VoiceEditTargetTests.fourHotkeysRejectEveryCollision`
/// and `BackupBundleTests`; this file adds one quartet-restore rejection case specific to the
/// fourth slot.
@MainActor
@Suite struct DictationHistoryPanelTests {
    // MARK: - FTS/LIKE escaping (pure query construction)

    @Test func ftsMatchExpressionDoublesEmbeddedQuotesAndAppendsPrefixStar() {
        // Embedded quotes doubled, whole query is one phrase literal, trailing `*` (OUTSIDE the
        // closing quote) makes the final token a prefix match for live as-you-type search.
        #expect(DictationSearchQuery.ftsMatchExpression(for: #"say "hello""#) == #""say ""hello"""*"#)
        #expect(DictationSearchQuery.ftsMatchExpression(for: "kuber") == #""kuber"*"#)
        // A `*` typed by the user stays INSIDE the phrase literal (a literal character), never
        // query syntax; the prefix `*` we append is the only one outside the quotes.
        #expect(DictationSearchQuery.ftsMatchExpression(for: "wild*card") == #""wild*card"*"#)
    }

    @Test func likePatternEscapesEscapeCharacterBeforePercentAndUnderscore() {
        // Escaping order matters: the escape character itself must be escaped FIRST, or a
        // literal backslash already in the query would corrupt a subsequently-escaped %/_.
        #expect(DictationSearchQuery.likePattern(for: "100%") == "%100\\%%")
        #expect(DictationSearchQuery.likePattern(for: "a_b") == "%a\\_b%")
        #expect(DictationSearchQuery.likePattern(for: "back\\slash") == "%back\\\\slash%")
        // A literal escape character immediately followed by a real "%" must not be
        // reinterpreted as an (already-escaped) wildcard once %/_ escaping runs afterward.
        #expect(DictationSearchQuery.likePattern(for: "\\%") == "%\\\\\\%%")
    }

    @Test func boundedClampsToMaxQueryBytesAtACharacterBoundary() {
        let raw = String(repeating: "a", count: DictationSearchQuery.maxQueryBytes + 50)
        let bounded = DictationSearchQuery.bounded(raw)
        #expect(bounded.utf8.count == DictationSearchQuery.maxQueryBytes)

        // Combining-mark-heavy input: the clamp must cut at a Character boundary, never split a
        // grapheme cluster mid-scalar.
        let combining = String(repeating: "e\u{0301}", count: DictationSearchQuery.maxQueryBytes) // "é" via combining acute
        let boundedCombining = DictationSearchQuery.bounded(combining)
        #expect(boundedCombining.utf8.count <= DictationSearchQuery.maxQueryBytes)
        #expect(String(boundedCombining.reversed()).utf8.count == boundedCombining.utf8.count) // valid UTF-8, round-trips
    }

    // MARK: - FTS/LIKE escaping + SQL LIMIT (integration, real SQLite)

    @Test func searchFindsQuotesPercentUnderscoreEscapeCharAndControlCharsWithoutSQLError() throws {
        let fixture = try SearchFixture()
        try fixture.insert(refined: #"She said "hello" to me"#)
        try fixture.insert(refined: "Discount is 100% off")
        try fixture.insert(refined: "file_name_here")
        try fixture.insert(refined: "a\\b backslash")
        try fixture.insert(refined: "control\u{0007}char bell")

        // FTS path: exact-phrase match on text containing an embedded quote.
        #expect(try fixture.db.search(query: #""hello""#, limit: 10).count == 1)
        // LIKE fallback path: FTS5 rejects bare "%"/"_" tokens as query syntax on some builds, so
        // these exercise the LIKE fallback and must not throw or silently return zero rows due to
        // a broken pattern.
        #expect(try fixture.db.search(query: "100%", limit: 10).contains { $0.refined.contains("100%") })
        #expect(try fixture.db.search(query: "file_name", limit: 10).contains { $0.refined.contains("file_name") })
        #expect(try fixture.db.search(query: "a\\b", limit: 10).contains { $0.refined.contains("a\\b") })
        // A control character in the query must not crash/throw — the search degrades to "no
        // match" or a literal-text match, never a SQL error. (An uncaught throw here fails the
        // test, since this function is itself `throws`.)
        _ = try fixture.db.search(query: "control\u{0007}char", limit: 10)
    }

    @Test func searchMatchesFinalTokenAsPrefixForLiveTyping() throws {
        let fixture = try SearchFixture()
        try fixture.insert(refined: "Deploying to Kubernetes today")
        // A partially-typed final word ("kuber") must match "Kubernetes" — the prefix `*` keeps
        // as-you-type search working through the shared FTS path (Library + panel both benefit).
        #expect(try fixture.db.search(query: "kuber", limit: 10).count == 1)
        // A `*` typed by the user never causes an FTS syntax error: it lives inside the phrase
        // literal (see ftsMatchExpression string test), so the query still runs cleanly.
        _ = try fixture.db.search(query: "kuber*", limit: 10)
    }

    @Test func searchLimitIsEnforcedInSQLNotJustTruncatedInSwift() throws {
        let fixture = try SearchFixture()
        for index in 0..<30 {
            try fixture.insert(refined: "shared searchable phrase \(index)")
        }

        let limited = try fixture.db.search(query: "searchable", limit: 5)
        #expect(limited.count == 5)

        let defaultList = try fixture.db.search(query: "", limit: HistoryPanelController.defaultListLimit)
        #expect(defaultList.count == HistoryPanelController.defaultListLimit)

        let unlimited = try fixture.db.search(query: "searchable", limit: nil)
        #expect(unlimited.count == 30)
    }

    // MARK: - Stale-result discard (generation token)

    @Test func staleResultIsDiscardedOnlyWhenGenerationMovedOn() {
        #expect(HistoryPanelController.isStaleResult(requestGeneration: 1, currentGeneration: 1) == false)
        #expect(HistoryPanelController.isStaleResult(requestGeneration: 1, currentGeneration: 2) == true)
        // A close() then a fresh open() bumps the generation twice — a result from the closed
        // session must still read as stale against the new one.
        #expect(HistoryPanelController.isStaleResult(requestGeneration: 1, currentGeneration: 3) == true)
    }

    // MARK: - Recording gate

    @Test func recordingGateBlocksOpenAndForcesCloseWhileActive() {
        #expect(HistoryPanelController.isBlockedByRecording(isRecording: false, isProcessing: false) == false)
        #expect(HistoryPanelController.isBlockedByRecording(isRecording: true, isProcessing: false) == true)
        #expect(HistoryPanelController.isBlockedByRecording(isRecording: false, isProcessing: true) == true)
        #expect(HistoryPanelController.isBlockedByRecording(isRecording: true, isProcessing: true) == true)
    }

    // MARK: - Row display text (refined-else-transcript)

    @Test func displayTextPrefersRefinedElseTranscript() {
        let withRefined = Dictation(
            id: 1, timestamp: Date(), sourceLanguage: SourceLanguage("en"),
            requestedOutputLanguage: .sameAsSpoken, templateName: "Clean",
            transcript: "raw text", refined: "refined text", engine: "local"
        )
        #expect(HistoryPanelRow.displayText(for: withRefined) == "refined text")

        let withoutRefined = Dictation(
            id: 2, timestamp: Date(), sourceLanguage: SourceLanguage("en"),
            requestedOutputLanguage: .sameAsSpoken, templateName: "Clean",
            transcript: "raw only", refined: "", engine: "local"
        )
        #expect(HistoryPanelRow.displayText(for: withoutRefined) == "raw only")
    }

    // MARK: - Stale cached row revalidated before insert (Codex finding: permanently-deleted row still inserted)

    @Test func shouldInsertRowOnlyWhenAffirmativelyConfirmedToStillExist() {
        #expect(HistoryPanelController.shouldInsertRow(exists: true) == true)
        #expect(HistoryPanelController.shouldInsertRow(exists: false) == false)
        // nil ("store unavailable, can't verify") refuses just like a confirmed-gone `false` —
        // never treated as "assume it's still there".
        #expect(HistoryPanelController.shouldInsertRow(exists: nil) == false)
    }

    @Test func libraryStoreExistsReflectsARowDeletedAfterThePanelCachedIt() throws {
        // Mirrors `selectRow`'s real revalidation call (`LibraryStore.shared.exists(id:)`)
        // against an isolated temporary store rather than the process-wide singleton — proves
        // the exact contract `selectRow` depends on: a row present when the panel's search ran,
        // then deleted (singly, or via Delete All) before the row is clicked, reads back as
        // `exists == false`, which `shouldInsertRow` refuses.
        let store = try LibraryStore.temporary()
        let id = try store.record(
            language: "en", template: "Clean", transcript: "raw", refined: "cached text", engine: "local"
        )
        #expect(store.exists(id: id) == true)
        #expect(HistoryPanelController.shouldInsertRow(exists: store.exists(id: id)) == true)

        try store.delete(id: id)

        #expect(store.exists(id: id) == false)
        #expect(HistoryPanelController.shouldInsertRow(exists: store.exists(id: id)) == false)
    }

    @Test func libraryStoreExistsReflectsDeleteAllOfACachedRow() throws {
        let store = try LibraryStore.temporary()
        let id = try store.record(
            language: "en", template: "Clean", transcript: "raw", refined: "cached text", engine: "local"
        )
        #expect(store.exists(id: id) == true)

        try store.deleteAll()

        #expect(HistoryPanelController.shouldInsertRow(exists: store.exists(id: id)) == false)
    }

    // MARK: - Menu-driven panel open refreshes a stale AX target (Codex finding: same-app focus drift)

    @Test func refreshedTargetReturnsNilWhenNoStaleTargetWasTracked() {
        #expect(AppCoordinator.refreshedTarget(stale: nil, refresh: { _ in fatalError("must not be called") }) == nil)
    }

    @Test func refreshedTargetFallsBackToTheStaleTargetWhenTheAppCanNoLongerBeRefreshed() {
        let stale = InsertionTarget(bundleID: "com.example.app", pid: 42, focusedElement: nil, window: nil)
        let result = AppCoordinator.refreshedTarget(stale: stale, refresh: { _ in nil })
        #expect(result?.bundleID == stale.bundleID)
        #expect(result?.pid == stale.pid)
    }

    @Test func refreshedTargetReturnsTheFreshlySnapshottedTargetWhenTheAppIsStillFound() {
        let stale = InsertionTarget(bundleID: "com.example.app", pid: 42, focusedElement: nil, window: nil)
        let fresh = InsertionTarget(bundleID: "com.example.app", pid: 42, focusedElement: nil, window: nil)
        var receivedStale: InsertionTarget?
        let result = AppCoordinator.refreshedTarget(stale: stale, refresh: { candidate in
            receivedStale = candidate
            return fresh
        })
        #expect(receivedStale?.pid == stale.pid)
        #expect(result?.bundleID == fresh.bundleID)
    }

    // MARK: - PID-reuse wrong-app menu-path target (Codex finding: refreshedTarget accepted ANY
    // process found at the tracked pid, so an OS-reused pid could resolve to an unrelated app)

    /// Finder is always running, non-sandboxed, on any macOS box this suite runs on — a stable
    /// real `NSRunningApplication` with a non-nil bundle id, unlike this test executable's own
    /// `NSRunningApplication.current` (whose `bundleIdentifier` is nil for a bare CLI binary).
    private static func requireFinder() throws -> NSRunningApplication {
        try #require(NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == "com.apple.finder" })
    }

    @Test func verifiedRunningApplicationRequiresTheAppsBundleIDToMatchTheTrackedOne() throws {
        let finder = try Self.requireFinder()
        #expect(AppCoordinator.verifiedRunningApplication(finder, matchesBundleID: "com.apple.finder"))
        // A pid that now resolves to a DIFFERENT app than the one originally tracked (the OS
        // reused the pid) must never be accepted as a legitimate refresh — its bundle id won't
        // match the tracked one.
        #expect(!AppCoordinator.verifiedRunningApplication(finder, matchesBundleID: "com.example.a-completely-different-app"))
    }

    @Test func verifiedRunningApplicationRejectsUnverifiableNilCases() throws {
        let finder = try Self.requireFinder()
        // No app found at the tracked pid at all (it quit) — unverifiable.
        #expect(!AppCoordinator.verifiedRunningApplication(nil, matchesBundleID: "com.apple.finder"))
        // A found app but no tracked bundle id to compare against — neither side of the
        // comparison is trustworthy on its own.
        #expect(!AppCoordinator.verifiedRunningApplication(finder, matchesBundleID: nil))
    }

    // MARK: - Fourth hotkey slot in the Backup Bundle quartet

    @Test func backupBundleRejectsHistoryPanelHotKeyCollidingWithSibling() async throws {
        let suite = "DictationHistoryPanelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let templatesDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("history-panel-backup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: templatesDirectory, withIntermediateDirectories: true)
        let snippetsDatabaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("sqlite")

        let settings = AppSettings(defaults: defaults)
        let templateStore = TemplateStore(fileURL: templatesDirectory.appendingPathComponent("templates.json"))
        let snippetStore = try SnippetStore(databaseURL: snippetsDatabaseURL)

        var settingsDict = settings.exportableSettingsSnapshot()
        // historyPanelHotKeySpec bound to the SAME chord as PTT itself — exercises the fourth
        // slot's own PTT-vs-action check specifically (sibling-vs-sibling collision is already
        // covered by `VoiceEditTargetTests.fourHotkeysRejectEveryCollision`). Both
        // insertLastDictationHotKeySpec and voiceEditHotKeySpec stay unbound (their default
        // NSNull from `exportableSettingsSnapshot()`), so this is unambiguously the
        // historyPanelHotKeySpec field failing.
        let colliding = try JSONEncoder().encode(HotKeySpec(modifiers: 0, keyCode: 9))
        let collidingJSON = try JSONSerialization.jsonObject(with: colliding)
        settingsDict[AppSettings.Keys.hotKeySpec] = collidingJSON
        settingsDict[AppSettings.Keys.historyPanelHotKeySpec] = collidingJSON
        let payload: [String: Any] = [
            "app": "FreeTalker", "formatVersion": 2, "settings": settingsDict,
            "templates": [[String: Any]](), "snippets": [[String: Any]]()
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.fragmentsAllowed])

        await #expect(throws: BackupBundleError.invalidSettingsValue(key: AppSettings.Keys.historyPanelHotKeySpec)) {
            try await BackupBundle.restore(data: data, settings: settings, templateStore: templateStore, snippetStore: snippetStore)
        }
        // Reject-before-write: the hotkey quartet was never applied.
        #expect(settings.hotKeySpec == .default)
        #expect(settings.historyPanelHotKeySpec == nil)
    }
}

/// Minimal real-SQLite fixture for `Database.search` integration tests — a fresh temp-file
/// database per test, cleaned up on deinit.
private final class SearchFixture {
    let url: URL
    let db: Database

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("freetalker-history-panel-\(UUID().uuidString).sqlite")
        db = try Database(path: url)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(atPath: url.path + "-wal")
        try? FileManager.default.removeItem(atPath: url.path + "-shm")
    }

    @discardableResult
    func insert(refined: String) throws -> Int64 {
        try db.insertDictation(.init(
            timestamp: Date(),
            sourceLanguage: SourceLanguage("en"),
            requestedOutputLanguage: .sameAsSpoken,
            template: "Clean",
            transcript: "raw",
            refined: refined,
            engine: "local"
        ))
    }
}
