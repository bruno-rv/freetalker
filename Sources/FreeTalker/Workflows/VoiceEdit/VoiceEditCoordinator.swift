import AppKit
import Combine
import Foundation

struct VoiceEditPreview: Equatable {
    enum Source: Equatable {
        case localModel
        case snippet(name: String)
    }

    let result: String
    let source: Source
}

enum VoiceEditCoordinatorError: Error, Equatable {
    case noSelection
    case generationFailed
    case copyFailed
    case targetChanged
    case selectionChanged
    case secureField
    case noEditableSelection
    case replacementFailed

    var message: String {
        switch self {
        case .noSelection: "Select editable text first."
        case .generationFailed: "The local model could not prepare this edit. Try again."
        case .copyFailed: "The result could not be copied to the clipboard. Try Copy again."
        case .targetChanged: "The target field changed. Return to the original field and try again, or copy the result."
        case .selectionChanged: "The selected text changed. Reselect the original text and try again, or copy the result."
        case .secureField: "Voice Edit is unavailable in secure fields. Copy the result instead."
        case .noEditableSelection: "The target is no longer an editable selection. Reselect text and try again, or copy the result."
        case .replacementFailed: "The app rejected the replacement. Try again, or copy the result."
        }
    }
}

enum VoiceEditClipboardError: Error { case writeFailed }

@MainActor
final class VoiceEditCoordinator: ObservableObject {
    typealias SnippetMatcher = @Sendable (String) async throws -> SnippetMatch

    @Published private(set) var preview: VoiceEditPreview?
    @Published private(set) var snippetChoices: [Snippet] = []
    @Published private(set) var error: VoiceEditCoordinatorError?
    @Published private(set) var hasSensitiveContent: Bool
    private(set) var instruction: String

    private var selection: SelectionSnapshot?
    private let selectionAccess: any SelectionAccessing
    private let snippetMatcher: SnippetMatcher
    private let editService: any LocalEditServicing
    private let copy: (String) throws -> Void
    private var operationID: UUID?

    var errorMessage: String? { error?.message }

    init(
        selection: SelectionSnapshot?,
        instruction: String,
        selectionAccess: any SelectionAccessing,
        snippetMatcher: @escaping SnippetMatcher,
        editService: any LocalEditServicing = LocalEditService(),
        copy: @escaping (String) throws -> Void = { text in
            guard NSPasteboard.general.writeObjects([text as NSString]) else {
                throw VoiceEditClipboardError.writeFailed
            }
        }
    ) {
        self.selection = selection
        self.instruction = instruction
        hasSensitiveContent = selection != nil || !instruction.isEmpty
        self.selectionAccess = selectionAccess
        self.snippetMatcher = snippetMatcher
        self.editService = editService
        self.copy = copy
    }

    func begin() async {
        let operationID = UUID()
        self.operationID = operationID
        preview = nil
        snippetChoices = []
        error = nil
        guard let selection else {
            finish(error: .noSelection)
            return
        }
        do {
            let match = try await snippetMatcher(instruction)
            guard self.operationID == operationID, !Task.isCancelled else { return }
            switch match {
            case .match(let snippet):
                setPreview(snippet.expansion, source: .snippet(name: snippet.name))
            case .ambiguous(let snippets):
                snippetChoices = snippets
            case .none:
                let result = try await editService.edit(
                    selectedText: selection.text, instruction: instruction
                )
                guard self.operationID == operationID, !Task.isCancelled else { return }
                setPreview(result, source: .localModel)
            }
        } catch {
            guard self.operationID == operationID, !Task.isCancelled else { return }
            finish(error: .generationFailed)
        }
    }

    func chooseSnippet(id: String) {
        guard selection != nil, let snippet = snippetChoices.first(where: { $0.id == id }) else { return }
        snippetChoices = []
        setPreview(snippet.expansion, source: .snippet(name: snippet.name))
    }

    func confirm() throws {
        guard let selection, let preview else { return }
        do {
            try selectionAccess.replace(selection, with: preview.result)
            clearMemory()
        } catch let selectionError as SelectionAccessError {
            error = Self.coordinatorError(for: selectionError)
            throw selectionError
        }
    }

    func cancel() { clearMemory() }

    func dismissError() { error = nil }

    func copyResult() throws {
        guard let result = preview?.result else { return }
        do {
            try copy(result)
            clearMemory()
        } catch {
            self.error = .copyFailed
            throw error
        }
    }

    private func setPreview(_ result: String, source: VoiceEditPreview.Source) {
        preview = VoiceEditPreview(result: result, source: source)
        operationID = nil
    }

    private func clearMemory() {
        preview = nil
        snippetChoices = []
        error = nil
        operationID = nil
        selection = nil
        instruction = ""
        hasSensitiveContent = false
    }

    private func finish(error: VoiceEditCoordinatorError) {
        clearMemory()
        self.error = error
    }

    private static func coordinatorError(for error: SelectionAccessError) -> VoiceEditCoordinatorError {
        switch error {
        case .noFrontmostApplication, .targetChanged: .targetChanged
        case .noEditableSelection: .noEditableSelection
        case .secureField: .secureField
        case .selectionChanged: .selectionChanged
        case .replacementFailed: .replacementFailed
        }
    }
}
