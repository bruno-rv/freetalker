import Foundation
import Testing
@testable import FreeTalker

@MainActor
struct ExportSettingsTests {
    @Test func exportedJSONContainsSettingsButNeverAnAPIKey() throws {
        let suite = "ExportSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)
        settings.noiseSuppressionEnabled = false
        settings.languagePin = "en"
        settings.hotKeySpec = HotKeySpec(modifiers: 0x40, keyCode: nil)

        let data = try settings.exportSettingsJSON()
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let payload = try #require(json)

        #expect(payload["formatVersion"] as? Int == 1)
        #expect(payload["app"] as? String == "FreeTalker")

        let exported = try #require(payload["settings"] as? [String: Any])
        #expect(exported["noiseSuppressionEnabled"] as? Bool == false)
        #expect(exported["languagePin"] as? String == "en")
        let hotKeySpec = try #require(exported["hotKeySpec"] as? [String: Any])
        #expect(hotKeySpec["modifiers"] as? Int == 0x40)

        let raw = String(data: data, encoding: .utf8) ?? ""
        #expect(!raw.localizedCaseInsensitiveContains("apiKey"))
    }
}
