import Foundation
import Testing
@testable import FreeTalker

@Suite struct MediaAdapterTests {
    @Test func exactReloadUsesRequestedModelInsteadOfGlobalSelection() async throws {
        let controller = ModelReloadController<String>()
        let loaded = AdapterStringProbe()
        try await controller.reloadExact(to: "requested-small") { model in
            await loaded.record(model); return model
        } event: { _, _ in } didInstall: { _ in }
        #expect(await loaded.values == ["requested-small"])
        #expect(controller.state.snapshot().variant == "requested-small")
    }

    @Test func taskLocalExactModelDoesNotReplaceLiveModel() async throws {
        let controller = ModelReloadController<String>()
        controller.state.installIfEmpty(kit: "live-kit", variant: "global-large")
        let recoveryKit = try await controller.exactModel(to: "recovery-small") { "kit-for-\($0)" }
        #expect(recoveryKit == "kit-for-recovery-small")
        #expect(controller.state.snapshot().kit == "live-kit")
        #expect(controller.state.snapshot().variant == "global-large")
    }
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

    @Test func diarizerDrainsUncancellableBackendAndSuppressesProgressAndResultAfterCancellation() async throws {
        let release = ReleaseProbe()
        let backend = UncancellableDiarizerBackend(release: release)
        let progress = LockedValues<Double>()
        let completion = CompletionProbe()
        let task = Task {
            defer { completion.markComplete() }
            return try await FluidAudioDiarizer(backend: backend).diarizeFile(
                at: URL(fileURLWithPath: "/tmp/long.wav"),
                progress: { progress.append($0) }
            )
        }
        await backend.waitUntilStarted()
        backend.report(0.25)

        task.cancel()
        backend.report(0.75)
        await Task.yield()
        #expect(!completion.isComplete)
        #expect(progress.values == [0, 0.25])
        #expect(!release.wasReleased)

        backend.drain(returning: [.init(speakerID: "S1", start: 0, end: 1)])
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(completion.isComplete)
        #expect(release.wasReleased)
        #expect(progress.values == [0, 0.25])
    }

    @Test func modelPreparationSharesConcurrentFirstUsePerDirectory() async throws {
        let coordinator = FluidAudioModelPreparationCoordinator<Int>()
        let loader = ModelLoaderProbe(results: [.success(42)])
        let directory = URL(fileURLWithPath: "/tmp/models")

        async let first = coordinator.model(for: directory) { try await loader.load() }
        async let second = coordinator.model(for: directory) { try await loader.load() }

        #expect(try await (first, second) == (42, 42))
        #expect(await loader.calls == 1)
    }

    @Test func modelPreparationFailureIsRetryableAndDoesNotPoisonCache() async throws {
        let coordinator = FluidAudioModelPreparationCoordinator<Int>()
        let expected = AdapterProbeError.modelUnavailable("download failed")
        let loader = ModelLoaderProbe(results: [.failure(expected), .success(7)])
        let directory = URL(fileURLWithPath: "/tmp/models")

        await #expect(throws: expected) {
            try await coordinator.model(for: directory) { try await loader.load() }
        }
        #expect(try await coordinator.model(for: directory) { try await loader.load() } == 7)
        #expect(await loader.calls == 2)
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

private final class CompletionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var complete = false
    var isComplete: Bool { lock.withLock { complete } }
    func markComplete() { lock.withLock { complete = true } }
}

private final class ReleaseProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var released = false
    var wasReleased: Bool { lock.withLock { released } }
    func markReleased() { lock.withLock { released = true } }
}

private final class HeldResource: @unchecked Sendable {
    let release: ReleaseProbe
    init(release: ReleaseProbe) { self.release = release }
    deinit { release.markReleased() }
}

private final class UncancellableDiarizerBackend: SpeakerDiarizationBackend, @unchecked Sendable {
    private struct State {
        var started = false
        var continuation: CheckedContinuation<[RawSpeakerTurn], Never>?
        var progress: (@Sendable (Double) -> Void)?
    }
    private let state = NSLock()
    private var storage = State()
    private let release: ReleaseProbe
    init(release: ReleaseProbe) { self.release = release }
    func diarizeFile(at url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> [RawSpeakerTurn] {
        let resource = HeldResource(release: release)
        defer { _fixLifetime(resource) }
        return await withCheckedContinuation { continuation in
            state.withLock {
                storage.started = true
                storage.progress = progress
                storage.continuation = continuation
            }
        }
    }
    func waitUntilStarted() async { while !state.withLock({ storage.started }) { await Task.yield() } }
    func report(_ value: Double) { state.withLock { storage.progress }?(value) }
    func drain(returning turns: [RawSpeakerTurn]) {
        let continuation = state.withLock { () -> CheckedContinuation<[RawSpeakerTurn], Never>? in
            defer { storage.continuation = nil; storage.progress = nil }
            return storage.continuation
        }
        continuation?.resume(returning: turns)
    }
}

private actor ModelLoaderProbe {
    private var results: [Result<Int, AdapterProbeError>]
    private(set) var calls = 0
    init(results: [Result<Int, AdapterProbeError>]) { self.results = results }
    func load() async throws -> Int {
        calls += 1
        await Task.yield()
        return try results.removeFirst().get()
    }
}

private actor AdapterStringProbe {
    private(set) var values: [String] = []
    func record(_ value: String) { values.append(value) }
}
