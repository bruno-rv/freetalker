import Darwin
import Foundation

public enum StableMediaInputError: Error, Equatable, Sendable {
    case invalidSource
    case sourceChanged
    case descriptorUnavailable
}

public struct StableMediaInput: @unchecked Sendable {
    private final class Storage: @unchecked Sendable {
        let descriptor: Int32
        init(descriptor: Int32) { self.descriptor = descriptor }
        deinit { close(descriptor) }
    }

    private struct Identity: Equatable, Sendable {
        let device: dev_t
        let inode: ino_t
        let size: off_t
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let changedSeconds: Int
        let changedNanoseconds: Int

        init(_ value: stat) {
            device = value.st_dev
            inode = value.st_ino
            size = value.st_size
            modifiedSeconds = value.st_mtimespec.tv_sec
            modifiedNanoseconds = value.st_mtimespec.tv_nsec
            changedSeconds = value.st_ctimespec.tv_sec
            changedNanoseconds = value.st_ctimespec.tv_nsec
        }
    }

    private let storage: Storage
    private let identity: Identity

    public init(opening url: URL) throws {
        guard url.isFileURL, url.path.hasPrefix("/") else {
            throw StableMediaInputError.invalidSource
        }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw StableMediaInputError.invalidSource }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG else {
            close(descriptor)
            throw StableMediaInputError.invalidSource
        }
        storage = Storage(descriptor: descriptor)
        identity = Identity(metadata)
    }

    public func withStableURL<Result: Sendable>(
        _ body: @Sendable (URL) async throws -> Result
    ) async throws -> Result {
        try verifyIdentity()
        let duplicate = fcntl(storage.descriptor, F_DUPFD_CLOEXEC, 0)
        guard duplicate >= 0 else { throw StableMediaInputError.descriptorUnavailable }
        defer { close(duplicate) }
        let result = try await body(URL(fileURLWithPath: "/dev/fd/\(duplicate)"))
        try verifyIdentity()
        return result
    }

    private func verifyIdentity() throws {
        var metadata = stat()
        guard fstat(storage.descriptor, &metadata) == 0,
              Identity(metadata) == identity else {
            throw StableMediaInputError.sourceChanged
        }
    }
}
