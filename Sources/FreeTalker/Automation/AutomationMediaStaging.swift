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
///
/// Codex round-3 Finding 3 (HIGH, hostile staging I/O freezes the main actor): two more concrete
/// inputs closed here. `mkfifo Allowed/hang.wav` used to block the final `openat(O_RDONLY)`
/// forever — before `fstat` ever got a chance to reject it — because a FIFO's blocking open()
/// waits for a writer that never arrives. The final open below adds `O_NONBLOCK`: a FIFO opened
/// this way returns immediately (POSIX), so `fstat` sees it, `S_IFIFO != S_IFREG`, and it's
/// rejected exactly like today's other non-regular-file cases — no wait, ever. Second: a permitted
/// multi-GiB source used to be copied SYNCHRONOUSLY ON `@MainActor` (`AutomationService` ran this
/// whole enum directly on the actor it also uses for hotkeys, Settings, and ordinary dictation) —
/// `AutomationService.authorizeAndStage` is now `nonisolated` and runs as a `withThrowingTaskGroup`
/// child task racing the 2-hour deadline, so it's scheduled off the main actor from the start
/// (never pinned to it the way a member of `@MainActor enum AutomationService` is by default), and
/// `copy` below checks `Task.isCancelled` between chunks so a request that outlives that deadline
/// (Codex round-1 Finding 7) doesn't have to run to completion before cancellation is observed —
/// a real structured child task's cancellation, unlike `Task.detached`'s, IS what the group's
/// `cancelAll()` sets.
enum AutomationMediaStaging {
    /// A copy of the authorized source file living under FreeTalker's own Application Support
    /// directory. `cleanup()` MUST be called once the caller is done with `url` — but NOT via an
    /// unconditional lexical `defer` around every call site: Codex round-3 Finding 6 requires this
    /// file's lifetime to match the durable import job it becomes the source of, not the lexical
    /// scope of the function that created it. See `AutomationService.authorizeStageAndTranscribe`,
    /// `MediaImportPipeline.execute`, `JobLibraryStore.deleteImport`, and `purgeOrphans` below for
    /// the four points that actually call `cleanup()`/`removeIfStaged`.
    ///
    /// `Sendable` (the cleanup closure is `@Sendable`) so a `StagedFile` produced inside
    /// `Task.detached` (off the main actor — see the type doc comment) can be returned across that
    /// boundary without further ceremony.
    struct StagedFile: Sendable {
        let url: URL
        private let cleanupAction: @Sendable () -> Void

        fileprivate init(url: URL, cleanup: @escaping @Sendable () -> Void) {
            self.url = url
            self.cleanupAction = cleanup
        }

        func cleanup() { cleanupAction() }
    }

    private static let copyChunkSize = 1 << 20

    /// The app-owned directory every staged copy lives under. Exposed (not just used internally by
    /// `stage`) so `isStagingPath`/`removeIfStaged`/`purgeOrphans` below, and callers elsewhere in
    /// the media-import pipeline, can recognize a staged source without duplicating this path.
    static var stagingDirectoryURL: URL {
        FreeTalkerPaths.applicationSupport.appendingPathComponent("automation-staging", isDirectory: true)
    }

