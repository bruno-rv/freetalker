import AVFoundation
import Foundation

struct RecoveryDictation: Sendable, Equatable {
    let language: String
    let template: String
    let transcript: String
    let refined: String
    let engine: String
}

protocol RecoveryRetryStoring: Sendable {
    func job(id: UUID) async throws -> TranscriptionJob?
    func transition(_ id: UUID, from: JobState.Kind, to state: JobState) async throws
    func beginAttempt(jobID: UUID, configuration: AttemptConfiguration) async throws -> JobAttempt
    func finishAttempt(_ id: Int64, result: AttemptResult) async throws
    func latestUnfinishedAttempt(jobID: UUID) async throws -> JobAttempt?
    func completeAttemptAndMarkJobReady(jobID: UUID, attemptID: Int64) async throws
    func failAttemptAndMarkJobFailed(jobID: UUID, attemptID: Int64, failure: JobFailure) async throws
    func recordSourceCleanupError(jobID: UUID, message: String) async throws
    func completeSourceCleanup(jobID: UUID) async throws
    func jobsNeedingSourceCleanup() async throws -> [TranscriptionJob]
}

protocol RecoveryLeaseStoring: RecoveryRetryStoring {
    func beginOwnedAttempt(jobID: UUID, owner: UUID, configuration: AttemptConfiguration) async throws -> JobAttempt
    func advanceOwnedStage(jobID: UUID, owner: UUID, stage: JobStage) async throws
    func finishOwnedAttempt(jobID: UUID, owner: UUID, attemptID: Int64, result: AttemptResult) async throws
    func completeOwnedAttemptAndJob(jobID: UUID, owner: UUID, attemptID: Int64) async throws
    func failOwnedAttemptAndJob(jobID: UUID, owner: UUID, attemptID: Int64, failure: JobFailure) async throws
}

extension TranscriptionJobStore: RecoveryRetryStoring {}

struct RecoveryRetryPipeline: Sendable {
    typealias ProcessDictation = @Sendable ([Float], AttemptConfiguration, UUID) async throws -> RecoveryDictation

    private let directory: URL
    private let store: any RecoveryRetryStoring
    private let loadSamples: @Sendable (URL) throws -> [Float]
    private let processDictation: ProcessDictation
    private let removeSource: @Sendable (URL) throws -> Void
    private let errorStage: @Sendable (any Error) -> JobStage
    private let libraryDictationID: @Sendable (UUID) async throws -> Int64?
    private let finalizeJournalCapture: @Sendable (UUID, Int64) async throws -> Bool

