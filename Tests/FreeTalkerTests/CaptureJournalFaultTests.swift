import CryptoKit
import Foundation
import Testing
@testable import FreeTalker

@Suite struct CaptureJournalFaultTests {
    @Test("durable failure marker prevents empty success when damage transition also fails")
    func fileAndDamageLedgerFailureCannotReopenEmpty() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("capture-double-failure-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileSystem = OneShotWriteFailingFileSystem()
        let ledger = MemoryCaptureLedger()
        let request = CaptureStartRequest(
            id: UUID(), directory: root, capturedAt: Date(timeIntervalSince1970: 10),
            sampleRate: 16_000, channelCount: 1, inputDeviceUID: nil, destination: "test"
        )
        try fileSystem.createDirectory(root)
        let session = try await ledger.createCapture(request)
        await ledger.failDamageTransitions(with: TestLedgerError.injected)
        var writer: CaptureJournalWriter? = CaptureJournalWriter(
            session: session, fileSystem: fileSystem, ledger: ledger,
            configuration: .init(segmentFrames: 4, maximumQueuedFrames: 8)
        )
        #expect(writer?.enqueue([0, 1, 2, 3]) == .accepted)
        await #expect(throws: CaptureJournalError.self) { try await writer?.finish() }
        #expect(await ledger.session(id: request.id)?.state == .capturing)
        writer = nil
        #expect(fileSystem.exists(root.appendingPathComponent("capture-failure.marker")))

        let reopened = CaptureJournalWriter(
            session: session, fileSystem: fileSystem, ledger: ledger,
            configuration: .init(segmentFrames: 4, maximumQueuedFrames: 8)
        )
        await #expect(throws: CaptureJournalError.self) { try await reopened.finish() }
        #expect(!fileSystem.exists(root.appendingPathComponent("\(request.id.uuidString).wav")))
    }

