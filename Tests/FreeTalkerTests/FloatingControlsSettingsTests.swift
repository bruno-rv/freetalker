import Foundation
import Testing
@testable import FreeTalker

@MainActor
struct FloatingControlsSettingsTests {
    @Test func launcherDefaultsAreSafe() {
        let defaults = isolatedDefaults()
        defer { remove(defaults) }

        let settings = AppSettings(defaults: defaults)

        #expect(settings.edgeLauncherEnabled == false)
        #expect(settings.edgeLauncherEdge == .right)
        #expect(settings.edgeLauncherPosition == 0.5)
        #expect(settings.launcherPanelPosition == nil)
        #expect(settings.recordingHUDPosition == nil)
        #expect(settings.transientHUDPosition == nil)
    }

    @Test(arguments: LauncherEdge.allCases)
    func launcherEdgesPersist(edge: LauncherEdge) {
        let defaults = isolatedDefaults()
        defer { remove(defaults) }

        var settings: AppSettings? = AppSettings(defaults: defaults)
        settings?.edgeLauncherEdge = edge
        settings = AppSettings(defaults: defaults)

        #expect(settings?.edgeLauncherEdge == edge)
    }

    @Test(arguments: [(-1.0, 0.0), (0.4, 0.4), (2.0, 1.0),
                      (.infinity, 0.5), (.nan, 0.5)])
    func launcherPositionClamps(input: Double, expected: Double) {
        let defaults = isolatedDefaults()
        defer { remove(defaults) }
        let settings = AppSettings(defaults: defaults)

        settings.edgeLauncherPosition = input

        #expect(settings.edgeLauncherPosition == expected)
    }

    @Test func floatingPanelPositionsRoundTripIndependently() {
        let defaults = isolatedDefaults()
        defer { remove(defaults) }
        let launcher = NormalizedWindowPosition(displayID: "display-1", x: 0.25, y: 0.75)
        let recording = NormalizedWindowPosition(displayID: "display-2", x: 0.5, y: 0.25)
        let transient = NormalizedWindowPosition(displayID: "display-3", x: 0.75, y: 0.5)

        var settings: AppSettings? = AppSettings(defaults: defaults)
        settings?.launcherPanelPosition = launcher
        settings?.recordingHUDPosition = recording
        settings?.transientHUDPosition = transient
        settings = AppSettings(defaults: defaults)

        #expect(settings?.launcherPanelPosition == launcher)
        #expect(settings?.recordingHUDPosition == recording)
        #expect(settings?.transientHUDPosition == transient)
    }

    @Test func legacyHUDPositionMigratesToTransientHUD() {
        let defaults = isolatedDefaults()
        defer { remove(defaults) }
        let legacy = NormalizedWindowPosition(displayID: "display-1", x: 0.25, y: 0.75)
        defaults.set(try! JSONEncoder().encode(legacy), forKey: "hudPosition")

        let settings = AppSettings(defaults: defaults)

        #expect(settings.transientHUDPosition == legacy)
        #expect(settings.recordingHUDPosition == nil)
    }

    @Test func resettingFloatingPanelPositionsRestoresMigrationDefaults() {
        let defaults = isolatedDefaults()
        defer { remove(defaults) }
        let settings = AppSettings(defaults: defaults)
        let position = NormalizedWindowPosition(displayID: "display-1", x: 0.25, y: 0.75)
        settings.launcherPanelPosition = position
        settings.recordingHUDPosition = position
        settings.transientHUDPosition = position

        settings.resetLauncherPanelPosition()
        settings.resetRecordingHUDPosition()
        settings.resetTransientHUDPosition()

        #expect(settings.launcherPanelPosition == nil)
        #expect(settings.recordingHUDPosition == nil)
        #expect(settings.transientHUDPosition == nil)
    }

    @Test func invalidStoredValuesFallBackSafely() {
        let defaults = isolatedDefaults()
        defer { remove(defaults) }
        defaults.set("diagonal", forKey: "edgeLauncherEdge")
        defaults.set(Double.infinity, forKey: "edgeLauncherPosition")
        defaults.set(Data("not json".utf8), forKey: "launcherPanelPosition")
        defaults.set(Data("not json".utf8), forKey: "recordingHUDPosition")
        defaults.set(Data("not json".utf8), forKey: "transientHUDPosition")

        let settings = AppSettings(defaults: defaults)

        #expect(settings.edgeLauncherEdge == .right)
        #expect(settings.edgeLauncherPosition == 0.5)
        #expect(settings.launcherPanelPosition == nil)
        #expect(settings.recordingHUDPosition == nil)
        #expect(settings.transientHUDPosition == nil)
    }

    @Test func nonFiniteStoredHUDCoordinatesAreRejected() {
        let defaults = isolatedDefaults()
        defer { remove(defaults) }
        defaults.set(Data(#"{"displayID":null,"x":1e999,"y":0.5}"#.utf8), forKey: "transientHUDPosition")

        let settings = AppSettings(defaults: defaults)

        #expect(settings.transientHUDPosition == nil)
    }

    @Test(arguments: [(" EN ", "en"), ("pt", "pt"), ("unknown", "auto")])
    func languagePinNormalizes(input: String, expected: String) {
        let defaults = isolatedDefaults()
        defer { remove(defaults) }
        let settings = AppSettings(defaults: defaults)

        settings.languagePin = input

        #expect(settings.languagePin == expected)
        #expect(defaults.string(forKey: "languagePin") == expected)
    }

    private func isolatedDefaults() -> UserDefaults {
        let suite = "FloatingControlsSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(suite, forKey: "testSuiteName")
        return defaults
    }

    private func remove(_ defaults: UserDefaults) {
        let suite = defaults.string(forKey: "testSuiteName")!
        defaults.removePersistentDomain(forName: suite)
    }
}
