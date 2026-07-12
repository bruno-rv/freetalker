import Foundation
import Testing
@testable import FreeTalker

@MainActor
struct NoiseSuppressionSettingsTests {
    @Test func noiseSuppressionDefaultsEnabledWhenUnset() {
        let suite = "NoiseSuppressionSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)

        #expect(settings.noiseSuppressionEnabled)
    }

    @Test func explicitDisabledNoiseSuppressionPersists() {
        let suite = "NoiseSuppressionSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        var settings: AppSettings? = AppSettings(defaults: defaults)
        settings?.noiseSuppressionEnabled = false
        settings = AppSettings(defaults: defaults)

        #expect(settings?.noiseSuppressionEnabled == false)
    }
}
