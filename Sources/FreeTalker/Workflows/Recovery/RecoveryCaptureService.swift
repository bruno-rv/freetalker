import Darwin
import Foundation

struct RecoveryMetadata: Sendable, Equatable {
    let capturedAt: Date
    let failure: JobFailure
}

struct ProvisionalRecoveryCapture: Sendable, Equatable {
    let id: UUID
    let source: JobSource
}

struct StagedRecoveryCapture: Sendable, Equatable {
    let source: JobSource
    let capturedAt: Date
    let marker: URL
}

struct RecoveryCaptureRollbackError: Error {
    let persistenceError: any Error
    let rollbackError: any Error
}

struct RecoveryPurgeClaim: Sendable, Equatable {
    let id: UUID
    let sourceReference: String
    let claimedAt: Date
    let cleanupError: String?
}

protocol RecoveryFileRemoving: Sendable {
    func removeItem(at url: URL) throws
}

struct SystemRecoveryFileRemover: RecoveryFileRemoving {
    func removeItem(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }
}

protocol RecoveryJobStoring: Sendable {
    func job(id: UUID) async throws -> TranscriptionJob?
    func createProvisionalRecovery(source: JobSource, capturedAt: Date) async throws -> TranscriptionJob
    func createProvisionalRecovery(
        id: UUID, source: JobSource, capturedAt: Date,
        voiceCommandsEnabled: Bool?, commandKeywords: [String]?
    ) async throws -> TranscriptionJob
    func failProvisionalRecovery(id: UUID, failure: JobFailure) async throws
    func deleteProvisionalRecovery(id: UUID, expectedSourceReference: String) async throws -> Bool
    func deleteCommittedRecovery(id: UUID, expectedSourceReference: String) async throws -> Bool
    func createRecovery(source: JobSource, metadata: RecoveryMetadata) async throws -> TranscriptionJob
    func claimExpiredRecoveries(cutoff: Date, claimedAt: Date) async throws -> [RecoveryPurgeClaim]
    func claimedRecoveries() async throws -> [RecoveryPurgeClaim]
    func recordPurgeError(id: UUID, message: String) async throws
    func deleteClaimedRecovery(id: UUID, expectedSourceReference: String) async throws -> Bool
}

extension TranscriptionJobStore: RecoveryJobStoring {}

enum RecoveryFinalizationError: Error, Equatable {
    case libraryOwnershipMissing(UUID)
    case captureIdentityMismatch
    case recoveryJobMismatch
}

struct RecoveryCaptureService: Sendable {
    private let directory: URL
    private let store: any RecoveryJobStoring
    private let fileRemover: any RecoveryFileRemoving
    private let ledger: (any CaptureLedgerStoring)?
    private let journalFileSystem: any JournalFileSystem
    private let libraryDictationID: @Sendable (UUID) async throws -> Int64?

    init(
        directory: URL,
        store: any RecoveryJobStoring,
        fileRemover: any RecoveryFileRemoving = SystemRecoveryFileRemover(),
        ledger: (any CaptureLedgerStoring)? = nil,
        journalFileSystem: any JournalFileSystem = LocalJournalFileSystem(),
        libraryDictationID: @escaping @Sendable (UUID) async throws -> Int64? = { _ in nil }
    ) {
        self.directory = directory.standardizedFileURL
        self.store = store
        self.fileRemover = fileRemover
        self.ledger = ledger
        self.journalFileSystem = journalFileSystem
        self.libraryDictationID = libraryDictationID
    }

    func stageProvisional(samples: [Float], capturedAt: Date) throws -> StagedRecoveryCapture {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stem = UUID().uuidString
        let temporaryAudio = directory.appendingPathComponent(".\(stem).tmp")
        let finalAudio = directory.appendingPathComponent("\(stem).wav")
        let temporaryMarker = directory.appendingPathComponent(".\(stem).pending.tmp")
        let finalMarker = directory.appendingPathComponent("\(stem).pending")
        var markerCommitted = false
        do {
            try writeSynchronously(WAVEncoder.encode(samples: samples, sampleRate: 16_000), to: temporaryAudio)
            try writeSynchronously(
                Data(String(capturedAt.timeIntervalSince1970).utf8),
                to: temporaryMarker
            )
            try FileManager.default.moveItem(at: temporaryMarker, to: finalMarker)
            markerCommitted = true
            try FileManager.default.moveItem(at: temporaryAudio, to: finalAudio)
            return StagedRecoveryCapture(
                source: JobSource(reference: finalAudio.path),
                capturedAt: capturedAt,
                marker: finalMarker
            )
        } catch {
            if !markerCommitted {
                try? FileManager.default.removeItem(at: temporaryAudio)
                try? FileManager.default.removeItem(at: temporaryMarker)
            }
            throw error
        }
    }

