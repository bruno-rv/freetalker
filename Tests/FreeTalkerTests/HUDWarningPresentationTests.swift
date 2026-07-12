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

    @Test func composedWarningTextIsNotLimitedButNormalHUDTextRemainsCapped() {
        let composed = "Instruction\nFirst warning\nSecond warning"

        #expect(HUDView.lineLimit(for: composed) == nil)
        #expect(HUDView.lineLimit(for: "Listening…") == 2)
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
            oneShotLanguage: nil,
            translationState: .init(
                effectiveOutput: .sameAsSpoken,
                override: nil,
                availability: .init(enabled: true, tooltip: nil, accessibilityHelp: nil)
            )
        )

        #expect(state.previewText == "live preview")
        #expect(state.warnings == ["Noise suppression unavailable; recording without it."])
    }

    @Test func activeHUDOutputCallbackChangesOnlyCurrentRecordingSelection() {
        var selection = RecordingOutputSelection()
        _ = selection.start(default: .portuguese)
        let callbacks = HUDController.PanelCallbacks(
            onOutput: { selection.select($0, isRecording: true) }
        )

        callbacks.onOutput(.german)

        #expect(selection.pending == nil)
        #expect(selection.current == .german)
    }

    @Test func HUDAndLauncherPresentTheSameEffectiveOverrideState() {
        let availability = CloudFeatureAvailability(
            enabled: true,
            tooltip: nil,
            accessibilityHelp: nil
        )
        let launcher = TranslationControlsState(
            effectiveOutput: .german,
            override: .german,
            availability: availability
        )
        let hud = HUDController.RecordingPanelState(
            isLocked: true,
            elapsed: 3,
            cap: 60,
            previewText: nil,
            warnings: [],
            activeTemplateName: "Clean",
            localContextScopeName: "Off",
            localContextPermissionHint: nil,
            oneShotLanguage: nil,
            translationState: launcher
        )

        #expect(hud.translationState == launcher)
        #expect(hud.translationState.override == .german)
    }

    @Test func coordinatorPresentationTracksLiveConfigurationEligibility() {
        let invalid = CloudLLMSettingsSnapshot(
            provider: .openAICompatible,
            baseURL: "not a url",
            model: "model",
            key: nil,
            vocabulary: []
        )
        let eligible = CloudLLMSettingsSnapshot(
            provider: .openAICompatible,
            baseURL: "http://localhost:11434/v1",
            model: "model",
            key: nil,
            vocabulary: []
        )

        #expect(!AppCoordinator.translationControlsState(
            defaultOutput: .sameAsSpoken,
            selection: .init(),
            snapshot: invalid
        ).availability.enabled)
        #expect(AppCoordinator.translationControlsState(
            defaultOutput: .sameAsSpoken,
            selection: .init(),
            snapshot: eligible
        ).availability.enabled)
    }
}
