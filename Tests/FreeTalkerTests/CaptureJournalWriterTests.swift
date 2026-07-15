import Foundation
import Testing
@testable import FreeTalker

@Suite struct CaptureJournalWriterTests {
    @Test("canonical assembly writes one bounded payload chunk per segment")
    func canonicalAssemblyStreamsSegments() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("capture-streaming-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileSystem = StreamingProbeFileSystem()
        let ledger = MemoryCaptureLedger()
        let request = captureRequest(directory: root)
        try fileSystem.createDirectory(root)
        let session = try await ledger.createCapture(request)
        let writer = CaptureJournalWriter(
            session: session, fileSystem: fileSystem, ledger: ledger,
            configuration: .init(segmentFrames: 4, maximumQueuedFrames: 128)
        )
        #expect(writer.enqueue(Array(repeating: 0.25, count: 40)) == .accepted)

        let staged = try await writer.finish()

        #expect(staged.segments.count == 10)
        #expect(fileSystem.appendCount == 10)
        #expect(fileSystem.maximumChunkBytes <= CaptureSegmentCodec.headerSize + 4 * 4)
    }

    @Test("journal service prepares, stages, and advances lifecycle metadata")
    func serviceLifecycle() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("capture-service-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = MemoryCaptureLedger()
        let service = CaptureJournalService(
            fileSystem: LocalJournalFileSystem(), ledger: ledger,
            configuration: .init(segmentFrames: 4, maximumQueuedFrames: 16)
        )
        let request = captureRequest(directory: root)

        let active = try await service.prepare(request)
        #expect(active.writer.enqueue([0, 1, 2, 3, 4]) == .accepted)
        let staged = try await service.finish(active)
        let recoveryID = UUID()
        try await service.markProcessing(captureID: request.id, recoveryJobID: recoveryID)
        try await service.markLibraryCommitted(captureID: request.id, dictationID: 42)

        #expect(staged.sampleCount == 5)
        let stored = try #require(await ledger.session(id: request.id))
        #expect(stored.state == .libraryCommitted)
        #expect(stored.recoveryJobID == recoveryID)
        #expect(stored.libraryDictationID == 42)
        #expect(stored.contentHash != nil)
    }

    @Test("journal service records silent capture diagnostics without an audio artifact")
    func serviceSilentCapture() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("capture-silent-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = MemoryCaptureLedger()
        let fileSystem = LocalJournalFileSystem()
        let service = CaptureJournalService(fileSystem: fileSystem, ledger: ledger)
        let request = captureRequest(directory: root)
        let active = try await service.prepare(request)
        #expect(active.writer.enqueue([0, 0, 0, 0]) == .accepted)

        try await service.recordSilent(active, diagnostics: CaptureDiagnostics(
            peak: 0, rms: 0, inputDeviceUID: "test-mic", routeFailure: nil
        ))

        #expect(await ledger.session(id: request.id)?.state == .silent)
        #expect(await ledger.session(id: request.id)?.assetKind == .silent)
        #expect(await ledger.session(id: request.id)?.failureMessage == "No microphone signal was captured.")
        #expect(try fileSystem.contents(root).allSatisfy { $0.pathExtension != "wav" })
    }

    @Test("cancel removes artifacts before deleting the ledger row")
    func serviceCancellation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("capture-cancel-\(UUID().uuidString)", isDirectory: true)
        let ledger = MemoryCaptureLedger()
        let fileSystem = LocalJournalFileSystem()
        let service = CaptureJournalService(fileSystem: fileSystem, ledger: ledger)
        let request = captureRequest(directory: root)
        let active = try await service.prepare(request)
        #expect(active.writer.enqueue([0, 1]) == .accepted)
        _ = try await service.finish(active)

        try await service.cancelAndClean(active)