    @Test("mark processing rejects missing durable capture ownership")
    func markProcessingRejectsMissingSession() async {
        let service = CaptureJournalService(
            fileSystem: LocalJournalFileSystem(), ledger: MemoryCaptureLedger()
        )
        let captureID = UUID()

        await #expect(throws: CaptureJournalError.missingCapture(captureID)) {
            try await service.markProcessing(captureID: captureID, recoveryJobID: UUID())
        }
    }

    @Test("mark library committed rejects missing durable capture ownership")
    func markLibraryCommittedRejectsMissingSession() async {
        let service = CaptureJournalService(
            fileSystem: LocalJournalFileSystem(), ledger: MemoryCaptureLedger()
        )
        let captureID = UUID()

        await #expect(throws: CaptureJournalError.missingCapture(captureID)) {
            try await service.markLibraryCommitted(captureID: captureID, dictationID: 42)
        }
    }

    @Test("post-library cleanup failure persists intent and retries successfully")
    func libraryCommittedCleanupIsResumable() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("capture-library-cleanup-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileSystem = RemoveFailingFileSystem()
        let ledger = MemoryCaptureLedger()
        let service = CaptureJournalService(fileSystem: fileSystem, ledger: ledger)
        let request = CaptureStartRequest(
            id: UUID(), directory: root, capturedAt: Date(timeIntervalSince1970: 10),
            sampleRate: 16_000, channelCount: 1, inputDeviceUID: nil, destination: "test"
        )
        let active = try await service.prepare(request)
        #expect(active.writer.enqueue([0.25]) == .accepted)
        _ = try await service.finish(active)
        try await service.markProcessing(captureID: request.id, recoveryJobID: UUID())
        try await service.markLibraryCommitted(captureID: request.id, dictationID: 42)

        await #expect(throws: JournalPersistenceError.remove(path: root.path, code: EIO)) {
            try await service.resumeCleanup(captureID: request.id)
        }
        #expect(await ledger.session(id: request.id)?.state == .cancelling)
        #expect(fileSystem.exists(root))

        fileSystem.allowRemove()
        try await service.resumeCleanup(captureID: request.id)
        #expect(await ledger.session(id: request.id) == nil)
        #expect(!fileSystem.exists(root))
    }

    @Test("prepare syncs the capture parent before inserting the ledger row")
    func prepareParentSyncPrecedesLedger() async throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("capture-prepare-parent-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let root = parent.appendingPathComponent("capture", isDirectory: true)
        let fileSystem = LifecycleSyncFileSystem()
        fileSystem.failNextSync()
        let ledger = MemoryCaptureLedger()
        let service = CaptureJournalService(fileSystem: fileSystem, ledger: ledger)
        let request = CaptureStartRequest(
            id: UUID(), directory: root, capturedAt: Date(timeIntervalSince1970: 10),
            sampleRate: 16_000, channelCount: 1, inputDeviceUID: nil, destination: "test"
        )

        await #expect(throws: (any Error).self) { try await service.prepare(request) }

        #expect(fileSystem.events == [
            .createDirectory(root.path),
            .synchronizeDirectory(parent.path),
            .synchronizeDirectory(parent.path), // compensated removal is durable too
        ])
        #expect(await ledger.session(id: request.id) == nil)
    }

    @Test("cleanup syncs the capture parent before deleting the ledger row")
    func cleanupParentSyncPrecedesLedgerRemoval() async throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("capture-clean-parent-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let root = parent.appendingPathComponent("capture", isDirectory: true)
        let fileSystem = LifecycleSyncFileSystem()
        let ledger = MemoryCaptureLedger()
        let service = CaptureJournalService(fileSystem: fileSystem, ledger: ledger)
        let request = CaptureStartRequest(
            id: UUID(), directory: root, capturedAt: Date(timeIntervalSince1970: 10),
            sampleRate: 16_000, channelCount: 1, inputDeviceUID: nil, destination: "test"
        )
        let active = try await service.prepare(request)
        fileSystem.failNextSync()

        await #expect(throws: (any Error).self) { try await service.cancelAndClean(active) }

        #expect(!fileSystem.exists(root))
        #expect(await ledger.session(id: request.id)?.state == .cancelling)
        fileSystem.allowSync()
        try await service.resumeCleanup(captureID: request.id)
        #expect(await ledger.session(id: request.id) == nil)
    }

    @Test("in-flight persistence remains inside the 128k frame bound")
    func inFlightFramesRemainBounded() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("capture-in-flight-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileSystem = BlockingWriteFileSystem()
        let ledger = MemoryCaptureLedger()
        let request = CaptureStartRequest(
            id: UUID(), directory: root, capturedAt: Date(timeIntervalSince1970: 10),
            sampleRate: 16_000, channelCount: 1, inputDeviceUID: nil, destination: "test"
        )
        try fileSystem.createDirectory(root)
        let session = try await ledger.createCapture(request)
        let writer = CaptureJournalWriter(
            session: session, fileSystem: fileSystem, ledger: ledger,
            configuration: .init(segmentFrames: 8_000, maximumQueuedFrames: 128_000)
        )
        #expect(writer.enqueue(Array(repeating: 0.25, count: 128_000)) == .accepted)
        await fileSystem.waitUntilBlocked()

        #expect(writer.queueMetrics().current == 128_000)
        #expect(writer.enqueue([0.5]) == .overflow)
        #expect(writer.queueMetrics().maximum <= 128_000)

        fileSystem.release()
        await #expect(throws: CaptureJournalError.self) { try await writer.finish() }
    }

    @Test("cleanup resume refuses a staged recoverable capture")
    func cleanupRefusesStagedCapture() async throws {
        let fixture = try await CleanupStateFixture()
        defer { fixture.cleanUp() }
        let active = try await fixture.service.prepare(fixture.request)
        #expect(active.writer.enqueue([0.25]) == .accepted)
        _ = try await fixture.service.finish(active)

        await #expect(throws: (any Error).self) {
            try await fixture.service.resumeCleanup(captureID: fixture.request.id)
        }

        #expect(await fixture.ledger.session(id: fixture.request.id)?.state == .staged)
        #expect(fixture.fileSystem.exists(fixture.request.directory))
    }

    @Test("cleanup resume refuses a processing recoverable capture")
    func cleanupRefusesProcessingCapture() async throws {
        let fixture = try await CleanupStateFixture()
        defer { fixture.cleanUp() }
        let active = try await fixture.service.prepare(fixture.request)
        #expect(active.writer.enqueue([0.25]) == .accepted)
        _ = try await fixture.service.finish(active)
        try await fixture.service.markProcessing(
            captureID: fixture.request.id, recoveryJobID: UUID()
        )

        await #expect(throws: (any Error).self) {
            try await fixture.service.resumeCleanup(captureID: fixture.request.id)
        }

        #expect(await fixture.ledger.session(id: fixture.request.id)?.state == .processing)
        #expect(fixture.fileSystem.exists(fixture.request.directory))
    }

    @Test(
        "writer reopens safely after every atomic segment boundary",
        arguments: SegmentCommitBoundary.allCases
    )
    func reopenAfterSegmentBoundary(boundary: SegmentCommitBoundary) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("capture-boundary-\(UUID().uuidString)", isDirectory: true)
        let fileSystem = BoundaryFailingFileSystem(boundary: boundary)
        defer {
            fileSystem.allowOperations()
            try? FileManager.default.removeItem(at: root)
        }
        let ledger = MemoryCaptureLedger()
        let request = CaptureStartRequest(
            id: UUID(), directory: root, capturedAt: Date(timeIntervalSince1970: 10),
            sampleRate: 16_000, channelCount: 1, inputDeviceUID: nil, destination: "test"
        )
        try fileSystem.createDirectory(root)
        let session = try await ledger.createCapture(request)
        let writer = CaptureJournalWriter(
            session: session, fileSystem: fileSystem, ledger: ledger,
            configuration: .init(segmentFrames: 4, maximumQueuedFrames: 8)
        )
        #expect(writer.enqueue([0, 1, 2, 3]) == .accepted)

        await #expect(throws: CaptureJournalError.self) { try await writer.finish() }
        #expect(try fileSystem.contents(root).allSatisfy { $0.pathExtension != "tmp" })

        fileSystem.allowOperations()
        let reopened = CaptureJournalWriter(
            session: session, fileSystem: fileSystem, ledger: ledger,
            configuration: .init(segmentFrames: 4, maximumQueuedFrames: 8)
        )
        if boundary == .synchronizeDirectory {
            let staged = try await reopened.finish()
            #expect(staged.sampleCount == 4)
        } else {
            #expect(await ledger.session(id: request.id)?.state == .damaged)
            await #expect(throws: CaptureJournalError.self) {
                try await reopened.finish()
            }
        }
    }

    @Test("cleanup failure preserves cancelling ledger state for resume")
    func resumableCleanupFailure() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("capture-cleanup-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileSystem = RemoveFailingFileSystem()
        let ledger = MemoryCaptureLedger()
        let service = CaptureJournalService(fileSystem: fileSystem, ledger: ledger)
        let request = CaptureStartRequest(
            id: UUID(), directory: root, capturedAt: Date(timeIntervalSince1970: 10),
            sampleRate: 16_000, channelCount: 1, inputDeviceUID: nil, destination: "test"
        )
        let active = try await service.prepare(request)

        await #expect(throws: JournalPersistenceError.remove(path: root.path, code: EIO)) {
            try await service.cancelAndClean(active)
        }
        #expect(await ledger.session(id: request.id)?.state == .cancelling)
        #expect(fileSystem.exists(root))

        fileSystem.allowRemove()
        try await service.resumeCleanup(captureID: request.id)
        #expect(await ledger.session(id: request.id) == nil)
        #expect(!fileSystem.exists(root))
    }

    @Test("codec rejects truncated WAV data")
    func truncatedSegment() async throws {
        let fixture = try await JournalWriterFixture(segmentFrames: 4)
        let url = fixture.root.appendingPathComponent("truncated.wav")
        try fixture.fileSystem.write(Data("RIFF".utf8), to: url)

        #expect(throws: CaptureJournalError.invalidWAV(url.path)) {
            _ = try fixture.codec.decode(url)
        }
    }

    @Test("codec rejects corrupt Float32 WAV format metadata")
    func corruptSegmentHeader() async throws {
        let fixture = try await JournalWriterFixture(segmentFrames: 4)
        let url = fixture.root.appendingPathComponent("corrupt.wav")
        var data = fixture.codec.encode([0.25])
        data[20] = 1 // PCM integer instead of IEEE Float
        try fixture.fileSystem.write(data, to: url)

        #expect(throws: CaptureJournalError.invalidWAV(url.path)) {
            _ = try fixture.codec.decode(url)
        }
    }

    @Test("assembly rejects reordered ordinals")
    func reorderedSegments() async throws {
        let fixture = try await JournalWriterFixture(segmentFrames: 4)
        #expect(fixture.writer.enqueue([0, 1, 2, 3, 4, 5, 6, 7]) == .accepted)
        let segments = await fixture.writer.committedSnapshot()

        #expect(throws: CaptureJournalError.invalidOrdinal(expected: 0, actual: 1)) {
            _ = try fixture.codec.assemble(
                segments: [segments[1], segments[0]],
                canonicalURL: fixture.root.appendingPathComponent("bad.wav")
            )
        }
    }

    @Test("assembly rejects duplicate ordinals")
    func duplicateOrdinals() async throws {
        let fixture = try await JournalWriterFixture(segmentFrames: 4)
        #expect(fixture.writer.enqueue([0, 1, 2, 3]) == .accepted)
        let segment = try #require(await fixture.writer.committedSnapshot().first)

        #expect(throws: CaptureJournalError.invalidOrdinal(expected: 1, actual: 0)) {
            _ = try fixture.codec.assemble(
                segments: [segment, segment],
                canonicalURL: fixture.root.appendingPathComponent("bad.wav")
            )
        }
    }

    @Test("assembly rejects segment hash mismatch")
    func hashMismatch() async throws {
        let fixture = try await JournalWriterFixture(segmentFrames: 4)
        #expect(fixture.writer.enqueue([0, 1, 2, 3]) == .accepted)
        let segment = try #require(await fixture.writer.committedSnapshot().first)
        let altered = CaptureSegment(
            captureID: segment.captureID, ordinal: segment.ordinal, url: segment.url,
            sampleCount: segment.sampleCount, contentHash: String(repeating: "0", count: 64)
        )

        #expect(throws: CaptureJournalError.hashMismatch(segment.url.path)) {
            _ = try fixture.codec.assemble(
                segments: [altered],
                canonicalURL: fixture.root.appendingPathComponent("bad.wav")
            )
        }
    }

    @Test("overflow latches failure and notifies exactly once")
    func overflowLatch() async throws {
        let fixture = try await JournalWriterFixture(segmentFrames: 4, maximumQueuedFrames: 4)
        let failures = FailureProbe()
        let writer = CaptureJournalWriter(
            session: fixture.session, fileSystem: fixture.fileSystem,
            ledger: fixture.ledger, codec: fixture.codec,
            configuration: .init(segmentFrames: 4, maximumQueuedFrames: 4),
            onFailure: { failures.record($0) }
        )

        #expect(writer.enqueue([0, 1, 2, 3, 4]) == .overflow)
        guard case .failed = writer.enqueue([0]) else {
            Issue.record("enqueue after overflow must remain failed")
            return
        }
        await #expect(throws: CaptureJournalError.self) { try await writer.finish() }
        await failures.waitForCount(1)
        #expect(failures.messages.count == 1)
    }

    @Test("ledger failure latches and leaves atomically committed segment")
    func failureLatchAfterCommit() async throws {
        let fixture = try await JournalWriterFixture(segmentFrames: 4)
        await fixture.ledger.failRecords(with: TestLedgerError.injected)
        let failures = FailureProbe()
        let writer = CaptureJournalWriter(
            session: fixture.session, fileSystem: fixture.fileSystem,
            ledger: fixture.ledger, codec: fixture.codec,
            configuration: .init(segmentFrames: 4, maximumQueuedFrames: 8),
            onFailure: { failures.record($0) }
        )

        #expect(writer.enqueue([0, 1, 2, 3]) == .accepted)
        await #expect(throws: CaptureJournalError.self) { try await writer.finish() }
        guard case .failed = writer.enqueue([4]) else {
            Issue.record("enqueue after worker failure must remain failed")
            return
        }
        #expect(failures.messages.count == 1)
        #expect(try fixture.fileSystem.contents(fixture.root).contains {
            $0.lastPathComponent.hasSuffix(".wav") && $0.lastPathComponent != "\(fixture.session.id).wav"
        })
        #expect(try fixture.fileSystem.contents(fixture.root).allSatisfy {
            $0.pathExtension != "tmp"
        })

        await fixture.ledger.allowRecords()
        let reopened = CaptureJournalWriter(
            session: fixture.session, fileSystem: fixture.fileSystem,
            ledger: fixture.ledger, codec: fixture.codec,
            configuration: .init(segmentFrames: 4, maximumQueuedFrames: 8)
        )
        let staged = try await reopened.finish()
        #expect(staged.segments.map(\.ordinal) == [0])
        #expect(staged.sampleCount == 4)
    }
}

