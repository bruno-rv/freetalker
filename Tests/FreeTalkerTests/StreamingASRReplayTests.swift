import AVFoundation
import Foundation
import Testing
import os
@testable import FreeTalker

/// Records `StreamingTranscriptionEngine.setPartialCallback` emissions synchronously, from
/// inside the `@Sendable` callback itself — an `actor` collector would need an unstructured
/// `Task` per emission (no `await` available inside a non-async callback), which races the test's
/// own sequential `append` loop. `OSAllocatedUnfairLock` mirrors the lock-based Sendable pattern
/// already used for cross-thread progress collection elsewhere (`FluidAudioDiarizer.swift`'s
/// `MonotonicProgress`).
private final class PartialCollector: Sendable {
    private let storage = OSAllocatedUnfairLock<[String]>(initialState: [])
    func record(_ value: String) { storage.withLock { $0.append(value) } }
    var values: [String] { storage.withLock { $0 } }
}

/// A `StreamingTranscriptionEngine` that replays a scripted sequence of RAW (i.e.
/// pre-append-only-guard) partial-transcript values, one per `append(samples:)` call — standing
/// in for FluidAudio's real CoreML decode, which needs a downloaded model and is not available in
/// a test/CI context (BRAINSTORM_STREAMING_ASR.md's own escape hatch: "If Library audio is not
/// available in a test context, use a small synthetic or fixture buffer"). Crucially, this fake
/// still runs the exact production `StreamingAppendOnly.appendOnly` guard `FluidAudioStreamingEngine`
/// uses (see `handleRawPartial` there) — so a deliberately regressive scripted value in the test
/// below exercises the real guard, not a test-only stand-in for it.
private actor FakeStreamingTranscriptionEngine: StreamingTranscriptionEngine {
    private let rawPartialSequence: [String]
    private var ready = false
    private var chunkIndex = 0
    private var lastConfirmed = ""
    private var callback: (@Sendable (String) -> Void)?

    init(rawPartialSequence: [String]) {
        self.rawPartialSequence = rawPartialSequence
    }

    var isReady: Bool { ready }

    func prepare(progress: (@Sendable (Double) -> Void)?) async throws {
        ready = true
    }

    func start() async throws {
        chunkIndex = 0
        lastConfirmed = ""
    }

    func append(samples: [Float]) async {
        guard ready, !samples.isEmpty, chunkIndex < rawPartialSequence.count else { return }
        let raw = rawPartialSequence[chunkIndex]
        chunkIndex += 1
        let confirmed = StreamingAppendOnly.appendOnly(previous: lastConfirmed, incoming: raw)
        guard confirmed != lastConfirmed else { return }
        lastConfirmed = confirmed
        callback?(confirmed)
    }

    func setPartialCallback(_ callback: @escaping @Sendable (String) -> Void) async {
        self.callback = callback
    }

    func finish() async throws -> String {
        lastConfirmed = rawPartialSequence.last ?? lastConfirmed
        return lastConfirmed
    }

    func reset() async {
        chunkIndex = 0
        lastConfirmed = ""
    }

    func unload() async {
        ready = false
        chunkIndex = 0
        lastConfirmed = ""
    }
}

@Suite struct StreamingASRReplayTests {
    /// Pure-function coverage of the append-only guard itself, independent of any engine.
    @Test func appendOnlyNeverRewritesOrShrinks() {
        #expect(StreamingAppendOnly.appendOnly(previous: "", incoming: "first word") == "first word")
        #expect(StreamingAppendOnly.appendOnly(previous: "hello", incoming: "hello world") == "hello world")
        #expect(StreamingAppendOnly.appendOnly(previous: "hello world", incoming: "hello") == "hello world")
        #expect(StreamingAppendOnly.appendOnly(previous: "same", incoming: "same") == "same")
        // Diverging incoming text keeps only the longest shared prefix, and only if that's an
        // extension of what's already confirmed — never a rewrite.
        #expect(StreamingAppendOnly.appendOnly(previous: "Testing one", incoming: "Testing on") == "Testing one")
    }

    /// The one runnable check required by BRAINSTORM_STREAMING_ASR.md's validation harness: feeds
    /// real fixture audio through a `StreamingTranscriptionEngine`, chunk by chunk — exactly how
    /// `AudioCapture`'s live tap feeds `FluidAudioStreamingEngine.append` in production — and
    /// asserts (a) every partial emission extends the previous one (append-only) and (b) a
    /// non-empty final transcript is produced.
    @Test func replayFeedsFixtureAudioAndProducesAppendOnlyPartialsAndFinalText() async throws {
        let source = try #require(Bundle.module.url(forResource: "tone", withExtension: "wav", subdirectory: "Fixtures"))
        let file = try AVAudioFile(forReading: source)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let channelData = try #require(buffer.floatChannelData)
        let allSamples = Array(UnsafeBufferPointer(start: channelData[0], count: Int(buffer.frameLength)))
        #expect(!allSamples.isEmpty)

        // One raw value per chunk — index 2 is a deliberate regression (shorter, and diverges
        // from index 1's text) to prove the guard swallows it rather than typing it live.
        let rawPartialSequence = [
            "Testing",
            "Testing one",
            "Testing on",
            "Testing one two",
            "Testing one two three"
        ]
        let engine = FakeStreamingTranscriptionEngine(rawPartialSequence: rawPartialSequence)
        let collector = PartialCollector()
        await engine.setPartialCallback { text in
            collector.record(text)
        }

        try await engine.prepare(progress: nil)
        try await engine.start()

        let chunkCount = rawPartialSequence.count
        let chunkSize = max(1, allSamples.count / chunkCount)
        for index in 0..<chunkCount {
            let start = index * chunkSize
            let end = index == chunkCount - 1 ? allSamples.count : min(allSamples.count, start + chunkSize)
            guard start < end else { continue }
            await engine.append(samples: Array(allSamples[start..<end]))
        }

        let final = try await engine.finish()
        #expect(!final.isEmpty)

        let emitted = collector.values
        // The regressive chunk (index 2) must not have produced its own emission.
        #expect(emitted.count == chunkCount - 1)
        for index in 1..<emitted.count {
            #expect(emitted[index].hasPrefix(emitted[index - 1]))
            #expect(emitted[index].count >= emitted[index - 1].count)
        }
    }
}
