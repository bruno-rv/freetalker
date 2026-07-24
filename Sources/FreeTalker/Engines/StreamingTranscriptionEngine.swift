import AVFoundation
import FluidAudio
import Foundation

/// A live, streaming counterpart to `TranscriptionEngine` (BRAINSTORM_STREAMING_ASR.md decision
/// #1/#2): consumes PCM as it arrives during a Recording and emits APPEND-ONLY confirmed text —
/// already-emitted characters are never rewritten mid-recording. That guarantee is what makes it
/// safe to type partials straight into the target field (`LiveInsertionSession`); the polling
/// preview this replaces re-decodes a rolling window and can rewrite earlier words, which is
/// exactly why it never reached the target app. Distinct from `TranscriptionEngine`, which only
/// ever runs once, at stop, over the full buffered recording — that batch path is unaffected and
/// remains the fallback for every language/engine this doesn't cover.
protocol StreamingTranscriptionEngine: Sendable {
    /// Downloads (if needed) and loads the underlying model. Safe to call repeatedly; a no-op
    /// once already loaded.
    func prepare(progress: (@Sendable (Double) -> Void)?) async throws

    /// True once `prepare` has completed and the engine can accept audio.
    var isReady: Bool { get async }

    /// Starts a new streaming session. Call once per Recording, after `prepare`, before `append`.
    func start() async throws

    /// Feeds 16 kHz mono Float32 samples — the exact format `AudioCapture` produces, so no
    /// resampling is needed between the live tap and this engine.
    func append(samples: [Float]) async

    /// Registers the callback invoked with the full APPEND-ONLY confirmed transcript so far,
    /// each time it grows. Never invoked with a value shorter than, or diverging from, the
    /// previous call — see `StreamingAppendOnly`.
    func setPartialCallback(_ callback: @escaping @Sendable (String) -> Void) async

    /// Signals end of audio, flushes remaining buffered audio, and returns the final transcript.
    func finish() async throws -> String

    /// Resets engine state for reuse across Recordings. The loaded model stays in memory.
    func reset() async
}

/// The spoken-language codes (`DictationLanguage.rawValue`) the live streaming lane can handle.
/// EN-only for this release: of FluidAudio 0.15.5's true-streaming managers reachable through
/// `StreamingModelVariant.createManager()` (Parakeet EOU, Nemotron, Parakeet Unified), all are
/// trained on English audio only. A multilingual Nemotron streaming manager exists in the package
/// (`StreamingNemotronMultilingualAsrManager`) but isn't wired into that factory yet and isn't
/// used here. Every other configured Dictation Language silently falls back to today's WhisperKit
/// batch path (BRAINSTORM_STREAMING_ASR.md decision #2) — see `AppCoordinator.shouldStreamLive`.
enum StreamingASRLanguageSupport {
    static let supportedLanguages: Set<String> = ["en"]
}

/// FluidAudio's true streaming managers decode causally (RNNT, left-to-right) and, in practice,
/// never revise already-emitted tokens — but this guard makes that a property of our code, not a
/// trust assumption borrowed from the model: a raw partial-callback value that doesn't extend
/// what's already confirmed is simply not surfaced further, rather than replacing what's already
/// been typed. Pure and synchronous so it's directly unit-testable without a loaded model — see
/// `StreamingASRReplayTests`.
enum StreamingAppendOnly {
    nonisolated static func appendOnly(previous: String, incoming: String) -> String {
        if incoming.hasPrefix(previous) { return incoming }
        var commonPrefix = ""
        for (previousCharacter, incomingCharacter) in zip(previous, incoming) {
            guard previousCharacter == incomingCharacter else { break }
            commonPrefix.append(previousCharacter)
        }
        return commonPrefix.count > previous.count ? commonPrefix : previous
    }
}

enum StreamingEngineError: Error, LocalizedError {
    case notReady

    var errorDescription: String? {
        switch self {
        case .notReady: "Streaming model is not loaded"
        }
    }
}

/// FluidAudio-backed `StreamingTranscriptionEngine`, wrapping `StreamingEouAsrManager` (Parakeet
/// EOU 120M, 160ms chunks — the lowest-latency true-streaming variant, matching
/// `StreamingAsrManager`'s own usage example). Models live under `FreeTalkerPaths.fluidAudioModels`
/// alongside the diarization models, so `StreamingModelStore` can present/delete them with the
/// same download-state pattern `SpeechModelStore` uses for WhisperKit.
///
/// Vocabulary boosting: FluidAudio 0.15.5's `configureVocabularyBoosting` exists only on
/// `SlidingWindowAsrManager` (offline sliding-window mode, not a `StreamingAsrManager`) — the
/// true-streaming managers used here don't expose it. Biasing the live lane toward the
/// configured vocabulary is therefore a no-op today, with an upgrade path once FluidAudio adds it
/// to a true streaming manager; the batch fallback still biases via `TranscriptionEngine.vocabulary`.
actor FluidAudioStreamingEngine: StreamingTranscriptionEngine {
    private let manager: StreamingEouAsrManager
    private let modelsDirectory: URL
    private(set) var isReady = false
    private var lastConfirmed = ""
    private var externalCallback: (@Sendable (String) -> Void)?

    init(modelsDirectory: URL = FreeTalkerPaths.fluidAudioModels) {
        self.manager = StreamingEouAsrManager(chunkSize: .ms160)
        self.modelsDirectory = modelsDirectory
    }

    func prepare(progress: (@Sendable (Double) -> Void)? = nil) async throws {
        guard !isReady else { return }
        try await manager.loadModels(to: modelsDirectory, configuration: nil) { update in
            progress?(update.fractionCompleted)
        }
        isReady = true
    }

    func start() async throws {
        guard isReady else { throw StreamingEngineError.notReady }
        lastConfirmed = ""
        await manager.reset()
    }

    func append(samples: [Float]) async {
        guard isReady, let buffer = Self.pcmBuffer(from: samples) else { return }
        do {
            try await manager.appendAudio(buffer)
            try await manager.processBufferedAudio()
        } catch {
            // Best-effort: a decode hiccup on the live lane must never interrupt capture. The
            // batch path still runs on the full sample buffer at stop regardless.
        }
    }

    func setPartialCallback(_ callback: @escaping @Sendable (String) -> Void) async {
        externalCallback = callback
        let handoff: @Sendable (String) -> Void = { [weak self] raw in
            guard let self else { return }
            Task { await self.handleRawPartial(raw) }
        }
        await manager.setPartialTranscriptCallback(handoff)
    }

    func finish() async throws -> String {
        let final = try await manager.finish()
        lastConfirmed = final
        return final
    }

    func reset() async {
        lastConfirmed = ""
        await manager.reset()
    }

    private func handleRawPartial(_ raw: String) {
        let confirmed = StreamingAppendOnly.appendOnly(previous: lastConfirmed, incoming: raw)
        guard confirmed != lastConfirmed else { return }
        lastConfirmed = confirmed
        externalCallback?(confirmed)
    }

    nonisolated private static func pcmBuffer(from samples: [Float]) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channelData = buffer.floatChannelData
        else { return nil }
        buffer.frameLength = buffer.frameCapacity
        samples.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            channelData[0].update(from: base, count: samples.count)
        }
        return buffer
    }
}
