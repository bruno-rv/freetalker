import Combine
import Foundation
import WhisperKit

actor SpeechModelDownloadCoordinator {
    typealias Downloader = @Sendable (String, @escaping @Sendable (Double) -> Void) async throws -> URL

    enum Error: Swift.Error, Equatable {
        case busy(activeVariant: String)
    }

    static let shared = SpeechModelDownloadCoordinator()
    private(set) var activeVariant: String?
    private var activityObservers: [UUID: AsyncStream<String?>.Continuation] = [:]

    func activityStream() -> AsyncStream<String?> {
        let id = UUID()
        return AsyncStream { continuation in
            activityObservers[id] = continuation
            continuation.yield(activeVariant)
            continuation.onTermination = { _ in
                Task { await self.removeActivityObserver(id) }
            }
        }
    }

    private func removeActivityObserver(_ id: UUID) {
        activityObservers.removeValue(forKey: id)
    }

    private func publishActivity() {
        for observer in activityObservers.values { observer.yield(activeVariant) }
    }

    func download(
        variant: String,
        progress: @escaping @Sendable (Double) -> Void = { _ in },
        using downloader: Downloader
    ) async throws -> URL {
        guard let activeVariant else {
            self.activeVariant = variant
            publishActivity()
            defer {
                self.activeVariant = nil
                publishActivity()
            }
            return try await downloader(variant, progress)
        }
        throw Error.busy(activeVariant: activeVariant)
    }

    func download(
        variant: String,
        downloadBase: URL? = nil,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> URL {
        try await download(variant: variant, progress: progress) { variant, progress in
            try await WhisperKit.download(variant: variant, downloadBase: downloadBase) {
                progress($0.fractionCompleted)
            }
        }
    }
}

enum SpeechModelEngineEvent: Sendable, Equatable {
    case active
    case downloading(progress: Double)
    case busy(reloadTarget: String)
    case downloaded
    case failed(hint: String)
}

@MainActor
protocol SpeechModelEngineEventReceiving: AnyObject {
    func receiveEngineEvent(_ event: SpeechModelEngineEvent, for variant: String)
}

@MainActor
final class SpeechModelStore: ObservableObject, SpeechModelEngineEventReceiving {
    enum Phase: Sendable, Equatable {
        case notDownloaded
        case downloading(Double)
        case downloaded
        case failed(String)
        case busy(reloadTarget: String)
    }

    struct State: Sendable, Equatable {
        var phase: Phase = .notDownloaded
        var sizeBytes: Int64?
        var active = false
        var supported = true
    }

    struct Inspection: Sendable, Equatable {
        let downloaded: Bool
        let sizeBytes: Int64?
    }

    nonisolated static let requiredArtifacts = ["AudioEncoder.mlmodelc", "MelSpectrogram.mlmodelc", "TextDecoder.mlmodelc"]

    @Published private(set) var states: [String: State]
    @Published private(set) var activeDownloadVariant: String?
    @Published private(set) var supportedVariants: Set<String>
    var onAutomaticSelection: ((String) -> Void)?

    private let baseURL: URL
    private let coordinator: SpeechModelDownloadCoordinator
    private let settings: AppSettings
    private let manualDownloader: SpeechModelDownloadCoordinator.Downloader?
    private let deleteOperation: @Sendable (String, URL) async throws -> Void
    private let remoteSupportFetcher: @Sendable () async -> Set<String>
    private let remoteSupportTimeout: Duration
    private var remoteRefreshStarted = false
    private var coordinatorActivityTask: Task<Void, Never>?
    private var deletingVariants: Set<String> = []
    private var manualDownloadOperations: [String: UUID] = [:]

    init(
        baseURL: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0],
        coordinator: SpeechModelDownloadCoordinator = .shared,
        settings: AppSettings = .shared,
        fallbackSupport: Set<String>? = nil,
        remoteSupportTimeout: Duration = .seconds(5),
        remoteSupportFetcher: @escaping @Sendable () async -> Set<String> = {
            Set((await WhisperKit.recommendedRemoteModels()).supported)
        },
        manualDownloader: SpeechModelDownloadCoordinator.Downloader? = nil,
        deleteOperation: @escaping @Sendable (String, URL) async throws -> Void = {
            let variant = $0
            let baseURL = $1
            try await Task.detached {
                try SpeechModelStore.deleteVariantDirectory(variant, baseURL: baseURL)
            }.value
        }
    ) {
        self.baseURL = baseURL
        self.coordinator = coordinator
        self.settings = settings
        self.manualDownloader = manualDownloader
        self.deleteOperation = deleteOperation
        self.remoteSupportFetcher = remoteSupportFetcher
        self.remoteSupportTimeout = remoteSupportTimeout
        let rawFallback = fallbackSupport ?? Set(WhisperKit.recommendedModels().supported)
        let fallback = Set(rawFallback.compactMap { SpeechModelCatalog.entry(for: $0)?.id })
        supportedVariants = fallback
        states = Dictionary(uniqueKeysWithValues: SpeechModelCatalog.entries.map {
            ($0.id, State(active: $0.id == settings.whisperModel, supported: fallback.contains($0.id)))
        })
        applyAutomaticDefaultIfNeeded(markCorrectedActive: true, notifyLifecycle: false)
        Task { await connectCoordinatorActivity() }
    }

    nonisolated static func repositoryRoot(baseURL: URL) -> URL {
        baseURL.appendingPathComponent("huggingface/models/argmaxinc/whisperkit-coreml", isDirectory: true).standardizedFileURL
    }

    nonisolated static func variantDirectory(for variant: String, baseURL: URL) -> URL {
        repositoryRoot(baseURL: baseURL).appendingPathComponent(variant, isDirectory: true).standardizedFileURL
    }

    nonisolated static func isSafeVariantDirectory(_ target: URL, baseURL: URL) -> Bool {
        let root = repositoryRoot(baseURL: baseURL).resolvingSymlinksInPath().standardizedFileURL
        let resolved = target.resolvingSymlinksInPath().standardizedFileURL
        return resolved != root && resolved.path.hasPrefix(root.path + "/")
    }

    nonisolated static func inspectVariant(_ variant: String, baseURL: URL) -> Inspection {
        let directory = variantDirectory(for: variant, baseURL: baseURL)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return Inspection(downloaded: false, sizeBytes: nil)
        }
        let complete = requiredArtifacts.allSatisfy {
            var artifactIsDirectory: ObjCBool = false
            return FileManager.default.fileExists(
                atPath: directory.appendingPathComponent($0).path,
                isDirectory: &artifactIsDirectory
            ) && artifactIsDirectory.boolValue
        }
        guard complete else { return Inspection(downloaded: false, sizeBytes: nil) }
        return Inspection(downloaded: true, sizeBytes: recursiveSize(of: directory))
    }

    nonisolated static func recursiveSize(of directory: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: Array(keys)) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    nonisolated static func deleteVariantDirectory(_ variant: String, baseURL: URL) throws {
        let target = variantDirectory(for: variant, baseURL: baseURL)
        guard isSafeVariantDirectory(target, baseURL: baseURL) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        try FileManager.default.removeItem(at: target)
    }

    static func canDelete(phase: Phase, active: Bool) -> Bool {
        guard !active else { return false }
        if case .downloaded = phase { return true }
        return false
    }

    static func canStartManualDownload(phase: Phase, reserved: Bool) -> Bool {
        guard !reserved else { return false }
        switch phase {
        case .notDownloaded, .failed:
            return true
        case .downloading, .downloaded, .busy:
            return false
        }
    }

    static func merging(inspection: Inspection, into state: State) -> State {
        switch state.phase {
        case .failed, .downloading, .busy:
            return state
        case .notDownloaded, .downloaded:
            var result = state
            result.phase = inspection.downloaded ? .downloaded : .notDownloaded
            result.sizeBytes = inspection.sizeBytes
            return result
        }
    }

    static func shouldApplyAutomaticDefault(chosenByUser: Bool, current: String, supported: Set<String>) -> Bool {
        !chosenByUser && !supported.isEmpty && !supported.contains(current)
    }

    func refresh() async {
        let baseURL = self.baseURL
        let inspections = await Task.detached {
            Dictionary(uniqueKeysWithValues: SpeechModelCatalog.entries.map {
                ($0.id, Self.inspectVariant($0.id, baseURL: baseURL))
            })
        }.value
        for entry in SpeechModelCatalog.entries {
            guard let inspection = inspections[entry.id], let state = states[entry.id] else { continue }
            states[entry.id] = Self.merging(inspection: inspection, into: state)
        }
    }

    func connectCoordinatorActivity() async {
        guard coordinatorActivityTask == nil else { return }
        let stream = await coordinator.activityStream()
        coordinatorActivityTask = Task { @MainActor [weak self] in
            for await active in stream { self?.activeDownloadVariant = active }
        }
        await Task.yield()
    }

    func download(_ variant: String) async {
        guard let state = states[variant],
              Self.canStartManualDownload(
                phase: state.phase,
                reserved: deletingVariants.contains(variant) || manualDownloadOperations[variant] != nil
              ) else { return }
        let operationID = UUID()
        manualDownloadOperations[variant] = operationID
        states[variant]?.phase = .downloading(0)
        await connectCoordinatorActivity()
        do {
            let progress: @Sendable (Double) -> Void = { progress in
                Task { @MainActor [weak self] in
                    self?.receiveManualProgress(progress, for: variant, operationID: operationID)
                }
            }
            if let manualDownloader {
                _ = try await coordinator.download(variant: variant, progress: progress, using: manualDownloader)
            } else {
                _ = try await coordinator.download(variant: variant, downloadBase: baseURL, progress: progress)
            }
            manualDownloadOperations.removeValue(forKey: variant)
        } catch SpeechModelDownloadCoordinator.Error.busy(let active) {
            manualDownloadOperations.removeValue(forKey: variant)
            states[variant]?.phase = .failed("waiting for current download: \(active)")
        } catch {
            manualDownloadOperations.removeValue(forKey: variant)
            states[variant]?.phase = .failed(error.localizedDescription)
        }
        if case .failed = states[variant]?.phase {
            // Keep the visible failure while refresh updates any cached filesystem metadata.
        } else {
            states[variant]?.phase = .notDownloaded
        }
        await refresh()
    }

    private func receiveManualProgress(_ progress: Double, for variant: String, operationID: UUID) {
        guard manualDownloadOperations[variant] == operationID,
              case .downloading = states[variant]?.phase else { return }
        states[variant]?.phase = .downloading(progress)
    }

    func delete(_ variant: String) async throws {
        guard let state = states[variant], Self.canDelete(phase: state.phase, active: state.active) else { return }
        deletingVariants.insert(variant)
        states[variant]?.phase = .busy(reloadTarget: variant)
        let baseURL = self.baseURL
        do {
            try await deleteOperation(variant, baseURL)
            deletingVariants.remove(variant)
            states[variant]?.phase = .notDownloaded
            await refresh()
        } catch {
            deletingVariants.remove(variant)
            states[variant] = state
            await refresh()
            throw error
        }
    }

    func receiveEngineEvent(_ event: SpeechModelEngineEvent, for variant: String) {
        guard states[variant] != nil else { return }
        guard !deletingVariants.contains(variant) else { return }
        switch event {
        case .active:
            for id in states.keys { states[id]?.active = id == variant }
            states[variant]?.phase = .downloaded
        case .downloading(let progress):
            states[variant]?.phase = .downloading(progress)
        case .busy(let target): states[variant]?.phase = .busy(reloadTarget: target)
        case .downloaded:
            states[variant]?.phase = .downloaded
        case .failed(let hint):
            states[variant]?.phase = .failed(hint)
        }
    }

    func refreshRemoteSupportOnce() {
        guard !remoteRefreshStarted else { return }
        remoteRefreshStarted = true
        Task {
            let fetcher = remoteSupportFetcher
            let remote = await Self.firstResult(within: remoteSupportTimeout, operation: fetcher)
            guard let remote else { return }
            let catalogRemote = Set(remote.compactMap { SpeechModelCatalog.entry(for: $0)?.id })
            supportedVariants = catalogRemote
            for id in states.keys { states[id]?.supported = catalogRemote.contains(id) }
            applyAutomaticDefaultIfNeeded(markCorrectedActive: false, notifyLifecycle: true)
        }
    }

    nonisolated static func firstResult<Value: Sendable>(
        within timeout: Duration,
        operation: @escaping @Sendable () async -> Value
    ) async -> Value? {
        await withCheckedContinuation { continuation in
            let gate = FirstResultGate(continuation)
            Task { await gate.resume(operation()) }
            Task {
                try? await Task.sleep(for: timeout)
                await gate.resume(nil)
            }
        }
    }

    private func applyAutomaticDefaultIfNeeded(markCorrectedActive: Bool, notifyLifecycle: Bool) {
        guard Self.shouldApplyAutomaticDefault(
            chosenByUser: settings.whisperModelChosen,
            current: settings.whisperModel,
            supported: supportedVariants
        ) else { return }
        let target = SpeechModelCatalog.bestSupported(in: supportedVariants)
        settings.applyAutomaticWhisperModel(target)
        for id in states.keys { states[id]?.active = markCorrectedActive && id == target }
        if notifyLifecycle { onAutomaticSelection?(target) }
    }
}

private actor FirstResultGate<Value: Sendable> {
    private var continuation: CheckedContinuation<Value?, Never>?

    init(_ continuation: CheckedContinuation<Value?, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: Value?) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}
