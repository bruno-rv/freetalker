import Foundation
import AppKit
import Testing
@testable import FreeTalker

@Suite struct VoiceEditPresentationTests {
    @Test func hotKeyPresentationDistinguishesUnboundBoundAndCapturing() {
        #expect(VoiceEditHotKeyPresentation.make(spec: nil, capturing: false).label == "Voice Edit key: Unbound")
        #expect(VoiceEditHotKeyPresentation.make(
            spec: HotKeySpec(modifiers: 0x0008, keyCode: 9), capturing: false
        ).label.contains("⌘"))
        #expect(VoiceEditHotKeyPresentation.make(spec: nil, capturing: true).actionLabel.contains("⎋ cancels"))
    }

    @Test func snippetDraftUsesCanonicalValidationAndExplainsConflicts() {
        #expect(SnippetDraft(name: "", triggersText: "hello", expansion: "value").validationMessage == "Name is required.")
        #expect(SnippetDraft(name: "Greeting", triggersText: "...", expansion: "value").validationMessage == "Add at least one trigger phrase.")
        #expect(SnippetDraft(name: "Greeting", triggersText: "Hello!\n HELLO ", expansion: "value").validationMessage == "Trigger phrases must be unique after normalization.")
        #expect(SnippetDraft(name: "Greeting", triggersText: "hello", expansion: "").validationMessage == "Expansion is required.")
        #expect(SnippetDraft(name: "Greeting", triggersText: "  Hello!  \nbye", expansion: "Hi").validatedTriggers == ["Hello!", "bye"])
    }

    @Test func snippetStoreErrorsHaveActionableEditorMessages() {
        #expect(SnippetEditorPresentation.message(for: .duplicateName).contains("name"))
        #expect(SnippetEditorPresentation.message(for: .duplicateTrigger("hello")).contains("hello"))
        #expect(SnippetEditorPresentation.message(for: .corruptData("legacy")).contains("legacy"))
    }

    @Test func previewAccessibilityNamesOriginalProposalAndActions() {
        #expect(VoiceEditPreviewAccessibility.originalLabel == "Original selected text")
        #expect(VoiceEditPreviewAccessibility.proposedLabel == "Proposed replacement text")
        #expect(VoiceEditPreviewAccessibility.replaceHint.contains("revalidates"))
        #expect(VoiceEditPreviewAccessibility.copyHint.contains("does not replace"))
    }

    @Test func previewWindowDoesNotActivateFreeTalkerOrStealFrontmostOwnership() {
        let presentation = VoiceEditPreviewWindowPresentation.make()
        #expect(presentation.styleMask.contains(.nonactivatingPanel))
        #expect(presentation.becomesKeyOnlyIfNeeded)
        #expect(!presentation.activatesApplication)
    }

    @Test func snippetStoreInitializationFailureIsVisibleAndRecoverable() {
        let presentation = SnippetStoreAvailabilityPresentation.failure("database unavailable")
        #expect(presentation.message.contains("database unavailable"))
        #expect(presentation.message.contains("local"))
        #expect(presentation.showsRetry)
    }

    @Test func targetDriftMessageKeepsCopyRecoveryAccurate() {
        #expect(VoiceEditCoordinatorError.targetChanged.message.contains("original field"))
        #expect(VoiceEditCoordinatorError.targetChanged.message.contains("copy the result"))
        #expect(VoiceEditCoordinatorError.selectionChanged.message.contains("Reselect"))
    }

    @Test func readmeDocumentsMandatoryLocalOnlyPreview() throws {
        let readme = try String(contentsOfFile: "README.md", encoding: .utf8)
        #expect(readme.contains("Voice Edit"))
        #expect(readme.contains("always shows a preview"))
        #expect(readme.contains("never sent to a cloud service"))
    }
}
