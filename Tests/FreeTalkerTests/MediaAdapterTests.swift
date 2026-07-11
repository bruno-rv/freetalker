import Foundation
import Testing
@testable import FreeTalker

@Suite struct MediaAdapterTests {
    @Test func timestampedAdapterForwardsRequestedFileLanguageAndModelAndPreservesSegments() async throws {
        let backend = WhisperBackendProbe(result: .success([
            .init(start: 0.25, end: 1.5, text: "  Hello  "),
            .init(start: 1.5, end: 2.75, text: "world")
        ]))
        let adapter = TimestampedWhisperTranscriber(backend: backend)
        let url = URL(fileURLWithPath: "/tmp/job.wav")

        let result = try await adapter.transcribeFile(at: url, language: "pt", model: "openai_whisper-large-v3-v20240930_turbo")

        #expect(result == [
            .init(start: 0.25, end: 1.5, text: "  Hello  "),
            .init(start: 1.5, end: 2.75, text: "world")
        ])
        #expect(await backend.request == .init(url: url, language: "pt", model: "openai_whisper-large-v3-v20240930_turbo"))
    }

    @Test func timestampedAdapterAllowsEmptyOutput() async throws {
        let adapter = TimestampedWhisperTranscriber(backend: WhisperBackendProbe(result: .success([])))
        #expect(try await adapter.transcribeFile(at: URL(fileURLWithPath: "/tmp/empty.wav"), language: nil, model: "tiny").isEmpty)
    }

    @Test(arguments: [
        RawTranscriptSegment(start: .nan, end: 1, text: "nan"),
        RawTranscriptSegment(start: 0, end: .infinity, text: "infinite"),
        RawTranscriptSegment(start: -1, end: 1, text: "negative"),
        RawTranscriptSegment(start: 2, end: 1, text: "reversed"),
        RawTranscriptSegment(start: 1, end: 1, text: "zero")
    ])
    func timestampedAdapterRejectsMalformedTimestamps(_ malformed: RawTranscriptSegment) async {
        let adapter = TimestampedWhisperTranscriber(backend: WhisperBackendProbe(result: .success([malformed])))
        await #expect(throws: MediaAdapterError.invalidTranscriptSegment(index: 0)) {
            try await adapter.transcribeFile(at: URL(fileURLWithPath: "/tmp/bad.wav"), language: nil, model: "tiny")
        }
    }

    @Test func timestampedAdapterPropagatesAvailabilityErrorsTruthfully() async {
        let expected = AdapterProbeError.modelUnavailable("missing model")
        let adapter = TimestampedWhisperTranscriber(backend: WhisperBackendProbe(result: .failure(expected)))
        await #expect(throws: expected) {
            try await adapter.transcribeFile(at: URL(fileURLWithPath: "/tmp/a.wav"), language: nil, model: "missing")
        }
    }

    @Test func timestampedAdapterCancelsPromptly() async throws {
        let backend = WhisperBackendProbe(result: .suspend)
        let task = Task { try await TimestampedWhisperTranscriber(backend: backend).transcribeFile(at: URL(fileURLWithPath: "/tmp/a.wav"), language: nil, model: "tiny") }
        await backend.waitUntilStarted()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        await backend.waitUntilCancelled()
    }

    @Test func diarizerMapsSpeakerIDsTimestampsAndMonotonicProgress() async throws {
        let backend = DiarizerBackendProbe(result: .success([
            .init(speakerID: "S2", start: 2, end: 3),
            .init(speakerID: "S1", start: 0, end: 2)
        ]), progressValues: [0.4, 0.2, 1])
        let progress = LockedValues<Double>()
        let url = URL(fileURLWithPath: "/tmp/job.wav")

        let result = try await FluidAudioDiarizer(backend: backend).diarizeFile(at: url) { progress.append($0) }

        #expect(result == [
            .init(speakerID: "S2", start: 2, end: 3),
            .init(speakerID: "S1", start: 0, end: 2)
        ])
        #expect(await backend.url == url)
        #expect(progress.values == [0, 0.4, 0.4, 1])
    }

    @Test func diarizerAllowsEmptyOutputAndRejectsMalformedTurns() async throws {
        #expect(try await FluidAudioDiarizer(backend: DiarizerBackendProbe(result: .success([]))).diarizeFile(at: URL(fileURLWithPath: "/tmp/silence.wav")) { _ in }.isEmpty)
        let malformed = RawSpeakerTurn(speakerID: "", start: 0, end: 1)
        await #expect(throws: MediaAdapterError.invalidSpeakerTurn(index: 0)) {
            try await FluidAudioDiarizer(backend: DiarizerBackendProbe(result: .success([malformed]))).diarizeFile(at: URL(fileURLWithPath: "/tmp/bad.wav")) { _ in }
        }
    }

    @Test func diarizerPropagatesModelDownloadFailureAndCancellation() async throws {
        let expected = AdapterProbeError.modelUnavailable("offline models missing")
        await #expect(throws: expected) {
            try await FluidAudioDiarizer(backend: DiarizerBackendProbe(result: .failure(expected))).diarizeFile(at: URL(fileURLWithPath: "/tmp/a.wav")) { _ in }
        }

        let backend = DiarizerBackendProbe(result: .suspend)
        let task = Task { try await FluidAudioDiarizer(backend: backend).diarizeFile(at: URL(fileURLWithPath: "/tmp/a.wav")) { _ in } }
        await backend.waitUntilStarted()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        await backend.waitUntilCancelled()
    }
}

private enum AdapterProbeError: Error, Equatable { case modelUnavailable(String) }

private actor WhisperBackendProbe: WhisperFileTranscriptionBackend {
    enum Result: Sendable { case success([RawTranscriptSegment]); case failure(AdapterProbeError); case suspend }
    let result: Result
    private(set) var request: WhisperFileRequest?
    private(set) var cancelled = false
    private var started = false
    init(result: Result) { self.result = result }
    func transcribeFile(_ request: WhisperFileRequest) async throws -> [RawTranscriptSegment] {
        self.request = request; started = true
        switch result {
        case .success(let value): return value
        case .failure(let error): throw error
        case .suspend:
            do { try await Task.sleep(for: .seconds(60)); return [] }
            catch { cancelled = true; throw error }
        }
    }
    func waitUntilStarted() async { while !started { await Task.yield() } }
    func waitUntilCancelled() async { while !cancelled { await Task.yield() } }
}

private actor DiarizerBackendProbe: SpeakerDiarizationBackend {
    enum Result: Sendable { case success([RawSpeakerTurn]); case failure(AdapterProbeError); case suspend }
    let result: Result
    let progressValues: [Double]
    private(set) var url: URL?
    private(set) var cancelled = false
    private var started = false
    init(result: Result, progressValues: [Double] = []) { self.result = result; self.progressValues = progressValues }
    func diarizeFile(at url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> [RawSpeakerTurn] {
        self.url = url; started = true
        for value in progressValues { progress(value) }
        switch result {
        case .success(let value): return value
        case .failure(let error): throw error
        case .suspend:
            do { try await Task.sleep(for: .seconds(60)); return [] }
            catch { cancelled = true; throw error }
        }
    }
    func waitUntilStarted() async { while !started { await Task.yield() } }
    func waitUntilCancelled() async { while !cancelled { await Task.yield() } }
}

private final class LockedValues<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []
    var values: [Value] { lock.withLock { storage } }
    func append(_ value: Value) { lock.withLock { storage.append(value) } }
}
