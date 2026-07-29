import Foundation
import Testing
@testable import FreeTalker

/// Two-phase insertion (docs/perf-dictation-latency-2026-07-29.md, fix 1): the raw transcript is
/// inserted as soon as STT finishes and replaced in place once post-processing returns, so a
/// 2–33 s variable-latency cloud call is no longer paid before ANY text reaches the document.
/// Every path that doesn't run a cloud post-processor — Raw, local Apple FM, translation — keeps
/// the single-insert behavior it has today.
@MainActor
@Suite("Two-phase insertion", .serialized)
struct TwoPhaseInsertionTests {
    @Test func cloudPostProcessingInsertsRawThenReplacesItWithRefined() async throws {
        let handler = EarlyInsertionSpy()
        var singlePhaseInserts: [String] = []
        var recorded: RecordingProcessingResult?

        let result = try await AppCoordinator.shared.processDictation(
            samples: [0.5], engine: PipelineEngineSpy(output: .init(text: "raw source", language: "pt")),
            engineName: "Spy", template: Self.template, outputLanguage: .sameAsSpoken,
            processor: PipelinePostProcessorSpy(output: "clean source"),
            earlyInsertion: handler.handler,
            insert: { text, _ in singlePhaseInserts.append(text); return true },
            record: { recorded = $0 }
        )

        #expect(handler.insertedRaw == ["raw source"])
        #expect(handler.replaced == ["clean source"])
        // Phase 2's own paste restores the clipboard; nothing else should.
        #expect(handler.clipboardRestores == 0)
        #expect(singlePhaseInserts.isEmpty)
        #expect(result.refinementDelivery == .replaced)
        #expect(result.posted)
        #expect(recorded?.finalOutput == "clean source")
        #expect(recorded?.rawTranscript == "raw source")
    }

    @Test func bothPhasesRunBeforeTheDictationIsRecorded() async throws {
        // The two-phase path bypasses the `insert:` closure (`Insertion.insertTrackingCorrection`),
        // so the Correction Loop's pending snapshot comes from phase 2's own re-note instead. That
        // only promotes to the right dictation if both phases are done by the time `record()` —
        // which calls `trackCorrectionForRecordedDictation` in production — runs.
        let handler = EarlyInsertionSpy()
        var order: [String] = []
        handler.onInsertRaw = { order.append("phase1") }
        handler.onReplace = { order.append("phase2") }

        _ = try await AppCoordinator.shared.processDictation(
            samples: [0.5], engine: PipelineEngineSpy(output: .init(text: "raw source", language: "pt")),
            engineName: "Spy", template: Self.template, outputLanguage: .sameAsSpoken,
            processor: PipelinePostProcessorSpy(output: "clean source"),
            earlyInsertion: handler.handler,
            insert: { _, _ in true },
            record: { _ in order.append("record") }
        )

        #expect(order == ["phase1", "phase2", "record"])
    }

    @Test func failedReplacementLeavesRawInPlaceAndReportsIt() async throws {
        let handler = EarlyInsertionSpy(replaceSucceeds: false)
        var singlePhaseInserts: [String] = []

        let result = try await AppCoordinator.shared.processDictation(
            samples: [0.5], engine: PipelineEngineSpy(output: .init(text: "raw source", language: "pt")),
            engineName: "Spy", template: Self.template, outputLanguage: .sameAsSpoken,
            processor: PipelinePostProcessorSpy(output: "clean source"),
            earlyInsertion: handler.handler,
            insert: { text, _ in singlePhaseInserts.append(text); return true },
            record: { _ in }
        )

        // The raw transcript is already in the document — re-pasting the refined text through the
        // single-phase closure would append a second copy rather than replace the first.
        #expect(singlePhaseInserts.isEmpty)
        #expect(result.refinementDelivery == .rawLeftInPlace)
        #expect(result.posted)
        // `.rawLeftInPlace` deliberately leaves the refined text on the clipboard for a manual
        // paste — restoring the old clipboard here would contradict the HUD.
        #expect(handler.clipboardRestores == 0)
    }

    @Test func untrackableEarlyInsertFallsBackToTheSinglePhasePaste() async throws {
        let handler = EarlyInsertionSpy(receipt: nil)
        var singlePhaseInserts: [String] = []

        let result = try await AppCoordinator.shared.processDictation(
            samples: [0.5], engine: PipelineEngineSpy(output: .init(text: "raw source", language: "pt")),
            engineName: "Spy", template: Self.template, outputLanguage: .sameAsSpoken,
            processor: PipelinePostProcessorSpy(output: "clean source"),
            earlyInsertion: handler.handler,
            insert: { text, _ in singlePhaseInserts.append(text); return true },
            record: { _ in }
        )

        #expect(handler.replaced.isEmpty)
        #expect(singlePhaseInserts == ["clean source"])
        #expect(result.refinementDelivery == .notApplicable)
    }

