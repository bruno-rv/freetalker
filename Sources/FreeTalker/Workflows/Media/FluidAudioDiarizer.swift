import FluidAudio
import Foundation
import os

protocol SpeakerDiarizing: Sendable {
    func diarizeFile(at url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> [SpeakerTurn]
}

struct RawSpeakerTurn: Sendable, Equatable {
    let speakerID: String
    let start: TimeInterval
    let end: TimeInterval
}

protocol SpeakerDiarizationBackend: Sendable {
    func diarizeFile(at url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> [RawSpeakerTurn]
}

private final class MonotonicProgress: @unchecked Sendable {
    private let value = OSAllocatedUnfairLock(initialState: 0.0)
    private let sink: @Sendable (Double) -> Void

    init(sink: @escaping @Sendable (Double) -> Void) {
        self.sink = sink
    }

    func report(_ candidate: Double) {
        let next = value.withLock { current in
            let normalized = min(1, max(0, candidate.isFinite ? candidate : current))
            current = max(current, normalized)
            return current
        }
        sink(next)
    }
}

struct FluidAudioDiarizer<Backend: SpeakerDiarizationBackend>: SpeakerDiarizing {
    private let backend: Backend

    init(backend: Backend) {
        self.backend = backend
    }

    func diarizeFile(at url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> [SpeakerTurn] {
        let monotonic = MonotonicProgress(sink: progress)
        monotonic.report(0)
        try Task.checkCancellation()
        let raw = try await withPromptCancellation {
            try await backend.diarizeFile(at: url) { monotonic.report($0) }
        }
        try Task.checkCancellation()
        return try raw.enumerated().map { index, turn in
            guard !turn.speakerID.isEmpty, turn.start.isFinite, turn.end.isFinite,
                  turn.start >= 0, turn.end > turn.start else {
                throw MediaAdapterError.invalidSpeakerTurn(index: index)
            }
            return SpeakerTurn(speakerID: turn.speakerID, start: turn.start, end: turn.end)
        }
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

    func diarizeFile(at url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> [RawSpeakerTurn] {
        try Task.checkCancellation()
        let manager = OfflineDiarizerManager()
        let models = try await OfflineDiarizerModels.load(from: modelsDirectory) { update in
            progress(update.fractionCompleted * 0.5)
        }
        try Task.checkCancellation()
        manager.initialize(models: models)
        let result = try await manager.process(url) { completed, total in
            guard total > 0 else { return }
            progress(0.5 + 0.5 * Double(completed) / Double(total))
        }
        try Task.checkCancellation()
        progress(1)
        return result.segments.map {
            RawSpeakerTurn(
                speakerID: $0.speakerId,
                start: TimeInterval($0.startTimeSeconds),
                end: TimeInterval($0.endTimeSeconds)
            )
        }
    }

    private static let defaultModelsDirectory = FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
    )[0]
        .appendingPathComponent("FreeTalker", isDirectory: true)
        .appendingPathComponent("models/fluidaudio", isDirectory: true)
}

typealias LocalFluidAudioDiarizer = FluidAudioDiarizer<FluidAudioBackend>