    /// `canonicalFolder`/`canonicalFile`/`folderIdentity` are what
    /// `AutomationFileAuthorization.authorize` returned. `maximumBytes` is
    /// `AutomationMediaGuard.maximumSourceFileBytes`.
    static func stage(
        canonicalFolder: URL,
        canonicalFile: URL,
        folderIdentity: AutomationFileAuthorization.FileIdentity,
        maximumBytes: Int64
    ) throws -> StagedFile {
        let sourceFD = try openPinned(
            canonicalFolder: canonicalFolder, canonicalFile: canonicalFile, expectedFolderIdentity: folderIdentity
        )
        defer { close(sourceFD) }

        var info = stat()
        guard fstat(sourceFD, &info) == 0 else { throw AutomationError.unsupportedMediaFile }
        guard (info.st_mode & S_IFMT) == S_IFREG else { throw AutomationError.unsupportedMediaFile }
        guard info.st_size >= 0, Int64(info.st_size) <= maximumBytes else { throw AutomationError.mediaTooLarge }

        try FileManager.default.createDirectory(
            at: stagingDirectoryURL, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let ext = canonicalFile.pathExtension
        let stagingURL = stagingDirectoryURL.appendingPathComponent(
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

    /// Codex round-3 Finding 3: checks `Task.isCancelled` once per chunk (this function runs
    /// synchronously inside `Task.detached` — no `await` points of its own — but `Task.isCancelled`
    /// still observes the enclosing task's cancellation, set when `AutomationService`'s 2-hour
    /// deadline fires). Bounds how long a legitimate large copy keeps running after cancellation
    /// instead of always running to completion first.
    private static func copy(sourceFD: Int32, into destination: FileHandle, maximumBytes: Int64) throws {
        var buffer = [UInt8](repeating: 0, count: copyChunkSize)
        var totalRead: Int64 = 0
        while true {
            guard !Task.isCancelled else { throw AutomationError.timedOut }
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
    /// with `ELOOP`/`ENOTDIR` rather than following it. The final component additionally sets
    /// `O_NONBLOCK` (Codex round-3 Finding 3) so a FIFO planted at that path returns immediately
    /// instead of blocking forever waiting for a writer — `fstat` then rejects it as non-regular,
    /// same as any other special file. Returns an open descriptor for the final, verified-non-
    /// symlink component; the caller is responsible for closing it.
    private static func openPinned(
        canonicalFolder: URL,
        canonicalFile: URL,
        expectedFolderIdentity: AutomationFileAuthorization.FileIdentity
    ) throws -> Int32 {
        var folderPath = canonicalFolder.path
        if !folderPath.hasSuffix("/") { folderPath += "/" }
        guard canonicalFile.path.hasPrefix(folderPath) else { throw AutomationError.fileNotAuthorized }
        let relative = String(canonicalFile.path.dropFirst(folderPath.count))
        let components = relative.split(separator: "/").map(String.init)
        guard !components.isEmpty else { throw AutomationError.fileNotAuthorized }

        var currentFD = open(canonicalFolder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard currentFD >= 0 else { throw AutomationError.unsupportedMediaFile }

        // Codex round-3 additional finding: this reopened the authorized root BY PATHNAME with no
        // check that the real directory object still matches what `authorize` validated moments
        // earlier — a same-user process that deletes/replaces the real directory at that path in
        // the gap between the two would otherwise be silently trusted. `fstat` the reopen and
        // compare device+inode against the identity `authorize` captured.
        var folderInfo = stat()
        guard fstat(currentFD, &folderInfo) == 0,
              folderInfo.st_dev == expectedFolderIdentity.device,
              folderInfo.st_ino == expectedFolderIdentity.inode else {
            close(currentFD)
            throw AutomationError.automationFolderUnavailable
        }

        for (index, component) in components.enumerated() {
            let isLast = index == components.count - 1
            let flags: Int32 = isLast
                ? (O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
                : (O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            let nextFD = component.withCString { openat(currentFD, $0, flags) }
            close(currentFD)
            guard nextFD >= 0 else { throw AutomationError.unsupportedMediaFile }
            currentFD = nextFD
        }
        return currentFD
    }

    /// Codex round-3 Finding 6: `true` iff `path` is inside `stagingDirectoryURL` — the ONLY files
    /// this enum, or anything downstream, may ever delete. A regular (non-automation) import's
    /// source is the user's own file and must never be touched by any of the functions below.
    static func isStagingPath(_ path: String) -> Bool {
        let target = URL(fileURLWithPath: path).standardizedFileURL.path
        var directory = stagingDirectoryURL.standardizedFileURL.path
        if !directory.hasSuffix("/") { directory += "/" }
        return target.hasPrefix(directory)
    }

    /// Deletes the staged source at `path` — a no-op unless `path` is actually inside the staging
    /// directory (see `isStagingPath`), so this is always safe to call speculatively against a job
    /// whose `source.reference` might be a user's real file. Codex round-3 Finding 6: called once
    /// decode has durably checkpointed (`MediaImportPipeline.execute`) or the job that owns the
    /// staged source is deleted (`JobLibraryStore.deleteImport`) — never by a lexical `defer`
    /// around the request that created it, which would delete a source a failed/cancelled job's
    /// Retry still needs.
    static func removeIfStaged(atPath path: String, fileManager: FileManager = .default) {
        guard isStagingPath(path) else { return }
        try? fileManager.removeItem(atPath: path)
    }

    /// Codex round-3 Finding 6 (startup reconciliation): a crash or SIGKILL between staging a file
    /// and either checkpointing its job's decode or cleaning it up on failure leaves that file
    /// behind forever — nothing else ever revisits it. Deletes every file under the staging
    /// directory whose path isn't in `keepPaths` (the still-pending-decode import jobs' sources —
    /// see `AppCoordinator.launchMediaImportWorkflows`). Safe to call unconditionally: an absent or
    /// empty staging directory is a no-op.
    static func purgeOrphans(keeping keepPaths: Set<String>, fileManager: FileManager = .default) {
        let keep = Set(keepPaths.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        guard let entries = try? fileManager.contentsOfDirectory(
            at: stagingDirectoryURL, includingPropertiesForKeys: nil
        ) else { return }
        for entry in entries where !keep.contains(entry.standardizedFileURL.path) {
            try? fileManager.removeItem(at: entry)
        }
    }
}
