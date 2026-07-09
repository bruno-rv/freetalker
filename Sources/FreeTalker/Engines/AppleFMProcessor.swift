import FoundationModels
import Foundation

/// On-device post-processing via Apple's Foundation Models framework. Default processor — used
/// for every Template whenever the cloud provider isn't fully configured (see
/// `AppCoordinator.isCloudLLMConfigured`; cloud selection is global, never per-Template — Amendment A).
struct AppleFMProcessor: PostProcessor {
    enum FMError: Error {
        /// The system language model isn't available on this machine (unsupported device,
        /// Apple Intelligence disabled, or model not yet downloaded). The pipeline treats this
        /// as a recoverable condition and falls back to the raw transcript — never an app crash.
        case unavailable
    }

    func process(transcript: String, template: Template, appName: String?) async throws -> String {
        guard case .available = SystemLanguageModel.default.availability else {
            throw FMError.unavailable
        }

        let vocabulary = await AppSettings.shared.vocabulary
        let instructions = buildProcessorInstructions(
            template: template,
            vocabulary: vocabulary,
            trailing: "Always respond in the same language as the transcript below.",
            appName: appName
        )
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(to: transcript)
        return response.content
    }
}
