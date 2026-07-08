import Foundation
import WhisperKit

/// On-device transcription via WhisperKit's `large-v3-turbo` model. The model is downloaded
/// and cached by WhisperKit/Hub on first use (~1 GB); see ADR-0001.
///
/// The class itself is nonisolated (`transcribe` does CPU-heavy work that must not tie up the
/// main actor); only `statusText` is main-actor-isolated since it feeds SwiftUI directly.
/// `@unchecked Sendable` is safe here because the only mutable state (`whisperKit`) is only
/// ever touched serially by AppCoordinator, which gates re-entry via isRecording/isProcessing.
final class WhisperKitEngine: ObservableObject, TranscriptionEngine, @unchecked Sendable {
    let name = "WhisperKit (large-v3-turbo)"
    @MainActor @Published private(set) var statusText: String = "Not loaded"

    // Exact HF repo folder name for the large-v3-turbo CoreML export — avoids ambiguous
    // glob matches against sibling variants (distil/turbo/dated) in the model repo.
    private static let modelVariant = "large-v3_turbo_954MB"

    private var whisperKit: WhisperKit?

    /// Warms up the model outside the hot path (e.g. at app launch) so the first real
    /// dictation doesn't pay the load/download cost. Errors are swallowed into `statusText`
    /// (already visible in the menu bar) rather than thrown — nothing here is user-initiated.
    func preload() async {
        do {
            _ = try await loadedKit()
        } catch {
            await setStatus("Preload failed: \(error.localizedDescription)")
        }
    }

    // ponytail: supported languages are hardcoded to {en, pt} per PLAN.md/CONTEXT.md (the app
    // only targets English and Brazilian Portuguese). Upgrade path: source this set from a
    // Settings-configurable language list once more languages are supported.
    private static let supportedLanguages = ["en", "pt"]

    func transcribe(samples: [Float]) async throws -> TranscriptionOutput {
        let kit = try await loadedKit()
        await setStatus("Detecting language…")

        do {
            // Whisper's unconstrained auto-detect spans ~99 languages and misfires badly on
            // short utterances (e.g. English "Hello, 1 2 3 4 5 6" hallucinated as Portuguese).
            // Restrict the winner to the two languages this app actually supports, then pin
            // the real decode to it instead of letting WhisperKit detect+decode freely.
            let (_, langProbs) = try await kit.detectLangauge(audioArray: samples)
            let language = Self.supportedLanguages.max { langProbs[$0, default: -.infinity] < langProbs[$1, default: -.infinity] } ?? "en"

            await setStatus("Transcribing…")
            var options = DecodingOptions()
            options.language = language
            options.usePrefillPrompt = true
            options.detectLanguage = false

            let results = try await kit.transcribe(audioArray: samples, decodeOptions: options)
            await setStatus("Ready")
            let text = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            return TranscriptionOutput(text: text, language: results.first?.language ?? language)
        } catch {
            await setStatus("Ready")
            throw error
        }
    }

    // ponytail: no single-flight guard for concurrent loads — AppCoordinator already
    // serializes calls via its isRecording/isProcessing state, so re-entry can't happen.
    private func loadedKit() async throws -> WhisperKit {
        if let whisperKit { return whisperKit }
        let kit = try await loadModel()
        whisperKit = kit
        return kit
    }

    private func loadModel() async throws -> WhisperKit {
        await setStatus("Checking for model…")
        let folder = try await WhisperKit.download(variant: Self.modelVariant) { [weak self] progress in
            let percent = Int(progress.fractionCompleted * 100)
            Task { @MainActor in self?.statusText = "Downloading model… \(percent)%" }
        }
        await setStatus("Loading model…")
        let config = WhisperKitConfig(modelFolder: folder.path, verbose: false, logLevel: .none, load: true, download: false)
        let kit = try await WhisperKit(config)
        await setStatus("Ready")
        return kit
    }

    @MainActor
    private func setStatus(_ text: String) {
        statusText = text
    }
}
