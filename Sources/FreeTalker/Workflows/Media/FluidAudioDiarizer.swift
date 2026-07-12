import Foundation
import os
import VoiceProfileCore
import VoiceProfileFluidAudio

protocol SpeakerDiarizing: Sendable {
    func diarizeFile(at url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> SpeakerDiarizationResult
}

struct RawSpeakerTurn: Sendable, Equatable {
    let speakerID: String
    let start: TimeInterval
    let end: TimeInterval
}

struct RawSpeakerEmbeddingSample: Sendable, Equatable {
    let values: [Float]
    let start: TimeInterval
    let end: TimeInterval
    let quality: Double?
}

struct RawSpeakerRepresentation: Sendable, Equatable {
    let speakerID: String
    let samples: [RawSpeakerEmbeddingSample]
}

struct RawSpeakerDiarizationResult: Sendable, Equatable {
    let turns: [RawSpeakerTurn]
    let speakers: [RawSpeakerRepresentation]
    let fingerprint: EmbeddingModelFingerprint
}

struct SpeakerDiarizationResult: Sendable, Equatable {
    let turns: [SpeakerTurn]
    let speakers: [SpeakerRepresentation]
    let fingerprint: EmbeddingModelFingerprint
}

protocol SpeakerDiarizationBackend: Sendable {
    func diarizeFile(at url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> RawSpeakerDiarizationResult
}

private final class MonotonicProgress: @unchecked Sendable {
    private struct State {
        var value = 0.0
        var cancelled = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let sink: @Sendable (Double) -> Void

    init(sink: @escaping @Sendable (Double) -> Void) {
        self.sink = sink
    }

    func report(_ candidate: Double) {
        state.withLock { current in
            guard !current.cancelled else { return }
            let normalized = min(1, max(0, candidate.isFinite ? candidate : current.value))
            current.value = max(current.value, normalized)
            sink(current.value)
        }
    }

    func cancel() { state.withLock { $0.cancelled = true } }
    var isCancelled: Bool { state.withLock { $0.cancelled } }
}

struct FluidAudioDiarizer<Backend: SpeakerDiarizationBackend>: SpeakerDiarizing {
    private let backend: Backend

    init(backend: Backend) {
        self.backend = backend
    }

    func diarizeFile(at url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> SpeakerDiarizationResult {
        let monotonic = MonotonicProgress(sink: progress)
        monotonic.report(0)
        try Task.checkCancellation()
        let raw: RawSpeakerDiarizationResult
        do {
            raw = try await withTaskCancellationHandler {
                try await backend.diarizeFile(at: url) { monotonic.report($0) }
            } onCancel: {
                monotonic.cancel()
            }
        } catch {
            if monotonic.isCancelled { throw CancellationError() }
            throw error
        }
        if monotonic.isCancelled { throw CancellationError() }
        let turns = try raw.turns.enumerated().map { index, turn in
            guard !turn.speakerID.isEmpty, turn.start.isFinite, turn.end.isFinite,
                  turn.start >= 0, turn.end > turn.start else {
                throw MediaAdapterError.invalidSpeakerTurn(index: index)
            }
            return SpeakerTurn(speakerID: turn.speakerID, start: turn.start, end: turn.end)
        }
        let groupedRepresentations = Dictionary(
            grouping: raw.speakers.filter { !$0.speakerID.isEmpty },
            by: \.speakerID
        )
        let speakers = groupedRepresentations.keys.sorted()
            .compactMap { speakerID -> SpeakerRepresentation? in
                let samples = groupedRepresentations[speakerID, default: []]
                    .flatMap(\.samples)
                    .compactMap { sample -> SpeakerEmbeddingSample? in
                    guard sample.start.isFinite, sample.end.isFinite,
                          sample.start >= 0, sample.end > sample.start,
                          sample.quality.map({ $0.isFinite }) ?? true,
                          let embedding = try? VoiceEmbedding(validating: sample.values) else {
                        return nil
                    }
                    return SpeakerEmbeddingSample(
                        embedding: embedding,
                        start: sample.start,
                        end: sample.end,
                        quality: sample.quality
                    )
                }.sorted {
                    if ($0.start, $0.end) != ($1.start, $1.end) {
                        return ($0.start, $0.end) < ($1.start, $1.end)
                    }
                    if $0.embedding.values != $1.embedding.values {
                        return $0.embedding.values.lexicographicallyPrecedes($1.embedding.values)
                    }
                    switch ($0.quality, $1.quality) {
                    case (nil, .some): return true
                    case (.some, nil): return false
                    case (.some(let lhs), .some(let rhs)): return lhs < rhs
                    case (nil, nil): return false
                    }
                }
                guard !samples.isEmpty else { return nil }
                return SpeakerRepresentation(
                    speakerID: speakerID,
                    samples: samples,
                    cleanSpeechSeconds: cleanSpeechDuration(samples)
                )
            }
        return SpeakerDiarizationResult(turns: turns, speakers: speakers, fingerprint: raw.fingerprint)
    }
}

extension FluidAudioDiarizer where Backend == FluidAudioBackend {
    init() {
        self.init(backend: FluidAudioBackend())
    }
}

struct FluidAudioBackend: SpeakerDiarizationBackend {
    private let modelsDirectory: URL

    init(modelsDirectory: URL = Self.defaultModelsDirectory) {
        self.modelsDirectory = modelsDirectory
    }

    func diarizeFile(at url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> RawSpeakerDiarizationResult {
        let result = try await OfflineSpeakerRepresentationExtractor(modelsDirectory: modelsDirectory)
            .process(url, progress: progress)
        return RawSpeakerDiarizationResult(
            turns: result.turns.map {
                RawSpeakerTurn(speakerID: $0.speakerID, start: $0.start, end: $0.end)
            },
            speakers: result.speakers.map { representation in
                RawSpeakerRepresentation(
                    speakerID: representation.speakerID,
                    samples: representation.samples.map { sample in
                        RawSpeakerEmbeddingSample(
                            values: sample.embedding.values,
                            start: sample.start,
                            end: sample.end,
                            quality: sample.quality
                        )
                    }
                )
            },
            fingerprint: result.fingerprint
        )
    }

    private static let defaultModelsDirectory = FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
    )[0]
        .appendingPathComponent("FreeTalker", isDirectory: true)
        .appendingPathComponent("models/fluidaudio", isDirectory: true)
}

typealias LocalFluidAudioDiarizer = FluidAudioDiarizer<FluidAudioBackend>

private func cleanSpeechDuration(_ samples: [SpeakerEmbeddingSample]) -> TimeInterval {
    let intervals = samples.map { ($0.start, $0.end) }.sorted { ($0.0, $0.1) < ($1.0, $1.1) }
    guard var current = intervals.first else { return 0 }
    var duration = 0.0
    for interval in intervals.dropFirst() {
        if interval.0 <= current.1 {
            current.1 = max(current.1, interval.1)
        } else {
            duration += current.1 - current.0
            current = interval
        }
    }
    return duration + current.1 - current.0
}
