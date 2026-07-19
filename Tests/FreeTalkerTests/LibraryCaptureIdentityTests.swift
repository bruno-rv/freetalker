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

    /// `AppCoordinator.reprocess` sets `suppressMining: true` on this overload (the one it calls)
    /// so a fresh post-processing pass over an ALREADY-mined transcript/refined pair doesn't mine
    /// (and inflate the recurrence of) the same correction a second time. See Codex finding
    /// (AppCoordinator.swift:3944).
    @Test func suppressMiningSkipsTheOnDictationRecordedHook() throws {
        let store = try LibraryStore.temporary()
        var firedCount = 0
        store.onDictationRecorded = { _ in firedCount += 1 }

        try store.record(language: "en", template: "Clean", transcript: "hi joao", refined: "hi João", engine: "local", suppressMining: true)

        #expect(firedCount == 0)
    }

    @Test func miningStillFiresByDefaultForNonReprocessedRows() throws {
        let store = try LibraryStore.temporary()
        var firedCount = 0
        store.onDictationRecorded = { _ in firedCount += 1 }

        try store.record(language: "en", template: "Clean", transcript: "hi joao", refined: "hi João", engine: "local")

        #expect(firedCount == 1)
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
