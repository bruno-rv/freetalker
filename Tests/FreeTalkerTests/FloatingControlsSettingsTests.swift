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
        #expect(settings.hudPosition == nil)
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

    @Test func hudPositionRoundTripsThroughJSON() {
        let defaults = isolatedDefaults()
        defer { remove(defaults) }
        let position = NormalizedWindowPosition(displayID: "display-1", x: 0.25, y: 0.75)

        var settings: AppSettings? = AppSettings(defaults: defaults)
        settings?.hudPosition = position
        settings = AppSettings(defaults: defaults)

        #expect(settings?.hudPosition == position)
    }

    @Test func invalidStoredValuesFallBackSafely() {
        let defaults = isolatedDefaults()
        defer { remove(defaults) }
        defaults.set("diagonal", forKey: "edgeLauncherEdge")
        defaults.set(Double.infinity, forKey: "edgeLauncherPosition")
        defaults.set(Data("not json".utf8), forKey: "hudPosition")

        let settings = AppSettings(defaults: defaults)

        #expect(settings.edgeLauncherEdge == .right)
        #expect(settings.edgeLauncherPosition == 0.5)
        #expect(settings.hudPosition == nil)
    }

    @Test func nonFiniteStoredHUDCoordinatesAreRejected() {
        let defaults = isolatedDefaults()
        defer { remove(defaults) }
        defaults.set(Data(#"{"displayID":null,"x":1e999,"y":0.5}"#.utf8), forKey: "hudPosition")

        let settings = AppSettings(defaults: defaults)

        #expect(settings.hudPosition == nil)
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
