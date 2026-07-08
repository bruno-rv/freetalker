import Foundation
import Testing
@testable import FreeTalker

/// PLAN.md step 8: "each stage leaves one runnable check" — FTS search roundtrip and template
/// seeding, run via `swift test`.
struct FreeTalkerTests {
    @Test func templatesSeedFourBuiltIns() {
        let templates = Template.builtIns
        #expect(templates.count == 4)
        #expect(templates.contains { $0.id == Template.defaultID })
        #expect(Set(templates.map(\.id)).count == templates.count) // unique ids
    }

    @Test func ftsSearchRoundTrip() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbURL = tempDir.appendingPathComponent("test.db")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try Database(path: dbURL)
        let id = try db.insertDictation(
            timestamp: Date(),
            language: "en",
            template: "Clean Dictation",
            transcript: "the quick brown fox jumps over the lazy dog",
            refined: "The quick brown fox jumps over the lazy dog.",
            engine: "WhisperKit"
        )
        #expect(id > 0)

        let hits = try db.searchDictations(query: "brown fox")
        #expect(hits.contains { $0.id == id })

        let misses = try db.searchDictations(query: "nonexistent-zzz-term")
        #expect(!misses.contains { $0.id == id })
    }

    /// Round 2 Codex finding 8: exercises the *actual* `AppCoordinator.processDictation` pipeline
    /// (the same method `runPipeline` calls) with a fake engine/processor, a no-CGEvent insert
    /// hook, and a record hook pointed at a temp DB instead of the user's real Library — not a
    /// hand-rolled re-implementation of the contract. `FakeTranscriptionEngine`/
    /// `PassthroughPostProcessor`/`EmptyPostProcessor` are shared with SelfCheck.swift via
    /// `@testable import`. Compile-only in this CLT-only environment — see README.md "Running
    /// tests" — but kept in sync with SelfCheck's runnable duplicate.
    @Test @MainActor func pipelineContractFakeEngineToLibraryRow() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let db = try Database(path: tempDir.appendingPathComponent("pipeline-contract.db"))

        let cannedSamples: [Float] = [0.1, -0.2, 0.05, 0.3]
        let fakeEngine = FakeTranscriptionEngine(cannedText: "the quick brown fox jumps over the lazy dog")
        let template = Template.builtIns.first!
        let recordToTempDB: (String, String, String, String, String) throws -> Void = { language, templateName, transcript, refined, engine in
            try db.insertDictation(timestamp: Date(), language: language, template: templateName, transcript: transcript, refined: refined, engine: engine)
        }

        // (a) canned samples -> non-empty transcript -> refined lands in a Library row.
        let resultA = try await AppCoordinator.shared.processDictation(
            samples: cannedSamples,
            engine: fakeEngine,
            engineName: fakeEngine.name,
            template: template,
            processor: PassthroughPostProcessor(),
            insert: { _ in true },
            record: recordToTempDB
        )
        #expect(!resultA.refined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        let rows = try db.allDictations()
        #expect(rows.contains { $0.transcript == resultA.transcript && $0.refined == resultA.refined })

        // (b) empty-refined post-processor output falls back to the raw transcript.
        let resultB = try await AppCoordinator.shared.processDictation(
            samples: cannedSamples,
            engine: fakeEngine,
            engineName: fakeEngine.name,
            template: template,
            processor: EmptyPostProcessor(),
            insert: { _ in true },
            record: recordToTempDB
        )
        #expect(resultB.refined == resultB.transcript)
    }
}
