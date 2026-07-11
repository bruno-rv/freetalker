import Foundation

protocol TimestampedTranscribing: Sendable {
    func transcribeFile(at url: URL, language: String?, model: String) async throws -> [TranscriptSegment]
}

struct WhisperFileRequest: Sendable, Equatable {
    let url: URL
    let language: String?
    let model: String
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

    func transcribeFile(at url: URL, language: String?, model: String) async throws -> [TranscriptSegment] {
        try Task.checkCancellation()
        let request = WhisperFileRequest(url: url, language: language, model: model)
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
