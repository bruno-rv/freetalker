import Darwin
import Foundation
import Testing
@testable import FreeTalker

@Suite struct JournalFileSystemTests {
    @Test("atomic commit syncs file before rename and parent after")
    func atomicCommitOrder() throws {
        let fileSystem = RecordingJournalFileSystem()
        let writer = DurableArtifactWriter(fileSystem: fileSystem)

        try writer.commit(
            Data([1, 2, 3]),
            temporary: URL(fileURLWithPath: "/journal/1.tmp"),
            destination: URL(fileURLWithPath: "/journal/1.pcm")
        )

        #expect(fileSystem.events == [
            .write("/journal/1.tmp"),
            .synchronizeFile("/journal/1.tmp"),
            .rename("/journal/1.tmp", "/journal/1.pcm"),
            .synchronizeDirectory("/journal")
        ])
    }

    @Test(
        "atomic commit returns the first error and stops",
        arguments: CommitBoundary.allCases,
        [ENOSPC, EACCES, EIO]
    )
    func atomicCommitStopsAtFirstError(boundary: CommitBoundary, code: Int32) {
        let fileSystem = RecordingJournalFileSystem(failure: .init(boundary: boundary, code: code))
        let writer = DurableArtifactWriter(fileSystem: fileSystem)

        #expect(throws: boundary.error(code: code)) {
            try writer.commit(
                Data([1, 2, 3]),
                temporary: URL(fileURLWithPath: "/journal/1.tmp"),
                destination: URL(fileURLWithPath: "/journal/1.pcm")
            )
        }
        #expect(fileSystem.events == boundary.expectedEvents)
    }
}

enum FileSystemEvent: Equatable, Sendable {
    case write(String)
    case synchronizeFile(String)
    case rename(String, String)
    case synchronizeDirectory(String)
}

enum CommitBoundary: CaseIterable, Sendable {
    case write
    case synchronizeFile
    case rename
    case synchronizeDirectory

    var expectedEvents: [FileSystemEvent] {
        switch self {
        case .write:
            [.write("/journal/1.tmp")]
        case .synchronizeFile:
            [.write("/journal/1.tmp"), .synchronizeFile("/journal/1.tmp")]
        case .rename:
            [
                .write("/journal/1.tmp"),
                .synchronizeFile("/journal/1.tmp"),
                .rename("/journal/1.tmp", "/journal/1.pcm")
            ]
        case .synchronizeDirectory:
            [
                .write("/journal/1.tmp"),
                .synchronizeFile("/journal/1.tmp"),
                .rename("/journal/1.tmp", "/journal/1.pcm"),
                .synchronizeDirectory("/journal")
            ]
        }
    }

    func error(code: Int32) -> JournalPersistenceError {
        switch self {
        case .write:
            .write(path: "/journal/1.tmp", code: code)
        case .synchronizeFile:
            .synchronizeFile(path: "/journal/1.tmp", code: code)
        case .rename:
            .rename(source: "/journal/1.tmp", destination: "/journal/1.pcm", code: code)
        case .synchronizeDirectory:
            .synchronizeDirectory(path: "/journal", code: code)
        }
    }
}

private struct InjectedFailure: Sendable {
    let boundary: CommitBoundary
    let code: Int32
}

private final class RecordingJournalFileSystem: JournalFileSystem, @unchecked Sendable {
    private let lock = NSLock()
    private let failure: InjectedFailure?
    private var recordedEvents: [FileSystemEvent] = []

    init(failure: InjectedFailure? = nil) {
        self.failure = failure
    }

    var events: [FileSystemEvent] {
        lock.withLock { recordedEvents }
    }

    func createDirectory(_ url: URL) throws {}

    func write(_ data: Data, to url: URL) throws {
        try record(.write(url.path), at: .write)
    }

    func append(_ data: Data, to url: URL) throws {}

    func synchronizeFile(_ url: URL) throws {
        try record(.synchronizeFile(url.path), at: .synchronizeFile)
    }

    func rename(_ source: URL, to destination: URL) throws {
        try record(.rename(source.path, destination.path), at: .rename)
    }

    func synchronizeDirectory(_ url: URL) throws {
        try record(.synchronizeDirectory(url.path), at: .synchronizeDirectory)
    }

    func contents(_ url: URL) throws -> [URL] { [] }
    func read(_ url: URL) throws -> Data { Data() }
    func remove(_ url: URL) throws {}
    func exists(_ url: URL) -> Bool { false }

    private func record(_ event: FileSystemEvent, at boundary: CommitBoundary) throws {
        lock.withLock { recordedEvents.append(event) }
        if failure?.boundary == boundary, let failure {
            throw boundary.error(code: failure.code)
        }
    }
}