        #expect(!fileSystem.exists(root))
        #expect(await ledger.session(id: request.id) == nil)
    }

    @Test("eight thousand frames commit one segment")
    func segmentBoundary() async throws {
        let fixture = try await JournalWriterFixture(segmentFrames: 8_000)
        #expect(fixture.writer.enqueue(Array(repeating: 0.25, count: 8_000)) == .accepted)

        let staged = try await fixture.writer.finish()

        #expect(staged.segments.count == 1)
        #expect(staged.segments[0].sampleCount == 8_000)
        #expect(try fixture.codec.decode(staged.segments[0].url).count == 8_000)
    }

    @Test("finish commits a final partial segment")
    func partialFinish() async throws {
        let fixture = try await JournalWriterFixture(segmentFrames: 8_000)
        #expect(fixture.writer.enqueue(Array(repeating: -0.5, count: 8_127)) == .accepted)

        let staged = try await fixture.writer.finish()

        #expect(staged.segments.map(\.sampleCount) == [8_000, 127])
        #expect(staged.sampleCount == 8_127)
    }

    @Test("canonical WAV assembles committed segments in ordinal order")
    func orderedAssembly() async throws {
        let fixture = try await JournalWriterFixture(segmentFrames: 4)
        let samples: [Float] = [0, 0.25, 0.5, 0.75, -0.25, -0.5]
        #expect(fixture.writer.enqueue(samples) == .accepted)

        let staged = try await fixture.writer.finish()

        #expect(try fixture.codec.decode(staged.canonicalAudioURL) == samples)
        #expect(staged.segments.map(\.ordinal) == [0, 1])
    }

    @Test("finish is idempotent across concurrent and repeated callers")
    func repeatedFinish() async throws {
        let fixture = try await JournalWriterFixture(segmentFrames: 4)
        #expect(fixture.writer.enqueue([0, 1, 2, 3, 4]) == .accepted)

        async let first = fixture.writer.finish()
        async let second = fixture.writer.finish()
        let (a, b) = try await (first, second)
        let third = try await fixture.writer.finish()

        #expect(a == b)
        #expect(b == third)
        #expect(a.sampleCount == 5)
    }

    @Test("writer reopens committed segments and continues the next ordinal")
    func persistenceBoundaryReopen() async throws {
        let fixture = try await JournalWriterFixture(segmentFrames: 4)
        #expect(fixture.writer.enqueue([0, 1, 2, 3]) == .accepted)
        #expect(await fixture.writer.committedSnapshot().map(\.ordinal) == [0])

        let reopened = CaptureJournalWriter(
            session: fixture.session, fileSystem: fixture.fileSystem,
            ledger: fixture.ledger, codec: fixture.codec,
            configuration: .init(segmentFrames: 4, maximumQueuedFrames: 16)
        )
        #expect(reopened.enqueue([4, 5]) == .accepted)
        let staged = try await reopened.finish()

        #expect(staged.segments.map(\.ordinal) == [0, 1])
        #expect(try fixture.codec.decode(staged.canonicalAudioURL) == [0, 1, 2, 3, 4, 5])
    }

    @Test("sustained input never exceeds the configured queue bound")
    func sustainedInputIsBounded() async throws {
        let fixture = try await JournalWriterFixture(
            segmentFrames: 8_000, maximumQueuedFrames: 128_000
        )
        for _ in 0..<80 {
            #expect(fixture.writer.enqueue(Array(repeating: 0.125, count: 1_000)) == .accepted)
            if fixture.writer.queueMetrics().current > 120_000 {
                _ = await fixture.writer.committedSnapshot()
            }
        }
        _ = try await fixture.writer.finish()

        #expect(fixture.writer.queueMetrics().maximum <= 128_000)
    }

    private func captureRequest(directory: URL) -> CaptureStartRequest {
        CaptureStartRequest(
            id: UUID(), directory: directory, capturedAt: Date(timeIntervalSince1970: 100),
            sampleRate: 16_000, channelCount: 1, inputDeviceUID: "test-mic",
            destination: "test"
        )
    }
}

final class JournalWriterFixture: @unchecked Sendable {
    let root: URL
    let fileSystem: LocalJournalFileSystem
    let ledger: MemoryCaptureLedger
    let session: CaptureSession
    let codec: CaptureSegmentCodec
    let writer: CaptureJournalWriter

    init(segmentFrames: Int, maximumQueuedFrames: Int = 128_000) async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("capture-journal-\(UUID().uuidString)", isDirectory: true)
        fileSystem = LocalJournalFileSystem()
        ledger = MemoryCaptureLedger()
        let request = CaptureStartRequest(
            id: UUID(), directory: root, capturedAt: Date(timeIntervalSince1970: 100),
            sampleRate: 16_000, channelCount: 1, inputDeviceUID: "test-mic",
            destination: "test"
        )
        try fileSystem.createDirectory(root)
        session = try await ledger.createCapture(request)
        codec = CaptureSegmentCodec(fileSystem: fileSystem)
        writer = CaptureJournalWriter(
            session: session, fileSystem: fileSystem, ledger: ledger, codec: codec,
            configuration: .init(
                segmentFrames: segmentFrames, maximumQueuedFrames: maximumQueuedFrames
            )
        )
    }

    deinit { try? FileManager.default.removeItem(at: root) }
}

