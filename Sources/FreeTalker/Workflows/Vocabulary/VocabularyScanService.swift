import Foundation
import os

/// Drives `VocabularyMiner` over Library history (PLAN.md PR B, item 3): a full paged backfill
/// scan (Settings' "Scan library" button) and a single-row incremental hook (called once per
/// newly recorded dictation — see `LibraryStore.onDictationRecorded`/`AppCoordinator`). Stateless
/// — every method is a standalone call over its two collaborators (`LibraryStore`, `@MainActor`;
/// `VocabStore`, its own actor), safe to invoke concurrently for different dictation ids.
enum VocabularyScanService {
    /// Non-content logging only (PLAN.md PR B, item 8) — counts and outcomes, never transcript
    /// text or mined terms.
    private static let logger = Logger(subsystem: "org.freetalker.app", category: "vocabulary-suggestions")

    /// Rows fetched per page — small enough that a page never holds meaningfully more memory than
    /// a handful of dictations' transcripts, large enough to keep the scan's `MainActor` hops
    /// (one `vocabMiningProjectionPage` call per page) infrequent.
    static let pageSize = 200

    struct ScanProgress: Equatable, Sendable {
        var scanned: Int
        var total: Int
    }

    /// Mines one already-fetched row and (if eligible and it produced any anchored substitution
    /// candidates) records the evidence. The ONE path both the backfill scan and the incremental
    /// hook go through, so eligibility/mining behavior can never drift between them.
    static func mineRow(_ row: VocabMiningRow, into store: VocabStore) async throws {
        guard VocabularyMiner.isEligible(
            requestedOutputLanguage: row.requestedOutputLanguage,
            templateName: row.template,
            voiceCommandsActive: row.voiceCommandsActive
        ) else { return }
        let candidates = VocabularyMiner.candidates(transcript: row.transcript, refined: row.refined)
        guard !candidates.isEmpty else { return }
        try await store.recordEvidence(dictationID: row.id, candidates: candidates)
    }

    /// Full paged backfill (PLAN.md PR B, item 3) — keyset-pages through every dictation
    /// (`LibraryStore.vocabMiningProjectionPage`), mining each row, reporting progress after every
    /// page, and checking `Task.isCancelled` between pages and rows. Each row's `recordEvidence`
    /// is independently idempotent (PK upsert — see `VocabStore`), so a scan cancelled mid-page
    /// leaves no partial/inconsistent state and is always safe to re-run from the beginning (or
    /// resume — re-scanning already-mined rows is a no-op).
    static func scanLibrary(
        library: LibraryStore,
        store: VocabStore,
        onProgress: @escaping @Sendable (ScanProgress) -> Void = { _ in }
    ) async throws {
        let total = await MainActor.run { library.totalCount() }
        logger.notice("vocabulary scan starting: \(total, privacy: .public) dictations")
        var scanned = 0
        onProgress(ScanProgress(scanned: scanned, total: total))
        var afterID: Int64 = 0
        do {
            while true {
                try Task.checkCancellation()
                let page = try await MainActor.run { try library.vocabMiningProjectionPage(afterID: afterID, limit: pageSize) }
                guard !page.isEmpty else { break }
                for row in page {
                    try Task.checkCancellation()
                    try await mineRow(row, into: store)
                    afterID = row.id
                    scanned += 1
                }
                onProgress(ScanProgress(scanned: scanned, total: total))
            }
        } catch is CancellationError {
            logger.notice("vocabulary scan cancelled after \(scanned, privacy: .public) of \(total, privacy: .public) dictations")
            throw CancellationError()
        } catch {
            logger.error("vocabulary scan failed after \(scanned, privacy: .public) of \(total, privacy: .public) dictations: \(error.localizedDescription, privacy: .public)")
            throw error
        }
        logger.notice("vocabulary scan completed: \(scanned, privacy: .public) dictations scanned")
    }
}
