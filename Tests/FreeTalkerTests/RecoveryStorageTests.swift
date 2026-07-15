import Foundation
import Testing
@testable import FreeTalker

@Suite struct RecoveryStorageTests {
    @Test func stopStagesDurableAudioBeforeLaunchingAsyncRegistration() throws {
        let fixture = try RecoveryFixture()
        let service = RecoveryCaptureService(directory: fixture.directory, store: fixture.store)
        var events: [String] = []
        var launchedCapture: StagedRecoveryCapture?

        try AppCoordinator.stageCaptureBeforeLaunching(
            samples: [0.25],
            stage: { samples in
                events.append("stage")
                return try service.stageProvisional(samples: samples, capturedAt: Date())
            },
            launch: { capture in
                events.append("launch")
                #expect(FileManager.default.fileExists(atPath: capture.source.reference))
                launchedCapture = capture
            }
        )

        #expect(events == ["stage", "launch"])
        #expect(launchedCapture != nil)
    }

    @Test func launchReconcilesAudioStagedBeforeRegistration() async throws {
        let fixture = try RecoveryFixture()
        let service = RecoveryCaptureService(directory: fixture.directory, store: fixture.store)
        let staged = try service.stageProvisional(
            samples: [0.25],
            capturedAt: Date(timeIntervalSince1970: 8_000)
        )

        let captures = try await service.reconcileStagedProvisionalCaptures()

        #expect(captures.map(\.source) == [staged.source])
        let job = try #require(try await fixture.store.job(id: captures[0].id))
        #expect(job.state == .processing(stage: .preparing))
        #expect(FileManager.default.fileExists(atPath: staged.source.reference))
    }

    @Test func launchIgnoresUnmarkedOrphanWAV() async throws {
        let fixture = try RecoveryFixture()
        let orphan = fixture.directory.appendingPathComponent("\(UUID().uuidString).wav")
        try Data("orphan".utf8).write(to: orphan)
        let service = RecoveryCaptureService(directory: fixture.directory, store: fixture.store)

        #expect(try await service.reconcileStagedProvisionalCaptures().isEmpty)
        #expect(try await fixture.store.jobs(kind: .recovery).isEmpty)
        #expect(FileManager.default.fileExists(atPath: orphan.path))
    }

    @Test func provisionalRegistrationFailureKeepsStagedAudioForLaunchReconciliation() async throws {
        let directory = try TemporaryDirectory()
        let service = RecoveryCaptureService(directory: directory.url, store: FailingRecoveryStore())
        let staged = try service.stageProvisional(samples: [0.25], capturedAt: Date())

        await #expect(throws: RecoveryTestError.databaseFailure) {
            try await service.registerProvisional(staged)
        }

