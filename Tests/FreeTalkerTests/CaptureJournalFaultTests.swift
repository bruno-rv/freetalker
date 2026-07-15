import CryptoKit
import Foundation
import Testing
@testable import FreeTalker

@Suite struct CaptureJournalFaultTests {
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
        let staged = try await reopened.finish()
        #expect(staged.sampleCount == (boundary == .synchronizeDirectory ? 4 : 0))
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
    func exists(_ url: URL) -> Bool { base.exists(url) }

    private func shouldFail(_ candidate: SegmentCommitBoundary) -> Bool {
        lock.withLock { boundary == candidate }
    }
}
