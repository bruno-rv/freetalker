import AppKit
import Testing
@testable import FreeTalker

@MainActor
struct AppLifecycleWindowPolicyTests {
    @Test func oldestProcessOwnsGlobalHotKeys() {
        let launches = [
            AppLaunchCandidate(processIdentifier: 220, launchDate: Date(timeIntervalSince1970: 20)),
            AppLaunchCandidate(processIdentifier: 110, launchDate: Date(timeIntervalSince1970: 10))
        ]

        #expect(AppLifecycleWindowPolicy.owner(in: launches)?.processIdentifier == 110)
    }

    @Test func processIdentifierBreaksLaunchDateTiesDeterministically() {
        let launchDate = Date(timeIntervalSince1970: 10)
        let launches = [
            AppLaunchCandidate(processIdentifier: 220, launchDate: launchDate),
            AppLaunchCandidate(processIdentifier: 110, launchDate: launchDate)
        ]

        #expect(AppLifecycleWindowPolicy.owner(in: launches)?.processIdentifier == 110)
    }

    @Test func settingsWindowAppearsAcrossSpacesAndAboveFullScreenApps() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 500),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )

        AppLifecycleWindowPolicy.configureSettingsWindow(window)

        #expect(window.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(window.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(window.level == .floating)
    }
}
