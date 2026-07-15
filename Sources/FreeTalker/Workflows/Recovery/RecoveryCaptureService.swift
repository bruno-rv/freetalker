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
    func createProvisionalRecovery(id: UUID, source: JobSource, capturedAt: Date) async throws -> TranscriptionJob
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
        let job = try await store.createProvisionalRecovery(
            id: staged.captureID,
            source: JobSource(reference: staged.canonicalAudioURL.path),
            capturedAt: session?.capturedAt ?? capturedAt
        )
        guard job.id == staged.captureID else {
            throw RecoveryFinalizationError.captureIdentityMismatch
        }
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
