import Foundation

protocol TimestampedTranscribing: Sendable {
    /// `candidateLanguages`: the Dictation Language Set (F5) constraining local WhisperKit
    /// auto-detect when `language` is nil — media import is one of the local paths PLAN.md F5.3
    /// requires this on.
    func transcribeFile(at url: URL, language: String?, model: String, candidateLanguages: [String]) async throws -> [TranscriptSegment]
}

struct WhisperFileRequest: Sendable, Equatable {
    let url: URL
    let language: String?
    let model: String
    /// Defaults to `[]` (`WhisperKitEngine.constrainedLanguage` falls back to
    /// `AppSettings.defaultDictationLanguages`) so call sites that don't care about the
    /// candidate set — mostly tests exercising `language != nil` (forced) paths — don't need to
    /// pass it.
    var candidateLanguages: [String] = []
}

struct RawTranscriptSegment: Sendable, Equatable {
    let start: TimeInterval
    let end: TimeInterval
    let text: String
}

protocol WhisperFileTranscriptionBackend: Sendable {
    func transcribeFile(_ request: WhisperFileRequest) async throws -> [RawTranscriptSegment]
}

enum MediaAdapterError: Error, Equatable, LocalizedError {
    case invalidTranscriptSegment(index: Int)
    case invalidSpeakerTurn(index: Int)

    var errorDescription: String? {
        switch self {
        case .invalidTranscriptSegment(let index):
            "Transcription returned an invalid timestamp interval at segment \(index + 1)."
        case .invalidSpeakerTurn(let index):
            "Speaker separation returned an invalid speaker interval at turn \(index + 1)."
        }
    }
}

struct TimestampedWhisperTranscriber<Backend: WhisperFileTranscriptionBackend>: TimestampedTranscribing {
    private let backend: Backend

    init(backend: Backend) {
        self.backend = backend
    }

    func transcribeFile(at url: URL, language: String?, model: String, candidateLanguages: [String] = []) async throws -> [TranscriptSegment] {
        try Task.checkCancellation()
        let request = WhisperFileRequest(url: url, language: language, model: model, candidateLanguages: candidateLanguages)
        let raw = try await backend.transcribeFile(request)
        try Task.checkCancellation()
        return try raw.enumerated().map { index, segment in
            guard segment.start.isFinite, segment.end.isFinite,
                  segment.start >= 0, segment.end > segment.start else {
                throw MediaAdapterError.invalidTranscriptSegment(index: index)
            }
            return TranscriptSegment(start: segment.start, end: segment.end, text: segment.text)
        }
    }
}
