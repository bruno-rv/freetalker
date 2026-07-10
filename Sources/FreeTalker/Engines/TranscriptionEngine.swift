import Foundation

struct TranscriptionOutput {
    var text: String
    /// BCP-47-ish language code as reported by the engine (e.g. "en", "pt").
    var language: String
}

/// Turns a Dictation's audio into a Transcript. See CONTEXT.md: "Transcription Engine".
/// `transcribe` is intentionally nonisolated so the heavy on-device work never ties up the
/// main actor; `statusText` is main-actor-isolated since it feeds SwiftUI directly.
protocol TranscriptionEngine: Sendable {
    /// Human-readable engine name, stored on each Dictation row ("engine used").
    var name: String { get }
    /// Free-text status for the menu bar / Settings (e.g. download progress, "Ready").
    @MainActor var statusText: String { get }
    /// `forcedLanguage`: nil = auto-detect (existing behavior); "en"/"pt" pins the Transcript
    /// language (CONTEXT.md "Language Pin"). Resolved once at stop time by
    /// `AppCoordinator.resolveLanguage` and passed in — engines never read AppSettings for this
    /// themselves. See PLAN.md step 5.
    func transcribe(samples: [Float], forcedLanguage: String?) async throws -> TranscriptionOutput
}
