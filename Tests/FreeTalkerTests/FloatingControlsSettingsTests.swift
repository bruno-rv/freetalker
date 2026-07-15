import Foundation
import Testing
@testable import FreeTalker

@MainActor
struct FloatingControlsSettingsTests {
    @Test("changing edge clears drag and rematerializes placement",
          arguments: LauncherEdge.allCases)
    func changingEdge(edge: LauncherEdge) throws {
        let fixture = try FloatingSettingsFixture()
        fixture.settings.edgeLauncherPosition = 0.25
        fixture.settings.edgeLauncherEdge = edge == .right ? .left : .right
        fixture.settings.launcherPanelPosition = NormalizedWindowPosition(
            displayID: "main", x: 1, y: 0.5
        )

        fixture.settings.edgeLauncherEdge = edge

        #expect(fixture.settings.launcherPanelPosition == nil)
        #expect(fixture.defaults.data(forKey: "launcherPanelPosition") == nil)
        let visible = CGRect(x: 100, y: 80, width: 1_000, height: 700)
        let size = CGSize(width: 54, height: 54)
        let display = DisplayFrame(id: "main", visibleFrame: visible)
        let saved = FloatingPanelGeometry.legacyLauncherPosition(
            edge: edge,
            position: 0.25,
            panelSize: size,
            display: display
        )
        let origin = FloatingPanelGeometry.restoredOrigin(
            saved: saved, displays: [display], fallback: display, panelSize: size
        )
        let frame = CGRect(origin: origin, size: size)
        assert(frame: frame, touches: edge, visibleFrame: visible,
               alongEdgePosition: 0.25)
    }

    @Test("changing along-edge position clears drag override")
    func changingAlongEdgePosition() throws {
        let fixture = try FloatingSettingsFixture()
        fixture.settings.edgeLauncherEdge = .bottom
        fixture.settings.launcherPanelPosition = NormalizedWindowPosition(
            displayID: "main", x: 1, y: 0.5
        )

        fixture.settings.edgeLauncherPosition = 0.75

        #expect(fixture.settings.launcherPanelPosition == nil)
        #expect(fixture.defaults.data(forKey: "launcherPanelPosition") == nil)
    }

    @Test("drag after settings change becomes relaunch position")
    func dragWinsAfterSettingsChange() throws {
        let fixture = try FloatingSettingsFixture()
        fixture.settings.edgeLauncherEdge = .bottom
        fixture.settings.edgeLauncherPosition = 0.75
        let dragged = NormalizedWindowPosition(
            displayID: "secondary", x: 0.42, y: 0.38
        )
        fixture.settings.launcherPanelPosition = dragged

        let reloaded = AppSettings(defaults: fixture.defaults)
        #expect(reloaded.edgeLauncherEdge == .bottom)
        #expect(reloaded.edgeLauncherPosition == 0.75)
        #expect(reloaded.launcherPanelPosition == dragged)
    }

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

    private func assert(
        frame: CGRect,
        touches edge: LauncherEdge,
        visibleFrame: CGRect,
        alongEdgePosition: Double
    ) {
        let tolerance = 0.000_001
        switch edge {
        case .left:
            #expect(abs(frame.minX - visibleFrame.minX) < tolerance)
            let position = (frame.minY - visibleFrame.minY) / (visibleFrame.height - frame.height)
            #expect(abs(position - alongEdgePosition) < tolerance)
        case .right:
            #expect(abs(frame.maxX - visibleFrame.maxX) < tolerance)
            let position = (frame.minY - visibleFrame.minY) / (visibleFrame.height - frame.height)
            #expect(abs(position - alongEdgePosition) < tolerance)
        case .top:
            #expect(abs(frame.maxY - visibleFrame.maxY) < tolerance)
            let position = (frame.minX - visibleFrame.minX) / (visibleFrame.width - frame.width)
            #expect(abs(position - alongEdgePosition) < tolerance)
        case .bottom:
            #expect(abs(frame.minY - visibleFrame.minY) < tolerance)
            let position = (frame.minX - visibleFrame.minX) / (visibleFrame.width - frame.width)
            #expect(abs(position - alongEdgePosition) < tolerance)
        }
    }
}

@MainActor
private final class FloatingSettingsFixture {
    private let suiteName: String
    private nonisolated(unsafe) let cleanupDefaults: UserDefaults
    let defaults: UserDefaults
    let settings: AppSettings

    init() throws {
        let suite = "FloatingControlsSettingsTests.Fixture.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw FloatingSettingsFixtureError.unavailableDefaults
        }
        suiteName = suite
        cleanupDefaults = defaults
        self.defaults = defaults
        settings = AppSettings(defaults: defaults)
    }

    deinit {
        cleanupDefaults.removePersistentDomain(forName: suiteName)
    }
}

private enum FloatingSettingsFixtureError: Error {
    case unavailableDefaults
}
