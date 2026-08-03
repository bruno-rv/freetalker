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
    /// `CloudSTTEngine` reads the base URL again for its own request, so editing Settings between
    /// the stop and the upload can make the two disagree. Rather than thread an immutable STT
    /// configuration through the engine, `transcribe` makes the skip non-lossy: a skipped cloud is
    /// still attempted if the local leg fails, so a stale decision costs at most one wasted local
    /// transcription and never the dictation (Codex round 2, finding 3).
    let skipsPrimary: Bool
    /// Whether the post-processing pass will carry the vocabulary terms anyway — the input to
    /// `AppCoordinator.decoderBiasVocabulary`, which this engine applies per leg rather than
    /// letting the caller apply it once for a leg it cannot predict.
    let refinementCarriesVocabulary: Bool

    init(
        primary: any TranscriptionEngine,
        fallback: any TranscriptionEngine,
        skipsPrimary: Bool,
        refinementCarriesVocabulary: Bool
    ) {
        self.primary = primary
        self.fallback = fallback
        self.skipsPrimary = skipsPrimary
        self.refinementCarriesVocabulary = refinementCarriesVocabulary
    }

    /// The configured engine's name. What actually ran is reported per transcription, on
    /// `TranscriptionOutput.producedBy`, since it can differ one dictation at a time.
    var name: String { primary.name }

    @MainActor var statusText: String { primary.statusText }

    /// The cloud leg's answer, which means the caller withholds nothing and hands over the whole
    /// snapshot — and `transcribe` then applies the withholding rule per leg, with the engine that
    /// is about to run.
    ///
    /// One flag cannot serve two legs. Answering for the local engine strips the vocabulary from
    /// every successful cloud transcription, where biasing is free (Codex round 1, finding 2);
    /// answering for the cloud makes a local fallback pay decode time for terms the refinement
    /// carries anyway; and switching on `skipsPrimary` leaves the last-resort cloud call holding
    /// an already-emptied list (Codex round 3, finding 1). Projecting inside the engine is the
    /// only version where each leg gets what it should.
    var vocabularyBiasCostsDecodeTime: Bool { primary.vocabularyBiasCostsDecodeTime }

    /// Whether to go local first. Ollama-shaped endpoints have no `/audio/transcriptions`, which
    /// Settings already warns about — this is that same predicate, used to try local rather than
    /// spend the whole timeout rediscovering it. It reorders the legs; it does not remove the
    /// cloud one, which is still the last resort if local fails (Codex round 3, finding 5).
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
                return try await run(
                    primary, samples: samples, forcedLanguage: forcedLanguage,
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

        // Cancellation can land while the cloud leg is failing. Checking here, and inside `run`
        // on the way out, keeps a stop the user abandoned from being answered by a second
        // transcription — or by a success the pipeline would then deliver (Codex round 1,
        // finding 5).
        try Task.checkCancellation()
        let localError: any Error
        do {
            var output = try await run(
                fallback, samples: samples, forcedLanguage: forcedLanguage,
                candidateLanguages: candidateLanguages, vocabulary: vocabulary
            )
            output.producedBy = fallback.name
            return output
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            localError = error
        }

        // Both legs are the failure now. A cloud-only user has no local model downloaded, so
        // reporting only the cloud reason would send them chasing an endpoint that is not the
        // whole story — and the recovery entry this produces would fail its retry the same way.
        if let primaryError {
            throw BothEnginesFailed(primary: primaryError, fallback: localError)
        }
        // The skip is an optimization, and an optimization must not be why a dictation is lost:
        // the base URL is read again for the request, so Settings edited during the stop can make
        // the skip decision stale (Codex round 2, finding 3). A skipped cloud therefore still gets
        // its chance rather than the stop ending on a local engine that may have no model.
        do {
            return try await run(
                primary, samples: samples, forcedLanguage: forcedLanguage,
                candidateLanguages: candidateLanguages, vocabulary: vocabulary
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            throw BothEnginesFailed(primary: error, fallback: localError)
        }
    }

    /// One leg, biased with whatever that leg should actually receive, and bracketed by the
    /// cancellation checks that keep an abandoned stop from starting a paid request (Codex round
    /// 3, finding 2) or arriving as a success the pipeline delivers and flashes (round 2,
    /// finding 1).
    private func run(
        _ engine: any TranscriptionEngine,
        samples: [Float], forcedLanguage: String?, candidateLanguages: [String], vocabulary: [String]
    ) async throws -> TranscriptionOutput {
        try Task.checkCancellation()
        let output = try await engine.transcribe(
            samples: samples, forcedLanguage: forcedLanguage,
            candidateLanguages: candidateLanguages,
            vocabulary: AppCoordinator.decoderBiasVocabulary(
                vocabulary,
                refinementCarriesVocabulary: refinementCarriesVocabulary,
                biasCostsDecodeTime: engine.vocabularyBiasCostsDecodeTime
            )
        )
        try Task.checkCancellation()
        return output
    }

    struct BothEnginesFailed: LocalizedError {
        let primary: any Error
        let fallback: any Error

        var errorDescription: String? {
            "Cloud transcription failed (\(primary.localizedDescription)) and the local engine could not take over (\(fallback.localizedDescription))"
        }
    }
}
