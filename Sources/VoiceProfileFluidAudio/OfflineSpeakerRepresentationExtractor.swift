import CryptoKit
import FluidAudio
import Foundation
import os
import VoiceProfileCore

public struct OfflineSpeakerTurn: Sendable, Equatable {
    public let speakerID: String
    public let start: TimeInterval
    public let end: TimeInterval

    public init(speakerID: String, start: TimeInterval, end: TimeInterval) {
        self.speakerID = speakerID
        self.start = start
        self.end = end
    }
}

public struct OfflineVoiceRepresentationResult: Sendable, Equatable {
    public let turns: [OfflineSpeakerTurn]
    public let speakers: [SpeakerRepresentation]
    public let fingerprint: EmbeddingModelFingerprint

    public init(
        turns: [OfflineSpeakerTurn],
        speakers: [SpeakerRepresentation],
        fingerprint: EmbeddingModelFingerprint
    ) {
        self.turns = turns
        self.speakers = speakers
        self.fingerprint = fingerprint
    }
}

public enum OfflineSpeakerRepresentationError: Error, Equatable, Sendable {
    case invalidTurn(index: Int)
    case missingModelArtifact(ModelArtifact)
    case invalidModelArtifact(ModelArtifact)
    case unreadableModelArtifact(ModelArtifact)

    public enum ModelArtifact: String, Equatable, Sendable {
        case embedding
        case fbank
    }
}

public actor FluidAudioModelPreparationCoordinator<Model: Sendable> {
    private struct InFlight: Sendable {
        let id: UUID
        let task: Task<Model, Error>
    }

    private var prepared: [URL: Model] = [:]
    private var inFlight: [URL: InFlight] = [:]

    public init() {}

    public func model(
        for directory: URL,
        loader: @escaping @Sendable () async throws -> Model
    ) async throws -> Model {
        let key = directory.standardizedFileURL
        if let model = prepared[key] { return model }
        if let pending = inFlight[key] { return try await pending.task.value }

        let id = UUID()
        let task = Task { try await loader() }
        inFlight[key] = InFlight(id: id, task: task)
        do {
            let model = try await task.value
            if inFlight[key]?.id == id {
                inFlight.removeValue(forKey: key)
                prepared[key] = model
            }
            return model
        } catch {
            if inFlight[key]?.id == id { inFlight.removeValue(forKey: key) }
            throw error
        }
    }
}

private final class ProgressGate: @unchecked Sendable {
    private struct State {
        var cancelled = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let sink: @Sendable (Double) -> Void

    init(sink: @escaping @Sendable (Double) -> Void) {
        self.sink = sink
    }

    func report(_ value: Double) {
        state.withLock { current in
            guard !current.cancelled else { return }
            sink(value)
        }
    }

    func cancel() { state.withLock { $0.cancelled = true } }
    var isCancelled: Bool { state.withLock { $0.cancelled } }
}

public struct OfflineSpeakerRepresentationExtractor: Sendable {
    private struct PreparedModels: Sendable {
        let models: OfflineDiarizerModels
        let fingerprint: EmbeddingModelFingerprint
    }

    typealias Operation = @Sendable (
        URL, @escaping @Sendable (Double) -> Void
    ) async throws -> (DiarizationResult, EmbeddingModelFingerprint)

    private static let modelCoordinator = FluidAudioModelPreparationCoordinator<PreparedModels>()
    private let operation: Operation

    public init(modelsDirectory: URL) {
        operation = { url, progress in
            let config = Self.diarizerConfig
            let prepared = try await Self.modelCoordinator.model(for: modelsDirectory) {
                let models = try await OfflineDiarizerModels.load(from: modelsDirectory) { update in
                    progress(update.fractionCompleted * 0.5)
                }
                return PreparedModels(
                    models: models,
                    fingerprint: try Self.fingerprint(modelsDirectory: modelsDirectory, config: config)
                )
            }
            try Task.checkCancellation()
            let manager = OfflineDiarizerManager(config: config)
            manager.initialize(models: prepared.models)
            let result = try await manager.process(url) { completed, total in
                guard total > 0 else { return }
                progress(0.5 + 0.5 * Double(completed) / Double(total))
            }
            return (result, prepared.fingerprint)
        }
    }

