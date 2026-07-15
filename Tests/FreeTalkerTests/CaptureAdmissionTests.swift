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

        #expect(reducer.reduce(.begin(destination: "external")) == .none)
        #expect(reducer.reduce(.stopRequested) == .none)
        #expect(reducer.reduce(.prepared(captureID: captureID)) == .startAndStop(captureID))
        #expect(reducer.state == .recording(captureID: captureID))
    }

    @Test func cancelDuringPreparationCleansWithoutStartingEngine() {
        let captureID = UUID()
        var reducer = CaptureAdmissionReducer()
        _ = reducer.reduce(.begin(destination: "external"))

        #expect(reducer.reduce(.cancelRequested) == .none)
        #expect(reducer.reduce(.prepared(captureID: captureID)) == .cancel(captureID))
        #expect(reducer.state == .cancelling(captureID: captureID))
    }

    @Test func cancelWinsWhenStopAndCancelArriveDuringPreparation() {
        let captureID = UUID()
        var stopThenCancel = CaptureAdmissionReducer()
        _ = stopThenCancel.reduce(.begin(destination: "external"))
        _ = stopThenCancel.reduce(.stopRequested)
        _ = stopThenCancel.reduce(.cancelRequested)

        #expect(stopThenCancel.reduce(.prepared(captureID: captureID)) == .cancel(captureID))

        var cancelThenStop = CaptureAdmissionReducer()
        _ = cancelThenStop.reduce(.begin(destination: "external"))
        _ = cancelThenStop.reduce(.cancelRequested)
        _ = cancelThenStop.reduce(.stopRequested)

        #expect(cancelThenStop.reduce(.prepared(captureID: captureID)) == .cancel(captureID))
    }

    @Test func preparationFailureReturnsReducerToIdle() {
        var reducer = CaptureAdmissionReducer()
        _ = reducer.reduce(.begin(destination: "external"))

        #expect(reducer.reduce(.preparationFailed("disk full")) == .fail("disk full"))
        #expect(reducer.state == .idle)
    }

    @Test func engineStartFailureAfterPreparationReturnsReducerToIdle() {
        var reducer = CaptureAdmissionReducer()
        _ = reducer.reduce(.begin(destination: "external"))
        _ = reducer.reduce(.prepared(captureID: UUID()))

        #expect(reducer.reduce(.preparationFailed("engine failed")) == .fail("engine failed"))
        #expect(reducer.state == .idle)
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
