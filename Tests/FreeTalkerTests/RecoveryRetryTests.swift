import Foundation
import Testing
@testable import FreeTalker

@Suite struct RecoveryRetryTests {
    @Test func oneRetryCreatesOneAttemptAndUsesOverrides() async throws {
        let fixture = try await RetryFixture()
        let configuration = AttemptConfiguration(language: "pt", speechModel: "small", template: "email")
        let probe = RetryProbe()
        let pipeline = fixture.pipeline(probe: probe)

        try await pipeline.execute(jobID: fixture.job.id, configuration: configuration, cancellation: CancellationToken())

        #expect(try await fixture.store.attempts(jobID: fixture.job.id).count == 1)
        #expect(probe.configurations == [configuration])
    }

    @Test func successfulRetryCommitsBeforeReadyAndDeletesExactSourceLast() async throws {
        let fixture = try await RetryFixture()
        let probe = RetryProbe()
        let pipeline = fixture.pipeline(probe: probe)

        try await pipeline.execute(jobID: fixture.job.id, configuration: .init(), cancellation: CancellationToken())

        #expect(probe.events == ["transcribe", "record", "ready", "remove:\(fixture.source.path)"])
        #expect(!FileManager.default.fileExists(atPath: fixture.source.path))
        #expect(try await fixture.store.job(id: fixture.job.id)?.state == .ready)
    }

    @Test func postProcessFailurePersistsRawTranscript() async throws {
        let fixture = try await RetryFixture()
        let probe = RetryProbe(postProcessFails: true)
        let pipeline = fixture.pipeline(probe: probe)

        try await pipeline.execute(jobID: fixture.job.id, configuration: .init(), cancellation: CancellationToken())

        #expect(probe.recorded?.transcript == "raw words")
        #expect(probe.recorded?.refined == "raw words")
        #expect(try await fixture.store.job(id: fixture.job.id)?.state == .ready)
    }

    @Test func databaseFailurePreservesSourceAndFailsAttempt() async throws {
        let fixture = try await RetryFixture()
        let probe = RetryProbe(recordFails: true)
        let pipeline = fixture.pipeline(probe: probe)

        await #expect(throws: RetryTestError.database) {
            try await pipeline.execute(jobID: fixture.job.id, configuration: .init(), cancellation: CancellationToken())
        }

        #expect(FileManager.default.fileExists(atPath: fixture.source.path))
        #expect(try await fixture.store.attempts(jobID: fixture.job.id).map(\.result) == [
            .failed(JobFailure(stage: .persisting, message: "database"))
        ])
    }

    @Test func interruptedRetryIsRecoveredAndRetriedAsANewAttempt() async throws {
        let fixture = try await RetryFixture()
        try await fixture.store.transition(fixture.job.id, from: .processing, to: .processing(stage: .transcribing))
        _ = try await fixture.store.beginAttempt(jobID: fixture.job.id, configuration: .init(language: "en"))

        #expect(try await fixture.store.recoverInterruptedJobs() == 1)
        try await fixture.store.transition(fixture.job.id, from: .queued, to: .processing(stage: .preparing))
        try await fixture.pipeline(probe: RetryProbe()).execute(
            jobID: fixture.job.id,
            configuration: .init(language: "pt"),
            cancellation: CancellationToken()
        )

        let attempts = try await fixture.store.attempts(jobID: fixture.job.id)
        #expect(attempts.map(\.number) == [1, 2])
        #expect(attempts.map(\.configuration.language) == ["en", "pt"])
        #expect(attempts[0].result == nil)
        #expect(attempts[1].result == .succeeded)
    }
}

private enum RetryTestError: Error, LocalizedError {
    case database

    var errorDescription: String? { "database" }
}

private final class RetryProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storedConfigurations: [AttemptConfiguration] = []
    private var storedEvents: [String] = []
    private var storedRecorded: (transcript: String, refined: String)?
    var configurations: [AttemptConfiguration] { lock.withLock { storedConfigurations } }
    var events: [String] { lock.withLock { storedEvents } }
    var recorded: (transcript: String, refined: String)? { lock.withLock { storedRecorded } }
    let postProcessFails: Bool
    let recordFails: Bool

    init(postProcessFails: Bool = false, recordFails: Bool = false) {
        self.postProcessFails = postProcessFails
        self.recordFails = recordFails
    }

    func process(samples: [Float], configuration: AttemptConfiguration) async throws -> RecoveryDictation {
        lock.withLock {
            storedConfigurations.append(configuration)
            storedEvents.append("transcribe")
        }
        let refined = postProcessFails ? "raw words" : "refined words"
        lock.withLock { storedEvents.append("record") }
        if recordFails { throw RetryTestError.database }
        lock.withLock { storedRecorded = ("raw words", refined) }
        return RecoveryDictation(language: "pt", template: configuration.template ?? "Clean", transcript: "raw words", refined: refined, engine: configuration.speechModel ?? "default")
    }

    func ready() { lock.withLock { storedEvents.append("ready") } }
    func removed(_ url: URL) throws {
        lock.withLock { storedEvents.append("remove:\(url.path)") }
        try FileManager.default.removeItem(at: url)
    }
}

private struct RetryFixture {
    let directory: URL
    let source: URL
    let store: TranscriptionJobStore
    let job: TranscriptionJob

    init() async throws {
        directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        source = directory.appending(path: "\(UUID().uuidString).wav")
        try Data([1, 2, 3]).write(to: source)
        store = try TranscriptionJobStore(databaseURL: directory.appending(path: "jobs.sqlite"), clock: SystemJobClock())
        job = try await store.create(kind: .recovery, source: .init(reference: source.path), now: Date())
        try await store.transition(job.id, from: .queued, to: .processing(stage: .preparing))
    }

    func pipeline(probe: RetryProbe) -> RecoveryRetryPipeline {
        RecoveryRetryPipeline(
            store: store,
            loadSamples: { _ in [0.1] },
            processDictation: probe.process,
            removeSource: probe.removed,
            didMarkReady: probe.ready
        )
    }

    
}
