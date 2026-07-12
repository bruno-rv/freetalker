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

private extension LLMProviderKind {
    var settingsName: String {
        switch self {
        case .anthropic: "Anthropic"
        case .ollama: "Ollama"
        case .openAICompatible: "OpenAI-compatible"
        }
    }
}
