import Foundation

@MainActor
protocol LibraryTranslationStoring: AnyObject {
    func translationVariants(parentID: Int64) throws -> [DictationTranslationVariant]
    func conditionalUpsertTranslation(parentID: Int64, target: TranslationTarget, text: String, expected: TranslationVariantExpectation) throws -> TranslationVariantWriteResult
}

/// Observable façade over Database for the Library UI.
@MainActor
final class LibraryStore: ObservableObject, LibraryTranslationStoring {
    static let shared = LibraryStore()

    enum LibraryStoreError: LocalizedError {
        case databaseUnavailable
        /// One or more debug-audio files under Application Support couldn't be removed during
        /// `deleteAll()` — surfaced rather than swallowed so a failed purge is never silently
        /// reported as a clean wipe. See Round 1 Codex finding 5.
        case audioPurgeFailed([Error])

        var errorDescription: String? {
            switch self {
            case .databaseUnavailable:
                return "Library database is unavailable."
            case .audioPurgeFailed(let errors):
                return "Failed to delete \(errors.count) debug audio file\(errors.count == 1 ? "" : "s")."
            }
        }
    }

    @Published private(set) var dictations: [Dictation] = []
    @Published var searchText: String = "" {
        didSet { refresh() }
    }

    private let db: Database?
    private let temporaryDirectory: URL?

    private init() {
        temporaryDirectory = nil
        do {
            db = try Database()
        } catch {
            db = nil
            print("FreeTalker: LibraryStore failed to open database: \(error)")
        }
        refresh()
    }

    private init(db: Database, temporaryDirectory: URL) {
        self.db = db
        self.temporaryDirectory = temporaryDirectory
        refresh()
    }

    static func temporary() throws -> LibraryStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("library-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            return try LibraryStore(
                db: Database(path: directory.appendingPathComponent("library.db")),
                temporaryDirectory: directory
            )
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    deinit {
        if let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) }
    }

    func refresh() {
        guard let db else { return }
        do {
            dictations = try searchText.isEmpty ? db.allDictations() : db.searchDictations(query: searchText)
        } catch {
            print("FreeTalker: LibraryStore refresh failed: \(error)")
        }
    }

    /// Total (unfiltered) Library entry count — used by the Delete All confirmation dialog so an
    /// active search doesn't misreport e.g. "0 Entries" while the whole archive is about to be
    /// wiped. 0 when the database is unavailable, matching `dictations`' empty-array fallback —
    /// the Delete All button is already disabled/inert with no database. See Round 1 Codex
    /// finding 1.
    func totalCount() -> Int {
        guard let db else { return 0 }
        return (try? db.totalCount()) ?? 0
    }

    func latestDictation() throws -> Dictation? {
        guard let db else { throw LibraryStoreError.databaseUnavailable }
        return try db.latestDictation()
    }

    /// Inserts a Dictation row. Throws (rather than silently swallowing) so callers can surface
    /// the failure — the transcript is already inserted/pasteboarded by this point, so a failure
    /// here only loses the Library row, not the user's words. See Round 1 Codex finding 10.
    @discardableResult
    func record(language: String, requestedOutputLanguage: OutputLanguage = .sameAsSpoken, template: String, transcript: String, refined: String, engine: String, sourceID: Int64? = nil, captureID: UUID? = nil, bundleID: String? = nil, durationSecs: Double? = nil) throws -> Int64 {
        guard let db else { throw LibraryStoreError.databaseUnavailable }
        let stored = try db.insertDictation(.init(
            timestamp: Date(),
            sourceLanguage: SourceLanguage(language),
            requestedOutputLanguage: requestedOutputLanguage,
            template: template,
            transcript: transcript,
            refined: refined,
            engine: engine,
            sourceID: sourceID,
            bundleID: bundleID,
            durationSecs: durationSecs
        ), captureID: captureID)
        refresh()
        return stored.id
    }

    @discardableResult
    func record(_ dictation: Dictation, captureID: UUID? = nil) throws -> Dictation {
        guard let db else { throw LibraryStoreError.databaseUnavailable }
        let stored = try db.insertDictation(.init(
            timestamp: dictation.timestamp,
            sourceLanguage: dictation.sourceLanguage,
            requestedOutputLanguage: dictation.requestedOutputLanguage,
            template: dictation.templateName,
            transcript: dictation.transcript,
            refined: dictation.refined,
            engine: dictation.engine,
            sourceID: dictation.sourceID,
            bundleID: dictation.bundleID,
            durationSecs: dictation.durationSecs
        ), captureID: captureID)
        refresh()
        return stored
    }

    func dictations(captureID: UUID) throws -> [Dictation] {
        guard let db else { throw LibraryStoreError.databaseUnavailable }
        return try db.dictations(captureID: captureID)
    }

    func translationVariants(parentID: Int64) throws -> [DictationTranslationVariant] {
        guard let db else { throw LibraryStoreError.databaseUnavailable }
        return try db.translationVariants(parentID: parentID)
    }

    func upsertTranslation(parentID: Int64, target: TranslationTarget, text: String) throws {
        guard let db else { throw LibraryStoreError.databaseUnavailable }
        try db.upsertTranslation(parentID: parentID, target: target, text: text)
    }

    func conditionalUpsertTranslation(parentID: Int64, target: TranslationTarget, text: String, expected: TranslationVariantExpectation) throws -> TranslationVariantWriteResult {
        guard let db else { throw LibraryStoreError.databaseUnavailable }
        return try db.conditionalUpsertTranslation(parentID: parentID, target: target, text: text, expected: expected)
    }

    func deleteTranslation(parentID: Int64, target: TranslationTarget) throws {
        guard let db else { throw LibraryStoreError.databaseUnavailable }
        try db.deleteTranslation(parentID: parentID, target: target)
    }

    func delete(id: Int64) throws {
        guard let db else { throw LibraryStoreError.databaseUnavailable }
        try db.deleteRow(id: id)
        try Self.runThenAlways({ try db.checkpointTruncate() }, always: { self.refresh() })
    }

    func deleteAll() throws {
        guard let db else { throw LibraryStoreError.databaseUnavailable }
        try db.deleteAllRows()
        try Self.runThenAlways(
            { try db.vacuumAndCheckpoint() },
            always: {
                self.refresh()
                try self.purgeDebugAudio()
            }
        )
    }

    nonisolated static func runThenAlways(_ step: () throws -> Void, always: () throws -> Void) throws {
        var stepError: Error?
        do {
            try step()
        } catch {
            stepError = error
        }
        var alwaysError: Error?
        do {
            try always()
        } catch {
            alwaysError = error
        }
        if let stepError { throw stepError }
        if let alwaysError { throw alwaysError }
    }

    func exists(id: Int64) -> Bool? {
        guard let db else { return nil }
        return try? db.dictationExists(id: id)
    }

    /// Removes the transient last-capture debug artifact. Recovery media has separate
    /// ownership and explicit deletion semantics and is never traversed here.
    private func purgeDebugAudio() throws {
        try Self.purgeDebugAudio(in: FreeTalkerPaths.applicationSupport)
    }

    nonisolated static func purgeDebugAudio(in dir: URL) throws {
        var errors: [Error] = []

        let lastDictationURL = dir.appendingPathComponent("last-dictation.wav")
        if FileManager.default.fileExists(atPath: lastDictationURL.path) {
            do {
                try FileManager.default.removeItem(at: lastDictationURL)
            } catch {
                errors.append(error)
            }
        }

        guard errors.isEmpty else {
            throw LibraryStoreError.audioPurgeFailed(errors)
        }
    }
}