    init(
        directory: URL,
        store: any RecoveryRetryStoring,
        loadSamples: @escaping @Sendable (URL) throws -> [Float] = Self.loadPCM,
        processDictation: @escaping ProcessDictation,
        removeSource: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) },
        errorStage: @escaping @Sendable (any Error) -> JobStage = { _ in .persisting },
        libraryDictationID: @escaping @Sendable (UUID) async throws -> Int64? = { _ in nil },
        finalizeJournalCapture: @escaping @Sendable (UUID, Int64) async throws -> Bool = { _, _ in false }
    ) {
        self.directory = directory.standardizedFileURL.resolvingSymlinksInPath()
        self.store = store
        self.loadSamples = loadSamples
        self.processDictation = processDictation
        self.removeSource = removeSource
        self.errorStage = errorStage
        self.libraryDictationID = libraryDictationID
        self.finalizeJournalCapture = finalizeJournalCapture
    }

    func execute(jobID: UUID, configuration: AttemptConfiguration?, cancellation: CancellationToken) async throws {
        guard let job = try await store.job(id: jobID), job.kind == .recovery else {
            throw JobStoreError.jobNotFound
        }
        let attempt: JobAttempt
        if let unfinished = try await store.latestUnfinishedAttempt(jobID: jobID) {
            attempt = unfinished
        } else {
            if let owner = cancellation.owner, let leased = store as? any RecoveryLeaseStoring {
                attempt = try await leased.beginOwnedAttempt(jobID: jobID, owner: owner, configuration: configuration ?? AttemptConfiguration())
            } else {
                attempt = try await store.beginAttempt(jobID: jobID, configuration: configuration ?? AttemptConfiguration())
            }
        }
        if let libraryID = try await libraryDictationID(jobID) {
            try cancellation.checkCancellation()
            try await cancellation.beginFinalization()
            if try await finalizeJournalCapture(jobID, libraryID) { return }
            try await completeAttemptAndJob(
                jobID: jobID, attemptID: attempt.id, cancellation: cancellation
            )
            await cleanSource(for: job)
            return
        }
        do {
            try cancellation.checkCancellation()
            if let owner = cancellation.owner, let leased = store as? any RecoveryLeaseStoring {
                try await leased.advanceOwnedStage(jobID: jobID, owner: owner, stage: .transcribing)
            } else { try await store.transition(jobID, from: .processing, to: .processing(stage: .transcribing)) }
            let samples = try loadSamples(URL(fileURLWithPath: job.source.reference))
            try cancellation.checkCancellation()
            _ = try await processDictation(samples, attempt.configuration, jobID)
            try cancellation.checkCancellation()
            try await cancellation.beginFinalization()
            if let libraryID = try await libraryDictationID(jobID),
               try await finalizeJournalCapture(jobID, libraryID) {
                return
            }
        } catch {
            let result = AttemptResult.failed(JobFailure(stage: errorStage(error), message: error.localizedDescription))
            if let owner = cancellation.owner, let leased = store as? any RecoveryLeaseStoring {
                try? await leased.finishOwnedAttempt(jobID: jobID, owner: owner, attemptID: attempt.id, result: result)
            } else { try? await store.finishAttempt(attempt.id, result: result) }
            throw error
        }
        try await completeAttemptAndJob(
            jobID: jobID, attemptID: attempt.id, cancellation: cancellation
        )
        await cleanSource(for: job)
    }

    func retryPendingSourceCleanup() async {
        guard let jobs = try? await store.jobsNeedingSourceCleanup() else { return }
        for job in jobs { await cleanSource(for: job) }
    }

    func failFinalization(jobID: UUID, owner: UUID?, error: any Error) async throws {
        guard let attempt = try await store.latestUnfinishedAttempt(jobID: jobID) else { return }
        let failure = JobFailure(stage: .persisting, message: error.localizedDescription)
        if let owner, let leased = store as? any RecoveryLeaseStoring {
            try await leased.failOwnedAttemptAndJob(jobID: jobID, owner: owner, attemptID: attempt.id, failure: failure)
        } else { try await store.failAttemptAndMarkJobFailed(jobID: jobID, attemptID: attempt.id, failure: failure) }
    }

    private func cleanSource(for job: TranscriptionJob) async {
        do {
            guard let source = ownedSource(job.source.reference) else {
                throw RecoveryCleanupError.outsideOwnedDirectory
            }
            if FileManager.default.fileExists(atPath: source.path) {
                try RecoveryImportDispositionStore(directory: directory).record(source: source)
                try removeSource(source)
            }
            try await store.completeSourceCleanup(jobID: job.id)
        } catch {
            try? await store.recordSourceCleanupError(jobID: job.id, message: error.localizedDescription)
        }
    }

    private func completeAttemptAndJob(
        jobID: UUID,
        attemptID: Int64,
        cancellation: CancellationToken
    ) async throws {
        if let owner = cancellation.owner, let leased = store as? any RecoveryLeaseStoring {
            try await leased.completeOwnedAttemptAndJob(
                jobID: jobID, owner: owner, attemptID: attemptID
            )
        } else {
            try await store.completeAttemptAndMarkJobReady(
                jobID: jobID, attemptID: attemptID
            )
        }
    }

    private func ownedSource(_ reference: String) -> URL? {
        let source = URL(fileURLWithPath: reference).standardizedFileURL
        guard source.pathExtension == "wav",
              UUID(uuidString: source.deletingPathExtension().lastPathComponent) != nil,
              source.resolvingSymlinksInPath().deletingLastPathComponent() == directory else { return nil }
        return source
    }

    static func loadPCM(from url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(file.length)
        ) else { throw CocoaError(.fileReadCorruptFile) }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else { throw CocoaError(.fileReadCorruptFile) }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }
}

private enum RecoveryCleanupError: LocalizedError {
    case outsideOwnedDirectory
    var errorDescription: String? { "Recovery source is outside the owned directory" }
}
