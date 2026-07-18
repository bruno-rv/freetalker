import AppKit
import Testing
@testable import FreeTalker

@Suite("Notchpad panel policy")
@MainActor
struct NotchpadPanelPolicyTests {
    @Test func settingsCopyDescribesAllHUDPresentationsAndFallback() {
        #expect(NotchpadSettingsCopy.toggleTitle == "Show FreeTalker in the notch")
        #expect(NotchpadSettingsCopy.caption == "All HUD presentations — recording panel, status flashes, and translation recovery — move to the notch on the built-in display; falls back to the floating panel in clamshell or external-only setups.")
    }

    @Test func recordingAndRecoveryCallbacksEachForwardExactlyOnce() {
        let controller = HUDController(settings: AppSettings(defaults: UserDefaults(suiteName: "NotchpadTests-\(UUID().uuidString)")!))
        var counts: [String: Int] = [:]
        func mark(_ key: String) { counts[key, default: 0] += 1 }
        controller.onPanelCancel = { mark("cancel") }
        controller.onPanelDone = { mark("done") }
        controller.onPanelRaw = { mark("raw") }
        controller.onPanelLanguage = { _ in mark("language") }
        controller.onPanelOutput = { _ in mark("output") }
        controller.onPanelCycleTemplate = { mark("template") }
        controller.onPanelLock = { mark("lock") }
        controller.onRetryTranslation = { mark("retry") }
        controller.onInsertSourceText = { mark("insert") }

        let callbacks = controller.makeCallbacks()
        callbacks.onCancel()
        callbacks.onDone()
        callbacks.onRaw()
        callbacks.onLanguage("en")
        callbacks.onOutput(.english)
        callbacks.onCycleTemplate()
        callbacks.onLock()
        callbacks.onRetryTranslation()
        callbacks.onInsertSourceText()

        #expect(counts == [
            "cancel": 1, "done": 1, "raw": 1, "language": 1, "output": 1,
            "template": 1, "lock": 1, "retry": 1, "insert": 1
        ])
    }

    @Test func floatingMakePanelKeepsFloatingLevelAndCollectionBehavior() {
        let panel = HUDController.makePanel(size: NSSize(width: 200, height: 60), surfaceStyle: .floating)

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

    @Test func notchMakePanelUsesStatusBarLevelSameCollectionBehavior() {
        let panel = HUDController.makePanel(size: NSSize(width: 200, height: 60), surfaceStyle: .notch)

        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(panel.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(panel.collectionBehavior.contains(.stationary))
        #expect(panel.level == .statusBar)
        #expect(panel.canBecomeKey == false)
        #expect(panel.canBecomeMain == false)
        #expect(panel.ignoresMouseEvents == false)
    }

    @Test func applySurfaceStyleSwitchesLevelWithoutChangingCollectionBehavior() {
        let panel = HUDController.makePanel(size: NSSize(width: 120, height: 40), surfaceStyle: .floating)
        #expect(panel.level == .floating)

        HUDController.applySurfaceStyle(.notch, to: panel)
        #expect(panel.level == .statusBar)
        #expect(panel.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(panel.collectionBehavior.contains(.stationary))
        #expect(panel.collectionBehavior.contains(.fullScreenAuxiliary))

        HUDController.applySurfaceStyle(.floating, to: panel)
        #expect(panel.level == .floating)
        #expect(panel.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(panel.collectionBehavior.contains(.stationary))
        #expect(panel.collectionBehavior.contains(.fullScreenAuxiliary))
    }

    @Test func connectorPanelIsNoninteractiveStatusBarAndBlack() {
        let frame = CGRect(x: 100, y: 900, width: 180, height: 38)
        let connector = HUDController.makeConnectorPanel(frame: frame)

        #expect(connector.styleMask.contains(.nonactivatingPanel))
        #expect(connector.level == .statusBar)
        #expect(connector.ignoresMouseEvents == true)
        #expect(connector.canBecomeKey == false)
        #expect(connector.canBecomeMain == false)
        #expect(connector.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(connector.collectionBehavior.contains(.stationary))
        #expect(connector.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(connector.backgroundColor == NSColor.black)
        #expect(connector.frame == frame)
    }
}
