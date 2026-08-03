import Foundation
import os

/// Cloud STT that never costs the user their words: when the cloud leg fails, the local engine
/// transcribes instead of the dictation failing.
///
/// A cloud stop that throws used to end as a failed job at stage `.transcribing`, which the
/// Library shows under Recoveries — and pressing "Retry Processing" there then succeeded
/// instantly, because `processRecoveredDictation` has always hardcoded local WhisperKit
/// ("recovery must not depend on the possibly-broken cloud STT"). The live path deserves the same
/// rule: whatever the endpoint does — stall, 404, expired key, DNS — the words still land.
///
/// Only the live path composes this (`AppCoordinator.activeSTTEngine`). Recovery retry keeps
/// calling the local engine directly; wrapping it would be circular.
final class FallbackSTTEngine: TranscriptionEngine, @unchecked Sendable {
    private static let logger = Logger(subsystem: "org.freetalker.app", category: "stt")

    let primary: any TranscriptionEngine
    let fallback: any TranscriptionEngine
    /// Snapshot taken when the engine is composed, not read live, so one dictation cannot change
    /// its mind halfway through. Mirrors the Settings warning — see `skipPrimary(baseURL:)`.
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

    /// True when *either* leg pays decode time for the bias, so `decoderBiasVocabulary` — which
    /// decides before the call, with no way to know which leg will run — never hands the local
    /// engine a full vocabulary as `promptTokens` (one decoder inference per term per 30 s
    /// window). Withholding it from the cloud costs nothing: it carries the terms as a few request
    /// bytes, and the post-processing pass carries them anyway.
    var vocabularyBiasCostsDecodeTime: Bool {
        primary.vocabularyBiasCostsDecodeTime || fallback.vocabularyBiasCostsDecodeTime
    }

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

        do {
            var output = try await fallback.transcribe(
                samples: samples, forcedLanguage: forcedLanguage,
                candidateLanguages: candidateLanguages, vocabulary: vocabulary
            )
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
