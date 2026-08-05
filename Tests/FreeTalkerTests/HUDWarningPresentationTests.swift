import Testing
@testable import FreeTalker

@Suite @MainActor struct HUDWarningPresentationTests {
    // MARK: Completion / delivery feedback
    // See docs/insertion-delivery-and-feedback-2026-08-05.md: the transcript failing to reach the
    // document used to be reported as a bare "Copied — paste manually", with the classification
    // `Insertion` had already made thrown away.

    @Test func everyInsertionFailureReasonGetsItsOwnExplanation() {
        let reasons: [InsertionFailureReason] = [.axDenied, .targetDrift, .noFocusedElement, .pasteFailed]
        let messages = reasons.map { AppCoordinator.notPastedMessage(reason: $0, skipPostProcessing: false) }

        #expect(Set(messages).count == reasons.count)
        // Whatever the reason, the message has to leave the user knowing the text is recoverable.
        for message in messages {
            #expect(message.contains("Copied") || message.contains("copied"))
        }
    }

    @Test func driftAndMissingFocusAreDistinguishedRatherThanBothReadingAsCopied() {
        #expect(
            AppCoordinator.notPastedMessage(reason: .targetDrift, skipPostProcessing: false)
                == "Focus changed — copied, paste manually"
        )
        #expect(
            AppCoordinator.notPastedMessage(reason: .noFocusedElement, skipPostProcessing: false)
                == "No text field focused — copied, paste manually"
        )
    }

    @Test func anUnclassifiedFailureKeepsTheOldGenericWording() {
        // Paths that don't route through the batch `insert:` closure have no classification to
        // report — saying nothing specific beats inventing a reason.
        #expect(
            AppCoordinator.notPastedMessage(reason: nil, skipPostProcessing: false)
                == "Copied — paste manually"
        )
        #expect(
            AppCoordinator.notPastedMessage(reason: nil, skipPostProcessing: true)
                == "Copied (raw) — paste manually"
        )
    }

    @Test func aRawStopIsMarkedAsRawWhateverTheReason() {
        // The marker sits next to "copied" — it describes what's on the clipboard, so trailing the
        // sentence with it ("…paste manually (raw)") would attach it to the wrong clause.
        #expect(
            AppCoordinator.notPastedMessage(reason: .targetDrift, skipPostProcessing: true)
                == "Focus changed — copied (raw), paste manually"
        )
        for reason in [InsertionFailureReason.axDenied, .noFocusedElement, .pasteFailed] {
            #expect(
                AppCoordinator.notPastedMessage(reason: reason, skipPostProcessing: true)
                    .contains("(raw)")
            )
        }
    }

    @Test func aNoticeTheUserMustActOnOutlivesTheOrdinaryFlash() {
        // The 2.5s default is the whole reason the clipboard fallback went unnoticed.
        #expect(AppCoordinator.actionableNoticeDuration > 2.5)
    }

    @Test func everyFailureReasonHasAStableNonSensitiveLogLabel() {
        let reasons: [InsertionFailureReason] = [.axDenied, .targetDrift, .noFocusedElement, .pasteFailed]
        let labels = reasons.map(\.logLabel)

        #expect(Set(labels).count == reasons.count)
        #expect(labels.allSatisfy { !$0.isEmpty })
    }

    @Test func allRecordingOwnedWarningCallsitesUseRestoreBaseLifetime() {
        for reason in AppCoordinator.RestoreBaseHUDFlashReason.allCases {
            #expect(AppCoordinator.hudFlashLifetime(for: reason) == .restoreBase)
        }
    }

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
            templateName: "Clean",
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
            templateName: "Clean",
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
