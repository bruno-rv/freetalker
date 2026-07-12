import CryptoKit
import Darwin
import FluidAudio
import Foundation
import os
import VoiceProfileCore

@_silgen_name("openat")
private func systemOpenAt(
    _ directory: Int32,
    _ path: UnsafePointer<CChar>,
    _ flags: Int32,
    _ mode: mode_t
) -> Int32

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
    case modelArtifactChangedDuringLoad

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
            let config = Self.config
            let prepared = try await Self.modelCoordinator.model(for: modelsDirectory) {
                if !Self.artifactsExist(modelsDirectory: modelsDirectory) {
                    _ = try await OfflineDiarizerModels.load(from: modelsDirectory) { update in
                        progress(update.fractionCompleted * 0.25)
                    }
                }
                let (models, fingerprint) = try await Self.verifyArtifactsAroundLoad(
                    modelsDirectory: modelsDirectory
                ) {
                    try await OfflineDiarizerModels.load(from: modelsDirectory) { update in
                        progress(0.25 + update.fractionCompleted * 0.25)
                    }
                }
                return PreparedModels(
                    models: models,
                    fingerprint: fingerprint
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
        try fingerprint(modelsDirectory: modelsDirectory, config: config)
    }

    static let config = OfflineDiarizerConfig(
        segmentation: .init(
            windowDurationSeconds: 10.0, sampleRate: 16_000,
            minDurationOn: 0.0, minDurationOff: 0.0, stepRatio: 0.2,
            speechOnsetThreshold: 0.5, speechOffsetThreshold: 0.5
        ),
        embedding: .init(
            batchSize: 32, excludeOverlap: true,
            minSegmentDurationSeconds: 1.0, skipStrategy: .none
        ),
        clustering: .init(
            threshold: 0.6, warmStartFa: 0.07, warmStartFb: 0.8,
            minSpeakers: nil, maxSpeakers: nil, numSpeakers: nil
        ),
        vbx: .init(maxIterations: 20, convergenceTolerance: 1e-4),
        postProcessing: .init(minGapDurationSeconds: 0.1, exclusiveSegments: true),
        zeroVoteReembed: .init(enabled: false, minDurationSeconds: 0.4),
        export: .init(embeddingsPath: nil),
        exposeChunkEmbeddings: true
    )

    static func verifyArtifactsAroundLoad<Value: Sendable>(
        modelsDirectory: URL,
        load: () async throws -> Value
    ) async throws -> (Value, EmbeddingModelFingerprint) {
        let before = try fingerprint(modelsDirectory: modelsDirectory)
        let value = try await load()
        let after = try fingerprint(modelsDirectory: modelsDirectory)
        guard before == after else {
            throw OfflineSpeakerRepresentationError.modelArtifactChangedDuringLoad
        }
        return (value, after)
    }

    private static func artifactsExist(modelsDirectory: URL) -> Bool {
        let repo = modelsDirectory.appendingPathComponent(Repo.diarizer.folderName, isDirectory: true)
        return FileManager.default.fileExists(
            atPath: repo.appendingPathComponent(ModelNames.OfflineDiarizer.embeddingPath).path
        ) && FileManager.default.fileExists(
            atPath: repo.appendingPathComponent(ModelNames.OfflineDiarizer.fbankPath).path
        )
    }

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
        let preprocessing = preprocessingRevision(config: config)
        return EmbeddingModelFingerprint(
            provider: "FluidAudio",
            modelID: "\(Repo.diarizer.folderName)/\(ModelNames.OfflineDiarizer.embeddingPath):embedding256",
            modelRevision: "tree-sha256-v1;Embedding.mlmodelc=\(embeddingDigest);FBank.mlmodelc=\(fbankDigest)",
            preprocessingRevision: preprocessing,
            dimension: VoiceEmbedding.dimension
        )
    }

    static func preprocessingRevision(config: OfflineDiarizerConfig) -> String {
        let skipStrategy: String
        switch config.embedding.skipStrategy {
        case .none: skipStrategy = "none"
        case .maskSimilarity(let threshold): skipStrategy = "maskSimilarity(\(threshold))"
        }
        func optional(_ value: Int?) -> String { value.map(String.init) ?? "nil" }
        return [
            "contract=v1",
            "fluidAudioVersion=0.15.5",
            "fluidAudioRevision=19600a485baa4998812e4654b70d2bab8f2c9949",
            "segmentation.windowDurationSeconds=\(config.segmentation.windowDurationSeconds)",
            "segmentation.sampleRate=\(config.segmentation.sampleRate)",
            "segmentation.minDurationOn=\(config.segmentation.minDurationOn)",
            "segmentation.minDurationOff=\(config.segmentation.minDurationOff)",
            "segmentation.stepRatio=\(config.segmentation.stepRatio)",
            "segmentation.speechOnsetThreshold=\(config.segmentation.speechOnsetThreshold)",
            "segmentation.speechOffsetThreshold=\(config.segmentation.speechOffsetThreshold)",
            "embedding.batchSize=\(config.embedding.batchSize)",
            "embedding.excludeOverlap=\(config.embedding.excludeOverlap)",
            "embedding.minSegmentDurationSeconds=\(config.embedding.minSegmentDurationSeconds)",
            "embedding.skipStrategy=\(skipStrategy)",
            "clustering.threshold=\(config.clustering.threshold)",
            "clustering.warmStartFa=\(config.clustering.warmStartFa)",
            "clustering.warmStartFb=\(config.clustering.warmStartFb)",
            "clustering.minSpeakers=\(optional(config.clustering.minSpeakers))",
            "clustering.maxSpeakers=\(optional(config.clustering.maxSpeakers))",
            "clustering.numSpeakers=\(optional(config.clustering.numSpeakers))",
            "vbx.maxIterations=\(config.vbx.maxIterations)",
            "vbx.convergenceTolerance=\(config.vbx.convergenceTolerance)",
            "postProcessing.minGapDurationSeconds=\(config.postProcessing.minGapDurationSeconds)",
            "postProcessing.exclusiveSegments=\(config.postProcessing.exclusiveSegments)",
            "zeroVoteReembed.enabled=\(config.zeroVoteReembed.enabled)",
            "zeroVoteReembed.minDurationSeconds=\(config.zeroVoteReembed.minDurationSeconds)",
            "exposeChunkEmbeddings=\(config.exposeChunkEmbeddings)"
        ].joined(separator: ";")
    }
}

