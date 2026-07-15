import Foundation
import Testing
@testable import FreeTalker

@Suite struct LegacyRecoveryImportTests {
    @Test("legacy audio is hash deduplicated across files and reopen")
    func legacyAudioIsDeduplicatedPersistently() async throws {
        let fixture = try ReconciliationFixture()
        let audio = WAVEncoder.encode(samples: [0.25, -0.2, 0.1], sampleRate: 16_000)
        let first = fixture.root.appendingPathComponent("failed-2024-01-01-120000.wav")
        let duplicate = fixture.root.appendingPathComponent("failed-manual-copy-17.wav")
        try audio.write(to: first)
        try audio.write(to: duplicate)

        let initial = await fixture.reconciler().reconcile()
        #expect(initial.imported == 1)
        #expect(initial.duplicates == 1)
        #expect(initial.failed == 0)
        #expect(FileManager.default.fileExists(atPath: first.path))
        #expect(FileManager.default.fileExists(atPath: duplicate.path))
        let imported = try #require(try await fixture.store.jobs(kind: .recovery).first)
        let owned = URL(fileURLWithPath: imported.source.reference)
        #expect(owned.deletingLastPathComponent().resolvingSymlinksInPath() == fixture.root.resolvingSymlinksInPath())
        #expect(UUID(uuidString: owned.deletingPathExtension().lastPathComponent) != nil)
        #expect(FileManager.default.fileExists(atPath: owned.path))

        let reopened = try fixture.reopen()
        let second = await reopened.reconciler().reconcile()
        #expect(second.imported == 0)
        #expect(second.duplicates == 3) // two historical sources plus the owned UUID copy
        #expect(try await reopened.store.jobs(kind: .recovery).count == 1)
    }

    @Test("quarantine discriminator and owned artifact survive reopen")
    func quarantineIsDurableAcrossReopen() async throws {
        let fixture = try ReconciliationFixture()
        let corrupt = fixture.root.appendingPathComponent("failed-corrupt-history.wav")
        try Data("not audio".utf8).write(to: corrupt)
        let report = await fixture.reconciler().reconcile()
        #expect(report.quarantined == 1)
        let job = try #require(try await fixture.store.jobs(kind: .recovery).first)
        #expect(try await fixture.store.session(id: job.id)?.assetKind == .quarantined)
        #expect(FileManager.default.fileExists(atPath: corrupt.path))
        #expect(FileManager.default.fileExists(atPath: job.source.reference))

        let reopened = try fixture.reopen()
        #expect(try await reopened.store.session(id: job.id)?.state == .damaged)
        #expect(try await reopened.store.session(id: job.id)?.assetKind == .quarantined)
    }

    @Test("partial registration pointing at historical source converges after reopen")
    func partialRegistrationConverges() async throws {
        let fixture = try ReconciliationFixture()
        let source = fixture.root.appendingPathComponent("failed-partial-registration.wav")
        let data = WAVEncoder.encode(samples: Array(repeating: 0.15, count: 1_600), sampleRate: 16_000)
        try data.write(to: source)
        let id = LegacyRecoveryImporter.stableID(
            hash: CaptureSegmentCodec(fileSystem: fixture.fileSystem).hash(data)
        )
        _ = try await fixture.store.createProvisionalRecovery(
            id: id, source: JobSource(reference: source.path), capturedAt: Date()
        )

        let reopened = try fixture.reopen()
        _ = await reopened.reconciler().reconcile()
        let job = try #require(try await reopened.store.job(id: id))
        #expect(job.source.reference == reopened.root.appendingPathComponent("\(id.uuidString).wav").path)
        #expect(job.state.kind == .failed)
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(FileManager.default.fileExists(atPath: job.source.reference))
    }

    @Test("retention accepts normalized ownership and retains historical source")
    func normalizedOwnershipWorksWithRetention() async throws {
        let fixture = try ReconciliationFixture()
        let historical = fixture.root.appendingPathComponent("failed-retention-history.wav")
        try WAVEncoder.encode(
            samples: Array(repeating: 0.2, count: 1_600), sampleRate: 16_000
        ).write(to: historical)
        _ = await fixture.reconciler().reconcile()
        let job = try #require(try await fixture.store.jobs(kind: .recovery).first)
        let owned = URL(fileURLWithPath: job.source.reference)
        _ = try await RecoveryRetentionService(directory: fixture.root, store: fixture.store)
            .purgeExpired(now: .distantFuture, retention: .oneDay)
        #expect(try await fixture.store.job(id: job.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: owned.path))
        #expect(FileManager.default.fileExists(atPath: historical.path))

        let reopened = try fixture.reopen()
        _ = await reopened.reconciler().reconcile()
        #expect(try await reopened.store.jobs(kind: .recovery).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: owned.path))
    }

