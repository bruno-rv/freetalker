import Foundation
import Testing
@testable import FreeTalker

@Suite @MainActor struct LibraryCaptureIdentityTests {
    @Test("one capture identity creates one Library dictation")
    func duplicateCaptureInsertIsIdempotent() async throws {
        let store = try LibraryStore.temporary()
        let captureID = UUID()

        let first = try store.record(sampleDictation(refined: "original"), captureID: captureID)
        let second = try store.record(sampleDictation(refined: "retry must not overwrite"), captureID: captureID)

        #expect(first.id == second.id)
        #expect(second.refined == "original")
        #expect(try store.dictations(captureID: captureID).count == 1)
    }

    @Test func nilCaptureIdentityDoesNotDeduplicateDictations() async throws {
        let store = try LibraryStore.temporary()

        let first = try store.record(sampleDictation(refined: "first"), captureID: nil)
        let second = try store.record(sampleDictation(refined: "second"), captureID: nil)

        #expect(first.id != second.id)
    }

    private func sampleDictation(refined: String) -> Dictation {
        Dictation(
            id: 0, timestamp: Date(timeIntervalSince1970: 1_234),
            sourceLanguage: SourceLanguage("en"), requestedOutputLanguage: .sameAsSpoken,
            templateName: "Clean", transcript: "hello", refined: refined,
            engine: "local", sourceID: nil, captureID: nil
        )
    }
}
