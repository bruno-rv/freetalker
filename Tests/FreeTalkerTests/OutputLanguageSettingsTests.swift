import Foundation
import Testing
@testable import FreeTalker

@Suite("Output language settings")
@MainActor
struct OutputLanguageSettingsTests {
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

    private func remove(_ defaults: UserDefaults) {
        let suite = defaults.string(forKey: "testSuiteName")!
        defaults.removePersistentDomain(forName: suite)
    }
}