    @Test("normalized ownership completes a real retry and cleans only the owned copy")
    func normalizedOwnershipWorksWithRetry() async throws {
        let fixture = try ReconciliationFixture()
        let historical = fixture.root.appendingPathComponent("failed-retry-history.wav")
        try WAVEncoder.encode(
            samples: Array(repeating: 0.2, count: 1_600), sampleRate: 16_000
        ).write(to: historical)
        _ = await fixture.reconciler().reconcile()
        let job = try #require(try await fixture.store.jobs(kind: .recovery).first)
        let owned = URL(fileURLWithPath: job.source.reference)
        _ = try await fixture.store.queueRecoveryRetry(jobID: job.id, configuration: .init())
        try await fixture.store.transition(job.id, from: .queued, to: .processing(stage: .preparing))
        let pipeline = RecoveryRetryPipeline(
            directory: fixture.root, store: fixture.store,
            processDictation: { _, _, _ in
                RecoveryDictation(
                    language: "en", template: "Raw Transcript", transcript: "words",
                    refined: "words", engine: "test"
                )
            }
        )
        try await pipeline.execute(
            jobID: job.id, configuration: nil, cancellation: CancellationToken()
        )
        #expect(try await fixture.store.job(id: job.id)?.state == .ready)
        #expect(!FileManager.default.fileExists(atPath: owned.path))
        #expect(FileManager.default.fileExists(atPath: historical.path))

        let reopened = try fixture.reopen()
        _ = await reopened.reconciler().reconcile()
        #expect(!FileManager.default.fileExists(atPath: owned.path))
        #expect(try await reopened.store.jobs(kind: .recovery).count == 1)
        #expect(try await reopened.store.job(id: job.id)?.state == .ready)
    }

    @MainActor @Test("explicit delete tombstones quarantine and ledger ownership")
    func quarantineDeleteDoesNotResurrect() async throws {
        let fixture = try ReconciliationFixture()
        let historical = fixture.root.appendingPathComponent("failed-delete-corrupt.wav")
        try Data("broken audio".utf8).write(to: historical)
        _ = await fixture.reconciler().reconcile()
        let job = try #require(try await fixture.store.jobs(kind: .recovery).first)
        let library = JobLibraryStore(store: fixture.store, recoveryDirectory: fixture.root)
        try await library.refresh()
        try await library.delete(id: job.id)
        #expect(try await fixture.store.job(id: job.id) == nil)
        #expect(try await fixture.store.session(id: job.id) == nil)
        #expect(FileManager.default.fileExists(atPath: historical.path))

        let reopened = try fixture.reopen()
        _ = await reopened.reconciler().reconcile()
        #expect(try await reopened.store.jobs(kind: .recovery).isEmpty)
        #expect(try await reopened.store.session(id: job.id) == nil)
    }

    @MainActor @Test("deleting one UUID capture never disposes identical audio owned by another UUID")
    func captureDispositionKeepsUUIDIdentity() async throws {
        let fixture = try ReconciliationFixture()
        let firstID = UUID()
        let secondID = UUID()
        let audio = WAVEncoder.encode(
            samples: Array(repeating: 0.3, count: 1_600), sampleRate: 16_000
        )
        let first = fixture.root.appendingPathComponent("\(firstID.uuidString).wav")
        let second = fixture.root.appendingPathComponent("\(secondID.uuidString).wav")
        try audio.write(to: first)
        try audio.write(to: second)
        let report = await fixture.reconciler().reconcile()
        #expect(report.failed == 0, Comment(rawValue: String(describing: report.failures)))
        #expect(try await fixture.store.job(id: firstID) != nil)
        #expect(try await fixture.store.job(id: secondID) != nil)

        let library = JobLibraryStore(store: fixture.store, recoveryDirectory: fixture.root)
        try await library.refresh()
        try await library.delete(id: firstID)
        #expect(try await fixture.store.session(id: firstID) == nil)
        #expect(try await fixture.store.job(id: secondID) != nil)
        #expect(FileManager.default.fileExists(atPath: second.path))

        let reopened = try fixture.reopen()
        _ = await reopened.reconciler().reconcile()
        #expect(try await reopened.store.job(id: firstID) == nil)
        #expect(try await reopened.store.session(id: firstID) == nil)
        #expect(try await reopened.store.job(id: secondID) != nil)
        #expect(FileManager.default.fileExists(atPath: second.path))
    }

