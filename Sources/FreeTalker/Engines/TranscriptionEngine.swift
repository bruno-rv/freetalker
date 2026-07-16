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
    func transcribe(samples: [Float], forcedLanguage: String?, candidateLanguages: [String]) async throws -> TranscriptionOutput
}
