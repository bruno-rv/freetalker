import Foundation
import Testing
import CSQLite
@testable import FreeTalker

@Suite struct TranscriptionJobStoreTests {
    @Test func persistedEnumsHaveExactStableEncodings() {
        #expect(Dictionary(uniqueKeysWithValues: JobKind.allCases.map { ($0, $0.rawValue) }) == [
            .recovery: "recovery", .mediaImport: "media_import"
        ])
        #expect(Dictionary(uniqueKeysWithValues: JobState.Kind.allCases.map { ($0, $0.rawValue) }) == [
            .queued: "queued", .processing: "processing", .ready: "ready",
            .failed: "failed", .cancelled: "cancelled"
        ])
        #expect(Dictionary(uniqueKeysWithValues: JobStage.allCases.map { ($0, $0.rawValue) }) == [
            .preparing: "preparing", .decoding: "decoding", .transcribing: "transcribing",
            .diarizing: "diarizing", .postProcessing: "post_processing", .persisting: "persisting",
            .finalizing: "finalizing"
        ])
    }

    @Test func createsAndReadsAJob() async throws {
        let database = try TemporaryJobDatabase()
        let now = Date(timeIntervalSince1970: 1_000)
        let store = try TranscriptionJobStore(databaseURL: database.url, clock: FixedJobClock(now: now))
        let source = JobSource(reference: "/tmp/recovery.wav", bookmark: Data([1, 2, 3]))

        let created = try await store.create(kind: .recovery, source: source, now: now)

        #expect(created.kind == .recovery)
        #expect(created.source == source)
        #expect(created.state == .queued)
        #expect(created.createdAt == now)
        #expect(try await store.job(id: created.id) == created)
        #expect(try await store.jobs(kind: .recovery) == [created])
        #expect(try await store.jobs(kind: .mediaImport).isEmpty)
    }

    @Test func permitsLegalTransitionAndRejectsStaleOrIllegalTransition() async throws {
        let fixture = try await fixture()

        try await fixture.store.transition(
            fixture.job.id,
            from: .queued,
            to: .processing(stage: .transcribing)
        )
        #expect(try await fixture.store.job(id: fixture.job.id)?.state == .processing(stage: .transcribing))

        await #expect(throws: JobStoreError.invalidTransition) {
            try await fixture.store.transition(fixture.job.id, from: .queued, to: .ready)
        }
        await #expect(throws: JobStoreError.invalidTransition) {
            try await fixture.store.transition(fixture.job.id, from: .processing, to: .queued)
        }
    }

    @Test func appendsAndFinishesAttempts() async throws {
        let fixture = try await fixture()
        let configuration = AttemptConfiguration(language: "pt", speechModel: "small", template: "clean")

        let first = try await fixture.store.beginAttempt(jobID: fixture.job.id, configuration: configuration)
        let second = try await fixture.store.beginAttempt(jobID: fixture.job.id, configuration: configuration)
        try await fixture.store.finishAttempt(first.id, result: .failed(JobFailure(stage: .transcribing, message: "bad audio")))
        try await fixture.store.finishAttempt(second.id, result: .succeeded)

        let attempts = try await fixture.store.attempts(jobID: fixture.job.id)
        #expect(attempts.map(\.number) == [1, 2])
        #expect(attempts[0].configuration == configuration)
        #expect(attempts[0].result == .failed(JobFailure(stage: .transcribing, message: "bad audio")))
        #expect(attempts[1].result == .succeeded)
    }

    @Test func queueRecoveryRetryAtomicallyPersistsConfigurationAndQueues() async throws {
        let fixture = try await failedFixture()
        let configuration = AttemptConfiguration(language: "pt", speechModel: "small", template: "email")

        let attempt = try await fixture.store.queueRecoveryRetry(jobID: fixture.job.id, configuration: configuration)

        #expect(attempt.configuration == configuration)
        #expect(try await fixture.store.job(id: fixture.job.id)?.state == .queued)
        #expect(try await fixture.store.latestUnfinishedAttempt(jobID: fixture.job.id) == attempt)
    }

    @Test func queueRecoveryRetryRollsBackAttemptWhenTransitionFails() async throws {
        let fixture = try await failedFixture()
        try installQueueTransitionFailure(databaseURL: fixture.database.url)

        await #expect(throws: (any Error).self) {
            try await fixture.store.queueRecoveryRetry(jobID: fixture.job.id, configuration: .init(language: "pt"))
        }

        #expect(try await fixture.store.job(id: fixture.job.id)?.state.kind == .failed)
        #expect(try await fixture.store.attempts(jobID: fixture.job.id).isEmpty)
    }

    @Test func concurrentQueueRecoveryRetryHasOneWinnerAndNoOrphanAttempt() async throws {
        let fixture = try await failedFixture()
        let second = try TranscriptionJobStore(databaseURL: fixture.database.url, clock: FixedJobClock(now: Date(timeIntervalSince1970: 1_001)))

        async let firstResult = retryResult(store: fixture.store, id: fixture.job.id, language: "en")
        async let secondResult = retryResult(store: second, id: fixture.job.id, language: "pt")
        let results = await [firstResult, secondResult]

        #expect(results.count { if case .success = $0 { true } else { false } } == 1)
        #expect(try await fixture.store.job(id: fixture.job.id)?.state == .queued)
        #expect(try await fixture.store.attempts(jobID: fixture.job.id).count == 1)
    }

    @Test func readsLatestUnfinishedAttemptAndAtomicallyCompletesItWithJob() async throws {
        let fixture = try await fixture()
        try await fixture.store.transition(fixture.job.id, from: .queued, to: .processing(stage: .preparing))
        let attempt = try await fixture.store.beginAttempt(
            jobID: fixture.job.id,
            configuration: .init(language: "pt", speechModel: "small", template: "email")
        )

        #expect(try await fixture.store.latestUnfinishedAttempt(jobID: fixture.job.id) == attempt)
        try await fixture.store.completeAttemptAndMarkJobReady(jobID: fixture.job.id, attemptID: attempt.id)

        #expect(try await fixture.store.latestUnfinishedAttempt(jobID: fixture.job.id) == nil)
        #expect(try await fixture.store.attempts(jobID: fixture.job.id).last?.result == .succeeded)
        #expect(try await fixture.store.job(id: fixture.job.id)?.state == .ready)
        #expect(try await fixture.store.job(id: fixture.job.id)?.needsSourceCleanup == true)
    }

    @Test func atomicCompletionRollsBackAttemptWhenReadyUpdateCannotApply() async throws {
        let fixture = try await fixture()
        let attempt = try await fixture.store.beginAttempt(jobID: fixture.job.id, configuration: .init())

        await #expect(throws: JobStoreError.invalidTransition) {
            try await fixture.store.completeAttemptAndMarkJobReady(jobID: fixture.job.id, attemptID: attempt.id)
        }

        #expect(try await fixture.store.attempts(jobID: fixture.job.id).last?.result == nil)
        #expect(try await fixture.store.job(id: fixture.job.id)?.state == .queued)
    }

    @Test func recoversInterruptedJobsAfterStoreRestart() async throws {
        let database = try TemporaryJobDatabase()
        let clock = FixedJobClock(now: Date(timeIntervalSince1970: 2_000))
        let id: UUID
        do {
            let store = try TranscriptionJobStore(databaseURL: database.url, clock: clock)
            let job = try await store.create(kind: .recovery, source: .init(reference: "audio.wav"), now: clock.now)
            id = job.id
            try await store.transition(id, from: .queued, to: .processing(stage: .postProcessing))
        }

        let restarted = try TranscriptionJobStore(databaseURL: database.url, clock: clock)
        #expect(try await restarted.recoverInterruptedJobs() == 1)
        #expect(try await restarted.job(id: id)?.state == .queued)
        #expect(try await restarted.recoverInterruptedJobs() == 0)
    }

    @Test func speakerRenameReplacesOneMappingWithoutChangingOthers() async throws {
        let fixture = try await fixture()
        try await fixture.store.replaceSpeakerName(jobID: fixture.job.id, speakerID: "speaker-1", name: "Alice")
        try await fixture.store.replaceSpeakerName(jobID: fixture.job.id, speakerID: "speaker-2", name: "Charlie")

        try await fixture.store.replaceSpeakerName(jobID: fixture.job.id, speakerID: "speaker-1", name: "Bob")

        #expect(try await fixture.store.speakerNames(jobID: fixture.job.id) == [
            "speaker-1": "Bob", "speaker-2": "Charlie"
        ])
    }

    private func fixture() async throws -> (database: TemporaryJobDatabase, store: TranscriptionJobStore, job: TranscriptionJob) {
        let database = try TemporaryJobDatabase()
        let clock = FixedJobClock(now: Date(timeIntervalSince1970: 1_000))
        let store = try TranscriptionJobStore(databaseURL: database.url, clock: clock)
        let job = try await store.create(kind: .recovery, source: .init(reference: "audio.wav"), now: clock.now)
        return (database, store, job)
    }

    private func failedFixture() async throws -> (database: TemporaryJobDatabase, store: TranscriptionJobStore, job: TranscriptionJob) {
        let fixture = try await fixture()
        try await fixture.store.transition(fixture.job.id, from: .queued, to: .processing(stage: .preparing))
        try await fixture.store.transition(fixture.job.id, from: .processing, to: .failed(.init(stage: .transcribing, message: "offline")))
        return fixture
    }

    private func installQueueTransitionFailure(databaseURL: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK, let database else { throw CocoaError(.fileWriteUnknown) }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, "CREATE TRIGGER fail_retry_queue BEFORE UPDATE OF state ON transcription_jobs WHEN NEW.state = 'queued' BEGIN SELECT RAISE(ABORT, 'injected queue failure'); END;", nil, nil, nil) == SQLITE_OK else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}

private func retryResult(store: TranscriptionJobStore, id: UUID, language: String) async -> Result<JobAttempt, Error> {
    do { return .success(try await store.queueRecoveryRetry(jobID: id, configuration: .init(language: language))) }
    catch { return .failure(error) }
}

private struct FixedJobClock: JobClock {
    let now: Date
}

private final class TemporaryJobDatabase: @unchecked Sendable {
    let url: URL

    init() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("jobs.sqlite")
    }

    deinit {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}
