struct CloudFeatureAvailability: Equatable, Sendable {
    let enabled: Bool
    let tooltip: String?
    let accessibilityHelp: String?

    static func make(
        eligibility: CloudLLMEligibility,
        provider: LLMProviderKind
    ) -> Self {
        let reason: String?
        switch eligibility {
        case .eligible:
            reason = nil
        case .invalidConfiguration:
            reason = "Complete the \(provider.settingsName) API configuration in Settings > General > Cloud post-processing."
        case .missingAPIKey:
            reason = "Add an API key for \(provider.settingsName) in Settings > General > Cloud post-processing."
        }
        return Self(
            enabled: reason == nil,
            tooltip: reason,
            accessibilityHelp: reason
        )
    }
}

enum CloudPrivacyDisclosure {
    static let liveOutputTranslation = "Output translation sends the live transcript to the configured Cloud post-processing endpoint."
    static let scratchpad = "Scratchpad AI actions send the selected text, or the whole Scratchpad when nothing is selected, to the configured Cloud post-processing endpoint."
    static let library = "Library translation sends the chosen Library text to the configured Cloud post-processing endpoint."
    static let settings = "Cloud post-processing sends live transcripts selected for output translation, Scratchpad AI text, and chosen Library text to the configured endpoint."
}

private extension LLMProviderKind {
    var settingsName: String {
        switch self {
        case .anthropic: "Anthropic"
        case .ollama: "Ollama"
        case .openAICompatible: "OpenAI-compatible"
        }
    }
}
