import Foundation
import Testing
@testable import FreeTalker

@Suite("Notchpad presentation lifecycle")
@MainActor
struct NotchpadPresentationLifecycleTests {
    @Test func actualControllerKeepsSameRecordingTickUnderRestoreOverlayAndHideIsAtomic() {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "NotchpadTests-\(UUID().uuidString)")!)
        let controller = HUDController(settings: settings)
        let base = recordingState(elapsed: 1, generation: 4)
        let tick = recordingState(elapsed: 2, generation: 4)

        controller.showRecordingPanel(base)
        controller.flash("warning", duration: 60, lifetime: .restoreBase)
        controller.showRecordingPanel(tick)

        #expect(controller.presentationSnapshot.baseMode == .recordingPanel(tick))
        #expect(controller.presentationSnapshot.overlayMode == .text("warning"))
        #expect(controller.presentationSnapshot.controllerVisible)
        #expect(controller.presentationSnapshot.pendingExpiryKind == .restoreBase)

        controller.hide()

        #expect(controller.presentationSnapshot.baseMode == nil)
        #expect(controller.presentationSnapshot.overlayMode == nil)
        #expect(!controller.presentationSnapshot.controllerVisible)
        #expect(controller.presentationSnapshot.pendingExpiryKind == nil)
    }

    @Test func timerGenerationInvalidationIgnoresStaleExpiry() {
        #expect(
            NotchpadPresentationLogic.expiryAction(
                scheduledGeneration: 3,
                eventGeneration: 2,
                kind: .terminal
            ) == .noOp
        )
        #expect(
            NotchpadPresentationLogic.expiryAction(
                scheduledGeneration: 3,
                eventGeneration: 2,
                kind: .restoreBase
            ) == .noOp
        )
    }

    @Test func matchingTerminalExpiryHidesAll() {
        #expect(
            NotchpadPresentationLogic.expiryAction(
                scheduledGeneration: 5,
                eventGeneration: 5,
                kind: .terminal
            ) == .hideAll
        )
    }

    @Test func matchingRestoreBaseExpiryRestoresBase() {
        #expect(
            NotchpadPresentationLogic.expiryAction(
                scheduledGeneration: 5,
                eventGeneration: 5,
                kind: .restoreBase
            ) == .restoreBase
        )
    }

    @Test func generationBumpInvalidatesPreviousOverlayTimer() {
        // cancelOverlayTimer bumps generation before scheduling a new one —
        // model the sequence pure: old gen no longer matches.
        var generation: UInt = 1
        let old = generation
        generation &+= 1 // cancel
        generation &+= 1 // schedule new
        let scheduled = generation
        #expect(
            NotchpadPresentationLogic.expiryAction(
                scheduledGeneration: scheduled,
                eventGeneration: old,
                kind: .restoreBase
            ) == .noOp
        )
        #expect(
            NotchpadPresentationLogic.expiryAction(
                scheduledGeneration: scheduled,
                eventGeneration: scheduled,
                kind: .restoreBase
            ) == .restoreBase
        )
    }

    @Test func sameRecordingUpdateUnderOverlayKeepsOverlaySemantics() {
        let base = recordingMode(elapsed: 1, generation: 7)
        let tick = recordingMode(elapsed: 2, generation: 7)
        #expect(
            NotchpadPresentationLogic.isSameRecordingBaseUpdate(
                incoming: tick,
                currentBase: base
            )
        )
        #expect(
            !NotchpadPresentationLogic.isSameRecordingBaseUpdate(
                incoming: .text("Processing…"),
                currentBase: base
            )
        )
        #expect(
            !NotchpadPresentationLogic.isSameRecordingBaseUpdate(
                incoming: tick,
                currentBase: .text("Listening…")
            )
        )
        #expect(
            NotchpadPresentationLogic.presentAction(
                mode: tick,
                lifetime: .persistentBase,
                currentBase: base,
                hasRestoreBaseOverlay: true
            ) == .updateBaseUnderOverlay
        )
    }

    @Test func differentRecordingUpdateCancelsOverlayInsteadOfUpdatingBase() {
        let base = recordingMode(elapsed: 1, generation: 7)
        let nextRecording = recordingMode(elapsed: 0, generation: 8)

        #expect(
            !NotchpadPresentationLogic.isSameRecordingBaseUpdate(
                incoming: nextRecording,
                currentBase: base
            )
        )
        #expect(
            NotchpadPresentationLogic.presentAction(
                mode: nextRecording,
                lifetime: .persistentBase,
                currentBase: base,
                hasRestoreBaseOverlay: true
            ) == .setBase(cancelOverlay: true)
        )
    }

    @Test func hideSemanticsClearDisplayAndConnector() {
        // hide() ⇒ controllerVisible false ⇒ connector off regardless of surface.
        #expect(
            !NotchpadPresentationLogic.connectorShouldBeVisible(
                controllerVisible: false,
                surfaceStyle: .notch
            )
        )
        #expect(
            NotchpadPresentationLogic.displayedMode(base: nil, overlay: nil) == nil
        )
    }

    @Test func flashExpiryLeavesConnectorInvariantTiedToVisibilityOnly() {
        // Terminal expiry → hideAll → not visible → connector off.
        // Restore-base expiry → still visible on notch → connector stays.
        #expect(
            !NotchpadPresentationLogic.connectorShouldBeVisible(
                controllerVisible: false,
                surfaceStyle: .notch
            )
        )
        #expect(
            NotchpadPresentationLogic.connectorShouldBeVisible(
                controllerVisible: true,
                surfaceStyle: .notch
            )
        )
    }

    @Test func terminalFlashClearsPathEvenWithRecordingBase() {
        let action = NotchpadPresentationLogic.presentAction(
            mode: .text("Cancelled"),
            lifetime: .terminalFlash,
            currentBase: recordingMode(),
            hasRestoreBaseOverlay: true
        )
        #expect(action == .terminalFlash)
    }

    @Test func translationRecoveryIsPersistentBaseReplacement() {
        // Synthetic recovery mode still routes as setBase(cancelOverlay:).
        // TranslationRecoveryPresentation construction is covered elsewhere; here we only
        // need a non-recording persistent mode to prove cancel-overlay behavior.
        let action = NotchpadPresentationLogic.presentAction(
            mode: .text("saved"),
            lifetime: .persistentBase,
            currentBase: recordingMode(),
            hasRestoreBaseOverlay: true
        )
        #expect(action == .setBase(cancelOverlay: true))
    }

    private func recordingMode(elapsed: TimeInterval = 1, generation: Int = 0) -> HUDController.Mode {
        .recordingPanel(recordingState(elapsed: elapsed, generation: generation))
    }

    private func recordingState(elapsed: TimeInterval = 1, generation: Int = 0) -> HUDController.RecordingPanelState {
        HUDController.RecordingPanelState(
            recordingGeneration: generation,
            isLocked: true,
            elapsed: elapsed,
            cap: 120,
            previewText: "preview",
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
    }
}
