import AppKit
import Combine
import Foundation

@MainActor
final class ScratchpadDocument: NSObject, ObservableObject, @preconcurrency NSTextStorageDelegate {
    @Published private(set) var warning: String?
    let textStorage: NSTextStorage

    private struct InsertionTarget {
        let revision: UInt64
        let range: NSRange
        let originalText: String
    }

    private let persistence: ScratchpadPersistence
    private var insertionTargets: [UUID: InsertionTarget] = [:]
    private var revision: UInt64 = 0
    private var needsSave = false
    private var saveTask: Task<Void, Never>?
    private let didScheduleSave: () -> Void
    private let didSave: () -> Void

    init(
        url: URL,
        didScheduleSave: @escaping () -> Void = {},
        didSave: @escaping () -> Void = {}
    ) {
        let persistence = ScratchpadPersistence(url: url)
        let result = persistence.load()
        self.persistence = persistence
        self.warning = result.warning
        self.textStorage = NSTextStorage(attributedString: result.text)
        self.didScheduleSave = didScheduleSave
        self.didSave = didSave
        super.init()
        textStorage.delegate = self
    }

    func makeInsertionToken(selectedRange: NSRange) -> ScratchpadInsertionToken {
        let token = ScratchpadInsertionToken(id: UUID())
        let string = textStorage.string as NSString
        guard selectedRange.location != NSNotFound,
              selectedRange.location <= string.length,
              selectedRange.length <= string.length - selectedRange.location,
              selectedRange.length == 0
                ? isComposedCharacterBoundary(selectedRange.location, in: string)
                : string.rangeOfComposedCharacterSequences(for: selectedRange) == selectedRange
        else { return token }

        insertionTargets[token.id] = InsertionTarget(
            revision: revision,
            range: selectedRange,
            originalText: string.substring(with: selectedRange)
        )
        return token
    }

    private func isComposedCharacterBoundary(_ location: Int, in string: NSString) -> Bool {
        location == string.length
            || string.rangeOfComposedCharacterSequence(at: location).location == location
    }

    func replaceIfValid(
        token: ScratchpadInsertionToken,
        with text: NSAttributedString,
        undoActionName: String,
        undoManager: UndoManager? = nil
    ) -> Bool {
        guard let target = insertionTargets.removeValue(forKey: token.id),
              target.revision == revision
        else { return false }

        let string = textStorage.string as NSString
        guard target.range.location <= string.length,
              target.range.length <= string.length - target.range.location,
              string.substring(with: target.range) == target.originalText
        else { return false }

        let original = textStorage.attributedSubstring(from: target.range)
        let replacementRange = NSRange(
            location: target.range.location,
            length: (text.string as NSString).length
        )
        textStorage.beginEditing()
        textStorage.replaceCharacters(in: target.range, with: text)
        textStorage.endEditing()
        registerUndo(
            replacing: replacementRange,
            with: original,
            actionName: undoActionName,
            undoManager: undoManager
        )
        return true
    }

    func scheduleSave() {
        didScheduleSave()
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(400))
                try self?.flush()
            } catch is CancellationError {
                return
            } catch {
                self?.warning = "The scratchpad could not be saved."
            }
        }
    }

    func flush() throws {
        saveTask?.cancel()
        saveTask = nil
        guard needsSave else { return }
        try persistence.save(textStorage)
        needsSave = false
        warning = nil
        didSave()
    }

    func textStorage(
        _ textStorage: NSTextStorage,
        didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        revision &+= 1
        insertionTargets.removeAll()
        needsSave = true
        scheduleSave()
    }

    private func registerUndo(
        replacing range: NSRange,
        with text: NSAttributedString,
        actionName: String,
        undoManager: UndoManager?
    ) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { document in
            let current = document.textStorage.attributedSubstring(from: range)
            let redoRange = NSRange(location: range.location, length: (text.string as NSString).length)
            document.textStorage.beginEditing()
            document.textStorage.replaceCharacters(in: range, with: text)
            document.textStorage.endEditing()
            document.registerUndo(
                replacing: redoRange,
                with: current,
                actionName: actionName,
                undoManager: undoManager
            )
        }
        undoManager.setActionName(actionName)
    }
}
