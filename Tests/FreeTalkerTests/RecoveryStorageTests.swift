import Foundation
import Testing
@testable import FreeTalker

@Suite struct RecoveryStorageTests {
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
