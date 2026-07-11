import AVFoundation
import Combine
import Foundation

@MainActor
final class JobLibraryStore: ObservableObject {
    @Published private(set) var recoveryJobs: [TranscriptionJob] = []
    @Published private(set) var importJobs: [TranscriptionJob] = []

    private let store: TranscriptionJobStore
    private let recoveryDirectory: URL
    private var enqueueRecovery: (@Sendable (UUID) async -> Void)?
    private var player: AVAudioPlayer?

    init(store: TranscriptionJobStore, recoveryDirectory: URL? = nil) {
        self.store = store
        self.recoveryDirectory = recoveryDirectory ?? URL(fileURLWithPath: "/dev/null")
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
        guard let job = try await store.job(id: id), case .failed = job.state else {
            throw JobStoreError.invalidTransition
        }
        _ = try await store.beginAttempt(jobID: id, configuration: configuration)
        try await store.transition(id, from: .failed, to: .queued)
        await enqueueRecovery?(id)
        try await refresh()
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
        player = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: job.source.reference))
        player?.play()
    }
}
