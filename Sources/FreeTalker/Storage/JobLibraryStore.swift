import AVFoundation
import Combine
import Foundation

protocol RecoveryAudioPlaying: AnyObject {
    func play() -> Bool
}

extension AVAudioPlayer: RecoveryAudioPlaying {}

enum RecoveryPlaybackError: LocalizedError, Equatable {
    case couldNotStart

    var errorDescription: String? { "The recovery audio could not start playing." }
}

@MainActor
final class JobLibraryStore: ObservableObject {
    @Published private(set) var recoveryJobs: [TranscriptionJob] = []
    @Published private(set) var importJobs: [TranscriptionJob] = []

    private let store: TranscriptionJobStore
    private let recoveryDirectory: URL
    private var enqueueRecovery: (@Sendable (UUID) async -> Void)?
    private var enqueueImport: (@Sendable (UUID) async -> Void)?
    private var cancelImport: (@Sendable (UUID) async -> LocalJobRunner.CancellationOutcome)?
    private var importService: MediaImportService?
    private var importsDirectory: URL?
    private let playbackFactory: (URL) throws -> any RecoveryAudioPlaying
    private var player: (any RecoveryAudioPlaying)?

    init(
        store: TranscriptionJobStore,
        recoveryDirectory: URL? = nil,
        playbackFactory: @escaping (URL) throws -> any RecoveryAudioPlaying = { try AVAudioPlayer(contentsOf: $0) }
    ) {
        self.store = store
        self.recoveryDirectory = recoveryDirectory ?? URL(fileURLWithPath: "/dev/null")
        self.playbackFactory = playbackFactory
    }

    func configureRetry(_ enqueue: @escaping @Sendable (UUID) async -> Void) {
        enqueueRecovery = enqueue
    }

    func configureImports(
        service: MediaImportService,
        directory: URL,
        enqueue: @escaping @Sendable (UUID) async -> Void,
        cancel: @escaping @Sendable (UUID) async -> LocalJobRunner.CancellationOutcome
    ) {
        importService = service
        importsDirectory = directory
        enqueueImport = enqueue
        cancelImport = cancel
    }

    func importMedia(_ url: URL) async throws {
        guard let importService else { throw MediaImportError.invalidMedia }
        let id = try await importService.createJob(for: url)
        try await refresh()
        await enqueueImport?(id)
    }

    func retryImport(id: UUID) async throws {
        try await store.queueMediaImportRetry(jobID: id)
        try await refresh()
        await enqueueImport?(id)
    }

    func cancelImport(id: UUID) async throws {
        guard let cancelImport else { throw JobStoreError.invalidTransition }
        let outcome = await cancelImport(id)
        if outcome == .notRunning, let job = try await store.job(id: id), job.state == .queued {
            try await store.transition(id, from: .queued, to: .cancelled)
        }
        try await refresh()
    }

    func deleteImport(id: UUID) async throws {
        guard let importsDirectory else { throw JobStoreError.invalidTransition }
        try await store.deleteMediaImport(jobID: id, jobsDirectory: importsDirectory)
        try await refresh()
    }

    func importDetail(id: UUID) async throws -> MediaImportDetail {
        guard let job = try await store.job(id: id), job.kind == .mediaImport else { throw JobStoreError.jobNotFound }
        let transcript = try await store.transcriptSegments(jobID: id)
        let turns = try await store.speakerTurns(jobID: id)
        return MediaImportDetail(
            job: job,
            transcript: transcript,
            turns: turns,
            names: try await store.speakerNames(jobID: id),
            completedStages: try await store.completedMediaStages(jobID: id)
        )
    }

    func renameSpeaker(jobID: UUID, speakerID: String, name: String) async throws {
        try await store.replaceSpeakerName(jobID: jobID, speakerID: speakerID, name: name)
        objectWillChange.send()
    }

    func refresh() async throws {
        async let recoveries = store.jobs(kind: .recovery)
        async let imports = store.jobs(kind: .mediaImport)
        recoveryJobs = try await recoveries
        importJobs = try await imports
    }

    func retry(id: UUID, configuration: AttemptConfiguration) async throws {
        _ = try await store.queueRecoveryRetry(jobID: id, configuration: configuration)
        await enqueueRecovery?(id)
        try await refresh()
    }

    func preserve(samples: [Float], metadata: RecoveryMetadata) async throws -> UUID {
        let id = try await RecoveryCaptureService(directory: recoveryDirectory, store: store)
            .preserve(samples: samples, metadata: metadata)
        try await refresh()
        return id
    }

    func delete(id: UUID) async throws {
        guard try await store.claimRecoveryForDeletion(id: id, claimedAt: Date()) else {
            throw JobStoreError.invalidTransition
        }
        _ = try await RecoveryRetentionService(directory: recoveryDirectory, store: store)
            .purgeExpired(now: Date(), retention: .never)
        try await refresh()
    }

    func play(id: UUID) throws {
        guard let job = recoveryJobs.first(where: { $0.id == id }) else {
            throw JobStoreError.jobNotFound
        }
        let nextPlayer = try playbackFactory(URL(fileURLWithPath: job.source.reference))
        guard nextPlayer.play() else { throw RecoveryPlaybackError.couldNotStart }
        player = nextPlayer
    }
}