    @Test func unchangedTextSkipsTheReplacementPaste() async throws {
        // Post-processing fell back to the raw transcript (`applyPostProcessing`'s never-lose-the-
        // user's-words path). The document already holds exactly that text.
        let handler = EarlyInsertionSpy()

        let result = try await AppCoordinator.shared.processDictation(
            samples: [0.5], engine: PipelineEngineSpy(output: .init(text: "raw source", language: "pt")),
            engineName: "Spy", template: Self.template, outputLanguage: .sameAsSpoken,
            processor: PipelinePostProcessorSpy(output: "raw source"),
            earlyInsertion: handler.handler,
            insert: { _, _ in true }, record: { _ in }
        )

        #expect(handler.insertedRaw == ["raw source"])
        #expect(handler.replaced.isEmpty)
        #expect(result.refinementDelivery == .replaced)
        // No phase 2 paste runs here, so this is the only thing that can give the user back the
        // clipboard phase 1 took over.
        #expect(handler.clipboardRestores == 1)
    }

    @Test func cancellationBetweenThePhasesRestoresTheClipboardAndDropsTheCorrectionTarget() async throws {
        let handler = EarlyInsertionSpy()
        // Stand in for whatever the Correction Loop was tracking before this dictation: phase 1's
        // paste means it is no longer the most recent thing on screen, and this dictation never
        // reaches `record()` to supply an id of its own.
        RecentInsertionStore.shared.notePending(.init(
            target: InsertionTarget(bundleID: "com.example", pid: 1, focusedElement: nil, window: nil),
            baselineValue: "", anchor: 0, text: "older dictation"
        ))
        RecentInsertionStore.shared.attachDictationID(42)
        defer { RecentInsertionStore.shared.reset() }

        await #expect(throws: CancellationError.self) {
            try await AppCoordinator.shared.processDictation(
                samples: [0.5], engine: PipelineEngineSpy(output: .init(text: "raw source", language: "pt")),
                engineName: "Spy", template: Self.template, outputLanguage: .sameAsSpoken,
                processor: PipelineCancellingProcessorSpy(),
                earlyInsertion: handler.handler,
                insert: { _, _ in true }, record: { _ in }
            )
        }

