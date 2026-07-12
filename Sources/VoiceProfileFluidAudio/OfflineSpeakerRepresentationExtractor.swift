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
    private static let modelCoordinator = FluidAudioModelPreparationCoordinator<OfflineDiarizerModels>()

    /// FluidAudio 0.15.5's community-1 offline stack: `Embedding.mlmodelc`
    /// over `FBank.mlmodelc`, returning the 256-dimensional `embedding256`.
    public static let fingerprint = EmbeddingModelFingerprint(
        provider: "FluidAudio",
        modelID: "community-1/Embedding.mlmodelc:embedding256",
        modelRevision: "FluidAudio-0.15.5",
        preprocessingRevision: "community-1/FBank.mlmodelc:16kHz-v0.15.5",
        dimension: VoiceEmbedding.dimension
    )

    private let modelsDirectory: URL

    public init(modelsDirectory: URL) {
        self.modelsDirectory = modelsDirectory
    }

    public func process(
        _ url: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> OfflineVoiceRepresentationResult {
        let gate = ProgressGate(sink: progress)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let config = OfflineDiarizerConfig(exposeChunkEmbeddings: true)
            let manager = OfflineDiarizerManager(config: config)
            let models = try await Self.modelCoordinator.model(for: modelsDirectory) {
                try await OfflineDiarizerModels.load(from: modelsDirectory) { update in
                    gate.report(update.fractionCompleted * 0.5)
                }
            }
            try Task.checkCancellation()
            manager.initialize(models: models)
            let result = try await manager.process(url) { completed, total in
                guard total > 0 else { return }
                gate.report(0.5 + 0.5 * Double(completed) / Double(total))
            }
            if gate.isCancelled { throw CancellationError() }
            gate.report(1)
            return try Self.map(result)
        } onCancel: {
            gate.cancel()
        }
    }

    static func map(_ result: DiarizationResult) throws -> OfflineVoiceRepresentationResult {
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