    func registerProvisional(_ staged: StagedRecoveryCapture) async throws -> ProvisionalRecoveryCapture {
        let job = try await store.createProvisionalRecovery(
            source: staged.source,
            capturedAt: staged.capturedAt
        )
        try registerOwnership(id: job.id, source: URL(fileURLWithPath: job.source.reference))
        if FileManager.default.fileExists(atPath: staged.marker.path) {
            try FileManager.default.removeItem(at: staged.marker)
        }
        return ProvisionalRecoveryCapture(id: job.id, source: job.source)
    }

    func preserveProvisional(samples: [Float], capturedAt: Date) async throws -> ProvisionalRecoveryCapture {
        try await registerProvisional(stageProvisional(samples: samples, capturedAt: capturedAt))
    }

    func reconcileStagedProvisionalCaptures() async throws -> [ProvisionalRecoveryCapture] {
        let markers = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { url in
            url.pathExtension == "pending"
                && UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil
        }.sorted { $0.path < $1.path }

        var captures: [ProvisionalRecoveryCapture] = []
        for marker in markers {
            let stem = marker.deletingPathExtension().lastPathComponent
            let finalAudio = directory.appendingPathComponent("\(stem).wav")
            let temporaryAudio = directory.appendingPathComponent(".\(stem).tmp")
            if !FileManager.default.fileExists(atPath: finalAudio.path) {
                guard FileManager.default.fileExists(atPath: temporaryAudio.path) else { continue }
                try FileManager.default.moveItem(at: temporaryAudio, to: finalAudio)
            }
            let timestamp = String(decoding: try Data(contentsOf: marker), as: UTF8.self)
            let staged = StagedRecoveryCapture(
                source: JobSource(reference: finalAudio.path),
                capturedAt: Double(timestamp).map(Date.init(timeIntervalSince1970:)) ?? Date(),
                marker: marker
            )
            captures.append(try await registerProvisional(staged))
        }
        return captures
    }

    func failProvisional(_ capture: ProvisionalRecoveryCapture, failure: JobFailure) async throws {
        try await store.failProvisionalRecovery(id: capture.id, failure: failure)
    }

    func registerJournalCapture(_ staged: StagedCapture, capturedAt: Date) async throws -> ProvisionalRecoveryCapture {
        let session = try await ledger?.session(id: staged.captureID)
        // Inherits the session's durable voice command snapshot into the provisional job (PLAN.md
        // PR A, item 1b) — `nil`/`nil` when the session never staged with one (legacy).
        let job = try await store.createProvisionalRecovery(
            id: staged.captureID,
            source: JobSource(reference: staged.canonicalAudioURL.path),
            capturedAt: session?.capturedAt ?? capturedAt,
            voiceCommandsEnabled: session?.voiceCommandsEnabled,
            commandKeywords: session?.commandKeywords
        )
        guard job.id == staged.captureID else {
            throw RecoveryFinalizationError.captureIdentityMismatch
        }
        SmokeCheckpoint.hit(.postJobCreate)
        if let ledger {
            guard let session else {
                throw RecoveryFinalizationError.captureIdentityMismatch
            }
            if session.state == .staged {
                try await ledger.transition(
                    id: staged.captureID, from: .staged, to: .processing,
                    recoveryJobID: job.id, libraryDictationID: nil,
                    assetKind: session.assetKind,
                    failureMessage: session.failureMessage,
                    contentHash: session.contentHash
                )
            }
        }
        return ProvisionalRecoveryCapture(id: job.id, source: job.source)
    }

