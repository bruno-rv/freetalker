import Darwin
import Foundation

private struct RecoveryReconciliationOperationError: LocalizedError {
    let operation: String
    let underlying: Error
    var errorDescription: String? { "\(operation): \(underlying.localizedDescription)" }
}

actor RecoveryReconciler {
    private let directory: URL
    private let store: TranscriptionJobStore
    private let ledger: any CaptureLedgerStoring
    private let fileSystem: any JournalFileSystem
    private let libraryDictationID: @Sendable (UUID) async throws -> Int64?
    private let importer: LegacyRecoveryImporter
    private let registrationRetrier: RecoveryRegistrationRetrier
    private let beforeRegistrationAttempt: @Sendable () async throws -> Void
    private var activeReconciliation: Task<RecoveryReconciliationReport, Never>?

    init(
        directory: URL,
        store: TranscriptionJobStore,
        ledger: any CaptureLedgerStoring,
        fileSystem: any JournalFileSystem = LocalJournalFileSystem(),
        libraryDictationID: @escaping @Sendable (UUID) async throws -> Int64?,
        retrySleep: @escaping @Sendable (Duration) async -> Void = { delay in
            guard delay > .zero else { return }
            do { try await Task.sleep(for: delay) } catch { return }
        },
        beforeRegistrationAttempt: @escaping @Sendable () async throws -> Void = {}
    ) {
        self.directory = directory.standardizedFileURL
        self.store = store
        self.ledger = ledger
        self.fileSystem = fileSystem
        self.libraryDictationID = libraryDictationID
        self.beforeRegistrationAttempt = beforeRegistrationAttempt
        registrationRetrier = RecoveryRegistrationRetrier(sleep: retrySleep)
        importer = LegacyRecoveryImporter(
            store: store, ledger: ledger, ownedDirectory: directory.standardizedFileURL,
            codec: CaptureSegmentCodec(fileSystem: fileSystem),
            retrier: RecoveryRegistrationRetrier(sleep: retrySleep),
            beforeRegistrationAttempt: beforeRegistrationAttempt
        )
    }

    func reconcile() async -> RecoveryReconciliationReport {
        if let activeReconciliation { return await activeReconciliation.value }
        let task = Task { await performReconciliation() }
        activeReconciliation = task
        let report = await task.value
        activeReconciliation = nil
        return report
    }

    private func performReconciliation() async -> RecoveryReconciliationReport {
        var report = RecoveryReconciliationReport()
        let rootItems: [URL]
        let sessions: [CaptureSession]
        let jobs: [TranscriptionJob]
        do {
            try fileSystem.createDirectory(directory)
            _ = try await RecoveryRetentionService(
                directory: directory, store: store, ledger: ledger, fileSystem: fileSystem
            ).purgeExpired(now: Date(), retention: .never)
            rootItems = try fileSystem.contents(directory).sorted { $0.path < $1.path }
            sessions = try await ledger.unfinishedSessions()
            jobs = try await store.jobs()
        } catch {
            report.storeFailure = error.localizedDescription
            return report
        }

        let migration = RecoveryOwnershipMigrator(root: directory, fileSystem: fileSystem)
            .migrate(jobs: jobs, sessions: sessions)
        for issue in migration.issues {
            report.recordFailure(
                issue.source,
                CaptureJournalError.failed(issue.message)
            )
        }
        var ownedPaths = Set(sessions.map { $0.directory.standardizedFileURL.path })
            .union(migration.protectedPaths)
        for session in sessions {
            await reconcileKnownSession(session, report: &report)
            ownedPaths.insert(session.directory.standardizedFileURL.path)
        }

        for item in rootItems {
            do {
                guard fileSystem.exists(item) else { continue }
                if Self.preparationCaptureID(item) != nil {
                    try await reconcilePreparationMarker(item, report: &report)
                } else if Self.isPendingMarker(item) {
                    try await reconcilePendingMarker(item, report: &report)
                } else if Self.directoryCaptureID(item) != nil {
                    if !ownedPaths.contains(item.standardizedFileURL.path) {
                        try await reconcileSessionDirectory(item, report: &report)
                    }
                } else if item.pathExtension.lowercased() == "wav" {
                    if !ownedPaths.contains(item.standardizedFileURL.path) {
                        try await reconcileLooseAudio(item, report: &report)
                    }
                }
            } catch {
                report.recordFailure(item, error)
            }
        }
        return report
    }

    private func reconcileKnownSession(
        _ session: CaptureSession, report: inout RecoveryReconciliationReport
    ) async {
        do {
            if try await cleanupDisposedSession(session) { return }
            if let libraryID = try await libraryDictationID(session.id) {
                try await reconcileLibraryOwnedSession(session, libraryID: libraryID)
                return
            }
            let canonical = session.directory.appendingPathComponent("\(session.id.uuidString).wav")
            let current = try await ledger.session(id: session.id) ?? session
            switch current.state {
            case .capturing:
                if fileSystem.exists(canonical) {
                    try await importCanonical(canonical, id: current.id)
                } else if fileSystem.exists(
                    current.directory.appendingPathComponent("capture-diagnostics.json")
                ) {
                    let diagnostics = try CaptureJournalService(
                        fileSystem: fileSystem, ledger: ledger
                    ).loadSilentDiagnostics(current)
                    guard diagnostics.indicatesSilence else {
                        throw RecoveryReconciliationOperationError(
                            operation: "restore silent capture",
                            underlying: CaptureJournalError.failed(
                                "persisted diagnostics contain microphone signal"
                            )
                        )
                    }
                    try await ledger.transition(
                        id: current.id, from: .capturing, to: .silent,
                        recoveryJobID: nil, libraryDictationID: nil,
                        assetKind: .silent,
                        failureMessage: SilentCapturePresentation.message,
                        contentHash: nil
                    )
                    try await CaptureJournalService(
                        fileSystem: fileSystem, ledger: ledger, recoveryRoot: directory
                    )
                        .resumeSilentCleanup(captureID: current.id)
                } else {
                    // Codex round-9 finding 1: hydrated BEFORE `reconcileSegmentInventory` and
                    // OUTSIDE every catch below — the malformed-orphan/EISDIR quarantine paths
                    // used to `return` before hydration ever ran, so a durable stop-time marker
                    // on disk (Stop wrote it) with a not-yet-persisted ledger snapshot (the
                    // snapshot write itself failed) left the quarantine job with a nil/nil
                    // fallback instead of the marker's exact stop-time policy. Still a metadata/
                    // storage step over capture state this branch hasn't touched yet (Codex
                    // round-3 finding 1): a transient failure here must surface as a
                    // reconciliation failure that retries next pass, never get folded into
                    // "segments are damaged".
                    try await hydrateVoiceCommandIntent(for: current)
                    let segments: [CaptureSegment]
                    do {
                        segments = try await reconcileSegmentInventory(for: current)
                    } catch let error as CaptureJournalError {
                        // Codex round-6 finding 3: `reconcileSegmentInventory` decodes newly
                        // discovered orphan segment FILES (never ledger-committed) before this
                        // point ever sees them, so a malformed one (bad WAV header, sample-count
                        // overflow) previously escaped the quarantine catch below entirely and
                        // retried forever — unlike the identical corruption evidence on an
                        // already ledger-committed segment, which the `assemble` catch below
                        // already quarantines. `.invalidOrdinal` is the one exception: a
                        // non-contiguous gap is evidence of a MISSING segment, not a damaged one,
                        // and must keep failing loudly so reconciliation retries instead of
                        // silently quarantining audio that may still show up on disk.
                        guard case .invalidOrdinal = error else {
                            // Codex round-10 blocker: the round-9 finding-4 fix cleared this orphan
                            // BEFORE the session was durably transitioned to `.damaged` below. If the
                            // survivor fetch or the transition itself then threw transiently, the
                            // session stayed `.capturing` with the orphan's corruption evidence
                            // already deleted — the next reconciliation pass would see a clean
                            // contiguous prefix (this orphan was the last/only one) and silently
                            // assemble TRUNCATED audio as a healthy recovery. Fixed ordering:
                            // 1) validate survivors (round-9 finding 2's contract — a transient
                            //    failure here must still leave the session `.capturing` for retry,
                            //    so this runs BEFORE any durable transition);
                            // 2) durably transition to `.damaged` (so any later transient failure in
                            //    this same call leaves the session unambiguously damaged, never
                            //    `.capturing` with missing evidence);
                            // 3) only then clear the orphan (round-9 finding 4 — never ledger-
                            //    committed, must not permanently strand the eventual Library-
                            //    committed cleanup in `cleanupNotPermitted`);
                            // 4) register the quarantine fallback recovery.
                            let quarantineMessage =
                                "Interrupted capture segments are damaged: \(error.localizedDescription)"
                            let survivors = try await ledger.committedSegments(captureID: current.id)
                            let fallback = try firstValidatedSurvivingSegment(survivors)
                            let quarantined = try await transitionToDamaged(current, message: quarantineMessage)
                            if let path = Self.orphanPath(from: error) {
                                try clearOwnedOrphan(atPath: path)
                            }
                            try await quarantineJournal(
                                quarantined, fallback: fallback, message: quarantineMessage
                            )
                            return
                        }
                        throw error
                    } catch let error as JournalPersistenceError {
                        // Codex round-7 finding 7: `reconcileSegmentInventory` reads each newly
                        // discovered orphan segment file via `fileSystem.read` before this point
                        // ever sees it — a `read` failure with EISDIR (a directory sitting where a
                        // `segment-*.wav` file should be) is exactly as deterministic as a bad WAV
                        // header and must quarantine, not retry forever. ENOENT (and every other
                        // code) stays retryable: it's a plausible enumeration/read race with a
                        // concurrent writer, unlike EISDIR which no writer would ever produce.
                        guard case .read(let path, let code) = error, code == EISDIR else {
                            throw error
                        }
                        // Codex round-10 blocker: same reordering as the malformed-orphan catch
                        // above, for the identical reason — survivor validation (transient failure
                        // must stay `.capturing`) before the durable `.damaged` transition, before
                        // the never-ledger-committed EISDIR orphan is cleared, before quarantine
                        // registration.
                        let quarantineMessage = "Interrupted capture segments are damaged: \(error)"
                        let survivors = try await ledger.committedSegments(captureID: current.id)
                        let fallback = try firstValidatedSurvivingSegment(survivors)
                        let quarantined = try await transitionToDamaged(current, message: quarantineMessage)
                        try clearOwnedOrphan(atPath: path)
                        try await quarantineJournal(
                            quarantined, fallback: fallback, message: quarantineMessage
                        )
                        return
                    }
                    if !segments.isEmpty {
                        // The quarantine catch is scoped to segment validation/assembly ONLY
                        // (Codex round-4 finding 3): assembly failure is real evidence of damaged
                        // audio, so it quarantines down to the first segment. The subsequent
                        // `.capturing -> .staged` transition and job registration are a metadata/
                        // storage step over audio already proven healthy by a successful assemble —
                        // a transient failure there must propagate to `report.recordFailure`
                        // (capture state untouched, retried next pass), never quarantine a healthy
                        // multi-segment recording down to its first segment.
                        let assembled: (sampleCount: Int, contentHash: String)
                        do {
                            assembled = try CaptureSegmentCodec(fileSystem: fileSystem)
                                .assemble(segments: segments, canonicalURL: canonical)
                        } catch let error as CaptureJournalError {
                            // Only a deterministic validation failure inside `assemble` (bad
                            // ordinal, capture-id mismatch, sample-count overflow, hash mismatch,
                            // malformed WAV header) is real evidence of damaged audio (Codex
                            // round-5 finding 2) — `assemble` also performs write/fsync/rename I/O
                            // for the canonical file, which can fail transiently (disk full,
                            // sandbox hiccup) on perfectly healthy segments. A non-
                            // `CaptureJournalError` here is exactly that: it must propagate to
                            // `report.recordFailure` below (capture state untouched, retried next
                            // pass), never quarantine a healthy multi-segment recording down to
                            // its first segment.
                            try await quarantineJournal(
                                current, fallback: try firstValidatedSurvivingSegment(segments),
                                message: "Interrupted capture segments are damaged: \(error.localizedDescription)"
                            )
                            return
                        } catch let error as JournalPersistenceError {
                            // Codex round-6 finding 2: `assemble` reads each segment's file via
                            // `validatedData` before touching the canonical output — a `read`
                            // failure with ENOENT (file missing) or EISDIR (not a regular file) is
                            // a permanently missing/non-regular ledger segment, exactly as
                            // deterministic as a bad WAV header, and was previously treated as
                            // transient I/O and retried forever. Every OTHER `JournalPersistenceError`
                            // here (including any other `read` error code) can still be an
                            // environmental hiccup on the OUTPUT side (write/append/rename/sync of
                            // the temporary canonical file) and must keep propagating to
                            // `report.recordFailure` for retry, unchanged from before.
                            guard case .read(_, let code) = error, code == ENOENT || code == EISDIR else {
                                throw error
                            }
                            try await quarantineJournal(
                                current, fallback: try firstValidatedSurvivingSegment(segments),
                                message: "Interrupted capture segments are damaged: \(error)"
                            )
                            return
                        }
                        try await ledger.transition(
                            id: current.id, from: .capturing, to: .staged,
                            recoveryJobID: nil, libraryDictationID: nil,
                            assetKind: .audio, failureMessage: nil,
                            contentHash: assembled.contentHash
                        )
                        try await registerCanonical(canonical, id: current.id)
                    } else {
                        let failureMarker = current.directory.appendingPathComponent("capture-failure.marker")
                        if fileSystem.exists(failureMarker) {
                            try await quarantineJournal(
                                current, fallback: failureMarker,
                                message: "Capture journal failed before recoverable audio was committed"
                            )
                        } else {
                            try await quarantineJournal(
                                current, fallback: nil,
                                message: "Interrupted capture has no committed audio"
                            )
                        }
                    }
                }
            case .staged:
                if fileSystem.exists(canonical) {
                    try await registerCanonical(canonical, id: current.id)
                } else {
                    try await quarantineJournal(
                        current, fallback: nil,
                        message: "Staged recovery audio is missing"
                    )
                }
            case .damaged:
                // Codex round-11 blocker: retry orphan cleanup unconditionally on every pass
                // through this steady-state branch (see `clearUnledgeredOrphanSegments`) —
                // a crash between the durable `.damaged` transition above and its matching
                // `clearOwnedOrphan` call (both malformed-orphan catches below) leaves a
                // never-ledger-committed orphan on disk with no durable record of the pending
                // cleanup; this rescan is what recovers it, before `items` is computed for
                // fallback selection so a still-uncleared corrupt orphan is never chosen.
                try await clearUnledgeredOrphanSegments(for: current)
                let items = fileSystem.exists(current.directory)
                    ? try fileSystem.contents(current.directory) : []
                // Codex round-13 blocker: `CaptureSegmentCodec.ordinal(from:)` matches on the
                // `segment-` filename prefix alone and accepts ANY extension. Without the
                // `pathExtension == "wav"` guard, a stray segment-shaped non-WAV file (e.g. a
                // leftover `segment-00000000.txt`) sitting alongside a genuinely adopted
                // `segment-*.wav` could win this `first(where:)` on directory ordering — and
                // `quarantineJournal` → `importAudio(forceQuarantine: true)` copies the selected
                // fallback's raw bytes into `<captureID>.wav` with NO WAV validation, so the wrong
                // file's bytes would be persisted as "recovered" audio while cleanup discards the
                // real one. Matches the `pathExtension == "wav"` guard `reconcileSegmentInventory`
                // and `clearUnledgeredOrphanSegments` (Codex round-12) already require.
                let fallback = fileSystem.exists(canonical) ? canonical
                    : items.first(where: { $0.lastPathComponent == "capture-failure.marker" })
                        ?? items.first(where: {
                            $0.pathExtension == "wav" && CaptureSegmentCodec.ordinal(from: $0) != nil
                        })
                try await quarantineJournal(
                    current, fallback: fallback,
                    message: current.failureMessage ?? "Capture journal is damaged"
                )
            case .cancelling:
                try await CaptureJournalService(fileSystem: fileSystem, ledger: ledger)
                    .resumeCleanup(captureID: current.id)
            case .silent:
                try await CaptureJournalService(
                    fileSystem: fileSystem, ledger: ledger, recoveryRoot: directory
                )
                    .resumeSilentCleanup(captureID: current.id)
            case .processing, .libraryCommitted:
                break
            }
        } catch {
            report.recordFailure(session.directory, error)
        }
    }

    private func cleanupDisposedSession(_ snapshot: CaptureSession) async throws -> Bool {
        let dispositions = RecoveryImportDispositionStore(
            directory: directory, fileSystem: fileSystem
        )
        guard let descriptor = try dispositions.descriptor(id: snapshot.id),
              try dispositions.contains(descriptor) else { return false }
        if let job = try await store.job(id: snapshot.id) {
            let source = URL(fileURLWithPath: job.source.reference).standardizedFileURL
            let direct = directory.appendingPathComponent("\(snapshot.id.uuidString).wav")
                .standardizedFileURL
            let nestedDirectory = directory.appendingPathComponent(
                snapshot.id.uuidString, isDirectory: true
            ).standardizedFileURL
            let nested = nestedDirectory.appendingPathComponent("\(snapshot.id.uuidString).wav")
            guard source == direct || source == nested else {
                throw RecoveryFinalizationError.recoveryJobMismatch
            }
            _ = try await store.deleteCommittedRecovery(
                id: job.id, expectedSourceReference: job.source.reference
            )
        }
        guard let current = try await ledger.session(id: snapshot.id) else { return true }
        if current.state != .cancelling {
            try await ledger.transition(
                id: current.id, from: current.state, to: .cancelling,
                recoveryJobID: current.recoveryJobID,
                libraryDictationID: current.libraryDictationID,
                assetKind: current.assetKind, failureMessage: current.failureMessage,
                contentHash: current.contentHash
            )
        }
        if current.directory.standardizedFileURL == directory {
            let canonical = directory.appendingPathComponent("\(current.id.uuidString).wav")
            if fileSystem.exists(canonical) { try fileSystem.remove(canonical) }
            try fileSystem.synchronizeDirectory(directory)
            try await ledger.removeCleanedSession(id: current.id)
        } else {
            let expected = directory.appendingPathComponent(
                current.id.uuidString, isDirectory: true
            ).standardizedFileURL
            guard current.directory.standardizedFileURL == expected else {
                throw RecoveryFinalizationError.captureIdentityMismatch
            }
            try await CaptureJournalService(fileSystem: fileSystem, ledger: ledger)
                .resumeCleanup(captureID: current.id)
        }
        return true
    }

    private func reconcileLibraryOwnedSession(
        _ snapshot: CaptureSession, libraryID: Int64
    ) async throws {
        guard var current = try await ledger.session(id: snapshot.id) else { return }
        if current.state == .cancelling {
            try await CaptureJournalService(fileSystem: fileSystem, ledger: ledger)
                .resumeCleanup(captureID: current.id)
            return
        }
        if current.state != .libraryCommitted {
            try await ledger.transition(
                id: current.id, from: current.state, to: .libraryCommitted,
                recoveryJobID: current.recoveryJobID, libraryDictationID: libraryID,
                assetKind: current.assetKind, failureMessage: current.failureMessage,
                contentHash: current.contentHash
            )
            guard let persisted = try await ledger.session(id: current.id) else { return }
            current = persisted
        }
        guard current.state == .libraryCommitted,
              current.libraryDictationID == libraryID else {
            throw RecoveryFinalizationError.captureIdentityMismatch
        }
        try await RecoveryCaptureService(
            directory: directory, store: store, ledger: ledger,
            journalFileSystem: fileSystem, libraryDictationID: libraryDictationID
        ).resumeLibraryCommittedCapture(captureID: current.id)
    }

    /// Hydrates `session`'s durable voice-command snapshot from the stop-time
    /// `VoiceCommandFinalizationIntent` marker (`CaptureJournalService.finish`) before the
    /// committed-segments and canonical-audio promotion paths create or recreate the recovery
    /// job — both the known-session path (Codex round-2 finding 1) and the orphan-directory
    /// reconstruction paths in `importCanonical`/`reconcileSessionDirectory` (Codex round-3
    /// finding 2), since an orphan capture row is freshly created with no snapshot of its own.
    /// Committed journal segments accumulate during capture independent of Stop, so this path can
    /// be reached both by a genuine mid-capture crash (no marker — Stop was never pressed, nil/nil
    /// current-settings fallback is the documented legacy semantics) and by a failed
    /// `recordVoiceCommandSnapshot` write after Stop (marker present — the exact stop-time policy
    /// must be restored instead of silently falling back). A session whose snapshot columns are
    /// already populated skips this entirely. Callers must NOT fold this into a broader
    /// segment/audio-corruption `catch` (Codex round-3 finding 1): a transient failure here is a
    /// metadata/storage problem, not evidence of damaged audio, and must be reported so
    /// reconciliation retries on the next pass instead of quarantining healthy capture state.
    private func hydrateVoiceCommandIntent(for session: CaptureSession) async throws {
        guard session.voiceCommandsEnabled == nil else { return }
        let marker = VoiceCommandFinalizationIntent.markerURL(in: session.directory)
        guard fileSystem.exists(marker) else { return }
        let intent = try JSONDecoder().decode(
            VoiceCommandFinalizationIntent.self, from: try fileSystem.read(marker)
        )
        try await ledger.recordVoiceCommandSnapshot(
            id: session.id, enabled: intent.enabled, keywords: intent.keywords
        )
    }

    /// Re-inventories the capture directory for `session` against the ledger's committed-segment
    /// list before trusting it for assembly (Codex round-5 finding 1). `CaptureJournalWriter.
    /// commit` durably renames a segment file to its final `segment-NNNNNNNN.wav` name BEFORE the
    /// matching `ledger.recordCommittedSegment` call — a crash in that window leaves a segment
    /// file on disk the ledger doesn't know about. The live writer repairs this via its own
    /// `bootstrap()` on resume, but reconciliation runs independently of any live writer and never
    /// calls it, so without this the known-session `.capturing` path would silently trust a
    /// partial ledger inventory and assemble truncated audio — or, when the ledger reports ZERO
    /// committed segments because the crash landed before even the first insert, wrongly conclude
    /// "no committed audio" and quarantine/discard audio that is sitting right there on disk.
    /// Mirrors `CaptureJournalWriter.bootstrap()`'s orphan-adoption: only a CONTIGUOUS run of
    /// orphans (ordinal == committed.count) is adopted — a gap is real evidence of a missing/
    /// corrupt segment and must fail loudly (propagating to `report.recordFailure`, retried next
    /// pass), never be silently skipped.
    private func reconcileSegmentInventory(for session: CaptureSession) async throws -> [CaptureSegment] {
        var committed = try await ledger.committedSegments(captureID: session.id)
        committed.sort { $0.ordinal < $1.ordinal }
        guard fileSystem.exists(session.directory) else { return committed }
        let knownOrdinals = Set(committed.map(\.ordinal))
        let codec = CaptureSegmentCodec(fileSystem: fileSystem)
        let files = try fileSystem.contents(session.directory)
        let orphanURLs = files.compactMap { url -> (Int, URL)? in
            guard url.pathExtension == "wav", let ordinal = CaptureSegmentCodec.ordinal(from: url),
                  !knownOrdinals.contains(ordinal) else { return nil }
            return (ordinal, url)
        }.sorted { $0.0 < $1.0 }
        for (ordinal, url) in orphanURLs {
            guard ordinal == committed.count else {
                throw CaptureJournalError.invalidOrdinal(expected: committed.count, actual: ordinal)
            }
            let data = try fileSystem.read(url)
            let samples = try codec.decode(url)
            let segment = CaptureSegment(
                captureID: session.id, ordinal: ordinal, url: url,
                sampleCount: samples.count, contentHash: codec.hash(data)
            )
            try await ledger.recordCommittedSegment(segment)
            committed.append(segment)
        }
        return committed
    }

    /// Codex round-7 finding 6: the quarantine fallback used to be `segments.first?.url`
    /// unconditionally — if segment 0 itself was the corrupted one that made `assemble` fail,
    /// quarantine would import THAT corrupted file as "recovered" audio while discarding every
    /// later, genuinely healthy segment. Scans in ordinal order for the first segment that
    /// validates cleanly; `nil` when none survive falls back to `quarantineJournal`'s fixed,
    /// non-colliding `capture-failure.marker` path.
    ///
    /// Codex round-9 finding 2: uses `codec.validate(segment)` — the same full check `assemble`
    /// applies to every segment (ordinal/filename match, persisted content hash, persisted sample
    /// count, THEN WAV syntax) — not a bare WAV-syntax decode. A structurally valid WAV whose
    /// bytes don't match its ledger-recorded hash/sample count (e.g. a partial overwrite that
    /// still parses) is exactly as much corruption evidence as a bad header and must not be
    /// selected over a later, genuinely healthy segment. `throws` instead of swallowing every
    /// failure: only a deterministic `CaptureJournalError` from `validate` is evidence THIS
    /// segment didn't survive — any other error (a transient read failure) must propagate to the
    /// caller's `report.recordFailure` for retry, never be silently read as "no segment survived"
    /// and converted into permanent audio loss.
    private func firstValidatedSurvivingSegment(_ segments: [CaptureSegment]) throws -> URL? {
        let codec = CaptureSegmentCodec(fileSystem: fileSystem)
        for segment in segments.sorted(by: { $0.ordinal < $1.ordinal }) {
            guard fileSystem.exists(segment.url) else { continue }
            do {
                _ = try codec.validate(segment)
                return segment.url
            } catch is CaptureJournalError {
                continue
            }
        }
        return nil
    }

    /// Codex round-9 finding 4: `error`'s associated path for the specific CaptureJournalError
    /// variants `reconcileSegmentInventory` can throw while inventorying a newly discovered,
    /// never-ledger-committed orphan segment file.
    private static func orphanPath(from error: CaptureJournalError) -> String? {
        switch error {
        case .invalidWAV(let path), .invalidSampleCount(let path), .hashMismatch(let path):
            return path
        default:
            return nil
        }
    }

    /// Codex round-9 finding 4 — see the two call sites above. `reconcileSegmentInventory` throws
    /// evidence of a malformed/EISDIR orphan BEFORE it's ever recorded via
    /// `ledger.recordCommittedSegment`, so it falls outside every set the eventual Library-
    /// committed cleanup (`RecoveryCaptureService.cleanupLibraryCommittedSession`) removes —
    /// left in place, it permanently strands that cleanup in `cleanupNotPermitted`. Must be
    /// durably cleared here, before `quarantineJournal` registers the fallback recovery.
    ///
    /// A malformed orphan is always a regular file (`reconcileSegmentInventory` only reaches the
    /// WAV-decode failure after `fileSystem.read` already succeeded on it) and is safe to remove
    /// outright — its bytes are already proven corrupt. An EISDIR orphan's directory contents are
    /// unknown and were never written by this subsystem's own segment writer (which only ever
    /// creates regular files at this path), so it must never be recursively deleted; it's only
    /// reclaimed when provably empty (a safe, non-recursive removal). A non-empty foreign
    /// directory is left untouched and surfaces later as `cleanupNotPermitted` — the same durable,
    /// distinct failure mode this subsystem already treats as correct for genuinely unexpected
    /// content (see the round-6 finding-4 residue handling in `RecoveryCaptureService`).
    private func clearOwnedOrphan(atPath path: String) throws {
        let url = URL(fileURLWithPath: path)
        guard fileSystem.exists(url) else { return }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return }
        if isDirectory.boolValue {
            // Codex round-10 minor 1: an emptiness check here followed by `remove(_:)` was a TOCTOU
            // race — content added to this directory between the check and the recursive delete
            // would be silently destroyed along with it. `removeEmptyDirectory` uses non-recursive
            // `rmdir(2)` instead: it atomically fails with `ENOTEMPTY` if the directory gained
            // content in that window, so unexpected content is always left untouched (the same
            // "leave it, surface `cleanupNotPermitted` later" outcome the prior empty-check produced
            // on the happy path), never swept away.
            do {
                try fileSystem.removeEmptyDirectory(url)
            } catch JournalPersistenceError.remove(_, let code) where code == ENOTEMPTY {
                return
            }
        } else {
            try fileSystem.remove(url)
        }
        try fileSystem.synchronizeDirectory(url.deletingLastPathComponent())
    }

    /// Codex round-11 blocker — see the `.damaged` case in `reconcileKnownSession`. The
    /// malformed-orphan/EISDIR catches in the `.capturing` branch each durably transition to
    /// `.damaged` BEFORE clearing the specific orphan that triggered them (round-10's fix,
    /// preserved here); a crash in that exact window leaves the orphan on disk with the session
    /// already `.damaged`. The next reconciliation pass never re-enters those catches (the
    /// session is no longer `.capturing`), so without this the orphan would never be revisited —
    /// it isn't a recognized residual-artifact shape (`RecoveryCaptureService.
    /// isRecognizedResidualArtifactName` only matches hidden `.tmp` temporaries), so it would
    /// permanently strand the eventual Library-committed cleanup in `cleanupNotPermitted`.
    ///
    /// Deliberately rescans rather than durably recording a pending-orphan path in the ledger at
    /// transition time: every input this needs to rediscover an orphan — its segment-name shape
    /// on disk and its absence from `ledger.committedSegments` — is already durable and cheap to
    /// recompute on every pass, unlike genuinely destroyed evidence (e.g. the corruption bytes
    /// `clearOwnedOrphan` removes) that only durable state could preserve. Extra ledger state
    /// here would only add its own new crash windows for no retry benefit, so retry-by-rescan is
    /// the simplest idempotent fix.
    ///
    /// Codex round-12 blocker: ordinal absence from `ledger.committedSegments` is evidence the
    /// segment was never RECORDED — it is not evidence the segment is CORRUPT. `CaptureJournal
    /// Writer.commit` durably renames a segment file into place, THEN calls `ledger.
    /// recordCommittedSegment` — a failure in that insert (the file already exists) propagates to
    /// `CaptureJournalService.preserveFailure`, which transitions the session straight to
    /// `.damaged` regardless of the segment's validity. The unconditional delete this method used
    /// to perform on every segment-shaped, unledgered name would then destroy perfectly healthy
    /// audio on the very next reconciliation pass. Each candidate is now decoded before any
    /// decision is made, mirroring how `reconcileSegmentInventory` treats a freshly discovered
    /// `.capturing`-state orphan:
    ///   - decodes cleanly → ADOPTED via `ledger.recordCommittedSegment`, never deleted, so it
    ///     becomes visible to survivor/fallback selection and owned by normal cleanup instead of
    ///     permanently unrecognized disk residue;
    ///   - a deterministic `CaptureJournalError` (bad WAV header, sample-count overflow) or an
    ///     EISDIR read is exactly as much corruption evidence as the malformed-orphan/EISDIR
    ///     catches above use, and is cleared via `clearOwnedOrphan` exactly as before;
    ///   - any other error (a transient read failure) must propagate to `report.recordFailure` for
    ///     retry — same contract `reconcileSegmentInventory` and `firstValidatedSurvivingSegment`
    ///     already hold, never silently read as "abandoned" and converted into permanent loss.
    /// Unlike `reconcileSegmentInventory`, adoption here deliberately does NOT require ordinals to
    /// be contiguous: the `.damaged` branch is terminal and never calls `assemble()`, so a gap is
    /// not evidence of anything and enforcing it would either loop forever on `invalidOrdinal` or
    /// strand a later, independently-valid ordinal behind an earlier one that never turns up. Each
    /// valid segment is adopted independently, purely so it is durably owned rather than orphaned.
    ///
    /// Codex round-12 blocker: `CaptureSegmentCodec.ordinal(from:)` strips only the LAST path
    /// extension before matching the `segment-` prefix — it accepts any extension (e.g.
    /// `segment-00000000.txt`), not just `.wav`. `reconcileSegmentInventory`'s own orphan
    /// discovery already ANDs this with `pathExtension == "wav"`; this rescan is fixed to match,
    /// so a non-WAV name that merely looks segment-shaped is left untouched — surfacing later as
    /// unexpected content, never adopted or deleted on name-shape alone.
    private func clearUnledgeredOrphanSegments(for session: CaptureSession) async throws {
        guard fileSystem.exists(session.directory) else { return }
        let knownOrdinals = Set(
            try await ledger.committedSegments(captureID: session.id).map(\.ordinal)
        )
        let codec = CaptureSegmentCodec(fileSystem: fileSystem)
        let candidates = try fileSystem.contents(session.directory).compactMap { item -> (Int, URL)? in
            guard item.pathExtension == "wav",
                  let ordinal = CaptureSegmentCodec.ordinal(from: item),
                  !knownOrdinals.contains(ordinal) else { return nil }
            return (ordinal, item)
        }.sorted { $0.0 < $1.0 }
        for (ordinal, item) in candidates {
            var rejectedSnapshot: Data?
            do {
                // Codex round-13 minor: read once into a single `Data` snapshot and decode/hash
                // from THAT snapshot — the previous two-read form (`fileSystem.read` for hashing,
                // then a separate `codec.decode(item)` re-reading the same URL) let a concurrent
                // replacement of `item` between the two reads persist a hash/sample-count pair
                // that doesn't match either version of the file's actual bytes.
                let data = try fileSystem.read(item)
                rejectedSnapshot = data
                let samples = try codec.decode(data, path: item.path)
                let segment = CaptureSegment(
                    captureID: session.id, ordinal: ordinal, url: item,
                    sampleCount: samples.count, contentHash: codec.hash(data)
                )
                try await ledger.recordCommittedSegment(segment)
            } catch is CaptureJournalError {
                // Codex round-14: the capture writer is dead during reconciliation, so this is
                // theoretical, but cheap to close outright — re-verify identity against the exact
                // bytes that failed decode before deleting. If `item` was atomically replaced
                // between the read above and here, its current hash no longer matches the
                // rejected snapshot's, and the (possibly healthy) replacement must survive; the
                // next reconciliation pass re-evaluates it from scratch.
                if let rejectedSnapshot, (try? codec.hashFile(item)) == codec.hash(rejectedSnapshot) {
                    try clearOwnedOrphan(atPath: item.path)
                }
            } catch let error as JournalPersistenceError {
                guard case .read(_, let code) = error, code == EISDIR else { throw error }
                try clearOwnedOrphan(atPath: item.path)
            }
        }
    }

    /// Codex round-10 blocker — see the two call sites above. Durably transitions `session`
    /// (always reached in the `.capturing` state) to `.damaged` and returns the persisted row,
    /// mirroring `reconcileLibraryOwnedSession`'s identical transition-then-refetch pattern so the
    /// caller's local snapshot reflects the durable state before it's handed to `quarantineJournal`,
    /// whose own `session.state == .capturing || .staged` guard then correctly skips re-transitioning.
    private func transitionToDamaged(_ session: CaptureSession, message: String) async throws -> CaptureSession {
        try await ledger.transition(
            id: session.id, from: .capturing, to: .damaged,
            recoveryJobID: session.recoveryJobID ?? session.id, libraryDictationID: nil,
            assetKind: .quarantined, failureMessage: message,
            contentHash: session.contentHash
        )
        return try await ledger.session(id: session.id) ?? session
    }

    private func quarantineJournal(
        _ session: CaptureSession, fallback: URL?, message: String
    ) async throws {
        if session.state == .capturing || session.state == .staged {
            try await ledger.transition(
                id: session.id, from: session.state, to: .damaged,
                recoveryJobID: session.recoveryJobID ?? session.id, libraryDictationID: nil,
                assetKind: .quarantined, failureMessage: message,
                contentHash: session.contentHash
            )
        }
        let source = fallback ?? session.directory.appendingPathComponent("capture-failure.marker")
        if !fileSystem.exists(source) {
            let temporary = source.deletingLastPathComponent().appendingPathComponent(
                ".capture-failure.\(UUID().uuidString).tmp"
            )
            try DurableArtifactWriter(fileSystem: fileSystem).commit(
                Data(message.utf8), temporary: temporary, destination: source
            )
        }
        let result: LegacyRecoveryImporter.Result
        if let existing = try await importer.existingOwnedLegacyResult(source, id: session.id) {
            result = existing
        } else {
            result = try await importer.importAudio(
                source, preferredID: session.id, forceQuarantine: true
            )
        }
        if result == .disposed {
            if let job = try await store.job(id: session.id) {
                _ = try await store.deleteCommittedRecovery(
                    id: job.id, expectedSourceReference: job.source.reference
                )
            }
            guard let current = try await ledger.session(id: session.id) else { return }
            if current.state != .cancelling {
                try await ledger.transition(
                    id: current.id, from: current.state, to: .cancelling,
                    recoveryJobID: current.recoveryJobID,
                    libraryDictationID: current.libraryDictationID,
                    assetKind: current.assetKind, failureMessage: current.failureMessage,
                    contentHash: current.contentHash
                )
            }
            try await CaptureJournalService(fileSystem: fileSystem, ledger: ledger)
                .resumeCleanup(captureID: current.id)
        }
    }

    private func reconcilePreparationMarker(
        _ marker: URL, report: inout RecoveryReconciliationReport
    ) async throws {
        guard let id = Self.preparationCaptureID(marker) else { return }
        if try await libraryDictationID(id) != nil {
            try fileSystem.remove(marker)
            try fileSystem.synchronizeDirectory(marker.deletingLastPathComponent())
            return
        }
        let existed = try await ledger.session(id: id) != nil
        let captureDirectory = directory.appendingPathComponent(id.uuidString)
        try await createDamagedOwnership(
            id: id, directory: captureDirectory, source: marker,
            message: "Capture preparation was interrupted"
        )
        if existed { report.duplicates += 1 } else { report.quarantined += 1 }
    }

    private func reconcilePendingMarker(
        _ marker: URL, report: inout RecoveryReconciliationReport
    ) async throws {
        let stem = marker.deletingPathExtension().lastPathComponent
        guard let captureID = UUID(uuidString: stem) else { return }
        let finalAudio = directory.appendingPathComponent("\(stem).wav")
        let temporaryAudio = directory.appendingPathComponent(".\(stem).tmp")
        let source = fileSystem.exists(finalAudio) ? finalAudio : temporaryAudio
        guard fileSystem.exists(source) else {
            throw CaptureJournalError.invalidWAV(finalAudio.path)
        }
        if try await libraryDictationID(captureID) != nil {
            try await cleanupLibraryOwnedLoose(captureID, artifact: finalAudio)
            try fileSystem.remove(marker)
            try fileSystem.synchronizeDirectory(directory)
            return
        }
        report.add(try await importer.importAudio(source, preferredID: captureID))
        try fileSystem.remove(marker)
        try fileSystem.synchronizeDirectory(directory)
    }

    private func reconcileSessionDirectory(
        _ sessionDirectory: URL, report: inout RecoveryReconciliationReport
    ) async throws {
        guard let id = Self.directoryCaptureID(sessionDirectory) else { return }
        if try await libraryDictationID(id) != nil {
            try await cleanupLibraryOwnedLoose(id, artifact: sessionDirectory)
            return
        }
        let items = try fileSystem.contents(sessionDirectory).sorted { $0.path < $1.path }
        let canonical = sessionDirectory.appendingPathComponent("\(id.uuidString).wav")
        if fileSystem.exists(canonical) {
            try await importCanonical(canonical, id: id)
            report.imported += 1
            return
        }
        // Codex round-13: same unfiltered `ordinal(from:) != nil` pattern flagged as a blocker in
        // the `.damaged` fallback above, but benign here — a non-WAV segment-shaped name either
        // breaks the ordinal-contiguity check below (loud throw, no ledger/disk mutation) or, if
        // it coincidentally fills a contiguous ordinal gap, fails `codec.decode` before it's ever
        // `ledger.recordCommittedSegment`-ed or read by `assemble`'s `validatedData`, so its bytes
        // can never reach the canonical output the way the raw-copy fallback above could.
        let segments = items.filter { CaptureSegmentCodec.ordinal(from: $0) != nil }
        if !segments.isEmpty {
            // Codex round-7 finding 8: validate the FULL ordinal sequence is contiguous from 0
            // before recording (or creating ownership of) ANY of these orphan segments. Recording
            // a gapped subset (e.g. ordinals 0 and 2, missing 1) durably commits ownership of a
            // partial inventory — the next reconciliation pass sees an already-owned session whose
            // segments are already ledger-committed, not "newly discovered orphans", so
            // `reconcileSegmentInventory`'s own contiguity guard never revisits them, and the
            // resulting `assemble` failure silently quarantines down to a single segment instead
            // of continuing to fail loudly while ordinal 1 might still show up on disk.
            let orderedSegments = segments.sorted {
                (CaptureSegmentCodec.ordinal(from: $0) ?? 0) < (CaptureSegmentCodec.ordinal(from: $1) ?? 0)
            }
            for (expectedOrdinal, url) in orderedSegments.enumerated() {
                guard CaptureSegmentCodec.ordinal(from: url) == expectedOrdinal else {
                    throw CaptureJournalError.invalidOrdinal(
                        expected: expectedOrdinal, actual: CaptureSegmentCodec.ordinal(from: url) ?? -1
                    )
                }
            }
            let request = Self.request(id: id, directory: sessionDirectory)
            let created = try await ledger.createCapture(request)
            let codec = CaptureSegmentCodec(fileSystem: fileSystem)
            var records: [CaptureSegment] = []
            for url in orderedSegments {
                guard let ordinal = CaptureSegmentCodec.ordinal(from: url) else { continue }
                let samples = try codec.decode(url)
                let record = CaptureSegment(
                    captureID: id, ordinal: ordinal, url: url,
                    sampleCount: samples.count, contentHash: try codec.hashFile(url)
                )
                // Segment metadata is recorded in the ledger BEFORE hydration (Codex round-4
                // finding 2): if hydration throws (or the process dies) after ownership exists but
                // before every segment is durably recorded, the next reconciliation pass must still
                // find committed segments via `ledger.committedSegments` and resume from them —
                // reversing this order left a window where a hydration failure produced an owned
                // session with zero committed ledger segments, and the still-present segment files
                // on disk were never reconsidered (quarantined as "no committed audio").
                try await ledger.recordCommittedSegment(record)
                records.append(record)
            }
            // Orphan-segment reconstruction (Codex round-3 finding 2): hydrate the durable
            // stop-time intent marker on the freshly created capture row before staging or
            // registering the assembled audio, mirroring the orphan-canonical path above. Now
            // ordered after segment recording (Codex round-4 finding 2) so a failure here is
            // resumable from the already-durable segment inventory on the next pass.
            try await hydrateVoiceCommandIntent(for: created)
            let assembled = try codec.assemble(segments: records.sorted { $0.ordinal < $1.ordinal }, canonicalURL: canonical)
            try await ledger.transition(
                id: id, from: .capturing, to: .staged, recoveryJobID: nil,
                libraryDictationID: nil, assetKind: .audio, failureMessage: nil,
                contentHash: assembled.contentHash
            )
            try await registerCanonical(canonical, id: id)
            report.imported += 1
            return
        }
        if let failureMarker = items.first(where: { $0.lastPathComponent == "capture-failure.marker" }) {
            try await createDamagedOwnership(
                id: id, directory: sessionDirectory, source: failureMarker,
                message: "Capture journal failed before recoverable audio was committed"
            )
            report.quarantined += 1
        }
    }

    private func reconcileLooseAudio(
        _ audio: URL, report: inout RecoveryReconciliationReport
    ) async throws {
        let stem = audio.deletingPathExtension().lastPathComponent
        if let id = UUID(uuidString: stem) {
            if try await libraryDictationID(id) != nil {
                try await cleanupLibraryOwnedLoose(id, artifact: audio)
                return
            }
            if let existing = try await importer.existingOwnedLegacyResult(audio, id: id) {
                report.add(existing)
            } else {
                report.add(try await importer.importAudio(audio, preferredID: id))
            }
        } else if stem.hasPrefix("failed-") {
            report.add(try await importer.importAudio(audio))
        }
    }

    private func importCanonical(_ audio: URL, id: UUID) async throws {
        let codec = CaptureSegmentCodec(fileSystem: fileSystem)
        _ = try codec.decode(audio)
        let request = Self.request(id: id, directory: audio.deletingLastPathComponent())
        let current: CaptureSession
        do {
            current = if let existing = try await ledger.session(id: id) {
                existing
            } else {
                try await ledger.createCapture(request)
            }
        }
        catch { throw RecoveryReconciliationOperationError(operation: "create capture ownership", underlying: error) }
        // Orphan and crash-recreated canonical audio share this path (Codex round-3 finding 2):
        // hydrate the durable stop-time intent marker before staging/registering so a freshly
        // created capture row doesn't inherit a NULL snapshot despite an exact intent on disk.
        do { try await hydrateVoiceCommandIntent(for: current) }
        catch { throw RecoveryReconciliationOperationError(operation: "hydrate voice command intent", underlying: error) }
        if current.state == .capturing {
            do {
                try await ledger.transition(
                    id: id, from: .capturing, to: .staged, recoveryJobID: nil,
                    libraryDictationID: nil, assetKind: .audio, failureMessage: nil,
                    contentHash: try codec.hashFile(audio)
                )
            } catch { throw RecoveryReconciliationOperationError(operation: "stage orphan audio", underlying: error) }
        }
        do { try await registerCanonical(audio, id: id) }
        catch { throw RecoveryReconciliationOperationError(operation: "register orphan recovery", underlying: error) }
    }

    private func cleanupLibraryOwnedLoose(_ id: UUID, artifact: URL) async throws {
        if let job = try await store.job(id: id) {
            _ = try await store.deleteCommittedRecovery(
                id: id, expectedSourceReference: job.source.reference
            )
        }
        if fileSystem.exists(artifact) { try fileSystem.remove(artifact) }
        try fileSystem.synchronizeDirectory(artifact.deletingLastPathComponent())
    }

    private func registerCanonical(_ audio: URL, id: UUID) async throws {
        try await registrationRetrier.run {
            try await self.beforeRegistrationAttempt()
            // Read the session BEFORE (re)creating the provisional job so a recreated job
            // inherits its durable voice command snapshot (PLAN.md PR A, item 1b) — `nil`/`nil`
            // when the session never staged with one (e.g. a crash during capture, before
            // `CaptureJournalService.finish` ever ran).
            let session = try await self.ledger.session(id: id)
            var job = if let existing = try await self.store.job(id: id) {
                existing
            } else {
                try await self.store.createProvisionalRecovery(
                    id: id, source: JobSource(reference: audio.path), capturedAt: Date(),
                    voiceCommandsEnabled: session?.voiceCommandsEnabled,
                    commandKeywords: session?.commandKeywords
                )
            }
            if let session, session.state == .staged {
                try await self.ledger.transition(
                    id: id, from: .staged, to: .processing, recoveryJobID: job.id,
                    libraryDictationID: nil, assetKind: .audio,
                    failureMessage: session.failureMessage, contentHash: session.contentHash
                )
                job = try await self.store.job(id: id) ?? job
            }
            if case .processing = job.state {
                try await self.store.failProvisionalRecovery(
                    id: id,
                    failure: JobFailure(stage: .preparing, message: "Interrupted recording is ready to retry")
                )
            }
        }
    }

    private func createDamagedOwnership(
        id: UUID, directory: URL, source: URL, message: String
    ) async throws {
        let session: CaptureSession
        do {
            session = if let existing = try await ledger.session(id: id) {
                existing
            } else {
                try await ledger.createCapture(Self.request(id: id, directory: directory))
            }
        }
        catch { throw RecoveryReconciliationOperationError(operation: "create damaged ownership", underlying: error) }
        if session.state == .capturing {
            do {
                try await ledger.transition(
                    id: id, from: .capturing, to: .damaged, recoveryJobID: id,
                    libraryDictationID: nil, assetKind: .quarantined,
                    failureMessage: message, contentHash: nil
                )
            } catch { throw RecoveryReconciliationOperationError(operation: "mark ownership damaged", underlying: error) }
        }
        do {
            let result = try await importer.importAudio(
                source, preferredID: id, forceQuarantine: true
            )
            if result == .disposed,
               let current = try await ledger.session(id: session.id) {
                if current.state != .cancelling {
                    try await ledger.transition(
                        id: current.id, from: current.state, to: .cancelling,
                        recoveryJobID: current.recoveryJobID,
                        libraryDictationID: current.libraryDictationID,
                        assetKind: current.assetKind, failureMessage: current.failureMessage,
                        contentHash: current.contentHash
                    )
                }
                try await CaptureJournalService(fileSystem: fileSystem, ledger: ledger)
                    .resumeCleanup(captureID: current.id)
            }
        } catch { throw RecoveryReconciliationOperationError(operation: "register damaged recovery", underlying: error) }
    }

    private static func request(id: UUID, directory: URL) -> CaptureStartRequest {
        CaptureStartRequest(
            id: id, directory: directory, capturedAt: Date(),
            sampleRate: Double(CaptureSegmentCodec.sampleRate),
            channelCount: CaptureSegmentCodec.channelCount,
            inputDeviceUID: nil, destination: "recovered"
        )
    }

    private static func directoryCaptureID(_ url: URL) -> UUID? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return UUID(uuidString: url.lastPathComponent)
    }

    private static func preparationCaptureID(_ url: URL) -> UUID? {
        let name = url.lastPathComponent
        let prefix = ".capture-preparation-"
        let suffix = ".marker"
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return nil }
        return UUID(uuidString: String(name.dropFirst(prefix.count).dropLast(suffix.count)))
    }

    private static func isPendingMarker(_ url: URL) -> Bool {
        url.pathExtension == "pending"
            && UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil
    }
}

private extension RecoveryReconciliationReport {
    mutating func add(_ result: LegacyRecoveryImporter.Result) {
        switch result {
        case .imported: imported += 1
        case .duplicate: duplicates += 1
        case .quarantined: quarantined += 1
        case .disposed: duplicates += 1
        }
    }
}
