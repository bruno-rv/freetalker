import Testing
@testable import FreeTalker

@Suite("Recording output selection")
struct RecordingOutputSelectionTests {
    @Test func selectionBeforeRecordingBecomesPendingAndEffective() {
        var selection = RecordingOutputSelection()

        selection.select(.german, isRecording: false)

        #expect(selection.pending == .german)
        #expect(selection.current == nil)
        #expect(selection.effective == .german)
    }

    @Test func startCopiesPendingOverrideIntoCurrentRecording() {
        var selection = RecordingOutputSelection()
        selection.select(.german, isRecording: false)

        let output = selection.start(default: .portuguese)

        #expect(output == .german)
        #expect(selection.pending == nil)
        #expect(selection.current == .german)
        #expect(selection.effective == .german)
    }

    @Test func startUsesDefaultWithoutPendingOverride() {
        var selection = RecordingOutputSelection()

        let output = selection.start(default: .portuguese)

        #expect(output == .portuguese)
        #expect(selection.current == .portuguese)
    }

    @Test func selectionDuringRecordingChangesOnlyCurrentRecording() {
        var selection = RecordingOutputSelection()
        _ = selection.start(default: .sameAsSpoken)

        selection.select(.french, isRecording: true)

        #expect(selection.current == .french)
        #expect(selection.pending == nil)
        #expect(selection.effective == .french)
    }

    @Test func translationFailureReturnsCurrentHUDOverrideForRecoveryAndClearsState() {
        var selection = RecordingOutputSelection()
        selection.select(.german, isRecording: false)
        _ = selection.start(default: .portuguese)
        selection.select(.french, isRecording: true)

        let recoveryOutput = selection.resolveTranslationFailure()

        #expect(recoveryOutput == .french)
        #expect(selection.pending == nil)
        #expect(selection.current == nil)
        #expect(selection.effective == nil)
    }

    @Test func translationFailureWithoutActiveRecordingCreatesNoRecovery() {
        var selection = RecordingOutputSelection()
        selection.select(.german, isRecording: false)

        let recoveryOutput = selection.resolveTranslationFailure()

        #expect(recoveryOutput == nil)
        #expect(selection.pending == nil)
        #expect(selection.current == nil)
    }

    @Test func successClearsWithoutTranslationRecovery() {
        assertNonRecoveryTerminalClearsState()
    }

    @Test func cancellationClearsWithoutTranslationRecovery() {
        assertNonRecoveryTerminalClearsState()
    }

    @Test func transcriptionFailureClearsWithoutTranslationRecovery() {
        assertNonRecoveryTerminalClearsState()
    }

    @Test func sourceInsertionClearsWithoutTranslationRecovery() {
        assertNonRecoveryTerminalClearsState()
    }

    private func assertNonRecoveryTerminalClearsState() {
        var selection = RecordingOutputSelection()
        selection.select(.german, isRecording: false)
        _ = selection.start(default: .portuguese)

        selection.resolveTerminal()

        #expect(selection.pending == nil)
        #expect(selection.current == nil)
        #expect(selection.effective == nil)
    }
}