    func completeJournalCapture(
        _ capture: ProvisionalRecoveryCapture,
        captureID: UUID
    ) async throws {
        guard capture.id == captureID else {
            throw RecoveryFinalizationError.captureIdentityMismatch
        }
        guard let ledger else {
            throw RecoveryFinalizationError.captureIdentityMismatch
        }
        guard let dictationID = try await libraryDictationID(captureID) else {
            throw RecoveryFinalizationError.libraryOwnershipMissing(captureID)
        }
        guard let session = try await ledger.session(id: captureID) else {
            throw RecoveryFinalizationError.captureIdentityMismatch
        }
        guard session.recoveryJobID == nil || session.recoveryJobID == capture.id else {
            throw RecoveryFinalizationError.recoveryJobMismatch
        }
        if session.state == .processing {
            try await ledger.transition(
                id: captureID, from: .processing, to: .libraryCommitted,
                recoveryJobID: capture.id, libraryDictationID: dictationID,
                assetKind: session.assetKind,
                failureMessage: session.failureMessage,
                contentHash: session.contentHash
            )
            SmokeCheckpoint.hit(.postLibraryCommitted)
        } else {
            guard session.state == .libraryCommitted,
                  session.libraryDictationID == dictationID else {
                throw JobStoreError.invalidTransition
            }
        }

        guard let committed = try await ledger.session(id: captureID) else {
            throw RecoveryFinalizationError.captureIdentityMismatch
        }
        try await cleanupLibraryCommittedSession(committed)
    }

    func resumeLibraryCommittedCaptures() async throws {
        guard let ledger else {
            throw RecoveryFinalizationError.captureIdentityMismatch
        }
        for session in try await ledger.unfinishedSessions()
        where session.state == .libraryCommitted {
            guard let dictationID = try await libraryDictationID(session.id),
                  dictationID == session.libraryDictationID else {
                throw RecoveryFinalizationError.libraryOwnershipMissing(session.id)
            }
            try await cleanupLibraryCommittedSession(session)
        }
    }

    func resumeLibraryCommittedCapture(captureID: UUID) async throws {
        guard let ledger,
              let session = try await ledger.session(id: captureID),
              session.state == .libraryCommitted else { return }
        guard let dictationID = try await libraryDictationID(captureID),
              dictationID == session.libraryDictationID else {
            throw RecoveryFinalizationError.libraryOwnershipMissing(captureID)
        }
        try await cleanupLibraryCommittedSession(session)
    }

