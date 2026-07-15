import CSQLite
import Foundation
import Testing
@testable import FreeTalker

enum PersistentFaultBoundary: String, CaseIterable, Sendable {
    case prepareDirectoryCreate
    case prepareParentSync
    case prepareLedgerUnknownCommit
    case segmentWrite
    case segmentFileSync
    case segmentRename
    case segmentDirectorySync
    case segmentLedger
    case overflowFailureMarker
    case canonicalFileSync
    case canonicalRename
    case canonicalDirectorySync
    case stagedTransition
    case recoveryJobCreate
    case recoveryJobLink
    case libraryInsertDurableThenThrow
    case libraryCommittedTransition
    case canonicalRemove
    case segmentRemove
    case sessionDirectorySync
    case recoveryJobDelete
    case ledgerDelete
    case silentDiagnosticsCommit
    case silentTransition
    case silentSegmentRemove
    case silentDirectorySync
    case silentMetadataDelete
    case cancelIntent
    case cancelDirectoryRemove
    case cancelParentSync
    case cancelLedgerDelete

    var isJournalBoundary: Bool {
        switch self {
        case .segmentWrite, .segmentFileSync, .segmentRename,
             .segmentDirectorySync, .segmentLedger, .overflowFailureMarker,
             .stagedTransition: true
        case .canonicalFileSync, .canonicalRename, .canonicalDirectorySync: true
        default: false
        }
    }

    var isSilentBoundary: Bool {
        switch self {
        case .silentDiagnosticsCommit, .silentTransition, .silentSegmentRemove,
             .silentDirectorySync, .silentMetadataDelete: true
        default: false
        }
    }

    var isCancelBoundary: Bool {
        switch self {
        case .cancelIntent, .cancelDirectoryRemove, .cancelParentSync, .cancelLedgerDelete: true
        default: false
        }
    }

    var isAdmissionBoundary: Bool {
        self == .prepareDirectoryCreate || self == .prepareParentSync
    }
}

private struct PersistentInjectedFault: Error, Sendable {
    let boundary: PersistentFaultBoundary
}

private final class LockedInteger: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0
    func increment() { lock.withLock { storage += 1 } }
    var value: Int { lock.withLock { storage } }
}

private final class InvariantJobClock: JobClock, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Date
    init(_ now: Date) { storage = now }
    var now: Date { lock.withLock { storage } }
    func advance(_ interval: TimeInterval) { lock.withLock { storage.addTimeInterval(interval) } }
}

