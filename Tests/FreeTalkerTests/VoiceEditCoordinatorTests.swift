import ApplicationServices
import Foundation
import Testing
@testable import FreeTalker

@MainActor
@Suite struct VoiceEditCoordinatorTests {
    @Test func rejectsMissingSelectionWithoutGenerating() async {
        let editor = StubLocalEditService(result: .success("edited"))
        let coordinator = makeCoordinator(selection: nil, editor: editor)

        await coordinator.begin()

        #expect(coordinator.error == .noSelection)
        #expect(editor.requests.isEmpty)
    }

    @Test func exactNormalizedSnippetMatchSkipsGenerationAndOnlyPreviews() async {
        let snippet = sampleSnippet(name: "Sign-off", expansion: "Kind regards")
        let editor = StubLocalEditService(result: .success("generated"))
        let access = StubCoordinatorSelectionAccess()
        let coordinator = makeCoordinator(
            instruction: "  SIGN-OFF! ", access: access, editor: editor,
            matcher: { _ in .match(snippet) }
        )

        await coordinator.begin()

        #expect(coordinator.preview?.result == "Kind regards")
        #expect(coordinator.preview?.source == .snippet(name: "Sign-off"))
        #expect(editor.requests.isEmpty)
        #expect(access.replacements.isEmpty)
    }

    @Test func ambiguousSnippetRequiresExplicitChoice() async {
        let first = sampleSnippet(id: "1", name: "Formal", expansion: "Regards")
        let second = sampleSnippet(id: "2", name: "Friendly", expansion: "Cheers")
        let editor = StubLocalEditService(result: .success("generated"))
        let coordinator = makeCoordinator(editor: editor, matcher: { _ in .ambiguous([first, second]) })

        await coordinator.begin()

        #expect(coordinator.preview == nil)
        #expect(coordinator.snippetChoices.map(\.name) == ["Formal", "Friendly"])
        #expect(editor.requests.isEmpty)
        coordinator.chooseSnippet(id: "2")
        #expect(coordinator.preview?.result == "Cheers")
    }

    @Test func generatedEditStaysInMemoryUntilConfirmAndCancelClearsIt() async {
        let access = StubCoordinatorSelectionAccess()
        let editor = StubLocalEditService(result: .success("polished"))
        let coordinator = makeCoordinator(access: access, editor: editor)

        await coordinator.begin()

        #expect(coordinator.preview?.result == "polished")
        #expect(access.replacements.isEmpty)
        coordinator.cancel()
        #expect(coordinator.preview == nil)
        #expect(coordinator.instruction.isEmpty)
    }

    @Test func confirmUsesSelectionAccessAndStaleConfirmationPerformsNoWrite() async throws {
        let access = StubCoordinatorSelectionAccess(replaceError: SelectionAccessError.selectionChanged)
        let coordinator = makeCoordinator(access: access)
        await coordinator.begin()

        #expect(throws: SelectionAccessError.selectionChanged) { try coordinator.confirm() }
        #expect(access.successfulWrites == 0)
        #expect(coordinator.preview?.result == "edited")
    }

    @Test func successfulConfirmReplacesExactlyOnceAndClearsMemory() async throws {
        let access = StubCoordinatorSelectionAccess()
        let coordinator = makeCoordinator(access: access)
        await coordinator.begin()

        try coordinator.confirm()

        #expect(access.replacements == ["edited"])
        #expect(coordinator.preview == nil)
        #expect(coordinator.instruction.isEmpty)
    }

    @Test func copyOccursOnlyOnExplicitAction() async {
        var copied: [String] = []
        let coordinator = makeCoordinator(copy: { copied.append($0) })
        await coordinator.begin()
        #expect(copied.isEmpty)

        coordinator.copyResult()

        #expect(copied == ["edited"])
        #expect(coordinator.preview == nil)
    }

    @Test func localGenerationFailureIsExposedWithoutPreviewOrCopy() async {
        var copied: [String] = []
        let editor = StubLocalEditService(result: .failure(TestError.failed))
        let coordinator = makeCoordinator(editor: editor, copy: { copied.append($0) })

        await coordinator.begin()

        #expect(coordinator.preview == nil)
        #expect(coordinator.error == .generationFailed)
        #expect(copied.isEmpty)
    }

    private func makeCoordinator(
        selection: SelectionSnapshot? = Self.snapshot(),
        instruction: String = "make concise",
        access: StubCoordinatorSelectionAccess = StubCoordinatorSelectionAccess(),
        editor: StubLocalEditService = StubLocalEditService(result: .success("edited")),
        matcher: @escaping @Sendable (String) async throws -> SnippetMatch = { _ in .none },
        copy: @escaping (String) -> Void = { _ in }
    ) -> VoiceEditCoordinator {
        VoiceEditCoordinator(
            selection: selection, instruction: instruction, selectionAccess: access,
            snippetMatcher: matcher, editService: editor, copy: copy
        )
    }

    private static func snapshot() -> SelectionSnapshot {
        let text = "draft"
        return SelectionSnapshot(
            target: InsertionTarget(bundleID: "test", pid: 7, focusedElement: nil, window: nil),
            range: NSRange(location: 0, length: text.utf16.count), text: text,
            fingerprint: SelectionSnapshot.fingerprint(for: text)
        )
    }

    private func sampleSnippet(id: String = "1", name: String, expansion: String) -> Snippet {
        Snippet(id: id, name: name, triggers: [name], expansion: expansion, createdAt: .distantPast, updatedAt: .distantPast)
    }
}

private enum TestError: Error { case failed }

@MainActor
private final class StubCoordinatorSelectionAccess: SelectionAccessing {
    var replacements: [String] = []
    var successfulWrites = 0
    let replaceError: Error?
    init(replaceError: Error? = nil) { self.replaceError = replaceError }
    func capture() throws -> SelectionSnapshot { throw SelectionAccessError.noEditableSelection }
    func replace(_ snapshot: SelectionSnapshot, with text: String) throws {
        replacements.append(text)
        if let replaceError { throw replaceError }
        successfulWrites += 1
    }
}

@MainActor
private final class StubLocalEditService: LocalEditServicing {
    struct Request: Equatable { let selectedText: String; let instruction: String }
    var requests: [Request] = []
    let result: Result<String, Error>
    init(result: Result<String, Error>) { self.result = result }
    func edit(selectedText: String, instruction: String) async throws -> String {
        requests.append(.init(selectedText: selectedText, instruction: instruction))
        return try result.get()
    }
}
