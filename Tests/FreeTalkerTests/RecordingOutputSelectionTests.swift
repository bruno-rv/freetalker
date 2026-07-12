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

    @Test(arguments: [
        "success", "cancellation", "transcription failure",
        "translation resolution", "explicit source insertion",
    ])
    func terminalResolutionClearsOverrideState(terminal: String) {
        var selection = RecordingOutputSelection()
        selection.select(.german, isRecording: false)
        _ = selection.start(default: .portuguese)

        selection.resolveTerminal()

        #expect(selection.pending == nil, Comment(rawValue: terminal))
        #expect(selection.current == nil, Comment(rawValue: terminal))
        #expect(selection.effective == nil, Comment(rawValue: terminal))
    }
}