        #expect(FileManager.default.fileExists(atPath: staged.source.reference))
    }

    @Test func provisionalCaptureAtomicallyWritesWAVAndCreatesLiveProcessingJob() async throws {
        let fixture = try RecoveryFixture()
        let now = Date(timeIntervalSince1970: 9_000)
        let service = RecoveryCaptureService(directory: fixture.directory, store: fixture.store)

        let capture = try await service.preserveProvisional(samples: [0, 0.5, -0.5], capturedAt: now)

        let job = try #require(try await fixture.store.job(id: capture.id))
        #expect(job.state == .processing(stage: .preparing))
        #expect(job.createdAt == now)
        #expect(job.source.reference == capture.source.reference)
        #expect(FileManager.default.fileExists(atPath: capture.source.reference))
    }

    @Test func provisionalFailureLeavesSameAudioRecoverableAndRetryable() async throws {
        let fixture = try RecoveryFixture()
        let service = RecoveryCaptureService(directory: fixture.directory, store: fixture.store)
        let capture = try await service.preserveProvisional(samples: [0.25], capturedAt: Date())
        let failure = JobFailure(stage: .transcribing, message: "cancelled")

        try await service.failProvisional(capture, failure: failure)

        let job = try #require(try await fixture.store.job(id: capture.id))
        #expect(job.state == .failed(failure))
        #expect(FileManager.default.fileExists(atPath: capture.source.reference))
    }

    @Test func journalCompletionKeepsRecoveryUntilLibraryOwnershipThenDeletesMediaJobAndLedgerInOrder() async throws {
        let fixture = try await JournalCompletionFixture()
        let libraryID = fixture.libraryID
        let service = fixture.service(libraryID: libraryID)

        try await service.completeJournalCapture(
            fixture.capture,
            captureID: fixture.captureID
        )

        #expect(fixture.events.values == [
            "lookup:\(fixture.captureID.uuidString)",
            "ledger-commit:\(fixture.captureID.uuidString)",
            "sync:\(fixture.temp.url.path)",
            "sync:\(fixture.temp.url.path)",
            "remove:\(fixture.canonical.path)",
            "remove:\(fixture.segment.path)",
            "sync:\(fixture.sessionDirectory.path)",
            "delete-job:\(fixture.captureID.uuidString)",
            "delete-ledger:\(fixture.captureID.uuidString)"
        ])
        #expect(try await fixture.store.job(id: fixture.captureID) == nil)
        #expect(try await fixture.store.session(id: fixture.captureID) == nil)
    }

    @Test func journalCompletionRefusesCleanupBeforeObservableLibraryCommit() async throws {
        let fixture = try await JournalCompletionFixture()
        let service = fixture.service(libraryID: nil)

        await #expect(throws: RecoveryFinalizationError.libraryOwnershipMissing(fixture.captureID)) {
            try await service.completeJournalCapture(
                fixture.capture,
                captureID: fixture.captureID
            )
        }

        #expect(try await fixture.store.job(id: fixture.captureID) != nil)
        #expect(try await fixture.store.session(id: fixture.captureID) != nil)
    }

    @Test func journalCompletionRetriesEveryInterruptedBoundaryWithoutLosingOwnership() async throws {
        let boundaries = [
            "lookup", "ledger-commit", "canonical", "segment", "sync", "delete-job", "delete-ledger"
        ]
        var fixtures: [JournalCompletionFixture] = []
        for _ in boundaries { fixtures.append(try await JournalCompletionFixture()) }
        for (boundary, fixture) in zip(boundaries, fixtures) {
            fixture.events.armFailure(boundary)
            let service = fixture.service(libraryID: fixture.libraryID)

            do {
                try await service.completeJournalCapture(
                    fixture.capture, captureID: fixture.captureID
                )
                Issue.record("expected injected failure at \(boundary)")
            } catch is InjectedRecoveryFinalizationFailure {
            }
            let libraryOwnsCapture = fixture.events.values.contains(
                "lookup:\(fixture.captureID.uuidString)"
            )
            let recoveryJobExists = try await fixture.store.job(id: fixture.captureID) != nil
            let recoveryLedgerExists = try await fixture.store.session(id: fixture.captureID) != nil
            #expect(libraryOwnsCapture || recoveryJobExists || recoveryLedgerExists)

            let reopened = try TranscriptionJobStore(
                databaseURL: fixture.databaseURL, clock: SystemJobClock()
            )
            let resumed = RecoveryCaptureService(
                directory: fixture.temp.url, store: reopened, ledger: reopened,
                journalFileSystem: LocalJournalFileSystem(),
                libraryDictationID: { id in try fixture.library.lookup(captureID: id) }
            )
            let reopenedSession = try await reopened.session(id: fixture.captureID)
            if reopenedSession == nil {
                // The final ledger delete committed before the injected throw.
            } else if reopenedSession?.state == .libraryCommitted {
                try await resumed.resumeLibraryCommittedCaptures()
            } else {
                try await resumed.completeJournalCapture(
                    fixture.capture, captureID: fixture.captureID
                )
            }
            #expect(try await reopened.job(id: fixture.captureID) == nil)
            #expect(try await reopened.session(id: fixture.captureID) == nil)
            #expect(try fixture.library.count(captureID: fixture.captureID) == 1)
        }
    }

    @Test func startupResumesLedgerOnlyCleanupAfterRecoveryJobDeleteCommittedThenThrew() async throws {
        let fixture = try await JournalCompletionFixture()
        try await fixture.store.transition(
            fixture.captureID, from: .processing,
            to: .failed(.init(stage: .persisting, message: "stale lease"))
        )
        try await fixture.store.transition(fixture.captureID, from: .failed, to: .queued)
        _ = try await fixture.store.claimQueuedJob(
            fixture.captureID, kind: .recovery, owner: UUID(), leaseDuration: 300
        )
        fixture.events.armFailure("delete-job")
        let service = fixture.service(libraryID: fixture.libraryID)

        await #expect(throws: InjectedRecoveryFinalizationFailure.self) {
            try await service.completeJournalCapture(
                fixture.capture, captureID: fixture.captureID
            )
        }
        #expect(try await fixture.store.job(id: fixture.captureID) == nil)
        #expect(try await fixture.store.session(id: fixture.captureID)?.state == .libraryCommitted)

        let reopened = try TranscriptionJobStore(
            databaseURL: fixture.databaseURL, clock: SystemJobClock()
        )
        let resumed = RecoveryCaptureService(
            directory: fixture.temp.url,
            store: reopened,
            ledger: reopened,
            journalFileSystem: LocalJournalFileSystem(),
            libraryDictationID: { id in try fixture.library.lookup(captureID: id) }
        )
        try await resumed.resumeLibraryCommittedCaptures()

        #expect(try await reopened.job(id: fixture.captureID) == nil)
        #expect(try await reopened.session(id: fixture.captureID) == nil)
    }

    @Test func captureAtomicallyWritesWAVAndCreatesFailedJob() async throws {
        let fixture = try RecoveryFixture()
        let now = Date(timeIntervalSince1970: 10_000)
        let service = RecoveryCaptureService(directory: fixture.directory, store: fixture.store)

        let id = try await service.preserve(
            samples: [0, 0.5, -0.5],
            metadata: RecoveryMetadata(capturedAt: now, failure: .init(stage: .transcribing, message: "no speech"))
        )

        let job = try #require(try await fixture.store.job(id: id))
        #expect(job.kind == .recovery)
        #expect(job.state == .failed(.init(stage: .transcribing, message: "no speech")))
        #expect(FileManager.default.fileExists(atPath: job.source.reference))
        let files = try FileManager.default.contentsOfDirectory(at: fixture.directory, includingPropertiesForKeys: nil)
        #expect(files.count == 1)
        #expect(files[0].pathExtension == "wav")
        #expect(try Data(contentsOf: URL(fileURLWithPath: job.source.reference)).prefix(4) == Data("RIFF".utf8))
    }

    @Test func captureRemovesFinalAndTemporaryFilesWhenJobCreationFails() async throws {
        let directory = try TemporaryDirectory()
        let service = RecoveryCaptureService(directory: directory.url, store: FailingRecoveryStore())

        await #expect(throws: RecoveryTestError.databaseFailure) {
            try await service.preserve(samples: [0.25], metadata: .init(
                capturedAt: Date(timeIntervalSince1970: 20_000),
                failure: .init(stage: .persisting, message: "database failed")
            ))
        }

        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.url.path).isEmpty)
    }

    @Test func captureExposesPersistenceAndRollbackErrorsWhenFinalRemovalFails() async throws {
        let directory = try TemporaryDirectory()
        let service = RecoveryCaptureService(
            directory: directory.url,
            store: FailingRecoveryStore(),
            fileRemover: AlwaysFailingRemover()
        )

        do {
            _ = try await service.preserve(samples: [0.25], metadata: .init(
                capturedAt: Date(), failure: .init(stage: .persisting, message: "database failed")
            ))
            Issue.record("Expected compound capture failure")
        } catch let error as RecoveryCaptureRollbackError {
            #expect(error.persistenceError is RecoveryTestError)
            #expect(error.rollbackError is CocoaError)
        }
    }

    @Test(arguments: [
        (RecoveryRetention.oneDay, 1), (.sevenDays, 7), (.thirtyDays, 30), (.ninetyDays, 90)
    ]) func purgesAtEveryConfiguredRetentionBoundary(retention: RecoveryRetention, days: Int) async throws {
        let fixture = try RecoveryFixture()
        let createdAt = Date(timeIntervalSince1970: 100_000)
        let id = try await fixture.failedRecovery(createdAt: createdAt)
        let service = RecoveryRetentionService(directory: fixture.directory, store: fixture.store)

        #expect(try await service.purgeExpired(now: createdAt.addingTimeInterval(Double(days * 86_400) - 1), retention: retention) == PurgeResult(deletedJobIDs: []))
        let path = try #require(try await fixture.store.job(id: id)).source.reference
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(try await service.purgeExpired(now: createdAt.addingTimeInterval(Double(days * 86_400)), retention: retention) == PurgeResult(deletedJobIDs: [id]))
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func neverRetentionDoesNothing() async throws {
        let fixture = try RecoveryFixture()
        let id = try await fixture.failedRecovery(createdAt: .distantPast)
        let result = try await RecoveryRetentionService(directory: fixture.directory, store: fixture.store)
            .purgeExpired(now: .distantFuture, retention: .never)
        #expect(result.deletedJobIDs.isEmpty)
        #expect(try await fixture.store.job(id: id) != nil)
        let path = try #require(try await fixture.store.job(id: id)).source.reference
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test func purgeDeletesOnlyExactOwnedPath() async throws {
        let fixture = try RecoveryFixture()
        let id = try await fixture.failedRecovery(createdAt: .distantPast)
        let source = try #require(try await fixture.store.job(id: id)).source.reference
        let sibling = URL(fileURLWithPath: source + ".backup")
        try Data("keep".utf8).write(to: sibling)

        _ = try await RecoveryRetentionService(directory: fixture.directory, store: fixture.store)
            .purgeExpired(now: .distantFuture, retention: .oneDay)

        #expect(FileManager.default.fileExists(atPath: sibling.path))
    }

    @Test func purgeExcludesQueuedProcessingReadyCancelledAndNonRecoveryJobs() async throws {
        let fixture = try RecoveryFixture()
        let old = Date(timeIntervalSince1970: 1)
        let states: [JobState] = [.queued, .processing(stage: .transcribing), .ready, .cancelled]
        var ids: [UUID] = []
        for state in states { ids.append(try await fixture.job(kind: .recovery, state: state, createdAt: old)) }
        ids.append(try await fixture.job(kind: .mediaImport, state: .failed(.init(stage: .transcribing, message: "x")), createdAt: old))

        let result = try await RecoveryRetentionService(directory: fixture.directory, store: fixture.store)
            .purgeExpired(now: .distantFuture, retention: .oneDay)

        #expect(result.deletedJobIDs.isEmpty)
        for id in ids { #expect(try await fixture.store.job(id: id) != nil) }
    }

    @Test func databaseClaimRejectsAJobThatBecameActiveAfterDiscovery() async throws {
        let fixture = try RecoveryFixture()
        let id = try await fixture.failedRecovery(createdAt: .distantPast)
        try await fixture.store.transition(id, from: .failed, to: .queued)

        #expect(try await fixture.store.claimExpiredRecoveries(cutoff: .distantFuture, claimedAt: Date()) == [])
        #expect(try await fixture.store.job(id: id)?.state == .queued)
    }

    @Test func claimedRecoveryCannotBeRetriedOrActivated() async throws {
        let fixture = try RecoveryFixture()
        let id = try await fixture.failedRecovery(createdAt: .distantPast)
        #expect(try await fixture.store.claimExpiredRecoveries(cutoff: .distantFuture, claimedAt: Date()).map(\.id) == [id])

        await #expect(throws: JobStoreError.invalidTransition) {
            try await fixture.store.transition(id, from: .failed, to: .queued)
        }
        await #expect(throws: JobStoreError.purgeClaimed) {
            _ = try await fixture.store.beginAttempt(jobID: id, configuration: .init())
        }
    }

    @Test func purgeClaimAndAttemptHaveExactlyOneWinnerAcrossConnectionsInBothOrderings() async throws {
        for claimFirst in [true, false] {
            let temp = try TemporaryDirectory()
            let databaseURL = temp.url.appendingPathComponent("jobs.sqlite")
            let first = try TranscriptionJobStore(databaseURL: databaseURL, clock: SystemJobClock())
            let second = try TranscriptionJobStore(databaseURL: databaseURL, clock: SystemJobClock())
            let source = temp.url.appendingPathComponent("\(UUID().uuidString).wav")
            try Data("audio".utf8).write(to: source)
            let job = try await first.createRecovery(
                source: .init(reference: source.path),
                metadata: .init(
                    capturedAt: .distantPast,
                    failure: .init(stage: .transcribing, message: "failed")
                )
            )

            if claimFirst {
                #expect(try await first.claimExpiredRecoveries(cutoff: .distantFuture, claimedAt: Date()).map(\.id) == [job.id])
                await #expect(throws: JobStoreError.purgeClaimed) {
                    _ = try await second.beginAttempt(jobID: job.id, configuration: .init())
                }
                #expect(try await second.attempts(jobID: job.id).isEmpty)
            } else {
                let attempt = try await first.beginAttempt(jobID: job.id, configuration: .init())
                #expect(attempt.number == 1)
                #expect(try await second.claimExpiredRecoveries(cutoff: .distantFuture, claimedAt: Date()).isEmpty)
                #expect(try await second.claimedRecoveries().isEmpty)
            }
        }
    }

    @Test func purgeReconcilesClaimedJobWithExistingFileAfterCrash() async throws {
        let fixture = try RecoveryFixture()
        let id = try await fixture.failedRecovery(createdAt: .distantPast)
        let source = try #require(try await fixture.store.job(id: id)).source.reference
        _ = try await fixture.store.claimExpiredRecoveries(cutoff: .distantFuture, claimedAt: Date())
        let restarted = try TranscriptionJobStore(
            databaseURL: fixture.temp.url.appendingPathComponent("jobs.sqlite"),
            clock: SystemJobClock()
        )

        let result = try await RecoveryRetentionService(directory: fixture.directory, store: restarted)
            .purgeExpired(now: Date(), retention: .never)

        #expect(result.deletedJobIDs == [id])
        #expect(!FileManager.default.fileExists(atPath: source))
        #expect(try await restarted.job(id: id) == nil)
    }

    @Test func purgeReconcilesClaimedJobWithMissingFileAfterCrash() async throws {
        let fixture = try RecoveryFixture()
        let id = try await fixture.failedRecovery(createdAt: .distantPast)
        let source = try #require(try await fixture.store.job(id: id)).source.reference
        _ = try await fixture.store.claimExpiredRecoveries(cutoff: .distantFuture, claimedAt: Date())
        try FileManager.default.removeItem(atPath: source)

        let result = try await RecoveryRetentionService(directory: fixture.directory, store: fixture.store)
            .purgeExpired(now: Date(), retention: .never)

        #expect(result.deletedJobIDs == [id])
        #expect(try await fixture.store.job(id: id) == nil)
    }

    @Test func removalFailureKeepsClaimAndVisibleCleanupError() async throws {
        let fixture = try RecoveryFixture()
        let job = try await fixture.failedRecovery(createdAt: .distantPast)

        await #expect(throws: Error.self) {
            _ = try await RecoveryRetentionService(
                directory: fixture.directory,
                store: fixture.store,
                fileRemover: AlwaysFailingRemover()
            )
                .purgeExpired(now: .distantFuture, retention: .oneDay)
        }

        let claim = try #require(try await fixture.store.claimedRecoveries().first { $0.id == job })
        #expect(claim.cleanupError != nil)
        #expect(try await fixture.store.job(id: job) != nil)
    }

    @Test func unsafeDotDotNestedAndSymlinkSourcesNeverDeleteOutsideFiles() async throws {
        let fixture = try RecoveryFixture()
        let outside = fixture.temp.url.appendingPathComponent("outside.wav")
        try Data("outside".utf8).write(to: outside)
        let nestedDirectory = fixture.directory.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: false)
        let nested = nestedDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        try Data("nested".utf8).write(to: nested)
        let symlink = fixture.directory.appendingPathComponent("\(UUID().uuidString).wav")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outside)
        let references = [
            fixture.directory.appendingPathComponent("../outside.wav").path,
            nested.path,
            symlink.path
        ]
        for reference in references {
            _ = try await fixture.failedRecovery(createdAt: .distantPast, sourceReference: reference)
        }

        _ = try? await RecoveryRetentionService(directory: fixture.directory, store: fixture.store)
            .purgeExpired(now: .distantFuture, retention: .oneDay)

        #expect(try Data(contentsOf: outside) == Data("outside".utf8))
        #expect(FileManager.default.fileExists(atPath: nested.path))
        #expect(FileManager.default.fileExists(atPath: symlink.path))
        #expect(try await fixture.store.claimedRecoveries().count == 3)
    }

    @Test func symlinkRootAllowsOwnedChildButNeverOutsideSymlinkTarget() async throws {
        let temp = try TemporaryDirectory()
        let realRoot = temp.url.appendingPathComponent("real", isDirectory: true)
        let linkedRoot = temp.url.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createDirectory(at: realRoot, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: realRoot)
        let store = try TranscriptionJobStore(databaseURL: temp.url.appendingPathComponent("jobs.sqlite"), clock: SystemJobClock())
        let owned = linkedRoot.appendingPathComponent("\(UUID().uuidString).wav")
        try Data("owned".utf8).write(to: owned)
        let job = try await store.createRecovery(source: .init(reference: owned.path), metadata: .init(capturedAt: .distantPast, failure: .init(stage: .transcribing, message: "x")))

        _ = try await RecoveryRetentionService(directory: linkedRoot, store: store)
            .purgeExpired(now: .distantFuture, retention: .oneDay)

        #expect(!FileManager.default.fileExists(atPath: owned.path))
        #expect(try await store.job(id: job.id) == nil)
    }
}