private final class CleanupStateFixture: @unchecked Sendable {
    let fileSystem = LocalJournalFileSystem()
    let ledger = MemoryCaptureLedger()
    let request: CaptureStartRequest
    let service: CaptureJournalService

    init() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cleanup-state-\(UUID().uuidString)", isDirectory: true)
        request = CaptureStartRequest(
            id: UUID(), directory: root, capturedAt: Date(timeIntervalSince1970: 10),
            sampleRate: 16_000, channelCount: 1, inputDeviceUID: nil, destination: "test"
        )
        service = CaptureJournalService(fileSystem: fileSystem, ledger: ledger)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: request.directory) }
}

private final class FailureProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    var messages: [String] { lock.withLock { storage } }
    func record(_ message: String) { lock.withLock { storage.append(message) } }
    func waitForCount(_ count: Int) async {
        while messages.count < count { await Task.yield() }
    }
}

private final class RemoveFailingFileSystem: JournalFileSystem, @unchecked Sendable {
    private let base = LocalJournalFileSystem()
    private let lock = NSLock()
    private var shouldFailRemove = true

    func allowRemove() { lock.withLock { shouldFailRemove = false } }
    func createDirectory(_ url: URL) throws { try base.createDirectory(url) }
    func write(_ data: Data, to url: URL) throws { try base.write(data, to: url) }
    func append(_ data: Data, to url: URL) throws { try base.append(data, to: url) }
    func synchronizeFile(_ url: URL) throws { try base.synchronizeFile(url) }
    func rename(_ source: URL, to destination: URL) throws { try base.rename(source, to: destination) }
    func synchronizeDirectory(_ url: URL) throws { try base.synchronizeDirectory(url) }
    func contents(_ url: URL) throws -> [URL] { try base.contents(url) }
    func read(_ url: URL) throws -> Data { try base.read(url) }
    func remove(_ url: URL) throws {
        if lock.withLock({ shouldFailRemove }) {
            throw JournalPersistenceError.remove(path: url.path, code: EIO)
        }
        try base.remove(url)
    }
    func removeEmptyDirectory(_ url: URL) throws { try base.removeEmptyDirectory(url) }
    func removeRegularFile(_ url: URL) throws { try base.removeRegularFile(url) }
    func exists(_ url: URL) -> Bool { base.exists(url) }
}

