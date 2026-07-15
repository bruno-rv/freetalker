import Foundation
import Testing
@testable import FreeTalker

@Suite("Capture admission")
struct CaptureAdmissionTests {
    @Test func durablePreparationCompletesBeforeEngineStart() async throws {
        let events = AdmissionEventLog()
        let root = URL(fileURLWithPath: "/recovery")
        let request = CaptureStartRequest(
            id: UUID(), directory: root.appendingPathComponent("capture"),
            capturedAt: Date(timeIntervalSince1970: 1), sampleRate: 16_000,
            channelCount: 1, inputDeviceUID: nil, destination: "external"
        )
        let service = CaptureJournalService(
            fileSystem: AdmissionFileSystem(events: events),
            ledger: AdmissionLedger(request: request, events: events)
        )

        _ = try await service.prepare(request)
        events.append(.startAudioEngine)

        #expect(events.snapshot == [
            .createDirectory, .synchronizeDirectory, .createLedger, .startAudioEngine,
        ])
    }

    @Test func preparationFailureNeverStartsEngine() async {
        let events = AdmissionEventLog()
        let request = CaptureStartRequest(
            id: UUID(), directory: URL(fileURLWithPath: "/recovery/capture"),
            capturedAt: Date(), sampleRate: 16_000, channelCount: 1,
            inputDeviceUID: nil, destination: "external"
        )
        let service = CaptureJournalService(
            fileSystem: AdmissionFileSystem(events: events, failDirectorySync: true),
            ledger: AdmissionLedger(request: request, events: events)
        )

        await #expect(throws: AdmissionFailure.self) { try await service.prepare(request) }

        #expect(events.snapshot == [.createDirectory, .synchronizeDirectory])
    }

    @Test func cancellationIntentPrecedesArtifactsAndLedgerRemoval() async throws {
        let events = AdmissionEventLog()
        let request = CaptureStartRequest(
            id: UUID(), directory: URL(fileURLWithPath: "/recovery/capture"),
            capturedAt: Date(), sampleRate: 16_000, channelCount: 1,
            inputDeviceUID: nil, destination: "external"
        )
        let fileSystem = AdmissionFileSystem(events: events, captureExists: true)
        let ledger = AdmissionLedger(request: request, events: events)
        let service = CaptureJournalService(fileSystem: fileSystem, ledger: ledger)
        let active = try await service.prepare(request)

        try await service.cancelAndClean(active)

        #expect(events.snapshot.suffix(4) == [
            .persistCancellation, .removeArtifacts, .synchronizeDirectory, .removeLedger,
        ])
    }

    @Test func keyUpDuringPreparationStartsThenStopsAfterAdmission() {
        let captureID = UUID()
        var reducer = CaptureAdmissionReducer()

        #expect(reducer.reduce(.begin(captureID: captureID, destination: "external")) == .none)
        #expect(reducer.reduce(.stopRequested) == .none)
        #expect(reducer.reduce(.prepared(captureID: captureID)) == .startAndStop(captureID))
        #expect(reducer.state == .recording(captureID: captureID))
    }

    @Test func cancelDuringPreparationCleansWithoutStartingEngine() {
        let captureID = UUID()
        var reducer = CaptureAdmissionReducer()
        _ = reducer.reduce(.begin(captureID: captureID, destination: "external"))

        #expect(reducer.reduce(.cancelRequested) == .none)
        #expect(reducer.reduce(.prepared(captureID: captureID)) == .cancel(captureID))
        #expect(reducer.state == .cancelling(captureID: captureID))
    }

    @Test func cancelWinsWhenStopAndCancelArriveDuringPreparation() {
        let captureID = UUID()
        var stopThenCancel = CaptureAdmissionReducer()
        _ = stopThenCancel.reduce(.begin(captureID: captureID, destination: "external"))
        _ = stopThenCancel.reduce(.stopRequested)
        _ = stopThenCancel.reduce(.cancelRequested)

        #expect(stopThenCancel.reduce(.prepared(captureID: captureID)) == .cancel(captureID))

        var cancelThenStop = CaptureAdmissionReducer()
        _ = cancelThenStop.reduce(.begin(captureID: captureID, destination: "external"))
        _ = cancelThenStop.reduce(.cancelRequested)
        _ = cancelThenStop.reduce(.stopRequested)

        #expect(cancelThenStop.reduce(.prepared(captureID: captureID)) == .cancel(captureID))
    }

    @Test func preparationFailureReturnsReducerToIdle() {
        let captureID = UUID()
        var reducer = CaptureAdmissionReducer()
        _ = reducer.reduce(.begin(captureID: captureID, destination: "external"))

        #expect(reducer.reduce(.preparationFailed(captureID: captureID, message: "disk full")) == .fail("disk full"))
        #expect(reducer.state == .idle)
    }

    @Test func engineStartFailureAfterPreparationReturnsReducerToIdle() {
        let captureID = UUID()
        var reducer = CaptureAdmissionReducer()
        _ = reducer.reduce(.begin(captureID: captureID, destination: "external"))
        _ = reducer.reduce(.prepared(captureID: captureID))

        #expect(reducer.reduce(.preparationFailed(captureID: captureID, message: "engine failed")) == .fail("engine failed"))
        #expect(reducer.state == .idle)
    }

    @Test func stalePreparationCompletionCannotTakeOverAnewCapture() {
        let current = UUID()
        var reducer = CaptureAdmissionReducer()
        _ = reducer.reduce(.begin(captureID: current, destination: "external"))

        #expect(reducer.reduce(.prepared(captureID: UUID())) == .none)
        #expect(reducer.state.captureID == current)
    }

    @Test func writerFailureResetsOnlyAfterDurableFailureHandlingAndAllowsNextAdmission() {
        let first = UUID()
        var reducer = CaptureAdmissionReducer()
        _ = reducer.reduce(.begin(captureID: first, destination: "external"))
        _ = reducer.reduce(.prepared(captureID: first))

        #expect(reducer.reduce(.failureHandlingStarted(captureID: first)) == .preserveFailure(first))
        #expect(reducer.state == .finalizing(captureID: first))
        #expect(reducer.reduce(.failureHandled(captureID: first)) == .none)
        #expect(reducer.state == .idle)

        let second = UUID()
        _ = reducer.reduce(.begin(captureID: second, destination: "external"))
        #expect(reducer.state.captureID == second)
    }

    @Test func finalizationAndCancellationBlockEveryNewCaptureUntilTerminal() {
        let captureID = UUID()
        var reducer = CaptureAdmissionReducer()
        _ = reducer.reduce(.begin(captureID: captureID, destination: "external"))
        _ = reducer.reduce(.prepared(captureID: captureID))
        _ = reducer.reduce(.stopRequested)

        #expect(reducer.state == .finalizing(captureID: captureID))
        #expect(!AppCoordinator.captureStartDecision(
            current: .dictation, requested: .voiceEdit,
            admissionState: reducer.state
        ).allowsStart)
        _ = reducer.reduce(.finalizationFinished(captureID: captureID))
        #expect(reducer.state == .idle)

        _ = reducer.reduce(.begin(captureID: captureID, destination: "external"))
        _ = reducer.reduce(.cancelRequested)
        #expect(!AppCoordinator.captureStartDecision(
            current: .dictation, requested: .voiceEdit,
            admissionState: reducer.state
        ).allowsStart)
        _ = reducer.reduce(.prepared(captureID: captureID))
        _ = reducer.reduce(.cleanupFinished(captureID: captureID))
        #expect(reducer.state == .idle)
    }

    @Test func cleanupFailureKeepsOwnershipUntilSuccessfulResume() {
        let captureID = UUID()
        var reducer = CaptureAdmissionReducer()
        _ = reducer.reduce(.begin(captureID: captureID, destination: "external"))
        _ = reducer.reduce(.cancelRequested)
        _ = reducer.reduce(.prepared(captureID: captureID))

        #expect(reducer.reduce(.cleanupFailed(captureID: captureID, message: "disk busy")) == .fail("disk busy"))
        #expect(reducer.state == .cleanupFailed(captureID: captureID, message: "disk busy"))
        #expect(reducer.reduce(.cleanupFinished(captureID: captureID)) == .none)
        #expect(reducer.state == .idle)
    }

    @Test func escapeDispatchRemainsActiveAfterStopDuringPreparation() {
        #expect(HotKeyManager.shouldSwallowEscape(
            keyCode: HotKeyManager.escapeKeyCode,
            isRecording: false,
            isCaptureLifecycleActive: true
        ))
        #expect(!HotKeyManager.shouldSwallowEscape(
            keyCode: HotKeyManager.escapeKeyCode,
            isRecording: false,
            isCaptureLifecycleActive: false
        ))
    }

    @Test func canonicalAudioLoadingRunsOffTheMainActor() async throws {
        let ranOnMain = LockedFlag()
        let samples = try await CaptureCanonicalAudioLoader.load {
            ranOnMain.set(Thread.isMainThread)
            return [0.25, -0.25]
        }

        #expect(samples == [0.25, -0.25])
        #expect(!ranOnMain.value)
    }

    @Test func stopSettingsRemainTheStopTimeValuesAfterSettingsChange() {
        let stopCloud = CloudLLMSettingsSnapshot(
            provider: .openAICompatible, baseURL: "https://stop.example", model: "stop",
            key: "stop-key", vocabulary: ["stop"]
        )
        let snapshot = AppCoordinator.captureStopSettingsSnapshot(
            oneShotLanguage: "pt", selectedOutput: .french,
            defaultOutput: .german, cloudSnapshot: stopCloud
        )

        let laterCloud = CloudLLMSettingsSnapshot(
            provider: .anthropic, baseURL: "https://later.example", model: "later",
            key: "later-key", vocabulary: ["later"]
        )
        _ = AppCoordinator.captureStopSettingsSnapshot(
            oneShotLanguage: nil, selectedOutput: nil,
            defaultOutput: .spanish, cloudSnapshot: laterCloud
        )

        #expect(snapshot.oneShotLanguage == "pt")
        #expect(snapshot.outputLanguage == .french)
        #expect(snapshot.cloudSnapshot == stopCloud)
    }

    @Test func recordingDestinationsDeclareDurableJournalPolicy() {
        let token = ScratchpadInsertionToken(id: UUID())
        #expect(RecordingDestination.external.requiresDurableJournal)
        #expect(RecordingDestination.scratchpad(token).requiresDurableJournal)
        #expect(RecordingDestination.external.journalIdentifier == "external")
        #expect(RecordingDestination.scratchpad(token).journalIdentifier == "scratchpad:\(token.id.uuidString)")
        #expect(!AppCoordinator.CaptureOwner.voiceEdit.requiresDurableJournal)
    }
}