private enum RecoveryTestError: Error { case databaseFailure }

private actor FailingRecoveryStore: RecoveryJobStoring {
    func job(id: UUID) throws -> TranscriptionJob? { throw RecoveryTestError.databaseFailure }
    func createProvisionalRecovery(source: JobSource, capturedAt: Date) throws -> TranscriptionJob { throw RecoveryTestError.databaseFailure }
    func createProvisionalRecovery(id: UUID, source: JobSource, capturedAt: Date) throws -> TranscriptionJob { throw RecoveryTestError.databaseFailure }
    func failProvisionalRecovery(id: UUID, failure: JobFailure) throws { throw RecoveryTestError.databaseFailure }
    func deleteProvisionalRecovery(id: UUID, expectedSourceReference: String) throws -> Bool { throw RecoveryTestError.databaseFailure }
    func deleteCommittedRecovery(id: UUID, expectedSourceReference: String) throws -> Bool { throw RecoveryTestError.databaseFailure }
    func createRecovery(source: JobSource, metadata: RecoveryMetadata) throws -> TranscriptionJob { throw RecoveryTestError.databaseFailure }
    func claimExpiredRecoveries(cutoff: Date, claimedAt: Date) throws -> [RecoveryPurgeClaim] { [] }
    func claimedRecoveries() throws -> [RecoveryPurgeClaim] { [] }
    func recordPurgeError(id: UUID, message: String) throws {}
    func deleteClaimedRecovery(id: UUID, expectedSourceReference: String) throws -> Bool { false }
}