@Suite struct RecordingDurabilityInvariantTests {
    @Test("smoke isolation is debug-only, double opted-in, absolute, and mounted")
    func smokeIsolationFailsClosed() throws {
        let fallback = URL(fileURLWithPath: "/Users/test/Library/Application Support/FreeTalker")
        let mounted = URL(fileURLWithPath: "/Volumes/FreeTalkerSmoke/session")
        let allowed = [
            "FREETALKER_ALLOW_ISOLATED_SMOKE": "1",
            "FREETALKER_SMOKE_ROOT": mounted.path,
        ]

        #expect(FreeTalkerPaths.resolveApplicationSupport(
            environment: allowed, fallback: fallback,
            isMountedVolume: { $0.path.hasPrefix("/Volumes/FreeTalkerSmoke/") },
            hasSafeComponents: { _ in true },
            debugBuild: true
        ).path == mounted.path)
        #expect(FreeTalkerPaths.resolveApplicationSupport(
            environment: ["FREETALKER_SMOKE_ROOT": mounted.path], fallback: fallback,
            isMountedVolume: { _ in true }, hasSafeComponents: { _ in true },
            debugBuild: true
        ) == fallback)
        #expect(FreeTalkerPaths.resolveApplicationSupport(
            environment: allowed, fallback: fallback,
            isMountedVolume: { _ in true }, hasSafeComponents: { _ in true },
            debugBuild: false
        ) == fallback)
        #expect(FreeTalkerPaths.resolveApplicationSupport(
            environment: [
                "FREETALKER_ALLOW_ISOLATED_SMOKE": "1",
                "FREETALKER_SMOKE_ROOT": "relative/path",
            ], fallback: fallback, isMountedVolume: { _ in true },
            hasSafeComponents: { _ in true }, debugBuild: true
        ) == fallback)
        #expect(FreeTalkerPaths.resolveApplicationSupport(
            environment: [
                "FREETALKER_ALLOW_ISOLATED_SMOKE": "1",
                "FREETALKER_SMOKE_ROOT": "/Volumes/FreeTalkerSmoke/../escape",
            ], fallback: fallback, isMountedVolume: { _ in true },
            hasSafeComponents: { _ in true }, debugBuild: true
        ) == fallback)
        #expect(FreeTalkerPaths.resolveApplicationSupport(
            environment: allowed, fallback: fallback,
            isMountedVolume: { _ in false }, hasSafeComponents: { _ in true },
            debugBuild: true
        ) == fallback)
        #expect(FreeTalkerPaths.resolveApplicationSupport(
            environment: allowed, fallback: fallback,
            isMountedVolume: { _ in true }, hasSafeComponents: { _ in false },
            debugBuild: true
        ) == fallback)
    }

    @Test("isolation path component validation rejects symlinks")
    func smokeIsolationRejectsSymlinkComponents() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            "smoke-path-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: temporary) }
        let real = temporary.appendingPathComponent("real", isDirectory: true)
        let link = temporary.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        #expect(FreeTalkerPaths.hasNoSymlinkComponents(real, beneath: temporary))
        #expect(!FreeTalkerPaths.hasNoSymlinkComponents(link, beneath: temporary))
    }

    @Test("smoke checkpoints require debug isolation and an explicitly named boundary")
    func smokeCheckpointConfigurationFailsClosed() {
        let environment = [
            "FREETALKER_ALLOW_ISOLATED_SMOKE": "1",
            "FREETALKER_SMOKE_ROOT": "/Volumes/FreeTalkerSmoke/session",
            "FREETALKER_SMOKE_CHECKPOINTS": "post-job-create,cancel-intent",
        ]
        let isolatedRoot = URL(fileURLWithPath: "/Volumes/FreeTalkerSmoke/session")
        #expect(SmokeCheckpoint.shouldEmit(
            .postJobCreate, environment: environment,
            applicationSupport: isolatedRoot, debugBuild: true
        ))
        #expect(!SmokeCheckpoint.shouldEmit(
            .postLibraryInsert, environment: environment,
            applicationSupport: isolatedRoot, debugBuild: true
        ))
        #expect(!SmokeCheckpoint.shouldEmit(
            .postJobCreate, environment: environment,
            applicationSupport: isolatedRoot, debugBuild: false
        ))
        #expect(!SmokeCheckpoint.shouldEmit(
            .postJobCreate,
            environment: ["FREETALKER_SMOKE_CHECKPOINTS": "post-job-create"],
            applicationSupport: isolatedRoot,
            debugBuild: true
        ))
        #expect(!SmokeCheckpoint.shouldEmit(
            .postJobCreate, environment: environment,
            applicationSupport: URL(fileURLWithPath: "/Users/test/Library/Application Support/FreeTalker"),
            debugBuild: true
        ))
    }

    @Test(
        "accepted capture survives process restart at every durable lifecycle state",
        arguments: RecordingDurabilityHarness.Destination.allCases,
        RecordingDurabilityHarness.Interruption.allCases
    )
    func acceptedCaptureSurvivesRestart(
        destination: RecordingDurabilityHarness.Destination,
        interruption: RecordingDurabilityHarness.Interruption
    ) async throws {
        let harness = try RecordingDurabilityHarness()
        let captureID = try await harness.interrupt(destination: destination, at: interruption)

        let evidence = try await harness.reopenAndReconcile(captureID: captureID)

        #expect(evidence.durableCount >= 1)
        #expect(evidence.libraryRows <= 1)
    }

    @Test(
        "real persistent side effect faults retain validated ownership after reopen",
        arguments: PersistentFaultBoundary.allCases.filter {
            !$0.isAdmissionBoundary && !$0.isSilentBoundary && !$0.isCancelBoundary
                && $0 != .overflowFailureMarker
        }
    )
    func persistentFaultMatrix(boundary: PersistentFaultBoundary) async throws {
        let harness = try RecordingDurabilityHarness()
        let captureID = try await harness.inject(boundary)

        let evidence = try await harness.reopenAndReconcile(captureID: captureID)

        #expect(evidence.durableCount >= 1, "boundary: \(boundary.rawValue)")
        #expect(evidence.libraryRows <= 1, "boundary: \(boundary.rawValue)")
    }

    @Test("overflow failure persistence is drained before completion")
    func overflowFailureIsDurable() async throws {
        let harness = try RecordingDurabilityHarness()
        let captureID = try await harness.inject(.overflowFailureMarker, destination: .external)
        let evidence = try await harness.reopenAndReconcile(captureID: captureID)
        #expect(evidence.durableCount >= 1)
    }

    @Test(
        "every silent fault remains visible for both destinations",
        arguments: PersistentFaultBoundary.allCases.filter(\.isSilentBoundary),
        RecordingDurabilityHarness.Destination.allCases
    )
    func silentFaultMatrix(
        boundary: PersistentFaultBoundary,
        destination: RecordingDurabilityHarness.Destination
    ) async throws {
        let harness = try RecordingDurabilityHarness()
        let captureID = try await harness.inject(boundary, destination: destination)
        let evidence = try await harness.reopenAndReconcile(captureID: captureID)
        #expect(evidence.visibleSilentOrDamaged, "\(boundary.rawValue) \(destination.rawValue)")
        #expect(evidence.durableCount >= 1)
        #expect(evidence.libraryRows == 0)
        #expect(evidence.recoveryJobs == 0)
    }

    @Test(
        "every cancellation fault converges to terminal cleanup for both destinations",
        arguments: PersistentFaultBoundary.allCases.filter(\.isCancelBoundary),
        RecordingDurabilityHarness.Destination.allCases
    )
    func cancellationFaultMatrix(
        boundary: PersistentFaultBoundary,
        destination: RecordingDurabilityHarness.Destination
    ) async throws {
        let harness = try RecordingDurabilityHarness()
        let captureID = try await harness.inject(boundary, destination: destination)
        let evidence = try await harness.reopenAndReconcile(captureID: captureID)
        #expect(evidence.isExplicitlyDisposed, "\(boundary.rawValue) \(destination.rawValue)")
        #expect(evidence.durableCount == 0)
        #expect(evidence.libraryRows == 0)
        #expect(evidence.recoveryJobs == 0)
        #expect(evidence.visibleRecoveries == 0)
    }

    @Test(
        "pre-accept filesystem faults block admission and compensate durable state",
        arguments: [
            PersistentFaultBoundary.prepareDirectoryCreate,
            PersistentFaultBoundary.prepareParentSync,
        ]
    )
    func preparationFaultBlocksAdmission(boundary: PersistentFaultBoundary) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "prepare-admission-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let database = root.appendingPathComponent("jobs.sqlite")
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let request = CaptureStartRequest(
            id: UUID(), directory: directory, capturedAt: Date(), sampleRate: 16_000,
            channelCount: 1, inputDeviceUID: nil, destination: "external"
        )
        do {
            let store = try TranscriptionJobStore(databaseURL: database, clock: SystemJobClock())
            let fileSystem = PersistentFaultFileSystem(
                base: LocalJournalFileSystem(), boundary: boundary
            )
            fileSystem.arm()
            await #expect(throws: (any Error).self) {
                try await CaptureJournalService(fileSystem: fileSystem, ledger: store)
                    .prepare(request)
            }
        }
        let reopened = try TranscriptionJobStore(databaseURL: database, clock: SystemJobClock())
        #expect(try await reopened.session(id: request.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test("Library identity wins restart cleanup without retranscription or duplication")
    func libraryIdentityWinsRestartCleanup() async throws {
        let harness = try RecordingDurabilityHarness()
        let captureID = try await harness.interrupt(destination: .external, at: .libraryInserted)

        let first = try await harness.reopenAndReconcile(captureID: captureID)
        let second = try await harness.reopenAndReconcile(captureID: captureID)

        #expect(first.libraryRows == 1)
        #expect(second.libraryRows == 1)
        #expect(second.recoveryJobs == 0)
        #expect(second.durableCount >= 1)
    }

    @Test(
        "silent and explicitly cancelled attempts converge after restart for both destinations",
        arguments: RecordingDurabilityHarness.Destination.allCases
    )
    func silentAndCancelledConverge(
        destination: RecordingDurabilityHarness.Destination
    ) async throws {
        let silentHarness = try RecordingDurabilityHarness()
        let silent = try await silentHarness.createSilent(destination: destination)
        let silentEvidence = try await silentHarness.reopenAndReconcile(captureID: silent)
        #expect(silentEvidence.visibleSilentOrDamaged)
        #expect(silentEvidence.durableCount >= 1)
        #expect(silentEvidence.message == SilentCapturePresentation.message)
        #expect(silentEvidence.actions == [.startNewRecording, .delete])
        #expect(silentEvidence.recoveryJobs == 0)
        #expect(silentEvidence.libraryRows == 0)

        let cancelledHarness = try RecordingDurabilityHarness()
        let cancelled = try await cancelledHarness.createInterruptedCancellation(destination: destination)
        let cancelledEvidence = try await cancelledHarness.reopenAndReconcile(captureID: cancelled)
        #expect(cancelledEvidence.isExplicitlyDisposed)
        #expect(cancelledEvidence.libraryRows == 0)
        #expect(cancelledEvidence.recoveryJobs == 0)
    }

    @Test("one corrupt legacy artifact does not prevent later valid import")
    func corruptArtifactDoesNotBlockValidImport() async throws {
        let harness = try RecordingDurabilityHarness()
        try harness.createLegacyAndOrphanFixtures()

        let result = try await harness.reopenAndReconcileInventory()
        let reopened = try await harness.reopenAndReconcileInventory()

        #expect(result.imported >= 2)
        #expect(result.quarantined + result.failed >= 1)
        #expect(result.visibleRecoveries >= 2)
        #expect(result.quarantinedItems >= 1)
        #expect(result.quarantinedItemsWithRetry == 0)
        #expect(result.retainedQuarantineArtifacts >= 1)
        #expect(reopened.visibleRecoveries == result.visibleRecoveries)
    }

    @Test("real SQLite lock blocks mutation, then exact retry preserves capture")
    func sqliteBusyRetryUsesPersistentStore() async throws {
        let harness = try RecordingDurabilityHarness()
        let captureID = try await harness.exerciseSQLiteLockAndRetry()
        let evidence = try await harness.reopenAndReconcile(captureID: captureID)
        #expect(evidence.durableCount >= 1)
        #expect(evidence.libraryRows <= 1)
    }

    @Test("corrupt jobs store reports unavailable without deleting journal evidence")
    func sqliteCorruptionRetainsFilesystemEvidence() async throws {
        let harness = try RecordingDurabilityHarness()
        let result = try await harness.exerciseJobsCorruptionAndRestore()
        #expect(result.openFailed)
        #expect(result.validatedFilesystemEvidence)
        #expect(result.recovered.durableCount >= 1)
    }

    @Test("invalid jobs database path fails closed before capture admission")
    func sqliteOpenFailureBlocksAdmission() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "jobs-open-failure-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let directoryAtDatabasePath = root.appendingPathComponent("jobs.db", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryAtDatabasePath, withIntermediateDirectories: true
        )
        #expect(throws: (any Error).self) {
            try TranscriptionJobStore(databaseURL: directoryAtDatabasePath, clock: SystemJobClock())
        }
    }

    @Test("Library-owned restart runs production retry finalization without audio processing")
    func libraryOwnedRetryNeverRetranscribes() async throws {
        let harness = try RecordingDurabilityHarness()
        let result = try await harness.runLibraryOwnedRetryAndReopenTwice()
        #expect(result.processCalls == 0)
        #expect(result.audioLoads == 0)
        #expect(result.evidence.libraryRows == 1)
        #expect(result.evidence.recoveryJobs == 0)
    }
}