private enum AdmissionEvent: Equatable {
    case createDirectory, synchronizeDirectory, createLedger, startAudioEngine
    case persistCancellation, removeArtifacts, removeLedger
}

private final class AdmissionEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [AdmissionEvent] = []
    func append(_ event: AdmissionEvent) { lock.withLock { events.append(event) } }
    var snapshot: [AdmissionEvent] { lock.withLock { events } }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false
    var value: Bool { lock.withLock { storage } }
    func set(_ value: Bool) { lock.withLock { storage = value } }
}

private enum AdmissionFailure: Error { case injected }

private struct AdmissionFileSystem: JournalFileSystem {
    let events: AdmissionEventLog
    var failDirectorySync = false
    var captureExists = false
    func createDirectory(_ url: URL) throws { events.append(.createDirectory) }
    func write(_ data: Data, to url: URL) throws {}
    func append(_ data: Data, to url: URL) throws {}
    func synchronizeFile(_ url: URL) throws {}
    func rename(_ source: URL, to destination: URL) throws {}
    func synchronizeDirectory(_ url: URL) throws {
        events.append(.synchronizeDirectory)
        if failDirectorySync { throw AdmissionFailure.injected }
    }
    func contents(_ url: URL) throws -> [URL] { [] }
    func read(_ url: URL) throws -> Data { Data() }
    func remove(_ url: URL) throws { events.append(.removeArtifacts) }
    func exists(_ url: URL) -> Bool { captureExists }
}