private struct AlwaysFailingRemover: RecoveryFileRemoving {
    func removeItem(at url: URL) throws {
        throw CocoaError(.fileWriteNoPermission)
    }
}

private final class LockedRecoveryEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    private var failureEvent: String?
    private var didFail = false
    init(failureEvent: String? = nil) { self.failureEvent = failureEvent }
    var values: [String] { lock.withLock { storage } }
    func append(_ value: String) { lock.withLock { storage.append(value) } }
    func armFailure(_ boundary: String) {
        lock.withLock {
            failureEvent = boundary
            didFail = false
        }
    }
    func record(_ value: String, boundary: String) throws {
        let fails = lock.withLock { () -> Bool in
            storage.append(value)
            guard !didFail, failureEvent == boundary else { return false }
            didFail = true
            return true
        }
        if fails { throw InjectedRecoveryFinalizationFailure(boundary: boundary) }
    }
}

private struct InjectedRecoveryFinalizationFailure: Error {
    let boundary: String
}

private struct RecordingRecoveryFileSystem: JournalFileSystem {
    let base = LocalJournalFileSystem()
    let events: LockedRecoveryEvents

    func createDirectory(_ url: URL) throws { try base.createDirectory(url) }
    func write(_ data: Data, to url: URL) throws { try base.write(data, to: url) }
    func append(_ data: Data, to url: URL) throws { try base.append(data, to: url) }
    func synchronizeFile(_ url: URL) throws { try base.synchronizeFile(url) }
    func rename(_ source: URL, to destination: URL) throws { try base.rename(source, to: destination) }
    func synchronizeDirectory(_ url: URL) throws {
        try base.synchronizeDirectory(url)
        try events.record("sync:\(url.path)", boundary: "sync")
    }
    func contents(_ url: URL) throws -> [URL] { try base.contents(url) }
    func read(_ url: URL) throws -> Data { try base.read(url) }
    func remove(_ url: URL) throws {
        let boundary = url.lastPathComponent.hasPrefix("segment-") ? "segment" : "canonical"
        try base.remove(url)
        try events.record("remove:\(url.path)", boundary: boundary)
    }
    func exists(_ url: URL) -> Bool { base.exists(url) }
}

