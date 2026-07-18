import Darwin
import Foundation

protocol JournalFileSystem: Sendable {
    func createDirectory(_ url: URL) throws
    func write(_ data: Data, to url: URL) throws
    func append(_ data: Data, to url: URL) throws
    func synchronizeFile(_ url: URL) throws
    func rename(_ source: URL, to destination: URL) throws
    func synchronizeDirectory(_ url: URL) throws
    func contents(_ url: URL) throws -> [URL]
    func read(_ url: URL) throws -> Data
    func remove(_ url: URL) throws
    func exists(_ url: URL) -> Bool
}

struct DurableArtifactWriter: Sendable {
    let fileSystem: any JournalFileSystem

    func commit(_ data: Data, temporary: URL, destination: URL) throws {
        try fileSystem.write(data, to: temporary)
        try fileSystem.synchronizeFile(temporary)
        try fileSystem.rename(temporary, to: destination)
        try fileSystem.synchronizeDirectory(destination.deletingLastPathComponent())
    }
}

enum JournalPersistenceError: Error, Equatable, LocalizedError {
    case createDirectory(path: String, code: Int32)
    case write(path: String, code: Int32)
    case synchronizeFile(path: String, code: Int32)
    case rename(source: String, destination: String, code: Int32)
    case synchronizeDirectory(path: String, code: Int32)
    case read(path: String, code: Int32)
    case remove(path: String, code: Int32)

    private static func reason(_ code: Int32) -> String {
        String(cString: strerror(code))
    }

    var errorDescription: String? {
        switch self {
        case .createDirectory(let path, let code):
            "Could not create recovery folder at \(path): \(Self.reason(code))"
        case .write(let path, let code):
            "Could not write recovery data to \(path): \(Self.reason(code))"
        case .synchronizeFile(let path, let code):
            "Could not save recovery data for \(path): \(Self.reason(code))"
        case .rename(let source, let destination, let code):
            "Could not finalize recovery file (\(source) → \(destination)): \(Self.reason(code))"
        case .synchronizeDirectory(let path, let code):
            "Could not save recovery folder \(path): \(Self.reason(code))"
        case .read(let path, let code):
            "Could not read recovery data from \(path): \(Self.reason(code))"
        case .remove(let path, let code):
            "Could not remove recovery file \(path): \(Self.reason(code))"
        }
    }
}

struct LocalJournalFileSystem: JournalFileSystem {
    func createDirectory(_ url: URL) throws {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw JournalPersistenceError.createDirectory(path: url.path, code: Self.code(for: error))
        }
    }

    func write(_ data: Data, to url: URL) throws {
        let descriptor = Darwin.open(
            url.path,
            O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            let code = errno
            throw JournalPersistenceError.write(path: url.path, code: code)
        }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        do {
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            throw JournalPersistenceError.write(path: url.path, code: Self.code(for: error))
        }
    }

    func append(_ data: Data, to url: URL) throws {
        let descriptor = Darwin.open(url.path, O_WRONLY | O_APPEND | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw JournalPersistenceError.write(path: url.path, code: errno)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        do {
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            throw JournalPersistenceError.write(path: url.path, code: Self.code(for: error))
        }
    }

    func synchronizeFile(_ url: URL) throws {
        try Self.synchronize(url, openFlags: O_RDWR) { code in
            .synchronizeFile(path: url.path, code: code)
        }
    }

    func rename(_ source: URL, to destination: URL) throws {
        let sourceParent = source.deletingLastPathComponent().standardizedFileURL
        let destinationParent = destination.deletingLastPathComponent().standardizedFileURL
        guard sourceParent == destinationParent else {
            throw JournalPersistenceError.rename(
                source: source.path,
                destination: destination.path,
                code: EXDEV
            )
        }

        let result = source.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in
                Darwin.rename(sourcePath, destinationPath)
            }
        }
        guard result == 0 else {
            let code = errno
            throw JournalPersistenceError.rename(
                source: source.path,
                destination: destination.path,
                code: code
            )
        }
    }

    func synchronizeDirectory(_ url: URL) throws {
        try Self.synchronize(url, openFlags: O_RDONLY) { code in
            .synchronizeDirectory(path: url.path, code: code)
        }
    }

    func contents(_ url: URL) throws -> [URL] {
        do {
            return try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: nil
            )
        } catch {
            throw JournalPersistenceError.read(path: url.path, code: Self.code(for: error))
        }
    }

    func read(_ url: URL) throws -> Data {
        do {
            return try Data(contentsOf: url)
        } catch {
            throw JournalPersistenceError.read(path: url.path, code: Self.code(for: error))
        }
    }

    func remove(_ url: URL) throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw JournalPersistenceError.remove(path: url.path, code: Self.code(for: error))
        }
    }

    func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private static func synchronize(
        _ url: URL,
        openFlags: Int32,
        error: (Int32) -> JournalPersistenceError
    ) throws {
        let descriptor = Darwin.open(url.path, openFlags | O_CLOEXEC)
        guard descriptor >= 0 else {
            let code = errno
            throw error(code)
        }
        defer { Darwin.close(descriptor) }

        if Darwin.fcntl(descriptor, F_FULLFSYNC) == 0 {
            return
        }
        let fullSyncCode = errno
        guard fullSyncCode == ENOTSUP || fullSyncCode == EINVAL else {
            throw error(fullSyncCode)
        }

        guard Darwin.fsync(descriptor) == 0 else {
            let code = errno
            throw error(code)
        }
    }

    private static func code(for error: Error) -> Int32 {
        let cocoaError = error as NSError
        if cocoaError.domain == NSPOSIXErrorDomain {
            return Int32(cocoaError.code)
        }
        if let underlyingError = cocoaError.userInfo[NSUnderlyingErrorKey] as? Error {
            return code(for: underlyingError)
        }
        return Int32(cocoaError.code)
    }
}
