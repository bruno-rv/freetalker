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
