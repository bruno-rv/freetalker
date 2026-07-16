import Foundation

enum RecoveryLocalProcessingError: LocalizedError {
    case emptyTranscript
    var errorDescription: String? { "No speech was detected in the recovery audio." }
}

protocol RecoveryLocalTranscribing: Sendable {
    func transcribe(samples: [Float], forcedLanguage: String?, candidateLanguages: [String], exactModel: String) async throws -> TranscriptionOutput
}

extension WhisperKitEngine: RecoveryLocalTranscribing {}

struct RecoveryLocalProcessor: Sendable {
    let transcriber: any RecoveryLocalTranscribing

    /// `candidateLanguages`: the Dictation Language Set to constrain auto-detect with when
    /// `configuration.language` is nil. Recovery/retry runs detached from any live Recording (it
    /// can happen after a relaunch), so there's no "Recording start" snapshot to reuse here — the
    /// caller passes the live configured set at the time this retry actually runs. See PLAN.md
    /// F5.3.
    func process(samples: [Float], configuration: AttemptConfiguration, candidateLanguages: [String] = [], defaultModel: String) async throws -> TranscriptionOutput {
        let output = try await transcriber.transcribe(
            samples: samples,
            forcedLanguage: configuration.language,
            candidateLanguages: candidateLanguages,
            exactModel: configuration.speechModel ?? defaultModel
        )
        guard !output.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RecoveryLocalProcessingError.emptyTranscript }
        return output
    }
}