private final class OneShotWriteFailingFileSystem: JournalFileSystem, @unchecked Sendable {
    private let base = LocalJournalFileSystem()
    private let lock = NSLock()
    private var shouldFailSegmentWrite = true

    func createDirectory(_ url: URL) throws { try base.createDirectory(url) }
    func write(_ data: Data, to url: URL) throws {
        let fail = lock.withLock { () -> Bool in
            guard shouldFailSegmentWrite, url.lastPathComponent.hasPrefix(".segment-") else {
                return false
            }
            shouldFailSegmentWrite = false
            return true
        }
        if fail { throw JournalPersistenceError.write(path: url.path, code: EIO) }
        try base.write(data, to: url)
    }
    func append(_ data: Data, to url: URL) throws { try base.append(data, to: url) }
    func synchronizeFile(_ url: URL) throws { try base.synchronizeFile(url) }
    func rename(_ source: URL, to destination: URL) throws { try base.rename(source, to: destination) }
    func synchronizeDirectory(_ url: URL) throws { try base.synchronizeDirectory(url) }
    func contents(_ url: URL) throws -> [URL] { try base.contents(url) }
    func read(_ url: URL) throws -> Data { try base.read(url) }
    func remove(_ url: URL) throws { try base.remove(url) }
    func removeEmptyDirectory(_ url: URL) throws { try base.removeEmptyDirectory(url) }
    func removeRegularFile(_ url: URL) throws { try base.removeRegularFile(url) }
    func exists(_ url: URL) -> Bool { base.exists(url) }
}

