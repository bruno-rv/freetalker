import AppKit
import Testing
@testable import FreeTalker

@Suite @MainActor struct FloatingPanelPolicyTests {
    @Test func hudPanelRemainsNonactivatingAndVisibleAcrossSpaces() {
        let panel = HUDController.makePanel(size: NSSize(width: 200, height: 60))

        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(panel.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(panel.collectionBehavior.contains(.stationary))
        #expect(panel.level == .floating)
        #expect(panel.canBecomeKey == false)
        #expect(panel.canBecomeMain == false)
        #expect(panel.ignoresMouseEvents == false)
        #expect(panel.isMovableByWindowBackground == false)
    }
}
