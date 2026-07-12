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

struct ScratchpadSourceSnapshot: Equatable {
    let range: NSRange
    let originalText: String
    let revision: Int
}

@MainActor
final class ScratchpadEditorController {
    private let document: ScratchpadDocument
    private unowned let textView: NSTextView
    private var capturedTransformation: (snapshot: ScratchpadSourceSnapshot, token: ScratchpadInsertionToken)?

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
            var allRequestedList = true
            document.textStorage.enumerateAttribute(.paragraphStyle, in: range) { value, _, stop in
                let style = value as? NSParagraphStyle
                if style?.textLists.first?.markerFormat != marker {
                    allRequestedList = false
                    stop.pointee = true
                }
            }
            document.textStorage.enumerateAttribute(.paragraphStyle, in: range) { value, subrange, _ in
                let style = ((value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle)
                    ?? NSMutableParagraphStyle()
                if allRequestedList {
                    style.textLists = []
                    if style.firstLineHeadIndent == 18 { style.firstLineHeadIndent = 0 }
                    if style.headIndent == 36 { style.headIndent = 0 }
                    style.tabStops.removeAll { $0.location == 18 }
                } else {
                    style.textLists = [NSTextList(markerFormat: marker, options: 0)]
                    style.firstLineHeadIndent = 18
                    style.headIndent = 36
                    style.tabStops.removeAll { $0.location == 18 }
                    style.addTabStop(NSTextTab(textAlignment: .left, location: 18))
                }
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
            let range = paragraphRange()
            guard range.length > 0 else { return }
            perform(actionName: "Clear Formatting", range: range) {
                for key in Self.supportedInlineFormattingAttributes {
                    document.textStorage.removeAttribute(key, range: range)
                }
                document.textStorage.enumerateAttribute(.paragraphStyle, in: range) { value, subrange, _ in
                    guard let style = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle else {
                        return
                    }
                    style.textLists = []
                    if style.firstLineHeadIndent == 18 { style.firstLineHeadIndent = 0 }
                    if style.headIndent == 36 { style.headIndent = 0 }
                    style.tabStops.removeAll { $0.location == 18 }
                    document.textStorage.addAttribute(.paragraphStyle, value: style, range: subrange)
                }
            }
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

    func captureTransformationSource() -> ScratchpadSourceSnapshot? {
        let string = document.textStorage.string as NSString
        guard string.length > 0 else { return nil }
        let selected = textView.selectedRange()
        guard selected.location != NSNotFound,
              selected.location <= string.length,
              selected.length <= string.length - selected.location
        else { return nil }
        let range = selected.length > 0 ? selected : NSRange(location: 0, length: string.length)
        let snapshot = ScratchpadSourceSnapshot(
            range: range,
            originalText: string.substring(with: range),
            revision: Int(truncatingIfNeeded: document.revision)
        )
        capturedTransformation = (snapshot, document.makeInsertionToken(selectedRange: range))
        return snapshot
    }

    func applyTransformation(_ result: String, to snapshot: ScratchpadSourceSnapshot) -> Bool {
        let string = document.textStorage.string as NSString
        guard snapshot.revision == Int(truncatingIfNeeded: document.revision),
              snapshot.range.location <= string.length,
              snapshot.range.length <= string.length - snapshot.range.location,
              string.substring(with: snapshot.range) == snapshot.originalText
        else { return false }

        guard let capturedTransformation, capturedTransformation.snapshot == snapshot else { return false }
        self.capturedTransformation = nil

        var attributes: [NSAttributedString.Key: Any] = [:]
        if snapshot.range.length > 0 {
            attributes = document.textStorage.attributes(at: snapshot.range.location, effectiveRange: nil)
        } else if snapshot.range.location > 0 {
            attributes = document.textStorage.attributes(at: snapshot.range.location - 1, effectiveRange: nil)
        }
        let paragraphRange = string.paragraphRange(for: snapshot.range)
        document.textStorage.enumerateAttribute(.paragraphStyle, in: paragraphRange) { value, _, stop in
            if let value {
                attributes[.paragraphStyle] = value
                stop.pointee = true
            }
        }
        let replacement = NSAttributedString(string: result, attributes: attributes)
        guard document.replaceIfValid(
            token: capturedTransformation.token,
            with: replacement,
            undoActionName: "AI Transformation",
            undoManager: textView.undoManager
        ) else { return false }
        textView.setSelectedRange(NSRange(location: snapshot.range.location, length: (result as NSString).length))
        return true
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

    private static let supportedInlineFormattingAttributes = supportedFormattingAttributes.filter {
        $0 != .paragraphStyle
    }

    private static func clearSupportedAttributes(from attributes: inout [NSAttributedString.Key: Any]) {
        for key in supportedFormattingAttributes {
            attributes.removeValue(forKey: key)
        }
    }
}
