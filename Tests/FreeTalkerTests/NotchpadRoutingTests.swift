import CoreGraphics
import Foundation
import Testing
@testable import FreeTalker

@Suite("Notchpad routing")
struct NotchpadRoutingTests {
    private let geometry = NotchGeometry(
        displayID: 1,
        screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        safeAreaTop: 38,
        notchFrame: CGRect(x: 666, y: 944, width: 180, height: 38)
    )

    @Test func routeRequiresEnabledAndValidGeometry() {
        #expect(NotchpadPresentationLogic.route(enabled: false, geometry: geometry) == .floating)
        #expect(NotchpadPresentationLogic.route(enabled: true, geometry: nil) == .floating)
        #expect(NotchpadPresentationLogic.route(enabled: false, geometry: nil) == .floating)
        #expect(NotchpadPresentationLogic.route(enabled: true, geometry: geometry) == .notch)
    }

    @Test func routeBoolOverloadMatchesGeometryPath() {
        #expect(NotchpadPresentationLogic.route(enabled: true, hasValidGeometry: true) == .notch)
        #expect(NotchpadPresentationLogic.route(enabled: true, hasValidGeometry: false) == .floating)
        #expect(NotchpadPresentationLogic.route(enabled: false, hasValidGeometry: true) == .floating)
    }

    @Test func routingSnapshotUsesValidBuiltinEvenWhenExternalIsFirst() {
        let external = NotchScreenDescriptor(
            displayID: 99,
            frame: CGRect(x: 1512, y: 0, width: 1920, height: 1080),
            isBuiltin: false,
            safeAreaTop: 0,
            auxiliaryTopLeft: nil,
            auxiliaryTopRight: nil
        )
        let builtin = NotchScreenDescriptor(
            displayID: geometry.displayID,
            frame: geometry.screenFrame,
            isBuiltin: true,
            safeAreaTop: geometry.safeAreaTop,
            auxiliaryTopLeft: CGRect(x: 0, y: 944, width: 666, height: 38),
            auxiliaryTopRight: CGRect(x: 846, y: 944, width: 666, height: 38)
        )

        let snapshot = NotchpadPresentationLogic.routingSnapshot(
            enabled: true,
            descriptors: [external, builtin]
        )

        #expect(snapshot.surfaceStyle == .notch)
        #expect(snapshot.displayID == geometry.displayID)
        #expect(snapshot.isBuiltin == true)
        #expect(snapshot.rejection == nil)
    }

    @Test func routingSnapshotReportsInvalidBuiltinInsteadOfFirstExternal() {
        let external = NotchScreenDescriptor(
            displayID: 99,
            frame: CGRect(x: 1512, y: 0, width: 1920, height: 1080),
            isBuiltin: false,
            safeAreaTop: 0,
            auxiliaryTopLeft: nil,
            auxiliaryTopRight: nil
        )
        let invalidBuiltin = NotchScreenDescriptor(
            displayID: geometry.displayID,
            frame: geometry.screenFrame,
            isBuiltin: true,
            safeAreaTop: 0,
            auxiliaryTopLeft: nil,
            auxiliaryTopRight: nil
        )

        let snapshot = NotchpadPresentationLogic.routingSnapshot(
            enabled: true,
            descriptors: [external, invalidBuiltin]
        )

        #expect(snapshot.surfaceStyle == .floating)
        #expect(snapshot.displayID == geometry.displayID)
        #expect(snapshot.isBuiltin == true)
        #expect(snapshot.rejection == NotchRejectionReason.noSafeAreaTop.rawValue)
    }

