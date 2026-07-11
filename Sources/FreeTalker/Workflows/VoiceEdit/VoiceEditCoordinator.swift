import AppKit
import Combine
import Foundation

struct VoiceEditPreview: Equatable {
    enum Source: Equatable {
        case localModel
        case snippet(name: String)
    }

    let original: String
    let result: String
    let source: Source
}

enum VoiceEditCoordinatorError: Error, Equatable {
    case noSelection
    case generationFailed
}

@MainActor
final class VoiceEditCoordinator: ObservableObject {
    typealias SnippetMatcher = @Sendable (String) async throws -> SnippetMatch

    @Published private(set) var preview: VoiceEditPreview?
    @Published private(set) var snippetChoices: [Snippet] = []
    @Published private(set) var error: VoiceEditCoordinatorError?
    private(set) var instruction: String

    private let selection: SelectionSnapshot?
    private let selectionAccess: any SelectionAccessing
    private let snippetMatcher: SnippetMatcher
    private let editService: any LocalEditServicing
    private let copy: (String) -> Void

    init(
        selection: SelectionSnapshot?,
        instruction: String,
        selectionAccess: any SelectionAccessing,
        snippetMatcher: @escaping SnippetMatcher,
        editService: any LocalEditServicing = LocalEditService(),
        copy: @escaping (String) -> Void = { text in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    ) {
        self.selection = selection
        self.instruction = instruction
        self.selectionAccess = selectionAccess
        self.snippetMatcher = snippetMatcher
        self.editService = editService
        self.copy = copy
    }

    func begin() async {
        preview = nil
        snippetChoices = []
        error = nil
        guard let selection else {
            error = .noSelection
            return
        }
        do {
            switch try await snippetMatcher(instruction) {
            case .match(let snippet):
                setPreview(snippet.expansion, source: .snippet(name: snippet.name), selection: selection)
            case .ambiguous(let snippets):
                snippetChoices = snippets
            case .none:
                let result = try await editService.edit(
                    selectedText: selection.text, instruction: instruction
                )
                setPreview(result, source: .localModel, selection: selection)
            }
        } catch {
            self.error = .generationFailed
        }
    }

    func chooseSnippet(id: String) {
        guard let selection, let snippet = snippetChoices.first(where: { $0.id == id }) else { return }
        snippetChoices = []
        setPreview(snippet.expansion, source: .snippet(name: snippet.name), selection: selection)
    }

    func confirm() throws {
        guard let selection, let preview else { return }
        try selectionAccess.replace(selection, with: preview.result)
        clearMemory()
    }

    func cancel() { clearMemory() }

    func copyResult() {
        guard let result = preview?.result else { return }
        copy(result)
        clearMemory()
    }

    private func setPreview(_ result: String, source: VoiceEditPreview.Source, selection: SelectionSnapshot) {
        preview = VoiceEditPreview(original: selection.text, result: result, source: source)
    }

    private func clearMemory() {
        preview = nil
        snippetChoices = []
        error = nil
        instruction = ""
    }
}
