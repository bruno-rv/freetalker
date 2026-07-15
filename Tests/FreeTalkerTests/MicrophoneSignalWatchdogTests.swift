import Foundation
import Testing
@testable import FreeTalker

@Suite struct MicrophoneSignalWatchdogTests {
    @Test("initial zero samples warn but silence alone never restarts")
    func initialSilenceOnlyWarns() {
        var watchdog = MicrophoneSignalWatchdog()
        #expect(watchdog.observe(peak: 0, rms: 0, fault: nil) == .continueRecording)
        #expect(watchdog.observe(peak: 0, rms: 0, fault: nil) == .continueRecording)
        #expect(watchdog.observe(peak: 0, rms: 0, fault: nil) == .warnNoSignal)
        #expect(watchdog.observe(peak: 0, rms: 0, fault: nil) == .continueRecording)
        #expect(!watchdog.hasObservedSignal)
    }

    @Test("valid signal permanently clears silent classification")
    func validThenZero() {
        var watchdog = MicrophoneSignalWatchdog()
        _ = watchdog.observe(peak: 0, rms: 0, fault: nil)
        #expect(watchdog.observe(peak: 0.2, rms: 0.1, fault: nil) == .continueRecording)
        #expect(watchdog.observe(peak: 0, rms: 0, fault: nil) == .continueRecording)
        #expect(watchdog.hasObservedSignal)
        #expect(!watchdog.isSilentAttempt)
    }

    @Test("route fault after valid signal does not restart")
    func validSignalThenFault() {
        let id = UUID()
        var watchdog = MicrophoneSignalWatchdog(captureID: id)
        _ = watchdog.observe(peak: 0.2, rms: 0.1, fault: nil)
        #expect(watchdog.observe(
            peak: 0, rms: 0,
            fault: .inputRoute(captureID: id, message: "route changed")
        ) == .continueRecording)
        #expect(!watchdog.didRequestRestart)
    }

    @Test("corroborated route fault restarts once only")
    func oneRestartOnly() {
        let id = UUID()
        var watchdog = MicrophoneSignalWatchdog(captureID: id)
        #expect(watchdog.observe(peak: 0, rms: 0, fault: .inputRoute(captureID: id, message: "input vanished")) == .restartForRouteFailure("input vanished"))
        #expect(watchdog.observe(peak: 0, rms: 0, fault: .engine(captureID: id, message: "engine stopped")) == .continueRecording)
        #expect(watchdog.routeFailure == "input vanished")
    }

    @Test("stale capture fault is ignored")
    func staleFaultIgnored() {
        var watchdog = MicrophoneSignalWatchdog(captureID: UUID())
        #expect(watchdog.observe(peak: 0, rms: 0, fault: .engine(captureID: UUID(), message: "old engine")) == .continueRecording)
        #expect(!watchdog.didRequestRestart)
    }

    @Test("incremental metrics stay bounded regardless of callback count")
    func callbackStateIsBounded() {
        var watchdog = MicrophoneSignalWatchdog()
        for _ in 0..<100_000 {
            _ = watchdog.observe(samples: [0, 0, 0, 0])
        }
        #expect(watchdog.observationCount == 100_000)
        #expect(watchdog.peak == 0)
        #expect(watchdog.rms == 0)
        #expect(watchdog.retainedSampleCount == 0)
    }

    @Test("stop waits for an admitted callback and rejects stale generations")
    func generationGateQuiescesCallbacks() async {
        let gate = AudioCaptureGenerationGate()
        let first = gate.activate()
        #expect(gate.begin(first))
        let stopReturned = LockedFlag()
        let stop = Task.detached {
            gate.deactivateAndWait()
            stopReturned.set()
        }
        await Task.yield()
        #expect(!stopReturned.value)
        gate.finish(first)
        await stop.value
        #expect(stopReturned.value)

        let second = gate.activate()
        #expect(!gate.begin(first))
        #expect(gate.begin(second))
        gate.finish(second)
        gate.deactivateAndWait()
    }

    @Test("all-silent stop uses exact visible non-retryable failure")
    func silentProjection() {
        let capture = CaptureSession(
            id: UUID(), state: .silent, directory: URL(fileURLWithPath: "/recovery/id"),
            capturedAt: Date(), sampleRate: 16_000, channelCount: 1,
            inputDeviceUID: nil, destination: "external", recoveryJobID: nil,
            libraryDictationID: nil, assetKind: .silent,
            failureMessage: SilentCapturePresentation.message, contentHash: nil
        )
        let presentation = SilentCapturePresentation(session: capture)
        #expect(presentation?.message == "No microphone signal was captured.")
        #expect(presentation?.isRetryable == false)
    }

    @Test("silent capture reopens as visible Recovery without processing work")
    @MainActor
    func silentCaptureReopensVisible() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("silent-reopen-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let database = root.appendingPathComponent("jobs.db")
        let captureID = UUID()
        do {
            let store = try TranscriptionJobStore(databaseURL: database, clock: SystemJobClock())
            _ = try await store.createCapture(.init(
                id: captureID, directory: root.appendingPathComponent(captureID.uuidString),
                capturedAt: Date(timeIntervalSince1970: 42), sampleRate: 16_000,
                channelCount: 1, inputDeviceUID: nil, destination: "scratchpad"
            ))
            try await store.transition(
                id: captureID, from: .capturing, to: .silent,
                recoveryJobID: nil, libraryDictationID: nil, assetKind: .silent,
                failureMessage: SilentCapturePresentation.message, contentHash: nil
            )
        }

        let reopened = try TranscriptionJobStore(databaseURL: database, clock: SystemJobClock())
        let library = JobLibraryStore(store: reopened, recoveryDirectory: root)
        try await library.refresh()

        #expect(library.silentCaptures.map(\.id) == [captureID])
        #expect(try await reopened.jobs(kind: .recovery).isEmpty)
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false
    var value: Bool { lock.withLock { storage } }
    func set() { lock.withLock { storage = true } }
}
