import CoreMedia
import Foundation

/// Codex round-1 Finding 4 (MEDIUM, hostile media inputs): a supported-extension FIFO, device
/// node, symlink, or a small-but-multi-hour compressed file passes the existing
/// extension/AVFoundation checks. Probing can block, decoding can consume gigabytes, and file
/// transcription holds WhisperKit's global serial gate so ordinary dictation appears hung behind
/// it.
///
/// Codex round-2 Finding 2 (HIGH, TOCTOU): the regular-file/not-a-symlink/size check used to run
/// against the caller-supplied PATHNAME (`resourceValues`, a `stat`), which a caller could swap
/// out from under it before the later, separately-timed AVFoundation/import calls reopened that
/// same pathname. That check has moved into `AutomationMediaStaging`, which performs the
/// equivalent regular-file/size validation via `fstat` on a file descriptor pinned with
/// `O_NOFOLLOW` — a `stat`-on-a-path can never be TOCTOU-safe the way an `fstat`-on-an-already-open
/// descriptor is, so this file no longer offers a path-based version of that check.
enum AutomationMediaGuard {
    // ponytail: fixed 4 GiB source-file ceiling. Generous for any legitimate WAV/M4A/MP3/MP4/MOV
    // a user would hand to Shortcuts, but bounds the "small compressed file, huge decoded
    // payload" class of hostile input at the cheapest possible check — an `fstat`, before any
    // AVFoundation call ever touches the file. Upgrade path: make configurable if a real use case
    // needs bigger files.
    static let maximumSourceFileBytes: Int64 = 4 * 1024 * 1024 * 1024

    // ponytail: fixed 4-hour media-duration ceiling, checked via AVFoundation's header-only
    // duration probe before the shared import pipeline ever decodes a sample. Same reasoning as
    // the byte ceiling above.
    static let maximumMediaDurationSeconds: Double = 4 * 60 * 60

    /// Codex round-2 Finding 5 (MEDIUM, fail-open duration ceiling): a thrown duration load, or an
    /// indefinite/NaN/infinite value, used to skip rejection instead of failing it — so a playable
    /// fragmented file with indefinite duration bypassed the four-hour guard entirely. This is now
    /// the single, explicit acceptance test: `AutomationService` requires the duration load to
    /// SUCCEED and requires `.isValid`, then passes the numeric seconds here — anything not
    /// finite, non-negative, and within the ceiling is rejected. There is no default-accept path.
    static func isDurationWithinLimit(seconds: Double) -> Bool {
        seconds.isFinite && seconds >= 0 && seconds <= maximumMediaDurationSeconds
    }

    /// The single acceptance test `AutomationService` runs before `importMedia`. `load` is
    /// injected (rather than calling `AVURLAsset.load(.duration)` directly) purely so this is
    /// unit-testable with fake success/failure/indefinite-duration closures without a real media
    /// asset — production always passes `{ try await asset.load(.duration) }`.
    ///
    /// A thrown `load()`, an invalid `CMTime`, or a non-finite/negative/over-ceiling seconds value
    /// (including `.indefinite`, whose `.seconds` is NaN, and `.positiveInfinity`) all reject —
    /// there is no default-accept path (Codex round-2 Finding 5).
    static func validateDuration(load: @Sendable () async throws -> CMTime) async throws {
        let duration: CMTime
        do {
            duration = try await load()
        } catch {
            throw AutomationError.mediaTooLarge
        }
        guard duration.isValid, isDurationWithinLimit(seconds: duration.seconds) else {
            throw AutomationError.mediaTooLarge
        }
    }
}