final class RecordingDurabilityHarness: @unchecked Sendable {
    enum Destination: String, CaseIterable, Sendable {
        case external
        case scratchpad
    }

    enum Interruption: CaseIterable, Sendable {
        case committedSegments
        case stagedCanonical
        case recoveryJobLinked
        case libraryInserted
        case libraryCommitted
        case cleanupIntent
    }

    struct Evidence: Sendable {
        let activeJournalEvidence: Bool
        let visibleRecoveries: Int
        let visibleSilentOrDamaged: Bool
        let libraryRows: Int
        let recoveryJobs: Int
        let isExplicitlyDisposed: Bool
        let actions: Set<RecoveryAction>
        let message: String?

        var durableCount: Int {
            (activeJournalEvidence ? 1 : 0) + (visibleRecoveries > 0 ? 1 : 0)
                + (libraryRows > 0 ? 1 : 0)
        }
    }

    struct InventoryResult: Sendable {
        let imported: Int
        let quarantined: Int
        let failed: Int
        let visibleRecoveries: Int
        let quarantinedItems: Int
        let quarantinedItemsWithRetry: Int
        let retainedQuarantineArtifacts: Int
    }

    struct CorruptionResult: Sendable {
        let openFailed: Bool
        let validatedFilesystemEvidence: Bool
        let recovered: Evidence
    }

    struct RetryResult: Sendable {
        let processCalls: Int
        let audioLoads: Int
        let evidence: Evidence
    }

    private let temporary: URL
    private let recoveryRoot: URL
    private let jobsDatabase: URL
    private let libraryDatabase: URL
    private let fileSystem = LocalJournalFileSystem()

