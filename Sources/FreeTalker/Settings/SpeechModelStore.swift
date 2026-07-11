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

    func download(
        variant: String,
        progress: @escaping @Sendable (Double) -> Void = { _ in },
        using downloader: Downloader
    ) async throws -> URL {
        guard let activeVariant else {
            self.activeVariant = variant
            defer { self.activeVariant = nil }
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

    private let baseURL: URL
    private let coordinator: SpeechModelDownloadCoordinator
    private let settings: AppSettings
    private var remoteRefreshStarted = false

    init(
        baseURL: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0],
        coordinator: SpeechModelDownloadCoordinator = .shared,
        settings: AppSettings = .shared
    ) {
        self.baseURL = baseURL
        self.coordinator = coordinator
        self.settings = settings
        let fallback = Set(WhisperKit.recommendedModels().supported.compactMap { SpeechModelCatalog.entry(for: $0)?.id })
        supportedVariants = fallback
        states = Dictionary(uniqueKeysWithValues: SpeechModelCatalog.entries.map {
            ($0.id, State(active: $0.id == settings.whisperModel, supported: fallback.contains($0.id)))
        })
        applyAutomaticDefaultIfNeeded()
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
        guard target == variantDirectory(for: variant, baseURL: baseURL), isSafeVariantDirectory(target, baseURL: baseURL) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        try FileManager.default.removeItem(at: target)
    }

    static func canDelete(phase: Phase, active: Bool) -> Bool {
        guard !active else { return false }
        if case .downloaded = phase { return true }
        return false
    }

    func refresh() async {
        let baseURL = self.baseURL
        let inspections = await Task.detached {
            Dictionary(uniqueKeysWithValues: SpeechModelCatalog.entries.map {
                ($0.id, Self.inspectVariant($0.id, baseURL: baseURL))
            })
        }.value
        for entry in SpeechModelCatalog.entries {
            guard let inspection = inspections[entry.id], var state = states[entry.id] else { continue }
            if case .downloading = state.phase { continue }
            if case .busy = state.phase { continue }
            state.phase = inspection.downloaded ? .downloaded : .notDownloaded
            state.sizeBytes = inspection.sizeBytes
            states[entry.id] = state
        }
    }

    func download(_ variant: String) async {
        guard states[variant] != nil else { return }
        activeDownloadVariant = variant
        states[variant]?.phase = .downloading(0)
        do {
            _ = try await coordinator.download(variant: variant, downloadBase: baseURL) { progress in
                Task { @MainActor [weak self] in self?.states[variant]?.phase = .downloading(progress) }
            }
        } catch SpeechModelDownloadCoordinator.Error.busy(let active) {
            states[variant]?.phase = .failed("waiting for current download: \(active)")
        } catch {
            states[variant]?.phase = .failed(error.localizedDescription)
        }
        activeDownloadVariant = nil
        await refresh()
    }

    func delete(_ variant: String) async throws {
        guard let state = states[variant], Self.canDelete(phase: state.phase, active: state.active) else { return }
        let baseURL = self.baseURL
        try await Task.detached { try Self.deleteVariantDirectory(variant, baseURL: baseURL) }.value
        await refresh()
    }

    func receiveEngineEvent(_ event: SpeechModelEngineEvent, for variant: String) {
        guard states[variant] != nil else { return }
        switch event {
        case .downloading(let progress):
            activeDownloadVariant = variant
            states[variant]?.phase = .downloading(progress)
        case .busy(let target): states[variant]?.phase = .busy(reloadTarget: target)
        case .downloaded:
            if activeDownloadVariant == variant { activeDownloadVariant = nil }
            states[variant]?.phase = .downloaded
        case .failed(let hint):
            if activeDownloadVariant == variant { activeDownloadVariant = nil }
            states[variant]?.phase = .failed(hint)
        }
    }

    func refreshRemoteSupportOnce() {
        guard !remoteRefreshStarted else { return }
        remoteRefreshStarted = true
        Task {
            let remote = await withTaskGroup(of: Set<String>?.self) { group in
                group.addTask {
                    let support = await WhisperKit.recommendedRemoteModels()
                    return Set(support.supported.compactMap { SpeechModelCatalog.entry(for: $0)?.id })
                }
                group.addTask {
                    try? await Task.sleep(for: .seconds(5))
                    return nil
                }
                let result = await group.next() ?? nil
                group.cancelAll()
                return result
            }
            guard let remote else { return }
            supportedVariants = remote
            for id in states.keys { states[id]?.supported = remote.contains(id) }
            applyAutomaticDefaultIfNeeded()
        }
    }

    private func applyAutomaticDefaultIfNeeded() {
        guard !supportedVariants.isEmpty,
              !settings.whisperModelChosen,
              !supportedVariants.contains(settings.whisperModel) else { return }
        settings.applyAutomaticWhisperModel(SpeechModelCatalog.bestSupported(in: supportedVariants))
        for id in states.keys { states[id]?.active = id == settings.whisperModel }
    }
}