    private func cleanupLibraryCommittedSession(_ session: CaptureSession) async throws {
        guard session.state == .libraryCommitted, let ledger else {
            throw JobStoreError.invalidTransition
        }
        // Codex round-6 finding 1: `session.directory` is a ledger-persisted value — a corrupted
        // or migrated row could point it anywhere on disk, including through a symlink planted at
        // the expected nested path. Every deletion below is keyed off `session.directory`, so it
        // must be proven to be EXACTLY `<recoveryRoot>/<captureID>` — lexically AND after
        // resolving symlinks — before anything is removed. Mirrors the lexical+resolved ownership
        // check `RecoveryRetentionService.cleanupLibraryCommittedSessions` already applies for the
        // same `.libraryCommitted` cleanup. The untouched legacy layout (`session.directory ==
        // directory`, the shared recovery root itself) is exempt: it's the constructor-provided
        // root, never attacker/corruption controlled.
        try validateNestedSessionDirectoryOwnership(session)
        let captureID = session.id
        let canonical = session.directory.appendingPathComponent("\(captureID.uuidString).wav")
        let recoveryJobID = session.recoveryJobID ?? captureID
        let job = try await store.job(id: recoveryJobID)
        if let job {
            let source = URL(fileURLWithPath: job.source.reference).standardizedFileURL
            let legacyCanonical = directory.appendingPathComponent("\(captureID.uuidString).wav")
                .standardizedFileURL
            guard source == canonical.standardizedFileURL || source == legacyCanonical else {
                throw RecoveryFinalizationError.recoveryJobMismatch
            }
            if journalFileSystem.exists(source) {
                let dispositions = RecoveryImportDispositionStore(
                    directory: directory, fileSystem: journalFileSystem
                )
                let descriptor = try dispositions.descriptor(
                    id: captureID, source: source, defaultScope: .capture(captureID)
                )
                try dispositions.record(descriptor)
                try journalFileSystem.remove(source)
            }
        }
        if journalFileSystem.exists(canonical) { try journalFileSystem.remove(canonical) }
        for segment in try await ledger.committedSegments(captureID: captureID) {
            if journalFileSystem.exists(segment.url) { try journalFileSystem.remove(segment.url) }
        }
        if journalFileSystem.exists(session.directory) {
            try journalFileSystem.synchronizeDirectory(session.directory)
        }
        // Codex round-5 finding 5: cleanup removed canonical audio and segments but left the
        // stop-time `.capture-voice-command-intent.json` marker (and the now-empty capture
        // directory holding only it) behind — once the ledger row and job are removed below, no
        // reconciliation path ever revisits this directory again, so an orphan marker there
        // becomes permanently uncollectable. Runs AFTER the sync above so a fault-injection test
        // targeting that sync still observes its unchanged ordering; the marker/directory removal
        // below is new, additive cleanup, not a reorder of existing steps.
        let marker = VoiceCommandFinalizationIntent.markerURL(in: session.directory)
        if journalFileSystem.exists(marker) {
            // Codex round-9 finding 5: this final removal previously checked only name and
            // existence — `FileManager.removeItem` recursively deletes whatever is planted at the
            // marker's exact path, so a directory (or anything else non-regular) there would be
            // destroyed instead of hitting the unexpected-content guard below. Reuses the same
            // `lstat`-based regular-non-symlink check the residue sweep already applies.
            guard Self.isRegularNonSymlinkFile(marker) else {
                throw CaptureJournalError.cleanupNotPermitted(marker.path)
            }
            // Codex round-10 minor 2: the `lstat` check above and a recursive `remove(_:)` are two
            // separate steps — something could replace `marker` with a directory (or a symlink to
            // one) in between, and `FileManager.removeItem` would then recursively delete whatever
            // was planted there. `removeRegularFile` uses non-recursive `unlink(2)`: it never
            // follows a symlink for the final path component and always fails (never recurses) if
            // the path is a directory by the time this runs.
            try journalFileSystem.removeRegularFile(marker)
            // Codex round-6 finding 4: the marker removal above needs its own fsync — the sync at
            // the top of this method only covers the canonical-audio/segment removals that
            // preceded it, and the directory-removal branch below (which fsyncs the PARENT
            // directory, mirroring `CaptureJournalService.cancelAndClean`) only runs when the
            // directory turns out empty. Without this, a crash after the marker's durable removal
            // but before either of those could resurrect the marker on the next launch.
            if journalFileSystem.exists(session.directory) {
                try journalFileSystem.synchronizeDirectory(session.directory)
            }
        }
        // Only remove the directory itself for the nested-per-capture layout — legacy sessions
        // stored their files directly in the shared recovery root (`session.directory ==
        // directory`), which must never be removed.
        if session.directory.standardizedFileURL != directory.standardizedFileURL {
            if journalFileSystem.exists(session.directory) {
                // Codex round-7 finding 4: every temporary file this subsystem ever writes into a
                // session directory (`DurableArtifactWriter.commit`'s `temporary:` argument —
                // segment, canonical-audio, marker, and diagnostics writes) uses the same
                // `.<name>.<uuid>.tmp` naming. A crash between that write and its rename leaves
                // exactly such a file behind — legitimate app-owned residue, not evidence of
                // unexpected content. Sweep recognized residue before the emptiness check below
                // so it doesn't wedge this directory in `cleanupNotPermitted` forever; anything
                // else present is still genuinely unexpected and keeps failing loudly.
                //
                // Codex round-8 finding 1: matching on `hasPrefix(".") && hasSuffix(".tmp")` alone
                // deleted ANY hidden `*.tmp` in the directory, app-owned or not. Now the name must
                // additionally decompose as `.<recognized-artifact-stem>.<uuid>.tmp` — one of the
                // exact stems this subsystem is known to write into a session directory (segment-
                // NNNNNNNN, the canonical `<captureID>.wav`, the voice-command-intent marker, the
                // diagnostics file, or the failure marker) — AND the on-disk item must be a
                // regular, non-symlink file (`lstat`, so a planted symlink masquerading as one of
                // these names is rejected without ever following it).
                //
                // Codex round-9 finding 3: the round-8 comment here claimed `LegacyRecoveryImporter`
                // only ever writes its `.<id>.<uuid>.import.tmp` temporary into the shared recovery
                // root — that's wrong. `LegacyRecoveryImporter.importAudio` computes `owned` from
                // the session's OWN (possibly nested) directory whenever one already exists, and
                // `quarantineJournal` always calls it with `preferredID: session.id` on an
                // already-owned session — so a crash between that temporary's write and its rename
                // (e.g. while copying a quarantine fallback segment into the owned `<id>.wav`)
                // leaves it sitting in exactly this nested session directory, matching the same
                // captureID. Recognized here with the identical `lstat` regular-non-symlink check.
                for item in try journalFileSystem.contents(session.directory) {
                    let name = item.lastPathComponent
                    guard Self.isRecognizedResidualArtifactName(name, captureID: captureID),
                          Self.isRegularNonSymlinkFile(item) else { continue }
                    try journalFileSystem.remove(item)
                }
                // Codex round-6 finding 4: an owned temporary or unexpected file can keep this
                // directory nonempty. Deleting the job and ledger rows below anyway would strand
                // it — once the ledger row is gone, no reconciliation path ever revisits this
                // directory again. Keep ownership (throw before the job/ledger deletes below) so
                // the next reconciliation pass retries cleanup instead of silently orphaning the
                // directory.
                guard try journalFileSystem.contents(session.directory).isEmpty else {
                    throw CaptureJournalError.cleanupNotPermitted(session.directory.path)
                }
                try journalFileSystem.remove(session.directory)
            }
            // Codex round-7 minor finding 2: fsync the recovery root on every nested-session
            // pass, not only when this run is the one that removed the child directory. A prior
            // run's `remove(session.directory)` above can itself have landed durably without its
            // matching parent fsync ever completing (crash between the two) — on a retry where
            // `exists` is already false, skipping this fsync released ownership (the job/ledger
            // deletes below) while that removal was still not guaranteed durable.
            try journalFileSystem.synchronizeDirectory(directory)
        }
        if let job {
            let removed = try await store.deleteCommittedRecovery(
                id: recoveryJobID,
                expectedSourceReference: job.source.reference
            )
            if !removed {
                guard try await store.job(id: recoveryJobID) == nil else {
                    throw RecoveryFinalizationError.recoveryJobMismatch
                }
            }
        }
        try await ledger.removeCleanedSession(id: captureID)
    }

