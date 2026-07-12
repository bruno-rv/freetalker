import Testing
@testable import FreeTalker

@Suite @MainActor struct HUDWarningPresentationTests {
    @Test func voiceEditInstructionComposesCaptureWarningsOnce() {
        let text = AppCoordinator.voiceEditRecordingHUDText(captureWarnings: [
            "Noise suppression unavailable; recording without it.",
            "Selected microphone unavailable; using the system default."
        ])

        #expect(text == "Speak the edit instruction, then press Voice Edit again\nNoise suppression unavailable; recording without it.\nSelected microphone unavailable; using the system default.")
    }

    @Test func recordingPanelStateKeepsWarningsSeparateFromPreview() {
        let state = HUDController.RecordingPanelState(
            isLocked: false,
            elapsed: 0,
            cap: 0,
            previewText: "live preview",
            warnings: ["Noise suppression unavailable; recording without it."],
            activeTemplateName: "Clean",
            localContextScopeName: "Off",
            localContextPermissionHint: nil,
            oneShotLanguage: nil
        )

        #expect(state.previewText == "live preview")
        #expect(state.warnings == ["Noise suppression unavailable; recording without it."])
    }
}
