import AppKit
import Foundation
import Testing
@testable import FreeTalker

@Suite("Scratchpad editor", .serialized)
@MainActor
struct ScratchpadEditorTests {
    @Test func boldWithEmptySelectionUpdatesTypingAttributes() {
        let harness = EditorHarness("Hello")
        harness.select(NSRange(location: 5, length: 0))

        harness.controller.toggleBold()

        #expect(fontTraits(harness.textView.typingAttributes[.font]).contains(.boldFontMask))
    }

    @Test func inlineTraitsApplyToAUTF16Selection() {
        let harness = EditorHarness("A😀 bold")
        harness.select(NSRange(location: 4, length: 4))

        harness.controller.toggleBold()
        harness.controller.toggleItalic()

        let font = harness.document.textStorage.attribute(.font, at: 4, effectiveRange: nil)
        #expect(fontTraits(font).contains([.boldFontMask, .italicFontMask]))
    }

    @Test func headingUsesTheCompleteUTF16ParagraphRange() {
        let harness = EditorHarness("First\nA😀 second\nThird")
        harness.select(NSRange(location: 9, length: 0))

        harness.controller.applyHeading(.heading1)

        let firstFont = harness.document.textStorage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        let headingFont = harness.document.textStorage.attribute(.font, at: 6, effectiveRange: nil) as? NSFont
        #expect(firstFont?.pointSize != ScratchpadHeading.heading1.pointSize)
        #expect(headingFont?.pointSize == ScratchpadHeading.heading1.pointSize)
        #expect(headingFont.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } == true)
    }

    @Test func listCommandsUseSemanticTextListsAndNativeIndents() {
        let harness = EditorHarness("One\nTwo")
        harness.select(NSRange(location: 0, length: 7))

        harness.controller.applyList(.bulleted)

        let style = harness.document.textStorage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        #expect(style?.textLists.first?.markerFormat == .disc)
        #expect((style?.headIndent ?? 0) > 0)
        #expect(style?.tabStops.isEmpty == false)

        harness.controller.applyList(.numbered)
        let numbered = harness.document.textStorage.attribute(.paragraphStyle, at: 4, effectiveRange: nil) as? NSParagraphStyle
        #expect(numbered?.textLists.first?.markerFormat == .decimal)
    }

    @Test func semanticListRoundTripsThroughRTF() throws {
        let harness = EditorHarness("One\nTwo")
        harness.select(NSRange(location: 0, length: 7))
        harness.controller.applyList(.bulleted)
        try harness.document.flush()

        let reloaded = ScratchpadDocument(url: harness.url)
        let style = reloaded.textStorage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        #expect(style?.textLists.first?.markerFormat == .disc)
    }

    @Test func requestedListTogglesOffAcrossFullyListedSelection() {
        let harness = EditorHarness("One\nTwo")
        let range = NSRange(location: 0, length: 7)
        let original = NSMutableParagraphStyle()
        original.alignment = .center
        original.paragraphSpacing = 11
        original.tabStops = [NSTextTab(textAlignment: .right, location: 72)]
        harness.document.textStorage.addAttribute(.paragraphStyle, value: original, range: range)
        harness.select(range)
        harness.controller.applyList(.bulleted)

        harness.controller.applyList(.bulleted)

        let style = harness.document.textStorage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        #expect(style?.textLists.isEmpty == true)
        #expect(style?.headIndent == 0)
        #expect(style?.firstLineHeadIndent == 0)
        #expect(style?.tabStops.contains { $0.location == 18 } == false)
        #expect(style?.tabStops.contains { $0.location == 72 } == true)
        #expect(style?.alignment == .center)
        #expect(style?.paragraphSpacing == 11)
    }

    @Test func mixedListSelectionAppliesRequestedListToEveryParagraph() {
        let harness = EditorHarness("One\nTwo")
        harness.select(NSRange(location: 0, length: 3))
        harness.controller.applyList(.bulleted)
        harness.select(NSRange(location: 0, length: 7))

        harness.controller.applyList(.bulleted)

        let first = harness.document.textStorage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        let second = harness.document.textStorage.attribute(.paragraphStyle, at: 4, effectiveRange: nil) as? NSParagraphStyle
        #expect(first?.textLists.first?.markerFormat == .disc)
        #expect(second?.textLists.first?.markerFormat == .disc)
    }