    /// Codex round-6 finding 1 — see the call site in `cleanupLibraryCommittedSession`. The
    /// lexical check runs unconditionally (cheap, no filesystem dependency, and this method must
    /// stay idempotent across retries where the directory is already gone). The resolved-symlink
    /// check only runs while the directory still exists: `resolvingSymlinksInPath()` only resolves
    /// symlinks for path components that are actually present on disk, so calling it on an
    /// already-removed leaf (an ordinary idempotent-retry outcome elsewhere in this method) can
    /// leave a parent symlink (e.g. `/var` → `/private/var`) unresolved on one side of the
    /// comparison and produce a false mismatch. A symlink planted AT `session.directory` can only
    /// be exploited while that path exists, so skipping the resolved check once it's gone loses no
    /// real protection.
    private func validateNestedSessionDirectoryOwnership(_ session: CaptureSession) throws {
        // Compared as `.path` strings, not `URL`s: `session.directory` round-trips through SQLite
        // as a bare path with no trailing slash (`URL(fileURLWithPath:)`, no `isDirectory` hint),
        // while the expected URLs here are built with `isDirectory: true` — `URL` equality is
        // sensitive to that trailing-slash difference even though both name the same path.
        guard session.directory.standardizedFileURL.path != directory.standardizedFileURL.path
        else { return }
        // Codex round-7 finding 5: the leaf is validated semantically as a UUID equal to
        // `session.id` — not by comparing against the exact-uppercase `session.id.uuidString` —
        // because `RecoveryReconciler.directoryCaptureID` accepts and persists lowercase (and any
        // other case-mixed) directory names via the same case-insensitive `UUID(uuidString:)`
        // parse. `UUID` equality is by underlying byte value, not string case, so this accepts
        // every directory name the reconciler can legitimately create while still rejecting any
        // non-UUID or foreign-identity leaf.
        let standardizedSessionDirectory = session.directory.standardizedFileURL
        guard standardizedSessionDirectory.deletingLastPathComponent().path
                == directory.standardizedFileURL.path,
              let leafID = UUID(uuidString: standardizedSessionDirectory.lastPathComponent),
              leafID == session.id
        else {
            throw RecoveryFinalizationError.captureIdentityMismatch
        }
        guard journalFileSystem.exists(session.directory) else { return }
        // Reconstructed with the ACTUAL on-disk leaf casing (already proven semantically equal to
        // `session.id` above), not the canonical-uppercase `session.id.uuidString` — otherwise a
        // legitimate lowercase leaf would mismatch here even with no symlink involved at all.
        let expectedResolved = directory.resolvingSymlinksInPath().standardizedFileURL
            .appendingPathComponent(
                standardizedSessionDirectory.lastPathComponent, isDirectory: true
            ).standardizedFileURL.path
        guard session.directory.resolvingSymlinksInPath().standardizedFileURL.path == expectedResolved
        else {
            throw RecoveryFinalizationError.captureIdentityMismatch
        }
    }

