import Foundation
import os

/// Cloud STT with the local engine behind it: when the cloud leg fails, the local one transcribes
/// rather than the dictation failing outright.
///
/// A cloud stop that throws used to end as a failed job at stage `.transcribing`, which the
/// Library shows under Recoveries — and pressing "Retry Processing" there then succeeded
/// instantly, because `processRecoveredDictation` has always hardcoded local WhisperKit
/// ("recovery must not depend on the possibly-broken cloud STT"). The live path deserves the same
/// rule: whatever the endpoint does — stall, 404, expired key, DNS — the local engine answers.
///
/// Not a guarantee that the words land. If the local engine also fails (a cloud-only user with no
/// model downloaded), this still throws, and the audio stays recoverable exactly as before.
///
/// Only the live path composes this (`AppCoordinator.activeSTTEngine`). Recovery retry keeps
/// calling the local engine directly; wrapping it would be circular.
final class FallbackSTTEngine: TranscriptionEngine, @unchecked Sendable {
    private static let logger = Logger(subsystem: "org.freetalker.app", category: "stt")

    let primary: any TranscriptionEngine
    let fallback: any TranscriptionEngine
    /// Snapshot taken when the engine is composed, not read live, so one dictation cannot change
    /// its mind halfway through. Mirrors the Settings warning — see `skipPrimary(baseURL:)`.
    ///
    /// Ceiling (Codex round 1, finding 3): `CloudSTTEngine` reads the base URL again for its own
    /// request, so editing Settings between the stop and the upload can make the two disagree.
    /// Both outcomes are safe — skipping a now-valid URL costs one local transcription, attempting
    /// a now-invalid one falls back — so this stops short of threading an immutable STT
    /// configuration through the engine.
    let skipsPrimary: Bool

    init(primary: any TranscriptionEngine, fallback: any TranscriptionEngine, skipsPrimary: Bool) {
        self.primary = primary
        self.fallback = fallback
        self.skipsPrimary = skipsPrimary
    }

    /// The configured engine's name. What actually ran is reported per transcription, on
    /// `TranscriptionOutput.producedBy`, since it can differ one dictation at a time.
    var name: String { primary.name }

    @MainActor var statusText: String { primary.statusText }

    /// The cloud leg's answer, which is the leg that runs on all but the failing dictations.
    ///
    /// `decoderBiasVocabulary` decides before the call and cannot know which leg will run, so this
    /// is a choice between two costs. Reporting the OR would withhold the vocabulary from *every*
    /// successful cloud transcription — where biasing is free, since the terms ride along as a few
    /// multipart bytes — to spare the rare fallback. Ceiling (Codex round 1, finding 2, inverted):
    /// a fallback therefore hands WhisperKit the full vocabulary as `promptTokens`, one decoder
    /// inference per term per 30 s window, on a dictation already running late. Bounded by the
    /// user's vocabulary size, and paid only when the cloud has already failed.
    var vocabularyBiasCostsDecodeTime: Bool { primary.vocabularyBiasCostsDecodeTime }

    /// Whether the cloud leg is worth attempting at all. Ollama-shaped endpoints have no
    /// `/audio/transcriptions`, which Settings already warns about — this is that same predicate,
    /// used to skip straight to local instead of spending the whole timeout discovering it.
    static func skipPrimary(baseURL: String) -> Bool {
        CloudSTTProviderKind.isKnownNonTranscriptionSTTBaseURL(baseURL)
    }

    func transcribe(
        samples: [Float], forcedLanguage: String?, candidateLanguages: [String], vocabulary: [String]
    ) async throws -> TranscriptionOutput {
        var primaryError: (any Error)?
        if skipsPrimary {
            Self.logger.notice("cloud STT skipped: base URL serves no transcription endpoint")
        } else {
            do {
                return try await primary.transcribe(
                    samples: samples, forcedLanguage: forcedLanguage,
                    candidateLanguages: candidateLanguages, vocabulary: vocabulary
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // A stop the user cancelled must not be answered with a second transcription.
                try Task.checkCancellation()
                primaryError = error
                Self.logger.notice(
                    "cloud STT failed, transcribing locally: \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        // Cancellation can land while the cloud leg is failing. Checking here and again on the way
        // out keeps a stop the user abandoned from being answered by a second transcription — or
        // by a success the pipeline would then deliver (Codex round 1, finding 5).
        try Task.checkCancellation()
        do {
            var output = try await fallback.transcribe(
                samples: samples, forcedLanguage: forcedLanguage,
                candidateLanguages: candidateLanguages, vocabulary: vocabulary
            )
            try Task.checkCancellation()
            output.producedBy = fallback.name
            return output
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            // Both legs are the failure. A cloud-only user has no local model downloaded, so
            // reporting only the cloud reason would send them chasing an endpoint that is not the
            // whole story — and the recovery entry this produces would fail its retry the same way.
            guard let primaryError else { throw error }
            throw BothEnginesFailed(primary: primaryError, fallback: error)
        }
    }

    struct BothEnginesFailed: LocalizedError {
        let primary: any Error
        let fallback: any Error

        var errorDescription: String? {
            "Cloud transcription failed (\(primary.localizedDescription)) and the local engine could not take over (\(fallback.localizedDescription))"
        }
    }
}