    @Test func ordinaryTypingSchedulesAndDebouncesPersistenceExactlyOnce() async throws {
        var scheduleCount = 0
        var saveCount = 0
        let url = temporaryURL()
        let document = ScratchpadDocument(
            url: url,
            didScheduleSave: { scheduleCount += 1 },
            didSave: { saveCount += 1 }
        )
        let textView = RichTextEditor.makeTextView(document: document)
        let coordinator = RichTextEditor.Coordinator(document: document)
        textView.delegate = coordinator
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [], backing: .buffered, defer: false)
        window.contentView = textView

        textView.insertText("A", replacementRange: textView.selectedRange())
        #expect(scheduleCount == 1)
        textView.insertText("B", replacementRange: textView.selectedRange())
        #expect(scheduleCount == 2)

        try await Task.sleep(for: .milliseconds(500))
        #expect(saveCount == 1)
        #expect(ScratchpadPersistence(url: url).load().text.string == "AB")
        _ = coordinator
        _ = window
    }

    @Test func clearFormattingRemovesOnlySupportedFormatting() {
        let harness = EditorHarness("Styled")
        let range = NSRange(location: 0, length: 6)
        harness.document.textStorage.addAttributes([
            .font: NSFont.boldSystemFont(ofSize: 24),
            .foregroundColor: NSColor.red,
            .link: URL(string: "https://example.com")!,
            .kern: 3,
        ], range: range)
        harness.select(range)

        harness.controller.clearFormatting()

        let clearedFont = harness.document.textStorage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect(clearedFont.map { !NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } == true)
        #expect(clearedFont?.pointSize != 24)
        #expect(harness.document.textStorage.attribute(.foregroundColor, at: 0, effectiveRange: nil) == nil)
        #expect(harness.document.textStorage.attribute(.kern, at: 0, effectiveRange: nil) == nil)
        #expect(harness.document.textStorage.attribute(.link, at: 0, effectiveRange: nil) != nil)
    }

    @Test func selectionReplacementUsesTheTextViewUndoManager() {
        let harness = EditorHarness("A😀B")
        harness.select(NSRange(location: 1, length: 2))
        let token = harness.controller.makeTransformationToken()

        #expect(harness.controller.replaceTransformation(token, with: NSAttributedString(string: "voice"), actionName: "Transform"))
        #expect(harness.document.textStorage.string == "AvoiceB")

        harness.textView.undoManager?.undo()
        #expect(harness.document.textStorage.string == "A😀B")
    }

    @Test func formattingIsOneUndoStep() {
        let harness = EditorHarness("Hello")
        harness.select(NSRange(location: 0, length: 5))

        harness.controller.toggleBold()
        #expect(fontTraits(harness.document.textStorage.attribute(.font, at: 0, effectiveRange: nil)).contains(.boldFontMask))

        harness.textView.undoManager?.undo()
        #expect(!fontTraits(harness.document.textStorage.attribute(.font, at: 0, effectiveRange: nil)).contains(.boldFontMask))
    }

    @Test func richTextBridgeKeepsTheDocumentsTextStorageIdentity() {
        let document = ScratchpadDocument(url: temporaryURL())
        let textView = RichTextEditor.makeTextView(document: document)

        #expect(textView.textStorage === document.textStorage)
    }

    private func fontTraits(_ value: Any?) -> NSFontTraitMask {
        guard let font = value as? NSFont else { return [] }
        return NSFontManager.shared.traits(of: font)
    }
}

@MainActor
private final class EditorHarness {
    let url: URL
    let document: ScratchpadDocument
    let textView: NSTextView
    let controller: ScratchpadEditorController
    private let window: NSWindow

    init(_ string: String) {
        url = temporaryURL()
        document = ScratchpadDocument(url: url)
        document.textStorage.append(NSAttributedString(string: string))
        textView = RichTextEditor.makeTextView(document: document)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [], backing: .buffered, defer: false)
        window.contentView = textView
        controller = ScratchpadEditorController(document: document, textView: textView)
    }

    func select(_ range: NSRange) {
        textView.setSelectedRange(range)
    }
}

private func temporaryURL() -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("Scratchpad.rtf")
}
