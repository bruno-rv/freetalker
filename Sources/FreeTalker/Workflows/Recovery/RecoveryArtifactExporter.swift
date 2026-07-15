import CryptoKit
import Darwin
import Foundation

protocol RecoveryArtifactExporting: Sendable {
    func export(source: URL, destination: URL, expectedHash: String) throws
}

struct RecoveryArtifactExporter: RecoveryArtifactExporting {
    private let beforeSourceOpen: @Sendable (URL) throws -> Void
    private let temporaryURL: @Sendable (URL) -> URL

    init(
        beforeSourceOpen: @escaping @Sendable (URL) throws -> Void = { _ in },
        temporaryURL: @escaping @Sendable (URL) -> URL = { destination in
            destination.deletingLastPathComponent().appendingPathComponent(
                ".\(destination.lastPathComponent).\(UUID().uuidString).exporting"
            )
        }
    ) {
        self.beforeSourceOpen = beforeSourceOpen
        self.temporaryURL = temporaryURL
    }

    func export(source: URL, destination: URL, expectedHash: String) throws {
        let source = source.standardizedFileURL
        let destination = destination.standardizedFileURL
        var original = stat()
        try check(lstat(source.path, &original), path: source.path)
        guard Self.isRegular(original), expectedHash.count == 64 else {
            throw CaptureJournalError.hashMismatch(source.path)
        }

        try beforeSourceOpen(source)
        let sourceDescriptor = open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard sourceDescriptor >= 0 else { throw POSIXExportError(path: source.path, code: errno) }
        defer { _ = close(sourceDescriptor) }
        var openedSource = stat()
        try check(fstat(sourceDescriptor, &openedSource), path: source.path)
        guard Self.isRegular(openedSource), Self.sameFile(original, openedSource) else {
            throw CaptureJournalError.hashMismatch(source.path)
        }

        let temporary = temporaryURL(destination).standardizedFileURL
        guard temporary.deletingLastPathComponent() == destination.deletingLastPathComponent(),
              temporary != destination else {
            throw CaptureJournalError.failed("Invalid recovery export temporary path")
        }
        let temporaryDescriptor = open(
            temporary.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard temporaryDescriptor >= 0 else {
            throw POSIXExportError(path: temporary.path, code: errno)
        }
        var openedTemporary = stat()
        do {
            try check(fstat(temporaryDescriptor, &openedTemporary), path: temporary.path)
            guard Self.isRegular(openedTemporary) else {
                throw CaptureJournalError.failed("Recovery export temporary file is not regular")
            }
        } catch {
            _ = close(temporaryDescriptor)
            Self.removeOwnedTemporary(temporary, identity: openedTemporary)
            throw error
        }
        var temporaryClosed = false
        var temporaryRemoved = false
        defer {
            if !temporaryClosed { _ = close(temporaryDescriptor) }
            if !temporaryRemoved {
                Self.removeOwnedTemporary(temporary, identity: openedTemporary)
            }
        }

        let (hash, count) = try copy(
            sourceDescriptor: sourceDescriptor,
            temporaryDescriptor: temporaryDescriptor
        )
        guard hash == expectedHash, count == openedSource.st_size else {
            throw CaptureJournalError.hashMismatch(source.path)
        }
        try synchronize(temporaryDescriptor, path: temporary.path)

        var finalSource = stat()
        var finalTemporary = stat()
        try check(fstat(sourceDescriptor, &finalSource), path: source.path)
        try check(fstat(temporaryDescriptor, &finalTemporary), path: temporary.path)
        var lexicalSource = stat()
        var lexicalTemporary = stat()
        try check(lstat(source.path, &lexicalSource), path: source.path)
        try check(lstat(temporary.path, &lexicalTemporary), path: temporary.path)
        guard Self.isRegular(finalSource), Self.sameFile(openedSource, finalSource),
              Self.sameFile(openedSource, lexicalSource), finalSource.st_size == count,
              Self.isRegular(finalTemporary), Self.sameFile(openedTemporary, finalTemporary),
              Self.sameFile(openedTemporary, lexicalTemporary), finalTemporary.st_size == count else {
            throw CaptureJournalError.hashMismatch(source.path)
        }
        try check(close(temporaryDescriptor), path: temporary.path)
        temporaryClosed = true

        // Exclusive atomic rename publishes only when the destination is absent;
        // it never follows or replaces an attacker-created destination symlink.
        try check(
            renameatx_np(
                AT_FDCWD, temporary.path, AT_FDCWD, destination.path,
                UInt32(RENAME_EXCL)
            ),
            path: destination.path
        )
        temporaryRemoved = true
        var published = stat()
        try check(lstat(destination.path, &published), path: destination.path)
        guard Self.isRegular(published), Self.sameFile(openedTemporary, published) else {
            throw CaptureJournalError.failed("Published recovery export is not a regular file")
        }
        try synchronizeDirectory(destination.deletingLastPathComponent())
    }

    private func copy(
        sourceDescriptor: Int32, temporaryDescriptor: Int32
    ) throws -> (hash: String, count: Int64) {
        var hasher = SHA256()
        var total: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let readCount = buffer.withUnsafeMutableBytes {
                Darwin.read(sourceDescriptor, $0.baseAddress, $0.count)
            }
            if readCount == 0 { break }
            if readCount < 0 {
                if errno == EINTR { continue }
                throw POSIXExportError(path: "source descriptor", code: errno)
            }
            let data = Data(buffer[0..<readCount])
            hasher.update(data: data)
            var written = 0
            while written < readCount {
                let result = data.withUnsafeBytes { bytes in
                    Darwin.write(
                        temporaryDescriptor,
                        bytes.baseAddress!.advanced(by: written),
                        readCount - written
                    )
                }
                if result < 0 {
                    if errno == EINTR { continue }
                    throw POSIXExportError(path: "temporary descriptor", code: errno)
                }
                guard result > 0 else {
                    throw POSIXExportError(path: "temporary descriptor", code: EIO)
                }
                written += result
            }
            total += Int64(readCount)
        }
        let hash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return (hash, total)
    }

    private func synchronize(_ descriptor: Int32, path: String) throws {
        while true {
            if fcntl(descriptor, F_FULLFSYNC) == 0 { return }
            let code = errno
            if code == EINTR { continue }
            guard code == EINVAL || code == ENOTSUP else {
                throw POSIXExportError(path: path, code: code)
            }
            break
        }
        while fsync(descriptor) != 0 {
            if errno == EINTR { continue }
            throw POSIXExportError(path: path, code: errno)
        }
    }

    private func synchronizeDirectory(_ directory: URL) throws {
        let descriptor = open(directory.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXExportError(path: directory.path, code: errno) }
        defer { _ = close(descriptor) }
        try synchronize(descriptor, path: directory.path)
    }

    private func check(_ result: Int32, path: String) throws {
        guard result == 0 else { throw POSIXExportError(path: path, code: errno) }
    }

    private static func isRegular(_ value: stat) -> Bool {
        (value.st_mode & S_IFMT) == S_IFREG
    }

    private static func sameFile(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
    }

    private static func removeOwnedTemporary(_ url: URL, identity: stat) {
        var current = stat()
        guard lstat(url.path, &current) == 0, isRegular(current),
              sameFile(identity, current) else { return }
        _ = unlink(url.path)
    }
}

private struct POSIXExportError: LocalizedError {
    let path: String
    let code: Int32
    var errorDescription: String? {
        "Recovery export failed at \(path): \(String(cString: strerror(code)))"
    }
}