        #expect(handler.insertedRaw == ["raw source"])
        #expect(handler.replaced.isEmpty)
        #expect(handler.clipboardRestores == 1)
        #expect(RecentInsertionStore.shared.current == nil)
    }

    @Test func rawDictationNeverInsertsTwice() async throws {
        let handler = EarlyInsertionSpy()
        var singlePhaseInserts: [String] = []

        let result = try await AppCoordinator.shared.processDictation(
            samples: [0.5], engine: PipelineEngineSpy(output: .init(text: "raw source", language: "pt")),
            engineName: "Spy", template: Self.template, skipPostProcessing: true,
            outputLanguage: .sameAsSpoken, processor: PipelinePostProcessorSpy(output: "unused"),
            earlyInsertion: handler.handler,
            insert: { text, _ in singlePhaseInserts.append(text); return true },
            record: { _ in }
        )

        #expect(handler.insertedRaw.isEmpty)
        #expect(singlePhaseInserts == ["raw source"])
        #expect(result.refinementDelivery == .notApplicable)
    }

    @Test func translationNeverInsertsTwice() async throws {
        let handler = EarlyInsertionSpy()
        var singlePhaseInserts: [String] = []

        let result = try await AppCoordinator.shared.processDictation(
            samples: [0.5], engine: PipelineEngineSpy(output: .init(text: "raw source", language: "en")),
            engineName: "Spy", template: Self.template, outputLanguage: .german,
            cloudSnapshot: Self.snapshot, processor: PipelinePostProcessorSpy(output: "unused"),
            translator: PipelineTranslationSpy(output: "translated"),
            earlyInsertion: handler.handler,
            insert: { text, _ in singlePhaseInserts.append(text); return true },
            record: { _ in }
        )

        #expect(handler.insertedRaw.isEmpty)
        #expect(singlePhaseInserts == ["translated"])
        #expect(result.refinementDelivery == .notApplicable)
    }

    // MARK: - Gate

    @Test func gateOpensOnlyForACloudPostProcessedExternalPaste() {
        #expect(AppCoordinator.shouldUseTwoPhaseInsertion(
            hasLiveStreamingSession: false, skipPostProcessing: false, outputLanguage: .sameAsSpoken,
            voiceCommandsEnabled: false, hasTarget: true, processor: Self.cloudProcessor
        ))
    }

    @Test func gateClosesForLocalAndRawAndCommandPaths() {
        // The user's constraint: nothing that doesn't call a cloud LLM changes behavior.
        #expect(!AppCoordinator.shouldUseTwoPhaseInsertion(
            hasLiveStreamingSession: false, skipPostProcessing: false, outputLanguage: .sameAsSpoken,
            voiceCommandsEnabled: false, hasTarget: true, processor: AppleFMProcessor()
        ))
        #expect(!AppCoordinator.shouldUseTwoPhaseInsertion(
            hasLiveStreamingSession: false, skipPostProcessing: false, outputLanguage: .sameAsSpoken,
            voiceCommandsEnabled: false, hasTarget: true, processor: nil
        ))
        #expect(!AppCoordinator.shouldUseTwoPhaseInsertion(
            hasLiveStreamingSession: false, skipPostProcessing: true, outputLanguage: .sameAsSpoken,
            voiceCommandsEnabled: false, hasTarget: true, processor: Self.cloudProcessor
        ))
        // Voice commands: the raw transcript still contains the literal spoken keywords, and
        // post-processing is what strips them. A failed replacement would strand them on screen.
        #expect(!AppCoordinator.shouldUseTwoPhaseInsertion(
            hasLiveStreamingSession: false, skipPostProcessing: false, outputLanguage: .sameAsSpoken,
            voiceCommandsEnabled: true, hasTarget: true, processor: Self.cloudProcessor
        ))
        // Streaming ASR already typed partials into the document; it owns its own ledger.
        #expect(!AppCoordinator.shouldUseTwoPhaseInsertion(
            hasLiveStreamingSession: true, skipPostProcessing: false, outputLanguage: .sameAsSpoken,
            voiceCommandsEnabled: false, hasTarget: true, processor: Self.cloudProcessor
        ))
        #expect(!AppCoordinator.shouldUseTwoPhaseInsertion(
            hasLiveStreamingSession: false, skipPostProcessing: false, outputLanguage: .german,
            voiceCommandsEnabled: false, hasTarget: true, processor: Self.cloudProcessor
        ))
        #expect(!AppCoordinator.shouldUseTwoPhaseInsertion(
            hasLiveStreamingSession: false, skipPostProcessing: false, outputLanguage: .sameAsSpoken,
            voiceCommandsEnabled: false, hasTarget: false, processor: Self.cloudProcessor
        ))
    }

    private static let template = Template(id: "plain", name: "Plain", prompt: "Clean it")
    private static let snapshot = CloudLLMSettingsSnapshot(
        provider: .anthropic, baseURL: "https://example.com", model: "model", key: "key", vocabulary: []
    )
    private static var cloudProcessor: CloudLLMProcessor { CloudLLMProcessor(snapshot: snapshot) }
}

@MainActor
private final class EarlyInsertionSpy {
    private(set) var insertedRaw: [String] = []
    private(set) var replaced: [String] = []
    private(set) var clipboardRestores = 0
    var onInsertRaw: () -> Void = {}
    var onReplace: () -> Void = {}
    private let receipt: Insertion.EarlyInsertionReceipt?
    private let replaceSucceeds: Bool

    init(receipt: Insertion.EarlyInsertionReceipt? = .init(
        target: InsertionTarget(bundleID: "com.example", pid: 1, focusedElement: nil, window: nil),
        text: "raw source", baselineValue: "", anchor: 0, savedPasteboard: []
    ), replaceSucceeds: Bool = true) {
        self.receipt = receipt
        self.replaceSucceeds = replaceSucceeds
    }

    var handler: EarlyInsertionHandler {
        EarlyInsertionHandler(
            insertRaw: { [self] text in
                insertedRaw.append(text)
                onInsertRaw()
                return receipt
            },
            replace: { [self] text, _ in
                replaced.append(text)
                onReplace()
                return replaceSucceeds
            },
            restoreClipboard: { [self] _ in clipboardRestores += 1 }
        )
    }
}

private actor PipelineEngineSpy: TranscriptionEngine {
    nonisolated let name = "Spy"
    nonisolated var statusText: String { "Ready" }
    private let output: TranscriptionOutput

    init(output: TranscriptionOutput) { self.output = output }

    func transcribe(samples: [Float], forcedLanguage: String?, candidateLanguages: [String], vocabulary: [String]) async throws -> TranscriptionOutput {
        output
    }
}

private actor PipelinePostProcessorSpy: PostProcessor {
    private let output: String
    init(output: String) { self.output = output }
    func process(_ request: PostProcessingRequest) async throws -> String { output }
}

private actor PipelineCancellingProcessorSpy: PostProcessor {
    func process(_ request: PostProcessingRequest) async throws -> String { throw CancellationError() }
}

private actor PipelineTranslationSpy: Translating {
    private let output: String
    init(output: String) { self.output = output }

    func process(source: String, template: Template, policy: OutputProcessingPolicy, snapshot: CloudLLMSettingsSnapshot) async throws -> String {
        output
    }
}
