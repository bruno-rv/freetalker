import Foundation
import Testing
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
            .preparing: "preparing", .transcribing: "transcribing",
            .postProcessing: "post_processing", .persisting: "persisting"
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
