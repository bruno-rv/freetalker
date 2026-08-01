import Foundation

struct TranscriptionOutput {
    var text: String
    /// BCP-47-ish language code as reported by the engine (e.g. "en", "pt").
    var language: String
}

protocol TranscriptionEngine: Sendable {
    /// Human-readable engine name, stored on each Dictation row ("engine used").
    var name: String { get }
    /// Free-text status for the menu bar / Settings (e.g. download progress, "Ready").
    @MainActor var statusText: String { get }
    /// `candidateLanguages`: the configured Dictation Language Set (F5), an immutable snapshot
    /// taken at Recording start. Local WhisperKit only — it constrains the engine's own
    /// auto-detect argmax when `forcedLanguage` is nil. Cloud engines ignore this parameter
    /// entirely; their API only ever takes a single `forcedLanguage`. See PLAN.md F5.3.
    /// `vocabulary`: the terms to bias decoding toward — the CALLER's snapshot, never re-read live
    /// inside the engine. PLAN.md PR B, item 2d/4: the live pipeline derives this from
    /// `RecordingProcessingContext.vocabularySnapshot` (captured once, at stop time) so STT
    /// biasing and post-processing's vocabulary hint can never disagree about which list applied
    /// to one dictation, even though the actual network/on-device call can run long after the
    /// settings that produced the snapshot might have changed. See Codex round 1 finding 4.
    ///
    /// Not necessarily the whole snapshot: where biasing is paid in decode time, callers pass it
    /// only where no LLM pass will carry the same terms — see
    /// `vocabularyBiasCostsDecodeTime` and `AppCoordinator.decoderBiasVocabulary`. An empty array
    /// means "don't bias", not "no vocabulary configured".
    func transcribe(samples: [Float], forcedLanguage: String?, candidateLanguages: [String], vocabulary: [String]) async throws -> TranscriptionOutput

    /// Whether biasing this engine toward a vocabulary is paid in transcription latency.
    ///
    /// True for WhisperKit, where the terms become `promptTokens` and each one is a full decoder
    /// inference per 30 s window. False for an engine that carries them as ordinary request
    /// content — `CloudSTTEngine` puts them in a multipart `prompt` field, which costs a few
    /// bytes on a request that was already being made.
    ///
    /// Only an engine that says the bias costs it something ever has it withheld
    /// (`AppCoordinator.decoderBiasVocabulary`), so the default is `false`: a new engine keeps the
    /// vocabulary feature until it declares a reason not to, rather than losing it silently.
    var vocabularyBiasCostsDecodeTime: Bool { get }
}

extension TranscriptionEngine {
    var vocabularyBiasCostsDecodeTime: Bool { false }
}