private struct JournalCompletionFixture {
    let temp: TemporaryDirectory
    let store: TranscriptionJobStore
    let databaseURL: URL
    let library: PersistentCaptureLibrary
    let libraryID: Int64
    let captureID: UUID
    let sessionDirectory: URL
    let canonical: URL
    let segment: URL
    let capture: ProvisionalRecoveryCapture
    let events: LockedRecoveryEvents

    init(removeCanonical: Bool = false, failureEvent: String? = nil) async throws {
        events = LockedRecoveryEvents(failureEvent: failureEvent)
        temp = try TemporaryDirectory()
        captureID = UUID()
        sessionDirectory = temp.url.appendingPathComponent(captureID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        canonical = sessionDirectory.appendingPathComponent("\(captureID.uuidString).wav")
        segment = sessionDirectory.appendingPathComponent("segment-00000000.wav")
        try Data([1]).write(to: canonical)
        try Data([2]).write(to: segment)
        databaseURL = temp.url.appendingPathComponent("jobs.sqlite")
        library = try PersistentCaptureLibrary(
            url: temp.url.appendingPathComponent("library.sqlite")
        )
        libraryID = try library.insert(captureID: captureID)
        store = try TranscriptionJobStore(
            databaseURL: databaseURL,
            clock: SystemJobClock()
        )
        let capturedAt = Date(timeIntervalSince1970: 12_345)
        _ = try await store.createCapture(.init(
            id: captureID, directory: sessionDirectory, capturedAt: capturedAt,
            sampleRate: 16_000, channelCount: 1, inputDeviceUID: nil,
            destination: "external"
        ))
        try await store.recordCommittedSegment(.init(
            captureID: captureID, ordinal: 0, url: segment,
            sampleCount: 1, contentHash: "hash"
        ))
        try await store.transition(
            id: captureID, from: .capturing, to: .staged,
            recoveryJobID: nil, libraryDictationID: nil, assetKind: .audio,
            failureMessage: nil, contentHash: "canonical"
        )
        let job = try await store.createProvisionalRecovery(
            id: captureID,
            source: .init(reference: canonical.path), capturedAt: capturedAt
        )
        try await store.transition(
            id: captureID, from: .staged, to: .processing,
            recoveryJobID: job.id, libraryDictationID: nil, assetKind: .audio,
            failureMessage: nil, contentHash: "canonical"
        )
        capture = .init(id: job.id, source: job.source)
        if removeCanonical { try FileManager.default.removeItem(at: canonical) }
    }

    func service(libraryID: Int64?) -> RecoveryCaptureService {
        RecoveryCaptureService(
            directory: temp.url,
            store: EventingRecoveryStore(base: store, events: events),
            ledger: EventingCaptureLedger(base: store, events: events),
            journalFileSystem: RecordingRecoveryFileSystem(events: events),
            libraryDictationID: { id in
                try events.record("lookup:\(id.uuidString)", boundary: "lookup")
                guard libraryID != nil else { return nil }
                return try library.lookup(captureID: id)
            }
        )
    }
}

private final class PersistentCaptureLibrary: @unchecked Sendable {
    let url: URL
    init(url: URL) throws {
        self.url = url
        _ = try Database(path: url)
    }

