import AppKit
import SwiftUI

@MainActor
struct RichTextEditor: NSViewRepresentable {
    let document: ScratchpadDocument

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        let textView = Self.makeTextView(document: document)
        textView.delegate = context.coordinator
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        // The text view remains attached to the document's original text storage.
        // Reassigning attributed content here would discard selection and undo state.
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(document: document)
    }

    static func makeTextView(document: ScratchpadDocument) -> NSTextView {
        let textView = NSTextView(frame: .zero)
        textView.isRichText = true
        textView.allowsUndo = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.layoutManager?.replaceTextStorage(document.textStorage)
        return textView
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private weak var document: ScratchpadDocument?

        init(document: ScratchpadDocument) {
            self.document = document
        }

        func textDidChange(_ notification: Notification) {
            document?.scheduleSave()
        }
    }
}
