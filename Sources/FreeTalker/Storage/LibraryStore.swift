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
    /// unavailable — a confirmed destructive action must always surface a failure. Once the row
    /// deletion (`Database.deleteRow`) commits, the deletion is real regardless of what happens
    /// next — `refresh()` always runs before a trailing checkpoint failure is allowed to escape,
    /// so a deleted row can never stay visible in the UI just because the WAL truncate failed.
    /// See PLAN.md step 2, Round 2 Codex finding 2.
    func delete(id: Int64) throws {
        guard let db else { throw LibraryStoreError.databaseUnavailable }
        try db.deleteRow(id: id)
        try Self.runThenAlways({ try db.checkpointTruncate() }, always: { self.refresh() })
    }

    /// Clears the entire Library, including the transient on-disk debug audio artifacts
    /// (`last-dictation.wav` and any saved failed-transcription recordings) — those live outside
    /// the DB but must not survive "clear the archive". See PLAN.md step 2/3.
    ///
    /// Row deletion (`Database.deleteAllRows`) and the privacy cleanup (`Database
    /// .vacuumAndCheckpoint`, VACUUM + WAL checkpoint) are separate throwing steps (see their
    /// doc comments): once row deletion commits the archive is already gone from the DB, so the
    /// debug-audio purge and the UI refresh must happen regardless of whether the privacy
    /// cleanup then fails — both run unconditionally before either error is allowed to escape to
    /// the caller. See Round 1 Codex findings 4/5, Round 2 Codex findings 1/2.
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

    /// Runs `step` (a privacy-cleanup step — VACUUM/checkpoint — that presumes the row deletion
    /// it follows already committed), capturing rather than immediately propagating any error,
    /// then unconditionally runs `always` (UI refresh, and for `deleteAll()` also the
    /// debug-audio purge) — itself captured, never swallowed — and only then rethrows whichever
    /// error occurred, `step`'s taking priority. Extracted as a standalone function (rather than
    /// inlined per call site) because `LibraryStore` is a hard singleton (`private init()`, no
    /// injectable `Database`) that SelfCheck can't drive end-to-end with a fake DB — this is the
    /// actual sequencing `delete(id:)`/`deleteAll()` run, not a simulation of it. See PLAN.md
    /// step 2, Round 2 Codex finding 2.
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
    /// `writeLastCaptureDebugArtifact` / `saveFailedAudio`) under the real Application Support
    /// directory — see `purgeDebugAudio(in:)` for the testable core logic.
    private func purgeDebugAudio() throws {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try Self.purgeDebugAudio(in: support.appendingPathComponent("FreeTalker", isDirectory: true))
    }

    /// Core purge logic for `last-dictation.wav` and any `*.wav` file under `failed-dictations/`
    /// — scoped by `shouldPurgeFailedDictationFile`, not "every child of the directory" — taking
    /// `dir` as a parameter (rather than hardcoding the real Application Support path) so
    /// SelfCheck can exercise it against an isolated temp directory. See Round 1 Codex finding 5.
    ///
    /// A missing file (the common case — most dictations produce neither artifact) is not an
    /// error; every other removal failure is collected and thrown as one `audioPurgeFailed`,
    /// rather than silently swallowed. Two refinements from Round 2 Codex review: an unreadable
    /// `failed-dictations/` directory feeds into `audioPurgeFailed` too, rather than a `try?`
    /// silently reporting a clean purge while audio is actually left behind (finding 3); and a
    /// non-regular entry that happens to be named `*.wav` (e.g. a directory) is left alone, not
    /// recursively removed, since extension-only scoping doesn't guarantee it's a file (finding
    /// 4).
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

        let failedDir = dir.appendingPathComponent("failed-dictations", isDirectory: true)
        if FileManager.default.fileExists(atPath: failedDir.path) {
            do {
                let contents = try FileManager.default.contentsOfDirectory(
                    at: failedDir, includingPropertiesForKeys: [.isRegularFileKey]
                )
                for file in contents where shouldPurgeFailedDictationFile(pathExtension: file.pathExtension) {
                    let isRegularFile = (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false
                    guard isRegularFile else { continue } // e.g. a directory named "foo.wav" — leave it alone
                    do {
                        try FileManager.default.removeItem(at: file)
                    } catch {
                        errors.append(error)
                    }
                }
            } catch {
                errors.append(error) // directory exists but couldn't be enumerated — audio may remain
            }
        }

        guard errors.isEmpty else {
            throw LibraryStoreError.audioPurgeFailed(errors)
        }
    }
}