    func insert(captureID: UUID) throws -> Int64 {
        let db = try Database(path: url)
        return try db.insertDictation(.init(
            timestamp: Date(timeIntervalSince1970: 12_345),
            sourceLanguage: SourceLanguage("en"),
            requestedOutputLanguage: .sameAsSpoken,
            template: "Clean", transcript: "raw", refined: "refined",
            engine: "local", sourceID: nil
        ), captureID: captureID).id
    }

    func lookup(captureID: UUID) throws -> Int64? {
        try Database(path: url).dictations(captureID: captureID).first?.id
    }

    func count(captureID: UUID) throws -> Int {
        try Database(path: url).dictations(captureID: captureID).count
    }
}

private struct EventingRecoveryStore: RecoveryJobStoring {
    let base: TranscriptionJobStore
    let events: LockedRecoveryEvents
    func job(id: UUID) async throws -> TranscriptionJob? { try await base.job(id: id) }
    func createProvisionalRecovery(source: JobSource, capturedAt: Date) async throws -> TranscriptionJob { try await base.createProvisionalRecovery(source: source, capturedAt: capturedAt) }
    func createProvisionalRecovery(id: UUID, source: JobSource, capturedAt: Date) async throws -> TranscriptionJob { try await base.createProvisionalRecovery(id: id, source: source, capturedAt: capturedAt) }
    func failProvisionalRecovery(id: UUID, failure: JobFailure) async throws { try await base.failProvisionalRecovery(id: id, failure: failure) }
    func deleteProvisionalRecovery(id: UUID, expectedSourceReference: String) async throws -> Bool { try await base.deleteProvisionalRecovery(id: id, expectedSourceReference: expectedSourceReference) }
    func deleteCommittedRecovery(id: UUID, expectedSourceReference: String) async throws -> Bool {
        let removed = try await base.deleteCommittedRecovery(
            id: id, expectedSourceReference: expectedSourceReference
        )
        try events.record("delete-job:\(id.uuidString)", boundary: "delete-job")
        return removed
    }
    func createRecovery(source: JobSource, metadata: RecoveryMetadata) async throws -> TranscriptionJob { try await base.createRecovery(source: source, metadata: metadata) }
    func claimExpiredRecoveries(cutoff: Date, claimedAt: Date) async throws -> [RecoveryPurgeClaim] { try await base.claimExpiredRecoveries(cutoff: cutoff, claimedAt: claimedAt) }
    func claimedRecoveries() async throws -> [RecoveryPurgeClaim] { try await base.claimedRecoveries() }
    func recordPurgeError(id: UUID, message: String) async throws { try await base.recordPurgeError(id: id, message: message) }
    func deleteClaimedRecovery(id: UUID, expectedSourceReference: String) async throws -> Bool { try await base.deleteClaimedRecovery(id: id, expectedSourceReference: expectedSourceReference) }
}

private struct EventingCaptureLedger: CaptureLedgerStoring {
    let base: TranscriptionJobStore
    let events: LockedRecoveryEvents
    func createCapture(_ request: CaptureStartRequest) async throws -> CaptureSession { try await base.createCapture(request) }
    func recordCommittedSegment(_ segment: CaptureSegment) async throws { try await base.recordCommittedSegment(segment) }
    func transition(id: UUID, from: CaptureSessionState, to: CaptureSessionState, recoveryJobID: UUID?, libraryDictationID: Int64?, assetKind: RecoveryAssetKind, failureMessage: String?, contentHash: String?) async throws {
        try await base.transition(id: id, from: from, to: to, recoveryJobID: recoveryJobID, libraryDictationID: libraryDictationID, assetKind: assetKind, failureMessage: failureMessage, contentHash: contentHash)
        if to == .libraryCommitted {
            try events.record("ledger-commit:\(id.uuidString)", boundary: "ledger-commit")
        }
    }
    func session(id: UUID) async throws -> CaptureSession? { try await base.session(id: id) }
    func unfinishedSessions() async throws -> [CaptureSession] { try await base.unfinishedSessions() }
    func committedSegments(captureID: UUID) async throws -> [CaptureSegment] { try await base.committedSegments(captureID: captureID) }
    func removeCommittedSegments(captureID: UUID) async throws { try await base.removeCommittedSegments(captureID: captureID) }
    func removeCleanedSession(id: UUID) async throws {
        try await base.removeCleanedSession(id: id)
        try events.record("delete-ledger:\(id.uuidString)", boundary: "delete-ledger")
    }
}

private final class RecoveryFixture: @unchecked Sendable {
    let temp: TemporaryDirectory
    let directory: URL
    let store: TranscriptionJobStore

