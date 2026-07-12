import Foundation
import Testing
@testable import FreeTalker

@Suite("Output language settings")
@MainActor
struct OutputLanguageSettingsTests {
    @Test func successfulCredentialSaveAndDeletePostGeneralSignalWithoutSecretPayload() {
        let center = NotificationCenter()
        let store = OutputCredentialStoreSpy()
        let observation = CredentialNotificationObservation()
        let token = center.addObserver(forName: .cloudLLMCredentialsDidChange, object: nil, queue: nil) { note in
            observation.record(note)
        }
        defer { center.removeObserver(token) }

        #expect(CloudLLMCredentialWriter.update("secret", account: "test", store: store, notificationCenter: center))
        #expect(CloudLLMCredentialWriter.update("", account: "test", store: store, notificationCenter: center))
        #expect(observation.count == 2)
        #expect(observation.payloadWasEmpty)
        #expect(store.values["test"] == nil)

        store.setSucceeds = false
        #expect(!CloudLLMCredentialWriter.update("new-secret", account: "test", store: store, notificationCenter: center))
        #expect(observation.count == 2)
    }
    @Test func invalidCloudConfigurationDisablesOnlyNamedTranslations() {
        let snapshot = cloudSnapshot(provider: .anthropic, baseURL: "not a URL", model: "model", key: "key")

        let presentation = OutputLanguageSettingsPresentation.make(snapshot: snapshot)

        #expect(presentation.isEnabled(.sameAsSpoken))
        #expect(!presentation.isEnabled(.german))
        #expect(presentation.tooltip == "Complete the Anthropic API configuration in Settings > General > Cloud post-processing.")
        #expect(presentation.accessibilityHelp == presentation.tooltip)
    }

    @Test(arguments: [
        (LLMProviderKind.anthropic, "Anthropic"),
        (.ollama, "Ollama"),
        (.openAICompatible, "OpenAI-compatible"),
    ])
    func missingKeyGuidanceNamesCurrentProvider(provider: LLMProviderKind, name: String) {
        let snapshot = cloudSnapshot(provider: provider, baseURL: "https://example.com", model: "model", key: nil)

        let presentation = OutputLanguageSettingsPresentation.make(snapshot: snapshot)

        #expect(!presentation.isEnabled(.french))
        #expect(presentation.tooltip == "Add an API key for \(name) in Settings > General > Cloud post-processing.")
        #expect(presentation.accessibilityHelp == presentation.tooltip)
    }

    @Test func canonicalKeylessLoopbackEligibilityEnablesNamedTranslations() {
        let snapshot = cloudSnapshot(
            provider: .openAICompatible,
            baseURL: "http://127.0.0.1:11434/v1",
            model: "local-model",
            key: nil
        )

        let presentation = OutputLanguageSettingsPresentation.make(snapshot: snapshot)

        #expect(snapshot.eligibility == .eligible(apiKey: nil))
        #expect(OutputLanguage.allCases.allSatisfy(presentation.isEnabled))
        #expect(presentation.tooltip == nil)
        #expect(presentation.accessibilityHelp == nil)
    }

    @Test func presentationUsesCanonicalSnapshotEligibilityWithoutReimplementingIt() {
        let snapshots = [
            cloudSnapshot(provider: .anthropic, baseURL: "bad", model: "model", key: "key"),
            cloudSnapshot(provider: .ollama, baseURL: "https://example.com", model: "model", key: nil),
            cloudSnapshot(provider: .openAICompatible, baseURL: "http://localhost:1234", model: "model", key: nil),
        ]

        for snapshot in snapshots {
            let presentation = OutputLanguageSettingsPresentation.make(snapshot: snapshot)
            let canonical = CloudFeatureAvailability.make(
                eligibility: snapshot.eligibility,
                provider: snapshot.provider
            )
            #expect(presentation.translationAvailability == canonical)
        }
    }

    @Test func outputLanguageDefaultsToSameAsSpoken() {
        let defaults = isolatedDefaults()
        defer { remove(defaults) }

        let settings = AppSettings(defaults: defaults)

        #expect(settings.defaultOutputLanguage == .sameAsSpoken)
    }

    @Test(arguments: OutputLanguage.allCases)
    func outputLanguageRoundTrips(language: OutputLanguage) {
        let defaults = isolatedDefaults()
        defer { remove(defaults) }

        var settings: AppSettings? = AppSettings(defaults: defaults)
        settings?.defaultOutputLanguage = language
        settings = AppSettings(defaults: defaults)

        #expect(settings?.defaultOutputLanguage == language)
        #expect(defaults.string(forKey: "defaultOutputLanguage") == language.rawValue)
    }

    @Test func invalidStoredOutputLanguageFallsBackToSameAsSpoken() {
        let defaults = isolatedDefaults()
        defer { remove(defaults) }
        defaults.set("invalid", forKey: "defaultOutputLanguage")

        let settings = AppSettings(defaults: defaults)

        #expect(settings.defaultOutputLanguage == .sameAsSpoken)
        #expect(defaults.string(forKey: "defaultOutputLanguage") == OutputLanguage.sameAsSpoken.rawValue)
    }

    @Test func outputDefaultDoesNotChangeSpokenPin() {
        let defaults = isolatedDefaults()
        defer { remove(defaults) }
        let settings = AppSettings(defaults: defaults)
        settings.languagePin = "en"

        settings.defaultOutputLanguage = .german

        #expect(settings.languagePin == "en")
    }

    private func isolatedDefaults() -> UserDefaults {
        let suite = "OutputLanguageSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(suite, forKey: "testSuiteName")
        return defaults
    }

    private func cloudSnapshot(
        provider: LLMProviderKind,
        baseURL: String,
        model: String,
        key: String?
    ) -> CloudLLMSettingsSnapshot {
        CloudLLMSettingsSnapshot(
            provider: provider,
            baseURL: baseURL,
            model: model,
            key: key,
            vocabulary: []
        )
    }

    private func remove(_ defaults: UserDefaults) {
        let suite = defaults.string(forKey: "testSuiteName")!
        defaults.removePersistentDomain(forName: suite)
    }
}

private final class OutputCredentialStoreSpy: SecretStore {
    var values: [String: String] = [:]
    var setSucceeds = true

    func get(account: String) -> String? { values[account] }

    func set(_ value: String, account: String) -> Bool {
        guard setSucceeds else { return false }
        values[account] = value
        return true
    }

    func delete(account: String) -> Bool {
        values.removeValue(forKey: account)
        return true
    }
}

private final class CredentialNotificationObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var notifications = 0
    private var emptyPayload = true

    var count: Int { lock.withLock { notifications } }
    var payloadWasEmpty: Bool { lock.withLock { emptyPayload } }

    func record(_ notification: Notification) {
        lock.withLock {
            notifications += 1
            emptyPayload = emptyPayload && notification.object == nil && notification.userInfo == nil
        }
    }
}
