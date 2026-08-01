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
    /// Not necessarily the whole snapshot: decoder-side biasing costs a full decoder inference per
    /// prompt token per window, so callers pass it only where no LLM pass will carry the same
    /// terms — see `AppCoordinator.decoderBiasVocabulary`. An empty array means "don't bias", not
    /// "no vocabulary configured".
    func transcribe(samples: [Float], forcedLanguage: String?, candidateLanguages: [String], vocabulary: [String]) async throws -> TranscriptionOutput
}
