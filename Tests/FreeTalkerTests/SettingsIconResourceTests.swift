import AppKit
import Testing
@testable import FreeTalker

struct SettingsIconResourceTests {
    @Test(arguments: SettingsDestination.allCases)
    func everySettingsDestinationLoadsItsPackagedPNG(destination: SettingsDestination) throws {
        let image = try #require(SettingsIconResources.image(named: destination.imageName))
        let cgImage = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))

        #expect(image.size == NSSize(width: 360, height: 360))
        #expect([
            CGImageAlphaInfo.first,
            .last,
            .premultipliedFirst,
            .premultipliedLast
        ].contains(cgImage.alphaInfo))
        #expect(try cornerAlpha(of: cgImage) == 0)
    }

    @Test func sidebarMetricsMatchTheApprovedLargerLayout() {
        #expect(SettingsSidebarMetrics.rowSpacing == 10)
        #expect(SettingsSidebarMetrics.iconSize == 28)
        #expect(SettingsSidebarMetrics.textSize == 14)
        #expect(SettingsSidebarMetrics.horizontalPadding == 10)
        #expect(SettingsSidebarMetrics.verticalPadding == 7)
        #expect(SettingsSidebarMetrics.cornerRadius == 8)
        #expect(SettingsSidebarMetrics.headerSize == 15)
        #expect(SettingsSidebarMetrics.minimumWidth == 200)
        #expect(SettingsSidebarMetrics.idealWidth == 216)
        #expect(SettingsSidebarMetrics.maximumWidth == 240)
    }

    private func cornerAlpha(of image: CGImage) throws -> UInt8 {
        let corner = try #require(image.cropping(to: CGRect(x: 0, y: 0, width: 1, height: 1)))
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try #require(CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(corner, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return pixel[3]
    }
}
