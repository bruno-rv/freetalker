import Foundation
import Testing
@testable import FreeTalker

@Suite struct CaptureSessionStoreTests {
    @Test func legalTransitionRetryIsIdempotentAndBackwardTransitionIsRejected() async throws {
        let database = try CaptureStoreDatabase()
        let store = try TranscriptionJobStore(databaseURL: database.url, clock: SystemJobClock())
        let request = captureRequest()
        _ = try await store.createCapture(request)

        try await store.transition(
            id: request.id, from: .capturing, to: .staged,
            recoveryJobID: nil, libraryDictationID: nil, assetKind: .audio,
            failureMessage: nil, contentHash: "capture-hash"
        )
        try await store.transition(
            id: request.id, from: .capturing, to: .staged,
            recoveryJobID: nil, libraryDictationID: nil, assetKind: .audio,
            failureMessage: nil, contentHash: "capture-hash"
        )

        #expect(try await store.session(id: request.id)?.state == .staged)
        await #expect(throws: JobStoreError.invalidTransition) {
            try await store.transition(
                id: request.id, from: .staged, to: .capturing,
                recoveryJobID: nil, libraryDictationID: nil, assetKind: .audio,
                failureMessage: nil, contentHash: nil
            )
        }
    }

    @Test func committedSegmentsAreIdempotentAndOrdered() async throws {
        let database = try CaptureStoreDatabase()
        let store = try TranscriptionJobStore(databaseURL: database.url, clock: SystemJobClock())
        let request = captureRequest()
        _ = try await store.createCapture(request)
        let first = CaptureSegment(
            captureID: request.id, ordinal: 0,
            url: request.directory.appendingPathComponent("0000.caf"),
            sampleCount: 8_000, contentHash: "first"
        )
        let second = CaptureSegment(
            captureID: request.id, ordinal: 1,
            url: request.directory.appendingPathComponent("0001.caf"),
            sampleCount: 4_000, contentHash: "second"
        )

        try await store.recordCommittedSegment(second)
        try await store.recordCommittedSegment(first)
        try await store.recordCommittedSegment(second)

        #expect(try await store.committedSegments(captureID: request.id) == [first, second])
    }

    @Test func unfinishedSessionsReopenAfterStoreRestart() async throws {
        let database = try CaptureStoreDatabase()
        let request = captureRequest()
        do {
            let store = try TranscriptionJobStore(databaseURL: database.url, clock: SystemJobClock())
            _ = try await store.createCapture(request)
            try await store.transition(
                id: request.id, from: .capturing, to: .staged,
                recoveryJobID: nil, libraryDictationID: nil, assetKind: .audio,
                failureMessage: nil, contentHash: "capture-hash"
            )
        }

        let reopened = try TranscriptionJobStore(databaseURL: database.url, clock: SystemJobClock())
        #expect(try await reopened.unfinishedSessions().map(\.id) == [request.id])
    }

    @Test func cleanedSessionRemovalIsIdempotentAndCascadesSegments() async throws {
        let database = try CaptureStoreDatabase()
        let store = try TranscriptionJobStore(databaseURL: database.url, clock: SystemJobClock())
        let request = captureRequest()
        _ = try await store.createCapture(request)
        try await store.recordCommittedSegment(CaptureSegment(
            captureID: request.id, ordinal: 0,
            url: request.directory.appendingPathComponent("0000.caf"),
            sampleCount: 8_000, contentHash: "segment"
        ))
        try await store.transition(
            id: request.id, from: .capturing, to: .staged,
            recoveryJobID: nil, libraryDictationID: nil, assetKind: .audio,
            failureMessage: nil, contentHash: "capture"
        )
        try await store.transition(
            id: request.id, from: .staged, to: .processing,
            recoveryJobID: nil, libraryDictationID: nil, assetKind: .audio,
            failureMessage: nil, contentHash: "capture"
        )
        try await store.transition(
            id: request.id, from: .processing, to: .libraryCommitted,
            recoveryJobID: nil, libraryDictationID: 42, assetKind: .audio,
            failureMessage: nil, contentHash: "capture"
        )

        try await store.removeCleanedSession(id: request.id)
        try await store.removeCleanedSession(id: request.id)

        #expect(try await store.session(id: request.id) == nil)
        #expect(try await store.committedSegments(captureID: request.id).isEmpty)
    }

    private func captureRequest() -> CaptureStartRequest {
        let id = UUID()
        return CaptureStartRequest(
            id: id,
            directory: FileManager.default.temporaryDirectory.appendingPathComponent(id.uuidString),
            capturedAt: Date(timeIntervalSince1970: 1_234.5), sampleRate: 48_000,
            channelCount: 1, inputDeviceUID: "mic-1", destination: "external"
        )
    }
}

private final class CaptureStoreDatabase: @unchecked Sendable {
    let url: URL

    init() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("capture-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("jobs.db")
    }

    deinit { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
}