    @Test("automatic retention purges a session-canonical quarantine without resurrection")
    func retentionPurgesSessionCanonicalQuarantine() async throws {
        let fixture = try ReconciliationFixture()
        let historical = fixture.root.appendingPathComponent("failed-session-retention.wav")
        try Data("damaged session audio".utf8).write(to: historical)
        _ = await fixture.reconciler().reconcile()
        let job = try #require(try await fixture.store.jobs(kind: .recovery).first)
        let owned = URL(fileURLWithPath: job.source.reference)

        _ = try await RecoveryRetentionService(
            directory: fixture.root, store: fixture.store, ledger: fixture.store
        ).purgeExpired(now: .distantFuture, retention: .oneDay)

        #expect(try await fixture.store.job(id: job.id) == nil)
        #expect(try await fixture.store.session(id: job.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: owned.path))
        #expect(FileManager.default.fileExists(atPath: historical.path))
        let reopened = try fixture.reopen()
        _ = await reopened.reconciler().reconcile()
        #expect(try await reopened.store.jobs(kind: .recovery).isEmpty)
        #expect(try await reopened.store.session(id: job.id) == nil)
    }

    @MainActor @Test("startup resumes an explicit Delete interrupted immediately after its durable claim")
    func claimedDeleteResumesAfterReopen() async throws {
        let fixture = try ReconciliationFixture()
        let historical = fixture.root.appendingPathComponent("failed-claimed-delete.wav")
        try Data("claimed delete audio".utf8).write(to: historical)
        _ = await fixture.reconciler().reconcile()
        let job = try #require(try await fixture.store.jobs(kind: .recovery).first)
        #expect(try await fixture.store.claimRecoveryForDeletion(id: job.id, claimedAt: Date()))

        let reopened = try fixture.reopen()
        let library = JobLibraryStore(store: reopened.store, recoveryDirectory: reopened.root)
        try await library.refresh()
        try await library.delete(id: job.id)
        _ = await reopened.reconciler().reconcile()
        #expect(try await reopened.store.job(id: job.id) == nil)
        #expect(try await reopened.store.session(id: job.id) == nil)
        #expect(FileManager.default.fileExists(atPath: historical.path))
        let rerun = try fixture.reopen()
        _ = await rerun.reconciler().reconcile()
        #expect(try await rerun.store.jobs(kind: .recovery).isEmpty)
    }

    @Test("startup resumes a claimed quarantine after removal throws")
    func claimedRetentionFailureResumesAfterReopen() async throws {
        let fixture = try ReconciliationFixture()
        let historical = fixture.root.appendingPathComponent("failed-claimed-retention.wav")
        try Data("claimed retention audio".utf8).write(to: historical)
        _ = await fixture.reconciler().reconcile()
        let job = try #require(try await fixture.store.jobs(kind: .recovery).first)

        await #expect(throws: Error.self) {
            _ = try await RecoveryRetentionService(
                directory: fixture.root, store: fixture.store,
                fileRemover: FailingLegacyRecoveryRemover(), ledger: fixture.store
            ).purgeExpired(now: .distantFuture, retention: .oneDay)
        }
        #expect(try await fixture.store.claimedRecoveries().map(\.id) == [job.id])

        let reopened = try fixture.reopen()
        _ = await reopened.reconciler().reconcile()
        #expect(try await reopened.store.job(id: job.id) == nil)
        #expect(try await reopened.store.session(id: job.id) == nil)
        #expect(FileManager.default.fileExists(atPath: historical.path))
    }

    @Test("registration retries at the exact same-session schedule")
    func registrationRetrySchedule() async throws {
        let recorder = RetryRecorder(failuresBeforeSuccess: 2)
        let retrier = RecoveryRegistrationRetrier(sleep: { delay in
            await recorder.record(delay)
        })
        try await retrier.run { try await recorder.attempt() }
        #expect(await recorder.delays == [.zero, .milliseconds(250), .seconds(1)])
        #expect(await recorder.attemptCount == 3)
    }
}

private actor RetryRecorder {
    private let failuresBeforeSuccess: Int
    private(set) var delays: [Duration] = []
    private(set) var attemptCount = 0

    init(failuresBeforeSuccess: Int) { self.failuresBeforeSuccess = failuresBeforeSuccess }
    func record(_ delay: Duration) { delays.append(delay) }
    func attempt() throws {
        attemptCount += 1
        if attemptCount <= failuresBeforeSuccess { throw CocoaError(.fileWriteUnknown) }
    }
}

private struct FailingLegacyRecoveryRemover: RecoveryFileRemoving {
    func removeItem(at _: URL) throws { throw CocoaError(.fileWriteUnknown) }
}
