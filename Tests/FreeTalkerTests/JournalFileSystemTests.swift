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

    @Test("removeEmptyDirectory uses non-recursive rmdir semantics: ENOTEMPTY on non-empty content, never deletes it (Codex round-10 minor 1)")
    func removeEmptyDirectoryNeverRecursesIntoUnexpectedContent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("journal-fs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("orphan", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let survivor = target.appendingPathComponent("unexpected-content.txt")
        try Data("do not delete me".utf8).write(to: survivor)

        let fileSystem = LocalJournalFileSystem()
        // Unlike the old empty-check-then-`remove(_:)` race, this must fail atomically instead of
        // recursively deleting `survivor` — there is no separate check-then-act window at all.
        #expect(throws: JournalPersistenceError.remove(path: target.path, code: ENOTEMPTY)) {
            try fileSystem.removeEmptyDirectory(target)
        }
        #expect(FileManager.default.fileExists(atPath: survivor.path))

        // An actually-empty directory is removed normally.
        try FileManager.default.removeItem(at: survivor)
        try fileSystem.removeEmptyDirectory(target)
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    @Test("removeRegularFile uses non-recursive unlink semantics: fails on a directory instead of recursing into it (Codex round-10 minor 2)")
    func removeRegularFileNeverRecursesIntoADirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("journal-fs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // Simulates the TOCTOU outcome: something replaced the expected regular file with a
        // directory (containing other content) between an `lstat` check and the removal call.
        let swapped = root.appendingPathComponent("marker", isDirectory: true)
        try FileManager.default.createDirectory(at: swapped, withIntermediateDirectories: true)
        let survivor = swapped.appendingPathComponent("unexpected-content.txt")
        try Data("do not delete me".utf8).write(to: survivor)

        let fileSystem = LocalJournalFileSystem()
        // Darwin's `unlink(2)` reports a directory target as `EPERM`, not `EISDIR` (Linux's code) —
        // the exact code doesn't matter here so much as the outcome: `unlink` NEVER recurses into a
        // directory's contents, unlike `FileManager.removeItem`'s `remove(_:)`.
        #expect(throws: JournalPersistenceError.remove(path: swapped.path, code: EPERM)) {
            try fileSystem.removeRegularFile(swapped)
        }
        #expect(FileManager.default.fileExists(atPath: survivor.path))

        // An actual regular file is removed normally.
        let regular = root.appendingPathComponent("regular.txt")
        try Data("bye".utf8).write(to: regular)
        try fileSystem.removeRegularFile(regular)
        #expect(!FileManager.default.fileExists(atPath: regular.path))
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
    // This double models no real filesystem state (every read/contents call is a stub) — there is
    // nothing behind it a non-recursive implementation could meaningfully protect, unlike the
    // production `LocalJournalFileSystem` or wrappers around it.
    func removeEmptyDirectory(_ url: URL) throws {}
    func removeRegularFile(_ url: URL) throws {}
    func exists(_ url: URL) -> Bool { false }

    private func record(_ event: FileSystemEvent, at boundary: CommitBoundary) throws {
        lock.withLock { recordedEvents.append(event) }
        if failure?.boundary == boundary, let failure {
            throw boundary.error(code: failure.code)
        }
    }
}
