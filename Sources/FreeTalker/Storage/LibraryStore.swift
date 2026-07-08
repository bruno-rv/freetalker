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
}
