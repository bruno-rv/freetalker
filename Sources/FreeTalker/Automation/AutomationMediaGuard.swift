import Foundation

/// Codex round-1 Finding 4 (MEDIUM, hostile media inputs): a supported-extension FIFO, device
/// node, symlink, or a small-but-multi-hour compressed file passes the existing
/// extension/AVFoundation checks. Probing can block, decoding can consume gigabytes, and file
/// transcription holds WhisperKit's global serial gate so ordinary dictation appears hung behind
/// it. This runs after the consent check and BEFORE `importMedia`, on the canonical URL
/// `AutomationFileAuthorization.authorize` returns.
enum AutomationMediaGuard {
    // ponytail: fixed 4 GiB source-file ceiling. Generous for any legitimate WAV/M4A/MP3/MP4/MOV
    // a user would hand to Shortcuts, but bounds the "small compressed file, huge decoded
    // payload" class of hostile input at the cheapest possible check — a `stat`, before any
    // AVFoundation call ever touches the file. Upgrade path: make configurable if a real use case
    // needs bigger files.
    static let maximumSourceFileBytes: Int64 = 4 * 1024 * 1024 * 1024

    // ponytail: fixed 4-hour media-duration ceiling, checked via AVFoundation's header-only
    // duration probe before the shared import pipeline ever decodes a sample. Same reasoning as
    // the byte ceiling above.
    static let maximumMediaDurationSeconds: Double = 4 * 60 * 60

    /// Requires `url` to be a regular file that is not a symbolic link (rejects FIFOs, device
    /// nodes, directories, and symlinks — `resourceValues` is a `stat`, so this never opens or
    /// reads the file itself), and enforces `maximumSourceFileBytes`.
    static func requireRegularFile(at url: URL) throws {
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        } catch {
            throw AutomationError.unsupportedMediaFile
        }
        guard values.isSymbolicLink != true, values.isRegularFile == true else {
            throw AutomationError.unsupportedMediaFile
        }
        if let size = values.fileSize, Int64(size) > maximumSourceFileBytes {
            throw AutomationError.mediaTooLarge
        }
    }

    /// Pure comparison against `maximumMediaDurationSeconds`, split out from the AVFoundation
    /// probe itself so the bound is unit-testable without a real media asset.
    static func exceedsMaximumDuration(seconds: Double) -> Bool {
        seconds.isFinite && seconds > maximumMediaDurationSeconds
    }
}
