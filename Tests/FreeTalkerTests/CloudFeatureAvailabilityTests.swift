import Testing
@testable import FreeTalker

@Suite("Cloud feature availability")
struct CloudFeatureAvailabilityTests {
    @Test(arguments: [
        (LLMProviderKind.anthropic, "Anthropic"),
        (.ollama, "Ollama"),
        (.openAICompatible, "OpenAI-compatible"),
    ])
    func missingKeyGuidanceNamesProvider(provider: LLMProviderKind, name: String) {
        let availability = CloudFeatureAvailability.make(
            eligibility: .missingAPIKey,
            provider: provider
        )

        #expect(availability.enabled == false)
        #expect(availability.tooltip == "Add an API key for \(name) in Settings > General > Cloud post-processing.")
        #expect(availability.accessibilityHelp == availability.tooltip)
    }

    @Test func invalidConfigurationHasSettingsGuidance() {
        let availability = CloudFeatureAvailability.make(
            eligibility: .invalidConfiguration,
            provider: .anthropic
        )

        #expect(availability.enabled == false)
        #expect(availability.tooltip == "Complete the Anthropic API configuration in Settings > General > Cloud post-processing.")
        #expect(availability.accessibilityHelp == availability.tooltip)
    }

    @Test func canonicalEligibilityAloneDeterminesAvailability() {
        for provider in LLMProviderKind.allCases {
            let availability = CloudFeatureAvailability.make(
                eligibility: .eligible(apiKey: nil),
                provider: provider
            )
            #expect(availability.enabled)
            #expect(availability.tooltip == nil)
            #expect(availability.accessibilityHelp == availability.tooltip)
        }
    }
}