actor MemoryCaptureLedger: CaptureLedgerStoring {
    var sessions: [UUID: CaptureSession] = [:]
    var segments: [UUID: [CaptureSegment]] = [:]
    var recordError: Error?
    var damageTransitionError: Error?

    func createCapture(_ request: CaptureStartRequest) throws -> CaptureSession {
        if let existing = sessions[request.id] { return existing }
        let session = CaptureSession(
            id: request.id, state: .capturing, directory: request.directory,
            capturedAt: request.capturedAt, sampleRate: request.sampleRate,
            channelCount: request.channelCount, inputDeviceUID: request.inputDeviceUID,
            destination: request.destination, recoveryJobID: nil, libraryDictationID: nil,
            assetKind: .audio, failureMessage: nil, contentHash: nil
        )
        sessions[request.id] = session
        return session
    }

    func recordCommittedSegment(_ segment: CaptureSegment) throws {
        if let recordError { throw recordError }
        var captureSegments = segments[segment.captureID, default: []]
        if let existing = captureSegments.first(where: { $0.ordinal == segment.ordinal }) {
            guard existing == segment else { throw TestLedgerError.conflict }
            return
        }
        captureSegments.append(segment)
        segments[segment.captureID] = captureSegments
    }

    func transition(
        id: UUID, from: CaptureSessionState, to: CaptureSessionState,
        recoveryJobID: UUID?, libraryDictationID: Int64?, assetKind: RecoveryAssetKind,
        failureMessage: String?, contentHash: String?
    ) throws {
        if to == .damaged, let damageTransitionError { throw damageTransitionError }
        guard let old = sessions[id], old.state == from || old.state == to else {
            throw TestLedgerError.conflict
        }
        sessions[id] = CaptureSession(
            id: old.id, state: to, directory: old.directory, capturedAt: old.capturedAt,
            sampleRate: old.sampleRate, channelCount: old.channelCount,
            inputDeviceUID: old.inputDeviceUID, destination: old.destination,
            recoveryJobID: recoveryJobID, libraryDictationID: libraryDictationID,
            assetKind: assetKind, failureMessage: failureMessage, contentHash: contentHash
        )
    }

    func session(id: UUID) -> CaptureSession? { sessions[id] }
    func unfinishedSessions() -> [CaptureSession] { Array(sessions.values) }
    func committedSegments(captureID: UUID) -> [CaptureSegment] {
        segments[captureID, default: []].sorted { $0.ordinal < $1.ordinal }
    }
    func removeCleanedSession(id: UUID) {
        sessions[id] = nil
        segments[id] = nil
    }

    func replaceSegments(_ replacement: [CaptureSegment], captureID: UUID) {
        segments[captureID] = replacement
    }

    func failRecords(with error: Error) { recordError = error }
    func allowRecords() { recordError = nil }
    func failDamageTransitions(with error: Error) { damageTransitionError = error }
}

enum TestLedgerError: Error { case conflict, injected }

private final class StreamingProbeFileSystem: JournalFileSystem, @unchecked Sendable {
    private let base = LocalJournalFileSystem()
    private let lock = NSLock()
    private var chunkSizes: [Int] = []
    private var appends = 0

    var appendCount: Int { lock.withLock { appends } }
    var maximumChunkBytes: Int { lock.withLock { chunkSizes.max() ?? 0 } }
    func createDirectory(_ url: URL) throws { try base.createDirectory(url) }
    func write(_ data: Data, to url: URL) throws {
        lock.withLock { chunkSizes.append(data.count) }
        try base.write(data, to: url)
    }
    func append(_ data: Data, to url: URL) throws {
        lock.withLock {
            appends += 1
            chunkSizes.append(data.count)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }
    func synchronizeFile(_ url: URL) throws { try base.synchronizeFile(url) }
    func rename(_ source: URL, to destination: URL) throws { try base.rename(source, to: destination) }
    func synchronizeDirectory(_ url: URL) throws { try base.synchronizeDirectory(url) }
    func contents(_ url: URL) throws -> [URL] { try base.contents(url) }
    func read(_ url: URL) throws -> Data { try base.read(url) }
    func remove(_ url: URL) throws { try base.remove(url) }
    func exists(_ url: URL) -> Bool { base.exists(url) }
}
