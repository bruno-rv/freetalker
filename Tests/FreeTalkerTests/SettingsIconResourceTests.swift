import AppKit
import Testing
@testable import FreeTalker

struct SettingsIconResourceTests {
    @Test(arguments: SettingsDestination.allCases)
    func everySettingsDestinationLoadsItsPackagedPNG(destination: SettingsDestination) throws {
        let image = try #require(SettingsIconResources.image(named: destination.imageName))

        #expect(image.size == NSSize(width: 360, height: 360))
    }
}
