import Darwin
import Foundation

final class OwnedJobDirectory: @unchecked Sendable {
    struct TemporaryFile {
        let name: String
        let descriptor: Int32
        let url: URL
    }

    let directoryURL: URL
    private let rootDescriptor: Int32
    private let directoryDescriptor: Int32
    private let jobName: String
    private let openedDevice: dev_t
    private let openedInode: ino_t

    init(root: URL, jobID: UUID, create: Bool) throws {
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        rootDescriptor = open(canonicalRoot.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard rootDescriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let name = jobID.uuidString
        jobName = name
        if create, mkdirat(rootDescriptor, name, S_IRWXU) != 0, errno != EEXIST {
            Darwin.close(rootDescriptor); throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        directoryDescriptor = openat(rootDescriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directoryDescriptor >= 0 else { Darwin.close(rootDescriptor); throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var opened = stat()
        guard fstat(directoryDescriptor, &opened) == 0 else { Darwin.close(directoryDescriptor); Darwin.close(rootDescriptor); throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        openedDevice = opened.st_dev
        openedInode = opened.st_ino
        directoryURL = canonicalRoot.appendingPathComponent(name, isDirectory: true)
    }

    deinit { Darwin.close(directoryDescriptor); Darwin.close(rootDescriptor) }

    func createTemporaryFile() throws -> TemporaryFile {
        let name = ".decode-\(UUID().uuidString).wav"
        let descriptor = openat(directoryDescriptor, name, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return TemporaryFile(name: name, descriptor: descriptor, url: URL(fileURLWithPath: "/dev/fd/\(descriptor)"))
    }

    func openExisting(_ basename: String) throws -> TemporaryFile {
        let descriptor = openat(directoryDescriptor, basename, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { Darwin.close(descriptor); throw POSIXError(.EFTYPE) }
        return TemporaryFile(name: basename, descriptor: descriptor, url: URL(fileURLWithPath: "/dev/fd/\(descriptor)"))
    }

    func close(_ temporary: TemporaryFile) { Darwin.close(temporary.descriptor) }
    func discard(_ temporary: TemporaryFile) { _ = unlinkat(directoryDescriptor, temporary.name, 0) }
    func rewind(_ temporary: TemporaryFile) { _ = lseek(temporary.descriptor, 0, SEEK_SET) }

    func isNormalizedWAV(_ temporary: TemporaryFile) -> Bool {
        var bytes = [UInt8](repeating: 0, count: 256)
        let count = pread(temporary.descriptor, &bytes, bytes.count, 0)
        guard count >= 36, String(bytes: bytes[0..<4], encoding: .ascii) == "RIFF",
              String(bytes: bytes[8..<12], encoding: .ascii) == "WAVE" else { return false }
        var offset = 12
        while offset + 8 <= count {
            let size = Int(UInt32(bytes[offset + 4]) | UInt32(bytes[offset + 5]) << 8 | UInt32(bytes[offset + 6]) << 16 | UInt32(bytes[offset + 7]) << 24)
            if String(bytes: bytes[offset..<(offset + 4)], encoding: .ascii) == "fmt ", offset + 16 <= count {
                let channels = UInt16(bytes[offset + 10]) | UInt16(bytes[offset + 11]) << 8
                let rate = UInt32(bytes[offset + 12]) | UInt32(bytes[offset + 13]) << 8 | UInt32(bytes[offset + 14]) << 16 | UInt32(bytes[offset + 15]) << 24
                return channels == 1 && rate == 16_000
            }
            offset += 8 + size + (size & 1)
        }
        return false
    }

    func promote(_ temporary: TemporaryFile, to basename: String) throws -> URL {
        try revalidateIdentity()
        var info = stat()
        guard fstat(temporary.descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw POSIXError(.EFTYPE) }
        guard renameatx_np(directoryDescriptor, temporary.name, directoryDescriptor, basename, UInt32(RENAME_EXCL)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return directoryURL.appendingPathComponent(basename)
    }

    func revalidateIdentity() throws {
        var current = stat()
        guard fstatat(rootDescriptor, jobName, &current, AT_SYMLINK_NOFOLLOW) == 0,
              (current.st_mode & S_IFMT) == S_IFDIR,
              current.st_dev == openedDevice, current.st_ino == openedInode else {
            throw JobStoreError.corruptData("Media job directory identity changed")
        }
    }

    func unlinkRegistered(path: String, source: URL, fileManager: FileManager) throws {
        let lexical = URL(fileURLWithPath: path).standardizedFileURL
        guard lexical.deletingLastPathComponent() == directoryURL,
              lexical.lastPathComponent != ".", lexical.lastPathComponent != ".." else {
            throw JobStoreError.corruptData("A derived file is not a direct job artifact")
        }
        var info = stat()
        if fstatat(directoryDescriptor, lexical.lastPathComponent, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else { throw JobStoreError.corruptData("A derived artifact is not a regular file") }
        var sourceInfo = stat()
        if stat(source.standardizedFileURL.resolvingSymlinksInPath().path, &sourceInfo) == 0,
           info.st_dev == sourceInfo.st_dev, info.st_ino == sourceInfo.st_ino {
            throw JobStoreError.corruptData("A derived file aliases the imported source")
        }
        guard unlinkat(directoryDescriptor, lexical.lastPathComponent, 0) == 0 || errno == ENOENT else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    func removeInvalidArtifact(_ basename: String, source: URL) throws {
        try revalidateIdentity()
        var info = stat()
        if fstatat(directoryDescriptor, basename, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard (info.st_mode & S_IFMT) != S_IFDIR else { throw JobStoreError.corruptData("Invalid artifact is a directory") }
        var sourceInfo = stat()
        if (info.st_mode & S_IFMT) == S_IFREG,
           stat(source.standardizedFileURL.resolvingSymlinksInPath().path, &sourceInfo) == 0,
           info.st_dev == sourceInfo.st_dev, info.st_ino == sourceInfo.st_ino {
            throw JobStoreError.corruptData("Invalid artifact aliases the imported source")
        }
        guard unlinkat(directoryDescriptor, basename, 0) == 0 || errno == ENOENT else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}
