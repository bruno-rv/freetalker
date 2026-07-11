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
}

private enum RecoveryTestError: Error { case databaseFailure }

private actor FailingRecoveryStore: RecoveryJobStoring {
    func createRecovery(source: JobSource, metadata: RecoveryMetadata) throws -> TranscriptionJob { throw RecoveryTestError.databaseFailure }
    func recoveryJobs() throws -> [TranscriptionJob] { [] }
    func deleteRecovery(id: UUID, expectedSourceReference: String) throws -> Bool { false }
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
