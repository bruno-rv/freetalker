import Combine
import Foundation

@MainActor
final class JobLibraryStore: ObservableObject {
    @Published private(set) var recoveryJobs: [TranscriptionJob] = []
    @Published private(set) var importJobs: [TranscriptionJob] = []

    private let store: TranscriptionJobStore

    init(store: TranscriptionJobStore) {
        self.store = store
    }

    func refresh() async throws {
        async let recoveries = store.jobs(kind: .recovery)
        async let imports = store.jobs(kind: .mediaImport)
        recoveryJobs = try await recoveries
        importJobs = try await imports
    }
}