private enum LifecycleFileEvent: Equatable, Sendable {
    case createDirectory(String)
    case synchronizeDirectory(String)
}

private final class LifecycleSyncFileSystem: JournalFileSystem, @unchecked Sendable {
    private let base = LocalJournalFileSystem()
    private let lock = NSLock()
    private var recordedEvents: [LifecycleFileEvent] = []
    private var shouldFailNextSync = false

    var events: [LifecycleFileEvent] { lock.withLock { recordedEvents } }
    func failNextSync() { lock.withLock { shouldFailNextSync = true } }
    func allowSync() { lock.withLock { shouldFailNextSync = false } }
    func createDirectory(_ url: URL) throws {
        lock.withLock { recordedEvents.append(.createDirectory(url.path)) }
        try base.createDirectory(url)
    }
    func write(_ data: Data, to url: URL) throws { try base.write(data, to: url) }
    func append(_ data: Data, to url: URL) throws { try base.append(data, to: url) }
    func synchronizeFile(_ url: URL) throws { try base.synchronizeFile(url) }
    func rename(_ source: URL, to destination: URL) throws { try base.rename(source, to: destination) }
    func synchronizeDirectory(_ url: URL) throws {
        let fail = lock.withLock { () -> Bool in
            recordedEvents.append(.synchronizeDirectory(url.path))
            if shouldFailNextSync {
                shouldFailNextSync = false
                return true
            }
            return false
        }
        if fail {
            throw JournalPersistenceError.synchronizeDirectory(path: url.path, code: EIO)
        }
        try base.synchronizeDirectory(url)
    }
    func contents(_ url: URL) throws -> [URL] { try base.contents(url) }
    func read(_ url: URL) throws -> Data { try base.read(url) }
    func remove(_ url: URL) throws { try base.remove(url) }
    func removeEmptyDirectory(_ url: URL) throws { try base.removeEmptyDirectory(url) }
    func removeRegularFile(_ url: URL) throws { try base.removeRegularFile(url) }
    func exists(_ url: URL) -> Bool { base.exists(url) }
}