    init(operation: @escaping Operation) {
        self.operation = operation
    }

    public func process(
        _ url: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> OfflineVoiceRepresentationResult {
        let gate = ProgressGate(sink: progress)
        return try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                let (result, fingerprint) = try await operation(url) { gate.report($0) }
                if gate.isCancelled { throw CancellationError() }
                gate.report(1)
                return try Self.map(result, fingerprint: fingerprint)
            } catch {
                if gate.isCancelled { throw CancellationError() }
                throw error
            }
        } onCancel: {
            gate.cancel()
        }
    }

    static func map(
        _ result: DiarizationResult,
        fingerprint: EmbeddingModelFingerprint
    ) throws -> OfflineVoiceRepresentationResult {
        let turns = try result.segments.enumerated().map { index, segment in
            let start = TimeInterval(segment.startTimeSeconds)
            let end = TimeInterval(segment.endTimeSeconds)
            guard !segment.speakerId.isEmpty, start.isFinite, end.isFinite,
                  start >= 0, end > start else {
                throw OfflineSpeakerRepresentationError.invalidTurn(index: index)
            }
            return OfflineSpeakerTurn(speakerID: segment.speakerId, start: start, end: end)
        }

        let validSamples = (result.chunkEmbeddings ?? []).compactMap { chunk -> (String, SpeakerEmbeddingSample)? in
            let start = TimeInterval(chunk.startTimeSeconds)
            let end = TimeInterval(chunk.endTimeSeconds)
            guard !chunk.speakerId.isEmpty, start.isFinite, end.isFinite,
                  start >= 0, end > start,
                  let embedding = try? VoiceEmbedding(validating: chunk.embedding256) else {
                return nil
            }
            return (
                chunk.speakerId,
                SpeakerEmbeddingSample(embedding: embedding, start: start, end: end, quality: nil)
            )
        }

        let grouped = Dictionary(grouping: validSamples, by: \.0)
        let speakers = grouped.keys.sorted().map { speakerID in
            let samples = grouped[speakerID, default: []]
                .map(\.1)
                .sorted {
                    if ($0.start, $0.end) != ($1.start, $1.end) {
                        return ($0.start, $0.end) < ($1.start, $1.end)
                    }
                    return $0.embedding.values.lexicographicallyPrecedes($1.embedding.values)
                }
            return SpeakerRepresentation(
                speakerID: speakerID,
                samples: samples,
                cleanSpeechSeconds: unionDuration(samples.map { ($0.start, $0.end) })
            )
        }
        return OfflineVoiceRepresentationResult(turns: turns, speakers: speakers, fingerprint: fingerprint)
    }

    static func fingerprint(modelsDirectory: URL) throws -> EmbeddingModelFingerprint {
        try fingerprint(modelsDirectory: modelsDirectory, config: diarizerConfig)
    }

    private static let diarizerConfig = OfflineDiarizerConfig(exposeChunkEmbeddings: true)