    init() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            "recording-durability-\(UUID().uuidString)", isDirectory: true
        )
        recoveryRoot = temporary.appendingPathComponent("failed-dictations", isDirectory: true)
        jobsDatabase = temporary.appendingPathComponent("jobs.sqlite")
        libraryDatabase = temporary.appendingPathComponent("library.sqlite")
        try FileManager.default.createDirectory(
            at: recoveryRoot, withIntermediateDirectories: true
        )
    }

    deinit { try? FileManager.default.removeItem(at: temporary) }

    func interrupt(destination: Destination, at interruption: Interruption) async throws -> UUID {
        let captureID = UUID()
        let directory = recoveryRoot.appendingPathComponent(
            captureID.uuidString, isDirectory: true
        )
        let store = try TranscriptionJobStore(databaseURL: jobsDatabase, clock: SystemJobClock())
        let service = CaptureJournalService(
            fileSystem: fileSystem, ledger: store, recoveryRoot: recoveryRoot
        )
        let active = try await service.prepare(.init(
            id: captureID, directory: directory,
            capturedAt: Date(timeIntervalSince1970: 1_721_000_000),
            sampleRate: 16_000, channelCount: 1, inputDeviceUID: "test-mic",
            destination: destination.rawValue
        ))
        #expect(active.writer.enqueue(Array(repeating: 0.25, count: 8_001)) == .accepted)

        if interruption == .committedSegments {
            try await waitForCommittedSegment(store: store, captureID: captureID)
            await active.writer.stop()
            return captureID
        }

        let staged = try await service.finish(active)
        if interruption == .stagedCanonical { return captureID }

        let job = try await store.createProvisionalRecovery(
            id: captureID,
            source: .init(reference: staged.canonicalAudioURL.path),
            capturedAt: active.session.capturedAt
        )
        try await service.markProcessing(captureID: captureID, recoveryJobID: job.id)
        if interruption == .recoveryJobLinked { return captureID }

        let library = try Database(path: libraryDatabase)
        let dictation = try library.insertDictation(sampleDictation, captureID: captureID)
        if interruption == .libraryInserted { return captureID }

        try await service.markLibraryCommitted(captureID: captureID, dictationID: dictation.id)
        if interruption == .libraryCommitted { return captureID }

        try await store.transition(
            id: captureID, from: .libraryCommitted, to: .cancelling,
            recoveryJobID: job.id, libraryDictationID: dictation.id,
            assetKind: .audio, failureMessage: nil,
            contentHash: try #require(try await store.session(id: captureID)?.contentHash)
        )
        return captureID
    }

    func inject(
        _ boundary: PersistentFaultBoundary,
        destination: Destination = .external
    ) async throws -> UUID {
        if boundary.isSilentBoundary {
            return try await injectSilent(boundary, destination: destination)
        }
        if boundary.isCancelBoundary {
            return try await injectCancellation(boundary, destination: destination)
        }
        let captureID = UUID()
        let directory = recoveryRoot.appendingPathComponent(captureID.uuidString, isDirectory: true)
        let store = try TranscriptionJobStore(databaseURL: jobsDatabase, clock: SystemJobClock())
        let faultFS = PersistentFaultFileSystem(base: fileSystem, boundary: boundary)
        let faultLedger = PersistentFaultLedger(base: store, boundary: boundary)
        let service = CaptureJournalService(
            fileSystem: faultFS, ledger: faultLedger, recoveryRoot: recoveryRoot
        )
        let request = CaptureStartRequest(
            id: captureID, directory: directory, capturedAt: Date(), sampleRate: 16_000,
            channelCount: 1, inputDeviceUID: "fault-mic", destination: destination.rawValue
        )

        let active: ActiveCaptureJournal
        do {
            active = try await service.prepare(request)
        } catch {
            throw error
        }
        if boundary == .overflowFailureMarker {
            #expect(active.writer.enqueue(Array(repeating: 0.25, count: 128_001)) == .overflow)
            await #expect(throws: (any Error).self) { try await service.finish(active) }
            await active.writer.waitForFailurePersistence()
            let marker = directory.appendingPathComponent("capture-failure.marker")
            for _ in 0..<2_000 where !fileSystem.exists(marker) {
                try await Task.sleep(for: .milliseconds(1))
            }
            #expect(fileSystem.exists(marker))
            return captureID
        }
        #expect(active.writer.enqueue(Array(repeating: 0.25, count: 8_001)) == .accepted)

        if boundary == .prepareLedgerUnknownCommit {
            _ = try await service.finish(active)
            return captureID
        }
        if boundary.isJournalBoundary {
            await #expect(throws: (any Error).self) { try await service.finish(active) }
            return captureID
        }
        let staged = try await service.finish(active)
        let jobFault = PersistentFaultJobStore(base: store, boundary: boundary)
        let registration = RecoveryCaptureService(
            directory: recoveryRoot, store: jobFault, ledger: faultLedger,
            journalFileSystem: faultFS
        )
        let capture: ProvisionalRecoveryCapture
        do {
            capture = try await registration.registerJournalCapture(staged, capturedAt: Date())
        } catch {
            if boundary == .recoveryJobCreate || boundary == .recoveryJobLink { return captureID }
            throw error
        }

        if boundary == .libraryInsertDurableThenThrow {
            do {
                _ = try Database(path: libraryDatabase).insertDictation(
                    sampleDictation, captureID: captureID
                )
                throw PersistentInjectedFault(boundary: boundary)
            } catch is PersistentInjectedFault {
                // Simulates an adapter that loses acknowledgement after SQLite commits.
            }
            return captureID
        }
        let library = try Database(path: libraryDatabase)
        let row = try library.insertDictation(sampleDictation, captureID: captureID)
        if boundary == .libraryCommittedTransition {
            await faultLedger.arm()
            await #expect(throws: (any Error).self) {
                try await CaptureJournalService(fileSystem: faultFS, ledger: faultLedger)
                    .markLibraryCommitted(captureID: captureID, dictationID: row.id)
            }
            return captureID
        }

        let completion = RecoveryCaptureService(
            directory: recoveryRoot, store: jobFault, ledger: faultLedger,
            journalFileSystem: faultFS,
            libraryDictationID: { id in
                try Database(path: self.libraryDatabase).dictations(captureID: id).first?.id
            }
        )
        faultFS.arm()
        await faultLedger.arm()
        await jobFault.arm()
        await #expect(throws: (any Error).self) {
            try await completion.completeJournalCapture(capture, captureID: captureID)
        }
        if boundary == .sessionDirectorySync {
            let events = faultFS.events
            let removed = try #require(events.firstIndex {
                $0 == "media-remove:\(directory.path)"
            })
            let synchronized = try #require(events.indices.first {
                $0 > removed && events[$0] == "directory-sync:\(directory.path)"
            })
            let fault = try #require(events.firstIndex { $0 == "fault:sessionDirectorySync" })
            #expect(removed < synchronized)
            #expect(synchronized < fault)
        }
        return captureID
    }

    private func injectSilent(
        _ boundary: PersistentFaultBoundary,
        destination: Destination
    ) async throws -> UUID {
        let captureID = UUID()
        let directory = recoveryRoot.appendingPathComponent(captureID.uuidString, isDirectory: true)
        let store = try TranscriptionJobStore(databaseURL: jobsDatabase, clock: SystemJobClock())
        let faultFS = PersistentFaultFileSystem(base: fileSystem, boundary: boundary)
        let faultLedger = PersistentFaultLedger(base: store, boundary: boundary)
        let service = CaptureJournalService(
            fileSystem: faultFS, ledger: faultLedger, recoveryRoot: recoveryRoot
        )
        let active = try await service.prepare(.init(
            id: captureID, directory: directory, capturedAt: Date(), sampleRate: 16_000,
            channelCount: 1, inputDeviceUID: "silent-fault", destination: destination.rawValue
        ))
        #expect(active.writer.enqueue(Array(repeating: 0, count: 8_001)) == .accepted)
        try await waitForCommittedSegment(store: store, captureID: captureID)
        faultFS.arm()
        await faultLedger.arm()
        await #expect(throws: (any Error).self) {
            try await service.recordSilent(active, diagnostics: .init(
                peak: 0, rms: 0, inputDeviceUID: "silent-fault", routeFailure: nil
            ))
        }
        return captureID
    }

    private func injectCancellation(
        _ boundary: PersistentFaultBoundary,
        destination: Destination
    ) async throws -> UUID {
        let captureID = UUID()
        let directory = recoveryRoot.appendingPathComponent(captureID.uuidString, isDirectory: true)
        let store = try TranscriptionJobStore(databaseURL: jobsDatabase, clock: SystemJobClock())
        let faultFS = PersistentFaultFileSystem(base: fileSystem, boundary: boundary)
        let faultLedger = PersistentFaultLedger(base: store, boundary: boundary)
        let service = CaptureJournalService(
            fileSystem: faultFS, ledger: faultLedger, recoveryRoot: recoveryRoot
        )
        let active = try await service.prepare(.init(
            id: captureID, directory: directory, capturedAt: Date(), sampleRate: 16_000,
            channelCount: 1, inputDeviceUID: "cancel-fault",
            destination: destination.rawValue
        ))
        #expect(active.writer.enqueue(Array(repeating: 0.25, count: 8_001)) == .accepted)
        _ = try await service.finish(active)
        faultFS.arm()
        await faultLedger.arm()
        await #expect(throws: (any Error).self) { try await service.cancelAndClean(active) }
        return captureID
    }

    func createSilent(destination: Destination) async throws -> UUID {
        let captureID = UUID()
        let store = try TranscriptionJobStore(databaseURL: jobsDatabase, clock: SystemJobClock())
        let service = CaptureJournalService(
            fileSystem: fileSystem, ledger: store, recoveryRoot: recoveryRoot
        )
        let active = try await service.prepare(.init(
            id: captureID,
            directory: recoveryRoot.appendingPathComponent(captureID.uuidString, isDirectory: true),
            capturedAt: Date(), sampleRate: 16_000, channelCount: 1,
            inputDeviceUID: "silent-mic", destination: destination.rawValue
        ))
        #expect(active.writer.enqueue(Array(repeating: 0, count: 8_001)) == .accepted)
        try await service.recordSilent(active, diagnostics: .init(
            peak: 0, rms: 0, inputDeviceUID: "silent-mic", routeFailure: nil
        ))
        return captureID
    }

    func createInterruptedCancellation(destination: Destination) async throws -> UUID {
        let captureID = try await interrupt(destination: destination, at: .stagedCanonical)
        let store = try TranscriptionJobStore(databaseURL: jobsDatabase, clock: SystemJobClock())
        let session = try #require(try await store.session(id: captureID))
        try await store.transition(
            id: captureID, from: .staged, to: .cancelling,
            recoveryJobID: nil, libraryDictationID: nil, assetKind: session.assetKind,
            failureMessage: session.failureMessage, contentHash: session.contentHash
        )
        return captureID
    }

    func reopenAndReconcile(captureID: UUID) async throws -> Evidence {
        let store = try TranscriptionJobStore(databaseURL: jobsDatabase, clock: SystemJobClock())
        let libraryPath = libraryDatabase
        _ = await RecoveryReconciler(
            directory: recoveryRoot, store: store, ledger: store, fileSystem: fileSystem,
            libraryDictationID: { id in
                try Database(path: libraryPath).dictations(captureID: id).first?.id
            },
            retrySleep: { _ in }
        ).reconcile()

        let session = try await store.session(id: captureID)
        let jobs = try await store.jobs(kind: .recovery).filter {
            $0.id == captureID || $0.source.reference.contains(captureID.uuidString)
        }
        let projected = try await projectedRecoveryItems(store: store).filter {
            $0.id == captureID
        }
        let rows = try Database(path: libraryDatabase).dictations(captureID: captureID)
        let active = try await validatedActiveEvidence(session: session, store: store)
        let exceptional = projected.contains {
            $0.session?.assetKind == .silent || $0.session?.assetKind == .damaged
                || $0.session?.assetKind == .quarantined
        }
        return Evidence(
            activeJournalEvidence: active,
            visibleRecoveries: projected.count,
            visibleSilentOrDamaged: exceptional,
            libraryRows: rows.count,
            recoveryJobs: jobs.count,
            isExplicitlyDisposed: session == nil
                && !fileSystem.exists(recoveryRoot.appendingPathComponent(
                    captureID.uuidString, isDirectory: true
                )),
            actions: projected.first?.availableActions ?? [],
            message: projected.first?.message
        )
    }

    @MainActor
    private func projectedRecoveryItems(store: TranscriptionJobStore) async throws -> [RecoveryItem] {
        let library = JobLibraryStore(store: store, recoveryDirectory: recoveryRoot)
        try await library.refresh()
        return library.recoveryItems
    }

    private func validatedActiveEvidence(
        session: CaptureSession?, store: TranscriptionJobStore
    ) async throws -> Bool {
        guard let session, session.state == .capturing else { return false }
        let segments = try await store.committedSegments(captureID: session.id)
        if !segments.isEmpty {
            let codec = CaptureSegmentCodec(fileSystem: fileSystem)
            return try segments.allSatisfy { segment in
                guard segment.captureID == session.id else { return false }
                return try !codec.validate(segment).isEmpty
            }
        }
        let failure = session.directory.appendingPathComponent("capture-failure.marker")
        let preparation = recoveryRoot.appendingPathComponent(
            ".capture-preparation-\(session.id.uuidString).marker"
        )
        return fileSystem.exists(failure) || fileSystem.exists(preparation)
    }

    func createLegacyAndOrphanFixtures() throws {
        try Data("not-a-wave".utf8).write(
            to: recoveryRoot.appendingPathComponent("failed-corrupt.wav")
        )
        try WAVEncoder.encode(samples: [0.2, -0.1], sampleRate: 16_000).write(
            to: recoveryRoot.appendingPathComponent("failed-legacy.wav")
        )
        try WAVEncoder.encode(samples: [0.3], sampleRate: 16_000).write(
            to: recoveryRoot.appendingPathComponent("\(UUID().uuidString).wav")
        )
    }

    func exerciseSQLiteLockAndRetry() async throws -> UUID {
        let captureID = try await interrupt(destination: .external, at: .stagedCanonical)
        let locked = try TranscriptionJobStore(databaseURL: jobsDatabase, clock: SystemJobClock())
        var lockDatabase: OpaquePointer?
        guard sqlite3_open(jobsDatabase.path, &lockDatabase) == SQLITE_OK,
              let lockDatabase else { throw PersistentInjectedFault(boundary: .segmentLedger) }
        defer { sqlite3_close(lockDatabase) }
        guard sqlite3_exec(lockDatabase, "BEGIN EXCLUSIVE;", nil, nil, nil) == SQLITE_OK else {
            throw PersistentInjectedFault(boundary: .segmentLedger)
        }
        await #expect(throws: (any Error).self) {
            try await locked.transition(
                id: captureID, from: .staged, to: .processing,
                recoveryJobID: captureID, libraryDictationID: nil, assetKind: .audio,
                failureMessage: nil,
                contentHash: try #require(try await locked.session(id: captureID)?.contentHash)
            )
        }
        _ = sqlite3_exec(lockDatabase, "ROLLBACK;", nil, nil, nil)
        let retry = try TranscriptionJobStore(databaseURL: jobsDatabase, clock: SystemJobClock())
        let session = try #require(try await retry.session(id: captureID))
        try await retry.transition(
            id: captureID, from: .staged, to: .processing,
            recoveryJobID: captureID, libraryDictationID: nil, assetKind: session.assetKind,
            failureMessage: session.failureMessage, contentHash: session.contentHash
        )
        return captureID
    }

    func exerciseJobsCorruptionAndRestore() async throws -> CorruptionResult {
        let captureID = try await interrupt(destination: .scratchpad, at: .committedSegments)
        let backup = temporary.appendingPathComponent("jobs-backup.sqlite")
        try FileManager.default.copyItem(at: jobsDatabase, to: backup)
        try Data("intentionally corrupt sqlite".utf8).write(to: jobsDatabase)
        for suffix in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: jobsDatabase.path + suffix) }
        let openFailed: Bool
        do {
            _ = try TranscriptionJobStore(databaseURL: jobsDatabase, clock: SystemJobClock())
            openFailed = false
        } catch { openFailed = true }
        let sessionDirectory = recoveryRoot.appendingPathComponent(captureID.uuidString)
        let segment = try #require(try FileManager.default.contentsOfDirectory(
            at: sessionDirectory, includingPropertiesForKeys: nil
        ).first { $0.lastPathComponent.hasPrefix("segment-") && $0.pathExtension == "wav" })
        let validated = !(try CaptureSegmentCodec(fileSystem: fileSystem).decode(segment)).isEmpty
        try FileManager.default.removeItem(at: jobsDatabase)
        try FileManager.default.copyItem(at: backup, to: jobsDatabase)
        let recovered = try await reopenAndReconcile(captureID: captureID)
        return CorruptionResult(
            openFailed: openFailed, validatedFilesystemEvidence: validated, recovered: recovered
        )
    }

    func runLibraryOwnedRetryAndReopenTwice() async throws -> RetryResult {
        let captureID = try await interrupt(destination: .external, at: .libraryInserted)
        let processCalls = LockedInteger()
        let audioLoads = LockedInteger()
        let clock = InvariantJobClock(Date(timeIntervalSince1970: 10_000))
        do {
            let staleStore = try TranscriptionJobStore(
                databaseURL: jobsDatabase, clock: clock
            )
            try await staleStore.transition(
                captureID, from: .processing,
                to: .failed(.init(stage: .persisting, message: "stale runner"))
            )
            try await staleStore.transition(captureID, from: .failed, to: .queued)
            _ = try await staleStore.claimQueuedJob(
                captureID, kind: .recovery, owner: UUID(), leaseDuration: -1
            )
        }
        clock.advance(2)
        do {
            let store = try TranscriptionJobStore(databaseURL: jobsDatabase, clock: clock)
            #expect(try await store.recoverStaleJobs(kind: .recovery) == 1)
            let libraryPath = libraryDatabase
            let root = recoveryRoot
            let pipeline = RecoveryRetryPipeline(
                directory: recoveryRoot,
                store: store,
                loadSamples: { _ in audioLoads.increment(); return [] },
                processDictation: { _, _, _ in
                    processCalls.increment()
                    return RecoveryDictation(
                        language: "en", template: "Default", transcript: "unexpected",
                        refined: "unexpected", engine: "unexpected"
                    )
                },
                libraryDictationID: { id in
                    try Database(path: libraryPath).dictations(captureID: id).first?.id
                },
                finalizeJournalCapture: { id, _ in
                    guard let job = try await store.job(id: id) else { return false }
                    try await RecoveryCaptureService(
                        directory: root, store: store, ledger: store,
                        libraryDictationID: { capture in
                            try Database(path: libraryPath).dictations(captureID: capture).first?.id
                        }
                    ).completeJournalCapture(
                        .init(id: job.id, source: job.source), captureID: id
                    )
                    return true
                }
            )
            try await pipeline.execute(
                jobID: captureID, configuration: .init(), cancellation: CancellationToken()
            )
        }
        _ = try await reopenAndReconcile(captureID: captureID)
        let evidence = try await reopenAndReconcile(captureID: captureID)
        return RetryResult(
            processCalls: processCalls.value, audioLoads: audioLoads.value,
            evidence: evidence
        )
    }

    func reopenAndReconcileInventory() async throws -> InventoryResult {
        let store = try TranscriptionJobStore(databaseURL: jobsDatabase, clock: SystemJobClock())
        let report = await RecoveryReconciler(
            directory: recoveryRoot, store: store, ledger: store, fileSystem: fileSystem,
            libraryDictationID: { _ in nil }, retrySleep: { _ in }
        ).reconcile()
        let projected = try await projectedRecoveryItems(store: store)
        let quarantined = projected.filter {
            $0.session?.assetKind == .quarantined || $0.session?.assetKind == .damaged
        }
        return InventoryResult(
            imported: report.imported, quarantined: report.quarantined,
            failed: report.failed,
            visibleRecoveries: projected.count,
            quarantinedItems: quarantined.count,
            quarantinedItemsWithRetry: quarantined.count {
                $0.availableActions.contains(.retryProcessing)
            },
            retainedQuarantineArtifacts: quarantined.count { $0.artifactURL != nil }
        )
    }

    private func waitForCommittedSegment(
        store: TranscriptionJobStore,
        captureID: UUID
    ) async throws {
        for _ in 0..<2_000 {
            if try await !store.committedSegments(captureID: captureID).isEmpty { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("journal worker did not durably commit a segment")
    }

    private var sampleDictation: DictationInsertRequest {
        .init(
            timestamp: Date(timeIntervalSince1970: 1_721_000_001),
            sourceLanguage: SourceLanguage("en"), requestedOutputLanguage: .sameAsSpoken,
            template: "Default", transcript: "durable transcript",
            refined: "durable transcript", engine: "invariant-test"
        )
    }
}

private final class PersistentFaultFileSystem: JournalFileSystem, @unchecked Sendable {
    private let base: any JournalFileSystem
    private let boundary: PersistentFaultBoundary
    private let lock = NSLock()
    private var armed: Bool
    private var segmentRenameObserved = false
    private var canonicalRenameObserved = false
    private var silentSegmentRemoved = false
    private var cancelledDirectoryRemoved = false
    private var mediaRemovalDirectory: URL?
    private var eventStorage: [String] = []

    init(base: any JournalFileSystem, boundary: PersistentFaultBoundary) {
        self.base = base
        self.boundary = boundary
        armed = boundary.isJournalBoundary
    }

    func arm() { lock.withLock { armed = true } }
    var events: [String] { lock.withLock { eventStorage } }
    private func fire(_ candidate: PersistentFaultBoundary) throws {
        let shouldThrow = lock.withLock { () -> Bool in
            guard armed, boundary == candidate else { return false }
            armed = false
            eventStorage.append("fault:\(candidate.rawValue)")
            return true
        }
        if shouldThrow { throw PersistentInjectedFault(boundary: boundary) }
    }

    func createDirectory(_ url: URL) throws {
        try base.createDirectory(url)
        try fire(.prepareDirectoryCreate)
    }
    func write(_ data: Data, to url: URL) throws {
        try base.write(data, to: url)
        if url.lastPathComponent.hasPrefix(".segment-") { try fire(.segmentWrite) }
    }
    func append(_ data: Data, to url: URL) throws { try base.append(data, to: url) }
    func synchronizeFile(_ url: URL) throws {
        try base.synchronizeFile(url)
        if url.lastPathComponent.hasPrefix(".segment-") { try fire(.segmentFileSync) }
        if url.lastPathComponent.contains(".wav.") { try fire(.canonicalFileSync) }
    }
    func rename(_ source: URL, to destination: URL) throws {
        try base.rename(source, to: destination)
        if destination.lastPathComponent.hasPrefix("segment-") {
            lock.withLock { segmentRenameObserved = true }
            try fire(.segmentRename)
        }
        if UUID(uuidString: destination.deletingPathExtension().lastPathComponent) != nil {
            lock.withLock { canonicalRenameObserved = true }
            try fire(.canonicalRename)
        }
        if destination.lastPathComponent == "capture-diagnostics.json" {
            try fire(.silentDiagnosticsCommit)
        }
    }
    func synchronizeDirectory(_ url: URL) throws {
        try base.synchronizeDirectory(url)
        lock.withLock { eventStorage.append("directory-sync:\(url.standardizedFileURL.path)") }
        try fire(.prepareParentSync)
        if boundary == .segmentDirectorySync,
           lock.withLock({ segmentRenameObserved }) { try fire(.segmentDirectorySync) }
        if boundary == .canonicalDirectorySync,
           lock.withLock({ canonicalRenameObserved }) { try fire(.canonicalDirectorySync) }
        if boundary == .sessionDirectorySync,
           lock.withLock({ mediaRemovalDirectory == url.standardizedFileURL }) {
            try fire(.sessionDirectorySync)
        }
        if boundary == .silentDirectorySync,
           lock.withLock({ silentSegmentRemoved }) { try fire(.silentDirectorySync) }
        if boundary == .cancelParentSync,
           lock.withLock({ cancelledDirectoryRemoved }) { try fire(.cancelParentSync) }
    }
    func contents(_ url: URL) throws -> [URL] { try base.contents(url) }
    func read(_ url: URL) throws -> Data { try base.read(url) }
    func remove(_ url: URL) throws {
        try base.remove(url)
        if url.pathExtension == "wav", url.lastPathComponent.hasPrefix("segment-") {
            lock.withLock {
                silentSegmentRemoved = true
                mediaRemovalDirectory = url.deletingLastPathComponent().standardizedFileURL
                eventStorage.append("media-remove:\(mediaRemovalDirectory!.path)")
            }
            try fire(.segmentRemove)
            try fire(.silentSegmentRemove)
        } else if url.pathExtension == "wav" {
            lock.withLock {
                mediaRemovalDirectory = url.deletingLastPathComponent().standardizedFileURL
                eventStorage.append("media-remove:\(mediaRemovalDirectory!.path)")
            }
            try fire(.canonicalRemove)
        }
        else {
            lock.withLock { cancelledDirectoryRemoved = true }
            try fire(.cancelDirectoryRemove)
        }
    }
    func exists(_ url: URL) -> Bool { base.exists(url) }
}

private actor PersistentFaultLedger: CaptureLedgerStoring {
    let base: TranscriptionJobStore
    let boundary: PersistentFaultBoundary
    var armed: Bool

    init(base: TranscriptionJobStore, boundary: PersistentFaultBoundary) {
        self.base = base
        self.boundary = boundary
        armed = boundary == .prepareLedgerUnknownCommit || boundary == .segmentLedger
            || boundary == .stagedTransition || boundary == .recoveryJobLink
    }

    func arm() { armed = true }
    private func fire(_ candidate: PersistentFaultBoundary) throws {
        guard armed, boundary == candidate else { return }
        armed = false
        throw PersistentInjectedFault(boundary: boundary)
    }

    func createCapture(_ request: CaptureStartRequest) async throws -> CaptureSession {
        let value = try await base.createCapture(request)
        try fire(.prepareLedgerUnknownCommit)
        return value
    }
    func recordCommittedSegment(_ segment: CaptureSegment) async throws {
        try await base.recordCommittedSegment(segment)
        try fire(.segmentLedger)
    }
    func transition(
        id: UUID, from: CaptureSessionState, to: CaptureSessionState,
        recoveryJobID: UUID?, libraryDictationID: Int64?, assetKind: RecoveryAssetKind,
        failureMessage: String?, contentHash: String?
    ) async throws {
        try await base.transition(
            id: id, from: from, to: to, recoveryJobID: recoveryJobID,
            libraryDictationID: libraryDictationID, assetKind: assetKind,
            failureMessage: failureMessage, contentHash: contentHash
        )
        if to == .staged { try fire(.stagedTransition) }
        if to == .processing { try fire(.recoveryJobLink) }
        if to == .libraryCommitted { try fire(.libraryCommittedTransition) }
        if to == .silent { try fire(.silentTransition) }
        if to == .cancelling { try fire(.cancelIntent) }
    }
    func session(id: UUID) async throws -> CaptureSession? { try await base.session(id: id) }
    func unfinishedSessions() async throws -> [CaptureSession] { try await base.unfinishedSessions() }
    func committedSegments(captureID: UUID) async throws -> [CaptureSegment] {
        try await base.committedSegments(captureID: captureID)
    }
    func removeCommittedSegments(captureID: UUID) async throws {
        try await base.removeCommittedSegments(captureID: captureID)
        try fire(.silentMetadataDelete)
    }
    func removeCleanedSession(id: UUID) async throws {
        try await base.removeCleanedSession(id: id)
        try fire(.ledgerDelete)
        try fire(.cancelLedgerDelete)
    }
}

private actor PersistentFaultJobStore: RecoveryJobStoring {
    let base: TranscriptionJobStore
    let boundary: PersistentFaultBoundary
    var armed: Bool

    init(base: TranscriptionJobStore, boundary: PersistentFaultBoundary) {
        self.base = base
        self.boundary = boundary
        armed = boundary == .recoveryJobCreate
    }
    func arm() { armed = true }
    private func fire(_ candidate: PersistentFaultBoundary) throws {
        guard armed, boundary == candidate else { return }
        armed = false
        throw PersistentInjectedFault(boundary: boundary)
    }
    func job(id: UUID) async throws -> TranscriptionJob? { try await base.job(id: id) }
    func createProvisionalRecovery(source: JobSource, capturedAt: Date) async throws -> TranscriptionJob {
        let job = try await base.createProvisionalRecovery(source: source, capturedAt: capturedAt)
        try fire(.recoveryJobCreate)
        return job
    }
    func createProvisionalRecovery(id: UUID, source: JobSource, capturedAt: Date) async throws -> TranscriptionJob {
        let job = try await base.createProvisionalRecovery(id: id, source: source, capturedAt: capturedAt)
        try fire(.recoveryJobCreate)
        return job
    }
    func failProvisionalRecovery(id: UUID, failure: JobFailure) async throws {
        try await base.failProvisionalRecovery(id: id, failure: failure)
    }
    func deleteProvisionalRecovery(id: UUID, expectedSourceReference: String) async throws -> Bool {
        try await base.deleteProvisionalRecovery(id: id, expectedSourceReference: expectedSourceReference)
    }
    func deleteCommittedRecovery(id: UUID, expectedSourceReference: String) async throws -> Bool {
        let value = try await base.deleteCommittedRecovery(id: id, expectedSourceReference: expectedSourceReference)
        try fire(.recoveryJobDelete)
        return value
    }
    func createRecovery(source: JobSource, metadata: RecoveryMetadata) async throws -> TranscriptionJob {
        try await base.createRecovery(source: source, metadata: metadata)
    }
    func claimExpiredRecoveries(cutoff: Date, claimedAt: Date) async throws -> [RecoveryPurgeClaim] {
        try await base.claimExpiredRecoveries(cutoff: cutoff, claimedAt: claimedAt)
    }
    func claimedRecoveries() async throws -> [RecoveryPurgeClaim] { try await base.claimedRecoveries() }
    func recordPurgeError(id: UUID, message: String) async throws {
        try await base.recordPurgeError(id: id, message: message)
    }
    func deleteClaimedRecovery(id: UUID, expectedSourceReference: String) async throws -> Bool {
        try await base.deleteClaimedRecovery(id: id, expectedSourceReference: expectedSourceReference)
    }
}