private final class BlockingWriteFileSystem: JournalFileSystem, @unchecked Sendable {
    private let base = LocalJournalFileSystem()
    private let lock = NSLock()
    private let releaseGate = DispatchSemaphore(value: 0)
    private var blocked = false
    private var didBlock = false

    func waitUntilBlocked() async {
        while !lock.withLock({ blocked }) { await Task.yield() }
    }
    func release() { releaseGate.signal() }
    func createDirectory(_ url: URL) throws { try base.createDirectory(url) }
    func write(_ data: Data, to url: URL) throws {
        let shouldBlock = lock.withLock { () -> Bool in
            guard !didBlock, url.lastPathComponent.hasPrefix(".segment-") else { return false }
            didBlock = true
            blocked = true
            return true
        }
        if shouldBlock { releaseGate.wait() }
        try base.write(data, to: url)
    }
    func append(_ data: Data, to url: URL) throws { try base.append(data, to: url) }
    func synchronizeFile(_ url: URL) throws { try base.synchronizeFile(url) }
    func rename(_ source: URL, to destination: URL) throws { try base.rename(source, to: destination) }
    func synchronizeDirectory(_ url: URL) throws { try base.synchronizeDirectory(url) }
    func contents(_ url: URL) throws -> [URL] { try base.contents(url) }
    func read(_ url: URL) throws -> Data { try base.read(url) }
    func remove(_ url: URL) throws { try base.remove(url) }
    func removeEmptyDirectory(_ url: URL) throws { try base.removeEmptyDirectory(url) }
    func removeRegularFile(_ url: URL) throws { try base.removeRegularFile(url) }
    func exists(_ url: URL) -> Bool { base.exists(url) }
}

