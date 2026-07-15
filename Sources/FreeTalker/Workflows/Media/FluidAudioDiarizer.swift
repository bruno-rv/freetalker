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

actor FluidAudioModelPreparationCoordinator<Model: Sendable> {
    private struct InFlight: Sendable {
        let id: UUID
        let task: Task<Model, Error>
    }

    private var prepared: [URL: Model] = [:]
    private var inFlight: [URL: InFlight] = [:]

    func model(
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

struct FluidAudioDiarizer<Backend: SpeakerDiarizationBackend>: SpeakerDiarizing {
    private let backend: Backend

    init(backend: Backend) {
        self.backend = backend
    }

    func diarizeFile(at url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> [SpeakerTurn] {
        let monotonic = MonotonicProgress(sink: progress)
        monotonic.report(0)
        try Task.checkCancellation()
        let raw: [RawSpeakerTurn]
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
    private static let modelCoordinator = FluidAudioModelPreparationCoordinator<OfflineDiarizerModels>()
    private let modelsDirectory: URL

    init(modelsDirectory: URL = Self.defaultModelsDirectory) {
        self.modelsDirectory = modelsDirectory
    }

    func diarizeFile(at url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> [RawSpeakerTurn] {
        try Task.checkCancellation()
        let manager = OfflineDiarizerManager()
        let models = try await Self.modelCoordinator.model(for: modelsDirectory) {
            try await OfflineDiarizerModels.load(from: modelsDirectory) { update in
                progress(update.fractionCompleted * 0.5)
            }
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

    private static let defaultModelsDirectory = FreeTalkerPaths.fluidAudioModels
}

typealias LocalFluidAudioDiarizer = FluidAudioDiarizer<FluidAudioBackend>
