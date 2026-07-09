import Foundation

/// Observable façade over Database for the Library UI.
@MainActor
final class LibraryStore: ObservableObject {
    static let shared = LibraryStore()

    enum LibraryStoreError: LocalizedError {
        case databaseUnavailable

        var errorDescription: String? {
            "Library database is unavailable."
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
    func deleteAll() throws {
        guard let db else { throw LibraryStoreError.databaseUnavailable }
        try db.deleteAllDictations()
        purgeDebugAudio()
        refresh()
    }

    /// Whether a Dictation row with this id still exists. `nil` means "unknown" (database
    /// unavailable) rather than "deleted" — callers must not conflate the two. Used by
    /// `AppCoordinator.reprocess` to detect a source row deleted mid-flight. See PLAN.md step 5.
    func exists(id: Int64) -> Bool? {
        guard let db else { return nil }
        return try? db.dictationExists(id: id)
    }

    /// Best-effort removal of debug audio written outside the Library DB (AppCoordinator's
    /// `writeLastCaptureDebugArtifact` / `saveFailedAudio`). A failed removal here doesn't
    /// undo the DB wipe that already succeeded, so failures are swallowed rather than thrown.
    private func purgeDebugAudio() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("FreeTalker", isDirectory: true)
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("last-dictation.wav"))
        let failedDir = dir.appendingPathComponent("failed-dictations", isDirectory: true)
        if let contents = try? FileManager.default.contentsOfDirectory(at: failedDir, includingPropertiesForKeys: nil) {
            for file in contents {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}