private actor AdmissionLedger: CaptureLedgerStoring {
    let request: CaptureStartRequest
    let events: AdmissionEventLog
    var stored: CaptureSession?
    init(request: CaptureStartRequest, events: AdmissionEventLog) {
        self.request = request
        self.events = events
    }
    func createCapture(_ request: CaptureStartRequest) async throws -> CaptureSession {
        events.append(.createLedger)
        let session = CaptureSession(
            id: request.id, state: .capturing, directory: request.directory,
            capturedAt: request.capturedAt, sampleRate: request.sampleRate,
            channelCount: request.channelCount, inputDeviceUID: request.inputDeviceUID,
            destination: request.destination, recoveryJobID: nil, libraryDictationID: nil,
            assetKind: .audio, failureMessage: nil, contentHash: nil
        )
        stored = session
        return session
    }
    func recordCommittedSegment(_ segment: CaptureSegment) async throws {}
    func transition(
        id: UUID, from: CaptureSessionState, to: CaptureSessionState,
        recoveryJobID: UUID?, libraryDictationID: Int64?, assetKind: RecoveryAssetKind,
        failureMessage: String?, contentHash: String?
    ) async throws {
        guard let old = stored else { return }
        if to == .cancelling { events.append(.persistCancellation) }
        stored = CaptureSession(
            id: old.id, state: to, directory: old.directory, capturedAt: old.capturedAt,
            sampleRate: old.sampleRate, channelCount: old.channelCount,
            inputDeviceUID: old.inputDeviceUID, destination: old.destination,
            recoveryJobID: recoveryJobID, libraryDictationID: libraryDictationID,
            assetKind: assetKind, failureMessage: failureMessage, contentHash: contentHash
        )
    }
    func session(id: UUID) async throws -> CaptureSession? { stored }
    func unfinishedSessions() async throws -> [CaptureSession] { [] }
    func committedSegments(captureID: UUID) async throws -> [CaptureSegment] { [] }
    func removeCleanedSession(id: UUID) async throws {
        events.append(.removeLedger)
        stored = nil
    }
}