    init() throws {
        temp = try TemporaryDirectory()
        directory = temp.url.appendingPathComponent("recoveries", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = try TranscriptionJobStore(databaseURL: temp.url.appendingPathComponent("jobs.sqlite"), clock: SystemJobClock())
    }

    func failedRecovery(createdAt: Date) async throws -> UUID {
        try await job(kind: .recovery, state: .failed(.init(stage: .transcribing, message: "failed")), createdAt: createdAt)
    }

    func failedRecovery(createdAt: Date, source: URL) async throws -> UUID {
        try await failedRecovery(createdAt: createdAt, sourceReference: source.path)
    }

    func failedRecovery(createdAt: Date, sourceReference: String) async throws -> UUID {
        let created = try await store.create(kind: .recovery, source: .init(reference: sourceReference), now: createdAt)
        try await store.transition(created.id, from: .queued, to: .processing(stage: .preparing))
        try await store.transition(created.id, from: .processing, to: .failed(.init(stage: .transcribing, message: "failed")))
        return created.id
    }

    func job(kind: JobKind, state: JobState, createdAt: Date) async throws -> UUID {
        let path = directory.appendingPathComponent("\(UUID().uuidString).wav").path
        try Data("audio".utf8).write(to: URL(fileURLWithPath: path))
        let created = try await store.create(kind: kind, source: .init(reference: path), now: createdAt)
        if state != .queued {
            if state.kind == .cancelled { try await store.transition(created.id, from: .queued, to: state) }
            else {
                try await store.transition(created.id, from: .queued, to: .processing(stage: .preparing))
                try await store.transition(created.id, from: .processing, to: state)
            }
        }
        return created.id
    }
}

private final class TemporaryDirectory: @unchecked Sendable {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }
}
