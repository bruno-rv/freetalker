import Darwin
import Foundation

/// Codex round-2 Finding 2 (HIGH, TOCTOU between authorization and use):
/// `AutomationFileAuthorization` validates a PATHNAME, but AVFoundation's duration probe and
/// `MediaImportService`/`JobLibraryStore.importMedia` both reopen that same pathname again later,
/// across an `await`. A caller can swap the authorized file for a symlink to an unauthorized file
/// in that window — repeated swapping makes this practical, not lucky.
///
/// This closes the window by pinning the real file via a file descriptor opened with `O_NOFOLLOW`
/// at every remaining path component beneath the authorized folder — synchronously, with no
/// `await` between `AutomationFileAuthorization.authorize` returning and this running — then
/// `fstat`s that descriptor (never the path again) and copies its verified bytes into an app-owned
/// staging file. `AutomationService` runs AVFoundation and `importMedia` against the STAGING file
/// only, never the caller-controlled original path, so nothing downstream can reopen a swapped
/// target. The `fstat`-before-copy is also what makes the size ceiling meaningful: it's checked on
/// the same descriptor the bytes are read from, not on a path that could describe a different,
/// larger file by the time the copy runs.
enum AutomationMediaStaging {
    /// A copy of the authorized source file living under FreeTalker's own Application Support
    /// directory. `cleanup()` MUST be called (via `defer`) once the caller is done with `url` —
    /// typically after the import job that reads it has finished, failed, or been cancelled.
    struct StagedFile {
        let url: URL
        private let cleanupAction: () -> Void

        fileprivate init(url: URL, cleanup: @escaping () -> Void) {
            self.url = url
            self.cleanupAction = cleanup
        }

        func cleanup() { cleanupAction() }
    }

    private static let copyChunkSize = 1 << 20

    /// `canonicalFolder`/`canonicalFile` are the pair `AutomationFileAuthorization.authorize`
    /// returned. `maximumBytes` is `AutomationMediaGuard.maximumSourceFileBytes`.
    static func stage(canonicalFolder: URL, canonicalFile: URL, maximumBytes: Int64) throws -> StagedFile {
        let sourceFD = try openPinned(canonicalFolder: canonicalFolder, canonicalFile: canonicalFile)
        defer { close(sourceFD) }

        var info = stat()
        guard fstat(sourceFD, &info) == 0 else { throw AutomationError.unsupportedMediaFile }
        guard (info.st_mode & S_IFMT) == S_IFREG else { throw AutomationError.unsupportedMediaFile }
        guard info.st_size >= 0, Int64(info.st_size) <= maximumBytes else { throw AutomationError.mediaTooLarge }

        let stagingDirectory = FreeTalkerPaths.applicationSupport
            .appendingPathComponent("automation-staging", isDirectory: true)
        try FileManager.default.createDirectory(
            at: stagingDirectory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let ext = canonicalFile.pathExtension
        let stagingURL = stagingDirectory.appendingPathComponent(
            UUID().uuidString + (ext.isEmpty ? "" : "." + ext)
        )

        guard FileManager.default.createFile(
            atPath: stagingURL.path, contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw AutomationError.unsupportedMediaFile
        }
        let destinationHandle: FileHandle
        do {
            destinationHandle = try FileHandle(forWritingTo: stagingURL)
        } catch {
            try? FileManager.default.removeItem(at: stagingURL)
            throw AutomationError.unsupportedMediaFile
        }

        do {
            try copy(sourceFD: sourceFD, into: destinationHandle, maximumBytes: maximumBytes)
            try destinationHandle.close()
        } catch {
            try? destinationHandle.close()
            try? FileManager.default.removeItem(at: stagingURL)
            throw error
        }

        return StagedFile(url: stagingURL) {
            try? FileManager.default.removeItem(at: stagingURL)
        }
    }

    private static func copy(sourceFD: Int32, into destination: FileHandle, maximumBytes: Int64) throws {
        var buffer = [UInt8](repeating: 0, count: copyChunkSize)
        var totalRead: Int64 = 0
        while true {
            let bytesRead = buffer.withUnsafeMutableBytes { pointer in
                Darwin.read(sourceFD, pointer.baseAddress, pointer.count)
            }
            if bytesRead < 0 { throw AutomationError.unsupportedMediaFile }
            if bytesRead == 0 { break }
            totalRead += Int64(bytesRead)
            guard totalRead <= maximumBytes else { throw AutomationError.mediaTooLarge }
            try destination.write(contentsOf: Data(bytes: buffer, count: bytesRead))
        }
    }

    /// Walks from `canonicalFolder` down every remaining path component of `canonicalFile`,
    /// opening each with `O_NOFOLLOW` (and `O_DIRECTORY` for every component but the last) so a
    /// symlink swapped in anywhere along the path after authorization is refused — `open` fails
    /// with `ELOOP`/`ENOTDIR` rather than following it. Returns an open descriptor for the final,
    /// verified-non-symlink component; the caller is responsible for closing it.
    private static func openPinned(canonicalFolder: URL, canonicalFile: URL) throws -> Int32 {
        var folderPath = canonicalFolder.path
        if !folderPath.hasSuffix("/") { folderPath += "/" }
        guard canonicalFile.path.hasPrefix(folderPath) else { throw AutomationError.fileNotAuthorized }
        let relative = String(canonicalFile.path.dropFirst(folderPath.count))
        let components = relative.split(separator: "/").map(String.init)
        guard !components.isEmpty else { throw AutomationError.fileNotAuthorized }

        var currentFD = open(canonicalFolder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard currentFD >= 0 else { throw AutomationError.unsupportedMediaFile }

        for (index, component) in components.enumerated() {
            let isLast = index == components.count - 1
            let flags: Int32 = isLast ? (O_RDONLY | O_NOFOLLOW) : (O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            let nextFD = component.withCString { openat(currentFD, $0, flags) }
            close(currentFD)
            guard nextFD >= 0 else { throw AutomationError.unsupportedMediaFile }
            currentFD = nextFD
        }
        return currentFD
    }
}
