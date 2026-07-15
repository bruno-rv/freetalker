import Foundation
import Testing
@testable import FreeTalker

@Suite struct RecordingDurabilityInvariantTests {
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

    @Test("silent and explicitly cancelled attempts converge after restart")
    func silentAndCancelledConverge() async throws {
        let silentHarness = try RecordingDurabilityHarness()
        let silent = try await silentHarness.createSilent(destination: .scratchpad)
        let silentEvidence = try await silentHarness.reopenAndReconcile(captureID: silent)
        #expect(silentEvidence.visibleSilentOrDamaged)
        #expect(silentEvidence.durableCount >= 1)

        let cancelledHarness = try RecordingDurabilityHarness()
        let cancelled = try await cancelledHarness.createInterruptedCancellation()
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

        #expect(result.imported >= 2)
        #expect(result.quarantined + result.failed >= 1)
        #expect(result.visibleRecoveries >= 2)
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

    func createInterruptedCancellation() async throws -> UUID {
        let captureID = try await interrupt(destination: .external, at: .stagedCanonical)
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
        let rows = try Database(path: libraryDatabase).dictations(captureID: captureID)
        let active = session.map { snapshot in
            fileSystem.exists(snapshot.directory)
                || fileSystem.exists(snapshot.directory.appendingPathComponent(
                    "capture-failure.marker"
                ))
        } ?? false
        let exceptional = session?.assetKind == .silent
            || session?.assetKind == .damaged || session?.assetKind == .quarantined
        return Evidence(
            activeJournalEvidence: active,
            visibleRecoveries: jobs.count + (exceptional ? 1 : 0),
            visibleSilentOrDamaged: exceptional,
            libraryRows: rows.count,
            recoveryJobs: jobs.count,
            isExplicitlyDisposed: session == nil
                && !fileSystem.exists(recoveryRoot.appendingPathComponent(
                    captureID.uuidString, isDirectory: true
                ))
        )
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

    func reopenAndReconcileInventory() async throws -> InventoryResult {
        let store = try TranscriptionJobStore(databaseURL: jobsDatabase, clock: SystemJobClock())
        let report = await RecoveryReconciler(
            directory: recoveryRoot, store: store, ledger: store, fileSystem: fileSystem,
            libraryDictationID: { _ in nil }, retrySleep: { _ in }
        ).reconcile()
        return InventoryResult(
            imported: report.imported, quarantined: report.quarantined,
            failed: report.failed,
            visibleRecoveries: try await store.jobs(kind: .recovery).count
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
