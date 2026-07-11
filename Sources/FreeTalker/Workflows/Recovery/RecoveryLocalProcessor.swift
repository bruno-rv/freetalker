import Foundation

enum RecoveryLocalProcessingError: LocalizedError {
    case emptyTranscript
    var errorDescription: String? { "No speech was detected in the recovery audio." }
}

protocol RecoveryLocalTranscribing: Sendable {
    func transcribe(samples: [Float], forcedLanguage: String?, exactModel: String) async throws -> TranscriptionOutput
}

extension WhisperKitEngine: RecoveryLocalTranscribing {}

struct RecoveryLocalProcessor: Sendable {
    let transcriber: any RecoveryLocalTranscribing

    func process(samples: [Float], configuration: AttemptConfiguration, defaultModel: String) async throws -> TranscriptionOutput {
        let output = try await transcriber.transcribe(
            samples: samples,
            forcedLanguage: configuration.language,
            exactModel: configuration.speechModel ?? defaultModel
        )
        guard !output.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RecoveryLocalProcessingError.emptyTranscript }
        return output
    }
}
