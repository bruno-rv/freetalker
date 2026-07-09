import Foundation

/// Observable façade over Database for the Library UI.
@MainActor
final class LibraryStore: ObservableObject {
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

    private init() {
        do {
            db = try Database()
        } catch {
            db = nil
            print("FreeTalker: LibraryStore failed to open database: \(error)")
        }
        refresh()
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

    /// The newest Library entry, straight from the database — deliberately NOT
    /// `dictations.first`, which is filtered by `searchText` and would silently redo a search
    /// result instead of the actual latest Dictation. Throws when the database is unavailable so
    /// `AppCoordinator.redoLast()` can distinguish "no database" from "empty Library" (nil). See
    /// CONTEXT.md "Redo Last", PLAN.md step 10.
    func latestDictation() throws -> Dictation? {
        guard let db else { throw LibraryStoreError.databaseUnavailable }
        return try db.latestDictation()
    }

    /// Inserts a Dictation row. Throws (rather than silently swallowing) so callers can surface
    /// the failure — the transcript is already inserted/pasteboarded by this point, so a failure
    /// here only loses the Library row, not the user's words. See Round 1 Codex finding 10.
    @discardableResult
    func record(language: String, template: String, transcript: String, refined: String, engine: String, sourceID: Int64? = nil) throws -> Int64 {
        guard let db else { throw LibraryStoreError.databaseUnavailable }
        let id = try db.insertDictation(
            timestamp: Date(),
            language: language,
            template: template,
            transcript: transcript,
            refined: refined,
            engine: engine,
            sourceID: sourceID
        )
        refresh()
        return id
    }

    /// Deletes one Dictation row. Throws (never silently no-ops) when the database is
    /// unavailable — a confirmed destructive action must always surface a failure. See
    /// PLAN.md step 2.
    func delete(id: Int64) throws {
        guard let db else { throw LibraryStoreError.databaseUnavailable }
        try db.deleteDictation(id: id)
        refresh()
    }

    /// Clears the entire Library, including the transient on-disk debug audio artifacts
    /// (`last-dictation.wav` and any saved failed-transcription recordings) — those live outside
    /// the DB but must not survive "clear the archive". See PLAN.md step 2/3.
    ///
    /// Row deletion (`Database.deleteAllDictations`, DELETE + VACUUM) and the WAL checkpoint
    /// (`Database.checkpointTruncate`) are separate throwing steps (see their doc comments): once
    /// row deletion succeeds the archive is already gone from the DB, so the debug-audio purge
    /// and the UI refresh must happen regardless of whether the checkpoint or the purge itself
    /// then fails — both run unconditionally (errors captured, not thrown immediately) before
    /// either error is allowed to escape to the caller. See Round 1 Codex findings 4/5.
    func deleteAll() throws {
        guard let db else { throw LibraryStoreError.databaseUnavailable }
        try db.deleteAllDictations()
        var checkpointError: Error?
        do {
            try db.checkpointTruncate()
        } catch {
            checkpointError = error
        }
        var purgeError: Error?
        do {
            try purgeDebugAudio()
        } catch {
            purgeError = error
        }
        refresh()
        if let checkpointError { throw checkpointError }
        if let purgeError { throw purgeError }
    }

    /// Whether a Dictation row with this id still exists. `nil` means "unknown" (database
    /// unavailable, or the existence check itself threw — see `Database.dictationExists`) rather
    /// than "deleted" — callers must not conflate the two. Used by `AppCoordinator.reprocess`,
    /// fail-open, to detect a source row deleted mid-flight without dropping a Library write on a
    /// transient error. See PLAN.md step 5, Round 1 Codex finding 3.
    func exists(id: Int64) -> Bool? {
        guard let db else { return nil }
        return try? db.dictationExists(id: id)
    }

    /// Whether a file inside `failed-dictations/` should be purged by `purgeDebugAudio` — `.wav`
    /// only (case-insensitive extension), never every child of the directory indiscriminately
    /// (which would also sweep up anything else that happened to land there). Pure `String ->
    /// Bool` so SelfCheck can drive it directly. See Round 1 Codex finding 5.
    nonisolated static func shouldPurgeFailedDictationFile(pathExtension: String) -> Bool {
        pathExtension.lowercased() == "wav"
    }

    /// Removes debug audio written outside the Library DB (AppCoordinator's
    /// `writeLastCaptureDebugArtifact` / `saveFailedAudio`): `last-dictation.wav` and any
    /// `*.wav` file under `failed-dictations/` — scoped by `shouldPurgeFailedDictationFile`, not
    /// "every child of the directory". A missing file (the common case — most dictations produce
    /// neither artifact) is not an error; every other removal failure is collected and thrown as
    /// one `audioPurgeFailed`, rather than silently swallowed. See Round 1 Codex finding 5.
    private func purgeDebugAudio() throws {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("FreeTalker", isDirectory: true)
        var errors: [Error] = []

        let lastDictationURL = dir.appendingPathComponent("last-dictation.wav")
        if FileManager.default.fileExists(atPath: lastDictationURL.path) {
            do {
                try FileManager.default.removeItem(at: lastDictationURL)
            } catch {
                errors.append(error)
            }
        }

        let failedDir = dir.appendingPathComponent("failed-dictations", isDirectory: true)
        if let contents = try? FileManager.default.contentsOfDirectory(at: failedDir, includingPropertiesForKeys: nil) {
            for file in contents where Self.shouldPurgeFailedDictationFile(pathExtension: file.pathExtension) {
                do {
                    try FileManager.default.removeItem(at: file)
                } catch {
                    errors.append(error)
                }
            }
        }

        guard errors.isEmpty else {
            throw LibraryStoreError.audioPurgeFailed(errors)
        }
    }
}