enum SegmentCommitBoundary: CaseIterable, Sendable {
    case write, synchronizeFile, rename, synchronizeDirectory
}

private final class BoundaryFailingFileSystem: JournalFileSystem, @unchecked Sendable {
    private let base = LocalJournalFileSystem()
    private let lock = NSLock()
    private var boundary: SegmentCommitBoundary?

    init(boundary: SegmentCommitBoundary) { self.boundary = boundary }

    func allowOperations() { lock.withLock { boundary = nil } }
    func createDirectory(_ url: URL) throws { try base.createDirectory(url) }
    func write(_ data: Data, to url: URL) throws {
        if shouldFail(.write) {
            throw JournalPersistenceError.write(path: url.path, code: EIO)
        }
        try base.write(data, to: url)
    }
    func append(_ data: Data, to url: URL) throws { try base.append(data, to: url) }
    func synchronizeFile(_ url: URL) throws {
        if shouldFail(.synchronizeFile) {
            throw JournalPersistenceError.synchronizeFile(path: url.path, code: EIO)
        }
        try base.synchronizeFile(url)
    }
    func rename(_ source: URL, to destination: URL) throws {
        if shouldFail(.rename) {
            throw JournalPersistenceError.rename(
                source: source.path, destination: destination.path, code: EIO
            )
        }
        try base.rename(source, to: destination)
    }
    func synchronizeDirectory(_ url: URL) throws {
        if shouldFail(.synchronizeDirectory) {
            throw JournalPersistenceError.synchronizeDirectory(path: url.path, code: EIO)
        }
        try base.synchronizeDirectory(url)
    }
    func contents(_ url: URL) throws -> [URL] { try base.contents(url) }
    func read(_ url: URL) throws -> Data { try base.read(url) }
    func remove(_ url: URL) throws { try base.remove(url) }
    func removeEmptyDirectory(_ url: URL) throws { try base.removeEmptyDirectory(url) }
    func removeRegularFile(_ url: URL) throws { try base.removeRegularFile(url) }
    func exists(_ url: URL) -> Bool { base.exists(url) }

    private func shouldFail(_ candidate: SegmentCommitBoundary) -> Bool {
        lock.withLock { boundary == candidate }
    }
}
