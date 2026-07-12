import AppKit
import Foundation
import Testing
@testable import FreeTalker

@Suite("Scratchpad persistence", .serialized)
@MainActor
struct ScratchpadPersistenceTests {
    @Test func missingFileLoadsAnEmptyDocument() throws {
        let url = temporaryURL()

        let result = ScratchpadPersistence(url: url).load()

        #expect(result.text.string.isEmpty)
        #expect(result.warning == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func firstSaveCreatesAnRTFDocument() throws {
        let url = temporaryURL()
        let persistence = ScratchpadPersistence(url: url)

        try persistence.save(NSAttributedString(string: "first"))

        #expect(try Data(contentsOf: url).starts(with: Data("{\\rtf".utf8)))
        #expect(persistence.load().text.string == "first")
    }

    @Test func replacementSaveReplacesTheExistingDocument() throws {
        let url = temporaryURL()
        let persistence = ScratchpadPersistence(url: url)
        try persistence.save(NSAttributedString(string: "first"))

        try persistence.save(NSAttributedString(string: "second"))

        #expect(persistence.load().text.string == "second")
    }

    @Test func richTextRoundTripsThroughRTF() throws {
        let url = temporaryURL()
        let persistence = ScratchpadPersistence(url: url)
        let source = NSMutableAttributedString(string: "Bold italic\nList item")
        source.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 15), range: NSRange(location: 0, length: 4))
        source.addAttribute(.font, value: NSFontManager.shared.convert(NSFont.systemFont(ofSize: 15), toHaveTrait: .italicFontMask), range: NSRange(location: 5, length: 6))
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = 9
        paragraph.textLists = [NSTextList(markerFormat: .disc, options: 0)]
        source.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 12, length: 9))

        try persistence.save(source)
        let loaded = persistence.load().text

        #expect(loaded.string == source.string)
        let bold = loaded.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        let italic = loaded.attribute(.font, at: 5, effectiveRange: nil) as? NSFont
        let loadedParagraph = loaded.attribute(.paragraphStyle, at: 12, effectiveRange: nil) as? NSParagraphStyle
        #expect(bold.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } == true)
        #expect(italic.map { NSFontManager.shared.traits(of: $0).contains(.italicFontMask) } == true)
        #expect(loadedParagraph?.paragraphSpacing == 9)
        #expect(loadedParagraph?.textLists.isEmpty == false)
    }

    @Test func corruptSourceIsNotOverwrittenUntilEdit() throws {
        let url = temporaryURL()
        let corrupt = Data("not rtf".utf8)
        try corrupt.write(to: url)

        let document = ScratchpadDocument(url: url)
        #expect(document.warning != nil)
        try document.flush()
        #expect(try Data(contentsOf: url) == corrupt)

        document.textStorage.append(NSAttributedString(string: "replacement"))
        try document.flush()
        #expect(try Data(contentsOf: url) != corrupt)
        #expect(ScratchpadPersistence(url: url).load().text.string == "replacement")
    }

    @Test func insertionTokenIsInvalidAfterAnInterveningEdit() throws {
        let document = ScratchpadDocument(url: temporaryURL())
        document.textStorage.append(NSAttributedString(string: "A😀B"))
        let token = document.makeInsertionToken(selectedRange: NSRange(location: 1, length: 2))

        document.textStorage.append(NSAttributedString(string: "!"))

        #expect(!document.replaceIfValid(
            token: token,
            with: NSAttributedString(string: "voice"),
            undoActionName: "Insert Dictation"
        ))
        #expect(document.textStorage.string == "A😀B!")
    }

    @Test func validInsertionTokenReplacesAUTF16Selection() throws {
        let document = ScratchpadDocument(url: temporaryURL())
        document.textStorage.append(NSAttributedString(string: "A😀B"))
        let token = document.makeInsertionToken(selectedRange: NSRange(location: 1, length: 2))

        #expect(document.replaceIfValid(
            token: token,
            with: NSAttributedString(string: "voice"),
            undoActionName: "Insert Dictation"
        ))
        #expect(document.textStorage.string == "AvoiceB")
        #expect(!document.replaceIfValid(
            token: token,
            with: NSAttributedString(string: "again"),
            undoActionName: "Insert Dictation"
        ))
    }

    @Test func caretTokenRequiresAComposedCharacterBoundary() throws {
        let document = ScratchpadDocument(url: temporaryURL())
        document.textStorage.append(NSAttributedString(string: "A😀B"))
        let splitSurrogate = document.makeInsertionToken(selectedRange: NSRange(location: 2, length: 0))

        #expect(!document.replaceIfValid(
            token: splitSurrogate,
            with: NSAttributedString(string: "invalid"),
            undoActionName: "Insert Dictation"
        ))
        #expect(document.textStorage.string == "A😀B")

        let start = document.makeInsertionToken(selectedRange: NSRange(location: 0, length: 0))
        #expect(document.replaceIfValid(
            token: start,
            with: NSAttributedString(string: "<"),
            undoActionName: "Insert Dictation"
        ))
        let end = document.makeInsertionToken(selectedRange: NSRange(location: 5, length: 0))
        #expect(document.replaceIfValid(
            token: end,
            with: NSAttributedString(string: ">"),
            undoActionName: "Insert Dictation"
        ))
        #expect(document.textStorage.string == "<A😀B>")
    }

    @Test func oneUndoRestoresTheOriginalAttributedSelection() throws {
        let document = ScratchpadDocument(url: temporaryURL())
        let original = NSMutableAttributedString(string: "before")
        original.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 14), range: NSRange(location: 0, length: 6))
        document.textStorage.append(original)
        let token = document.makeInsertionToken(selectedRange: NSRange(location: 0, length: 6))
        let undoManager = UndoManager()

        #expect(document.replaceIfValid(
            token: token,
            with: NSAttributedString(string: "after"),
            undoActionName: "Insert Dictation",
            undoManager: undoManager
        ))
        undoManager.undo()

        #expect(document.textStorage.string == "before")
        let font = document.textStorage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect(font.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } == true)
    }

    private func temporaryURL() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("Scratchpad.rtf")
    }
}