    @Test func connectorVisibilityInvariant() {
        #expect(
            NotchpadPresentationLogic.connectorShouldBeVisible(
                controllerVisible: true,
                surfaceStyle: .notch
            )
        )
        #expect(
            !NotchpadPresentationLogic.connectorShouldBeVisible(
                controllerVisible: false,
                surfaceStyle: .notch
            )
        )
        #expect(
            !NotchpadPresentationLogic.connectorShouldBeVisible(
                controllerVisible: true,
                surfaceStyle: .floating
            )
        )
        #expect(
            !NotchpadPresentationLogic.connectorShouldBeVisible(
                controllerVisible: false,
                surfaceStyle: .floating
            )
        )
    }

    @Test func flashLifetimeMapsToPresentationLifetime() {
        #expect(NotchpadPresentationLogic.FlashLifetime.terminal.presentation == .terminalFlash)
        #expect(NotchpadPresentationLogic.FlashLifetime.restoreBase.presentation == .restoreBaseFlash)
    }

    @Test func contentSitsBelowSafeAreaStrip() {
        let panelHeight: CGFloat = 48
        let originY = geometry.contentOriginY(panelHeight: panelHeight)
        #expect(originY + panelHeight == geometry.contentMaxY)
        #expect(originY + panelHeight <= geometry.screenFrame.maxY - geometry.safeAreaTop)
        #expect(geometry.connectorFrame.minY == geometry.contentMaxY)
        #expect(geometry.connectorFrame.height == geometry.safeAreaTop)
        #expect(geometry.connectorFrame.width == geometry.notchFrame.width)
    }

    // MARK: Lifetime decisions with synthetic modes

    private func recordingMode(elapsed: TimeInterval = 1) -> HUDController.Mode {
        .recordingPanel(
            HUDController.RecordingPanelState(
                recordingGeneration: 0,
                isLocked: false,
                elapsed: elapsed,
                cap: 60,
                previewText: "hi",
                warnings: [],
                activeTemplateName: "Clean",
                localContextScopeName: "Off",
                localContextPermissionHint: nil,
                oneShotLanguage: nil,
                translationState: .init(
                    effectiveOutput: .sameAsSpoken,
                    override: nil,
                    availability: .init(enabled: true, tooltip: nil, accessibilityHelp: nil)
                )
            )
        )
    }

    @Test func persistentBaseCancelsOverlayExceptSameRecordingUpdate() {
        let base = recordingMode(elapsed: 1)
        let tick = recordingMode(elapsed: 2)
        let text = HUDController.Mode.text("Processing…")

        #expect(
            NotchpadPresentationLogic.presentAction(
                mode: tick,
                lifetime: .persistentBase,
                currentBase: base,
                hasRestoreBaseOverlay: true
            ) == .updateBaseUnderOverlay
        )
        #expect(
            NotchpadPresentationLogic.presentAction(
                mode: text,
                lifetime: .persistentBase,
                currentBase: base,
                hasRestoreBaseOverlay: true
            ) == .setBase(cancelOverlay: true)
        )
        #expect(
            NotchpadPresentationLogic.presentAction(
                mode: tick,
                lifetime: .persistentBase,
                currentBase: base,
                hasRestoreBaseOverlay: false
            ) == .setBase(cancelOverlay: true)
        )
        #expect(
            NotchpadPresentationLogic.presentAction(
                mode: text,
                lifetime: .persistentBase,
                currentBase: nil,
                hasRestoreBaseOverlay: false
            ) == .setBase(cancelOverlay: true)
        )
    }

    @Test func flashLifetimesAreDistinct() {
        let mode = HUDController.Mode.text("No microphone signal detected yet — recording continues")
        #expect(
            NotchpadPresentationLogic.presentAction(
                mode: mode,
                lifetime: .terminalFlash,
                currentBase: recordingMode(),
                hasRestoreBaseOverlay: false
            ) == .terminalFlash
        )
        #expect(
            NotchpadPresentationLogic.presentAction(
                mode: mode,
                lifetime: .restoreBaseFlash,
                currentBase: recordingMode(),
                hasRestoreBaseOverlay: false
            ) == .restoreBaseFlash
        )
    }

    @Test func displayedModePrefersOverlay() {
        let base = recordingMode()
        let overlay = HUDController.Mode.text("warn")
        #expect(NotchpadPresentationLogic.displayedMode(base: base, overlay: overlay) == overlay)
        #expect(NotchpadPresentationLogic.displayedMode(base: base, overlay: nil) == base)
        #expect(NotchpadPresentationLogic.displayedMode(base: nil, overlay: overlay) == overlay)
        #expect(NotchpadPresentationLogic.displayedMode(base: nil, overlay: nil) == nil)
    }
}