private func artifactDigest(
    _ root: URL,
    artifact: OfflineSpeakerRepresentationError.ModelArtifact
) throws -> String {
    let descriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else {
        if errno == ENOENT { throw OfflineSpeakerRepresentationError.missingModelArtifact(artifact) }
        if errno == ELOOP { throw OfflineSpeakerRepresentationError.invalidModelArtifact(artifact) }
        throw OfflineSpeakerRepresentationError.unreadableModelArtifact(artifact)
    }
    defer { close(descriptor) }
    do {
        var hasher = SHA256()
        hasher.update(data: Data("artifact-tree-sha256-v1\0".utf8))
        var fileCount = 0
        try hashDirectory(descriptor, prefix: [], hasher: &hasher, fileCount: &fileCount, artifact: artifact)
        guard fileCount > 0 else { throw OfflineSpeakerRepresentationError.invalidModelArtifact(artifact) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    } catch let error as OfflineSpeakerRepresentationError { throw error }
    catch { throw OfflineSpeakerRepresentationError.unreadableModelArtifact(artifact) }
}

private func hashDirectory(
    _ descriptor: Int32,
    prefix: [UInt8],
    hasher: inout SHA256,
    fileCount: inout Int,
    artifact: OfflineSpeakerRepresentationError.ModelArtifact
) throws {
    let duplicate = dup(descriptor)
    guard duplicate >= 0, let directory = fdopendir(duplicate) else {
        if duplicate >= 0 { close(duplicate) }
        throw OfflineSpeakerRepresentationError.unreadableModelArtifact(artifact)
    }
    var names: [[UInt8]] = []
    errno = 0
    while let entry = readdir(directory) {
        let name = withUnsafeBytes(of: entry.pointee.d_name) { bytes in
            Array(bytes.prefix { $0 != 0 })
        }
        if name != [46] && name != [46, 46] { names.append(name) }
    }
    let readError = errno
    closedir(directory)
    guard readError == 0 else { throw OfflineSpeakerRepresentationError.unreadableModelArtifact(artifact) }
    names.sort { $0.lexicographicallyPrecedes($1) }

    for name in names {
        var cName = name.map { CChar(bitPattern: $0) }; cName.append(0)
        var metadata = stat()
        let status = cName.withUnsafeBufferPointer {
            fstatat(descriptor, $0.baseAddress, &metadata, AT_SYMLINK_NOFOLLOW)
        }
        guard status == 0 else { throw OfflineSpeakerRepresentationError.unreadableModelArtifact(artifact) }
        let mode = metadata.st_mode & S_IFMT
        let relative = prefix.isEmpty ? name : prefix + [47] + name
        if mode == S_IFDIR {
            let child = cName.withUnsafeBufferPointer {
                systemOpenAt(
                    descriptor, $0.baseAddress!,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC, 0
                )
            }
            guard child >= 0 else { throw OfflineSpeakerRepresentationError.invalidModelArtifact(artifact) }
            do {
                try hashDirectory(
                    child, prefix: relative, hasher: &hasher,
                    fileCount: &fileCount, artifact: artifact
                )
                close(child)
            } catch {
                close(child)
                throw error
            }
        } else if mode == S_IFREG {
            let file = cName.withUnsafeBufferPointer {
                systemOpenAt(descriptor, $0.baseAddress!, O_RDONLY | O_NOFOLLOW | O_CLOEXEC, 0)
            }
            guard file >= 0 else { throw OfflineSpeakerRepresentationError.invalidModelArtifact(artifact) }
            do {
                try hashFile(file, path: relative, initial: metadata, hasher: &hasher, artifact: artifact)
                close(file)
                fileCount += 1
            } catch {
                close(file)
                throw error
            }
        } else {
            throw OfflineSpeakerRepresentationError.invalidModelArtifact(artifact)
        }
    }
}

private func hashFile(
    _ descriptor: Int32,
    path: [UInt8],
    initial: stat,
    hasher: inout SHA256,
    artifact: OfflineSpeakerRepresentationError.ModelArtifact
) throws {
    var opened = stat()
    guard fstat(descriptor, &opened) == 0, (opened.st_mode & S_IFMT) == S_IFREG,
          opened.st_dev == initial.st_dev, opened.st_ino == initial.st_ino else {
        throw OfflineSpeakerRepresentationError.invalidModelArtifact(artifact)
    }
    hasher.update(data: encodedLength(path.count)); hasher.update(data: Data(path))
    hasher.update(data: encodedLength(Int(opened.st_size)))
    var remaining = opened.st_size
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while remaining > 0 {
        let requested = min(buffer.count, Int(remaining))
        let count = buffer.withUnsafeMutableBytes {
            read(descriptor, $0.baseAddress, requested)
        }
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { throw OfflineSpeakerRepresentationError.modelArtifactChangedDuringLoad }
        hasher.update(data: Data(buffer[0..<count])); remaining -= off_t(count)
    }
    var extra: UInt8 = 0
    let extraCount = read(descriptor, &extra, 1)
    guard extraCount == 0 else { throw OfflineSpeakerRepresentationError.modelArtifactChangedDuringLoad }
    var final = stat()
    guard fstat(descriptor, &final) == 0,
          final.st_dev == opened.st_dev, final.st_ino == opened.st_ino,
          final.st_size == opened.st_size,
          final.st_mtimespec.tv_sec == opened.st_mtimespec.tv_sec,
          final.st_mtimespec.tv_nsec == opened.st_mtimespec.tv_nsec,
          final.st_ctimespec.tv_sec == opened.st_ctimespec.tv_sec,
          final.st_ctimespec.tv_nsec == opened.st_ctimespec.tv_nsec else {
        throw OfflineSpeakerRepresentationError.modelArtifactChangedDuringLoad
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