    /// Codex round-8 finding 1 — see the call site in `cleanupLibraryCommittedSession`. Parses
    /// `name` as `.<stem>.<uuid>.tmp` (leading dot, trailing `.tmp`, a valid UUID as the final
    /// dot-separated component) and checks `stem` against the exact set of artifact names this
    /// subsystem is known to write into a nested session directory via
    /// `DurableArtifactWriter.commit`'s `temporary:` argument. A name that merely looks
    /// hidden-and-temporary but doesn't decompose this way (e.g. `.evil.tmp`, no embedded UUID)
    /// is rejected — it is not proven to be app-owned residue.
    private static func isRecognizedResidualArtifactName(_ name: String, captureID: UUID) -> Bool {
        // Codex round-9 finding 3: `LegacyRecoveryImporter.importAudio` names its temporary
        // `.<id>.<uuid>.import.tmp` — a DIFFERENT shape from the `.<stem>.<uuid>.tmp` the generic
        // check below decomposes (it ends in `.import.tmp`, and its own final component before
        // that suffix is a UUID matching `captureID`, not an artifact-name stem), so it must be
        // recognized separately before falling through to the generic form.
        if name.hasPrefix("."), name.hasSuffix(".import.tmp") {
            let trimmed = name.dropFirst().dropLast(".import.tmp".count)
            let components = trimmed.split(separator: ".", omittingEmptySubsequences: false)
            guard components.count == 2,
                  UUID(uuidString: String(components[0])) == captureID,
                  UUID(uuidString: String(components[1])) != nil else { return false }
            return true
        }
        guard name.hasPrefix("."), name.hasSuffix(".tmp") else { return false }
        let trimmed = name.dropFirst().dropLast(".tmp".count)
        let components = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count >= 2, UUID(uuidString: String(components.last!)) != nil else {
            return false
        }
        let stem = components.dropLast().joined(separator: ".")
        if stem == "capture-voice-command-intent" || stem == "capture-diagnostics"
            || stem == "capture-failure" || stem == "\(captureID.uuidString).wav" {
            return true
        }
        if stem.hasPrefix("segment-") {
            let ordinalDigits = stem.dropFirst("segment-".count)
            return ordinalDigits.count == 8 && ordinalDigits.allSatisfy(\.isNumber)
        }
        return false
    }

    /// Codex round-8 finding 1 — uses `lstat` (not `stat`/`FileManager.attributesOfItem`, which
    /// follow symlinks) so a symlink planted at a recognized-looking name is rejected without ever
    /// being resolved or removed.
    private static func isRegularNonSymlinkFile(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFREG
    }

    func preserve(samples: [Float], metadata: RecoveryMetadata) async throws -> UUID {
        let job = try await writeCapture(samples: samples) { source in
            try await store.createRecovery(source: source, metadata: metadata)
        }
        try registerOwnership(id: job.id, source: URL(fileURLWithPath: job.source.reference))
        return job.id
    }

    private func registerOwnership(id: UUID, source: URL) throws {
        try RecoveryImportDispositionStore(
            directory: directory, fileSystem: journalFileSystem
        ).registerOwnedSource(id: id, source: source)
    }

    private func writeCapture(
        samples: [Float],
        create: (JobSource) async throws -> TranscriptionJob
    ) async throws -> TranscriptionJob {
        let source = try writeAudio(samples: samples)
        let finalURL = URL(fileURLWithPath: source.reference)
        do {
            do {
                return try await create(source)
            } catch let persistenceError {
                do {
                    try fileRemover.removeItem(at: finalURL)
                } catch let rollbackError {
                    throw RecoveryCaptureRollbackError(
                        persistenceError: persistenceError,
                        rollbackError: rollbackError
                    )
                }
                throw persistenceError
            }
        } catch { throw error }
    }

    private func writeAudio(samples: [Float]) throws -> JobSource {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stem = UUID().uuidString
        let temporaryURL = directory.appendingPathComponent(".\(stem).tmp")
        let finalURL = directory.appendingPathComponent("\(stem).wav")
        do {
            try writeSynchronously(WAVEncoder.encode(samples: samples, sampleRate: 16_000), to: temporaryURL)
            try FileManager.default.moveItem(at: temporaryURL, to: finalURL)
            return JobSource(reference: finalURL.path)
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }

    private func writeSynchronously(_ data: Data, to url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: url)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
    }
}
