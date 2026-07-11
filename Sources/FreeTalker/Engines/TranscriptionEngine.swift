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
    func transcribe(samples: [Float], forcedLanguage: String?) async throws -> TranscriptionOutput
}
