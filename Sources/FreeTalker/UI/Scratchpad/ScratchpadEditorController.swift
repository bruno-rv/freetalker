import AppKit
import Foundation

enum ScratchpadHeading: Int, CaseIterable {
    case body
    case heading1
    case heading2

    var pointSize: CGFloat {
        switch self {
        case .body: NSFont.systemFontSize
        case .heading1: 24
        case .heading2: 19
        }
    }
}

enum ScratchpadListKind: Equatable {
    case bulleted
    case numbered
}

@MainActor
final class ScratchpadEditorController {
    private let document: ScratchpadDocument
    private unowned let textView: NSTextView

    init(document: ScratchpadDocument, textView: NSTextView) {
        self.document = document
        self.textView = textView
    }

    func toggleBold() {
        toggleFontTrait(.boldFontMask, actionName: "Bold")
    }

    func toggleItalic() {
        toggleFontTrait(.italicFontMask, actionName: "Italic")
    }

    func applyHeading(_ heading: ScratchpadHeading) {
        let range = paragraphRange()
        guard range.length > 0 else { return }
        perform(actionName: "Heading", range: range) {
            let font: NSFont
            if heading == .body {
                font = .systemFont(ofSize: heading.pointSize)
            } else {
                font = .boldSystemFont(ofSize: heading.pointSize)
            }
            document.textStorage.addAttribute(.font, value: font, range: range)
        }
    }

    func applyList(_ kind: ScratchpadListKind) {
        let range = paragraphRange()
        guard range.length > 0 else { return }
        perform(actionName: kind == .bulleted ? "Bulleted List" : "Numbered List", range: range) {
            let marker: NSTextList.MarkerFormat = kind == .bulleted ? .disc : .decimal
            document.textStorage.enumerateAttribute(.paragraphStyle, in: range) { value, subrange, _ in
                let style = ((value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle)
                    ?? NSMutableParagraphStyle()
                style.textLists = [NSTextList(markerFormat: marker, options: 0)]
                style.firstLineHeadIndent = 18
                style.headIndent = 36
                style.tabStops = [NSTextTab(textAlignment: .left, location: 18)]
                document.textStorage.addAttribute(.paragraphStyle, value: style, range: subrange)
            }
        }
    }

    func clearFormatting() {
        let selected = textView.selectedRange()
        if selected.length == 0 {
            var attributes = textView.typingAttributes
            Self.clearSupportedAttributes(from: &attributes)
            textView.typingAttributes = attributes
            return
        }
        perform(actionName: "Clear Formatting", range: selected) {
            for key in Self.supportedFormattingAttributes {
                document.textStorage.removeAttribute(key, range: selected)
            }
        }
    }

    func makeTransformationToken() -> ScratchpadInsertionToken {
        document.makeInsertionToken(selectedRange: textView.selectedRange())
    }

    func replaceTransformation(
        _ token: ScratchpadInsertionToken,
        with text: NSAttributedString,
        actionName: String
    ) -> Bool {
        document.replaceIfValid(
            token: token,
            with: text,
            undoActionName: actionName,
            undoManager: textView.undoManager
        )
    }

    private func toggleFontTrait(_ trait: NSFontTraitMask, actionName: String) {
        let selected = textView.selectedRange()
        if selected.length == 0 {
            var attributes = textView.typingAttributes
            let font = (attributes[.font] as? NSFont) ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
            attributes[.font] = toggled(font, trait: trait)
            textView.typingAttributes = attributes
            return
        }

        perform(actionName: actionName, range: selected) {
            document.textStorage.enumerateAttribute(.font, in: selected) { value, range, _ in
                let font = (value as? NSFont) ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
                document.textStorage.addAttribute(.font, value: toggled(font, trait: trait), range: range)
            }
        }
    }

    private func toggled(_ font: NSFont, trait: NSFontTraitMask) -> NSFont {
        let manager = NSFontManager.shared
        let current = manager.traits(of: font)
        let desired = current.contains(trait) ? current.subtracting(trait) : current.union(trait)
        var symbolic = font.fontDescriptor.symbolicTraits
        if desired.contains(.boldFontMask) {
            symbolic.insert(.bold)
        } else {
            symbolic.remove(.bold)
        }
        if desired.contains(.italicFontMask) {
            symbolic.insert(.italic)
        } else {
            symbolic.remove(.italic)
        }
        let descriptor = font.fontDescriptor.withSymbolicTraits(symbolic)
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }

    private func paragraphRange() -> NSRange {
        let string = document.textStorage.string as NSString
        let selected = textView.selectedRange()
        guard selected.location != NSNotFound, selected.location <= string.length else {
            return NSRange(location: 0, length: 0)
        }
        return string.paragraphRange(for: selected)
    }

    private func perform(actionName: String, range: NSRange, changes: () -> Void) {
        let before = document.textStorage.attributedSubstring(from: range)
        let undoManager = textView.undoManager
        undoManager?.beginUndoGrouping()
        document.textStorage.beginEditing()
        changes()
        document.textStorage.endEditing()
        undoManager?.registerUndo(withTarget: self) { controller in
            controller.restore(before, in: range, actionName: actionName)
        }
        undoManager?.setActionName(actionName)
        undoManager?.endUndoGrouping()
    }

    private func restore(_ text: NSAttributedString, in range: NSRange, actionName: String) {
        let current = document.textStorage.attributedSubstring(from: range)
        document.textStorage.beginEditing()
        document.textStorage.replaceCharacters(in: range, with: text)
        document.textStorage.endEditing()
        let restoredRange = NSRange(location: range.location, length: (text.string as NSString).length)
        textView.undoManager?.registerUndo(withTarget: self) { controller in
            controller.restore(current, in: restoredRange, actionName: actionName)
        }
        textView.undoManager?.setActionName(actionName)
    }

    private static let supportedFormattingAttributes: [NSAttributedString.Key] = [
        .font,
        .foregroundColor,
        .backgroundColor,
        .paragraphStyle,
        .underlineStyle,
        .strikethroughStyle,
        .kern,
        .baselineOffset,
    ]

    private static func clearSupportedAttributes(from attributes: inout [NSAttributedString.Key: Any]) {
        for key in supportedFormattingAttributes {
            attributes.removeValue(forKey: key)
        }
    }
}