    private static func fingerprint(
        modelsDirectory: URL,
        config: OfflineDiarizerConfig
    ) throws -> EmbeddingModelFingerprint {
        let repo = modelsDirectory.appendingPathComponent(Repo.diarizer.folderName, isDirectory: true)
        let embeddingDigest = try artifactDigest(
            repo.appendingPathComponent(ModelNames.OfflineDiarizer.embeddingPath, isDirectory: true),
            artifact: .embedding
        )
        let fbankDigest = try artifactDigest(
            repo.appendingPathComponent(ModelNames.OfflineDiarizer.fbankPath, isDirectory: true),
            artifact: .fbank
        )
        let skipStrategy: String
        switch config.embedding.skipStrategy {
        case .none: skipStrategy = "none"
        case .maskSimilarity(let threshold): skipStrategy = "maskSimilarity(\(threshold))"
        }
        let preprocessing = [
            "sampleRate=\(config.segmentation.sampleRate)",
            "embeddingBatchSize=\(config.embedding.batchSize)",
            "excludeOverlap=\(config.embedding.excludeOverlap)",
            "minSegmentDuration=\(config.embedding.minSegmentDurationSeconds)",
            "skipStrategy=\(skipStrategy)",
            "exposeChunkEmbeddings=\(config.exposeChunkEmbeddings)"
        ].joined(separator: ";")
        return EmbeddingModelFingerprint(
            provider: "FluidAudio",
            modelID: "\(Repo.diarizer.folderName)/\(ModelNames.OfflineDiarizer.embeddingPath):embedding256",
            modelRevision: "tree-sha256-v1;Embedding.mlmodelc=\(embeddingDigest);FBank.mlmodelc=\(fbankDigest)",
            preprocessingRevision: preprocessing,
            dimension: VoiceEmbedding.dimension
        )
    }
}

private func artifactDigest(
    _ root: URL,
    artifact: OfflineSpeakerRepresentationError.ModelArtifact
) throws -> String {
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: root.path) else {
        throw OfflineSpeakerRepresentationError.missingModelArtifact(artifact)
    }
    do {
        let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw OfflineSpeakerRepresentationError.invalidModelArtifact(artifact)
        }
        var files: [(path: Data, url: URL)] = []
        func collect(_ directory: URL, prefix: String) throws {
            let children = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
            )
            for url in children {
                let values = try url.resourceValues(
                    forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
                )
                guard values.isSymbolicLink != true else {
                    throw OfflineSpeakerRepresentationError.invalidModelArtifact(artifact)
                }
                let relative = prefix.isEmpty ? url.lastPathComponent : "\(prefix)/\(url.lastPathComponent)"
                if values.isDirectory == true {
                    try collect(url, prefix: relative)
                    continue
                }
                guard values.isRegularFile == true, !relative.isEmpty else {
                    throw OfflineSpeakerRepresentationError.invalidModelArtifact(artifact)
                }
                files.append((Data(relative.utf8), url))
            }
        }
        try collect(root, prefix: "")
        guard !files.isEmpty else {
            throw OfflineSpeakerRepresentationError.invalidModelArtifact(artifact)
        }
        files.sort { $0.path.lexicographicallyPrecedes($1.path) }
        var hasher = SHA256()
        hasher.update(data: Data("artifact-tree-sha256-v1\0".utf8))
        for file in files {
            let contents = try Data(contentsOf: file.url, options: [.mappedIfSafe])
            hasher.update(data: encodedLength(file.path.count))
            hasher.update(data: file.path)
            hasher.update(data: encodedLength(contents.count))
            hasher.update(data: contents)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    } catch let error as OfflineSpeakerRepresentationError {
        throw error
    } catch {
        throw OfflineSpeakerRepresentationError.unreadableModelArtifact(artifact)
    }
}

private func encodedLength(_ value: Int) -> Data {
    var length = UInt64(value).bigEndian
    return withUnsafeBytes(of: &length) { Data($0) }
}

private func unionDuration(_ intervals: [(TimeInterval, TimeInterval)]) -> TimeInterval {
    let sorted = intervals.sorted { ($0.0, $0.1) < ($1.0, $1.1) }
    guard var current = sorted.first else { return 0 }
    var duration = 0.0
    for interval in sorted.dropFirst() {
        if interval.0 <= current.1 {
            current.1 = max(current.1, interval.1)
        } else {
            duration += current.1 - current.0
            current = interval
        }
    }
    return duration + current.1 - current.0
}
